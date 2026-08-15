// SPDX-License-Identifier: AGPL-3.0-or-later

//! Audio-based DualSense haptics via SDL3. The controller's voice-coil
//! actuators are driven by its 4-channel USB audio stream at 48 kHz/16-bit:
//! FL/FR = speakers, RL/RR = haptic motors. This module streams synthesized
//! PCM; callers publish per-channel intensity and frequency.
//!
//! Per-channel pipeline: gamma low-boost -> attack/release envelope ->
//! freshness envelope -> textured harmonic oscillator. The freshness envelope
//! fades to silence shortly after the last published intensity.

const std = @import("std");
const sdl = @import("sdl_c.zig");
const c = sdl.c;
const platform = @import("hardware/platform.zig");
const config = @import("config.zig");
const audio_device = @import("hardware/audio_device.zig");

const print = std.debug.print;

const SAMPLE_RATE: u32 = 48_000;
const CHANNELS: u32 = 4;
const SAMPLE_BYTES: u32 = 2; // S16LE
const FRAME_BYTES: u32 = CHANNELS * SAMPLE_BYTES;

/// Fade to silence this long after the last published intensity.
const FRESH_TIMEOUT_MS: i64 = 250;

const GAMMA: f32 = 2.2; // perceptual low-boost: output = input^(1/GAMMA)
const ATTACK_COEFF: f32 = 0.02; // amp attack (~1 ms time constant)
const RELEASE_COEFF: f32 = 0.004; // amp release (~5 ms)
const FREQ_COEFF: f32 = 0.008; // oscillator frequency smoothing (~2.6 ms)
const FRESH_COEFF: f32 = 0.002; // freshness envelope (~10 ms)
const HARMONICS = [_]f32{ 1.0, 0.35, 0.12 }; // fundamental, 2nd, 3rd harmonic

/// Per-channel render state, touched only by the SDL audio thread.
const ChanState = struct {
    phase: f32 = 0,
    freq: f32 = 0,
    amp: f32 = 0,
    lp: f32 = 0, // low-passed noise state for texture
};

/// SDL-backed audio renderer for the DualSense USB haptic channels.
pub const AudioHaptics = struct {
    io: std.Io = undefined,
    stream: ?*c.SDL_AudioStream = null,
    sdl_inited: bool = false,

    sink_name: []const u8 = config.DEFAULT_AUDIO_SINK,
    /// Read by the audio thread; set before `start` and never mutated after.
    gain: f32 = 0.75,

    // published by the main loop, read by the SDL audio thread
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    l_amp: std.atomic.Value(f32) = std.atomic.Value(f32).init(0),
    r_amp: std.atomic.Value(f32) = std.atomic.Value(f32).init(0),
    l_freq: std.atomic.Value(f32) = std.atomic.Value(f32).init(90),
    r_freq: std.atomic.Value(f32) = std.atomic.Value(f32).init(90),

    // render state, touched only by the SDL audio thread
    chan_l: ChanState = .{},
    chan_r: ChanState = .{},
    noise_state: u32 = 0x9E3779B9,
    fresh_env: f32 = 0,

    /// Drives the freshness timeout.
    last_update: std.atomic.Value(i64) = std.atomic.Value(i64).init(-1_000_000),

    /// >= 0: emit a fixed test tone on this channel only (0=FL..3=RR).
    test_channel: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),

    /// Render scratch; SDL requests at most ~10 ms at a time.
    render_buf: [8192]u8 align(2) = [_]u8{0} ** 8192,

    /// Inits SDL audio and opens the DualSense playback sink.
    pub fn start(self: *AudioHaptics, io: std.Io) bool {
        self.io = io;
        // Keep our own SIGINT/SIGTERM handlers; SDL's would swallow them.
        _ = c.SDL_SetHint("SDL_NO_SIGNAL_HANDLERS", "1");
        if (!c.SDL_InitSubSystem(c.SDL_INIT_AUDIO)) {
            print("audio: SDL_InitSubSystem(SDL_INIT_AUDIO) failed: {s}\n", .{sdlError()});
            return false;
        }
        self.sdl_inited = true;

        const phys = audio_device.findDevice(self.sink_name) orelse {
            return false;
        };

        var spec: c.SDL_AudioSpec = .{
            .format = c.SDL_AUDIO_S16,
            .channels = @intCast(CHANNELS),
            .freq = @intCast(SAMPLE_RATE),
        };

        // SDL resamples/remixes to the physical device.
        self.stream = c.SDL_OpenAudioDeviceStream(phys, &spec, onAudio, self) orelse {
            print("audio: SDL_OpenAudioDeviceStream failed: {s}\n", .{sdlError()});
            return false;
        };
        if (!c.SDL_ResumeAudioStreamDevice(self.stream.?)) {
            print("audio: SDL_ResumeAudioStreamDevice failed: {s}\n", .{sdlError()});
            c.SDL_DestroyAudioStream(self.stream.?);
            self.stream = null;
            return false;
        }
        self.last_update.store(nowMillis(self.io), .monotonic);
        return true;
    }

    pub fn stop(self: *AudioHaptics) void {
        if (self.stream) |stream| {
            c.SDL_DestroyAudioStream(stream);
            self.stream = null;
        }
        if (self.sdl_inited) {
            c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
            self.sdl_inited = false;
        }
    }

    /// Publishes intensities (0..1); safe from any thread.
    pub fn setIntensity(self: *AudioHaptics, l: f32, r: f32) void {
        self.l_amp.store(std.math.clamp(finiteOrZero(l), 0, 1), .monotonic);
        self.r_amp.store(std.math.clamp(finiteOrZero(r), 0, 1), .monotonic);
        self.last_update.store(nowMillis(self.io), .monotonic);
    }

    /// Publishes target frequencies in Hz.
    pub fn setFrequency(self: *AudioHaptics, l: f32, r: f32) void {
        self.l_freq.store(finiteOrZero(l), .monotonic);
        self.r_freq.store(finiteOrZero(r), .monotonic);
        self.last_update.store(nowMillis(self.io), .monotonic);
    }

    pub fn setActive(self: *AudioHaptics, on: bool) void {
        self.active.store(on, .monotonic);
        if (on) self.last_update.store(nowMillis(self.io), .monotonic);
    }

    /// Fixed test tone on one channel (0..3), or -1 for normal rendering.
    pub fn setTestChannel(self: *AudioHaptics, channel: i32) void {
        self.test_channel.store(channel, .monotonic);
    }

    /// Fills `buf` (a multiple of FRAME_BYTES) and pushes it to SDL.
    /// Runs on the SDL audio thread.
    fn render(self: *AudioHaptics, stream: *c.SDL_AudioStream, buf: []u8) void {
        const n_frames = buf.len / FRAME_BYTES;

        const active = self.active.load(.monotonic);
        const l_amp = self.l_amp.load(.monotonic);
        const r_amp = self.r_amp.load(.monotonic);
        const l_freq = self.l_freq.load(.monotonic);
        const r_freq = self.r_freq.load(.monotonic);
        const test_channel = self.test_channel.load(.monotonic);

        // Freshness target: fade out when telemetry stops publishing.
        // (Checked once per buffer; the ~250 ms granularity doesn't need more.)
        const elapsed_ms = nowMillis(self.io) - self.last_update.load(.monotonic);
        const fresh_target: f32 = if (elapsed_ms < FRESH_TIMEOUT_MS) 1.0 else 0.0;

        var i: usize = 0;
        const dst: [*]i16 = @ptrCast(@alignCast(buf.ptr));
        while (i < n_frames) : (i += 1) {
            // Per-sample smoothing, same cadence as the envelopes in renderChannel.
            self.fresh_env += FRESH_COEFF * (fresh_target - self.fresh_env);
            const fresh = self.fresh_env;

            var v: [4]i16 = .{ 0, 0, 0, 0 };
            if (test_channel >= 0) {
                const chan: usize = @intCast(@min(test_channel, 3));
                v[chan] = testTone(&self.chan_l.phase);
            } else {
                // Zero targets keep envelopes decaying, not clicking off.
                const l_eff = if (active) l_amp else 0;
                const r_eff = if (active) r_amp else 0;
                v[2] = @intFromFloat(renderChannel(self, &self.chan_l, l_eff, l_freq, fresh) * 32767.0 * self.gain);
                v[3] = @intFromFloat(renderChannel(self, &self.chan_r, r_eff, r_freq, fresh) * 32767.0 * self.gain);
            }
            dst[i * 4 + 0] = v[0]; // FL: left speaker, muted
            dst[i * 4 + 1] = v[1]; // FR: right speaker, muted
            dst[i * 4 + 2] = v[2]; // RL: left haptic motor
            dst[i * 4 + 3] = v[3]; // RR: right haptic motor
        }

        const bytes = n_frames * FRAME_BYTES;
        if (bytes > 0 and !c.SDL_PutAudioStreamData(stream, @ptrCast(buf.ptr), @intCast(bytes))) {
            print("audio: SDL_PutAudioStreamData failed: {s}\n", .{sdlError()});
        }
    }
};

/// SDL callback filling the requested audio buffer.
fn onAudio(userdata: ?*anyopaque, stream: ?*c.SDL_AudioStream, additional_amount: c_int, total_amount: c_int) callconv(.c) void {
    _ = total_amount;
    const self: *AudioHaptics = @ptrCast(@alignCast(userdata orelse return));
    const s = stream orelse return;
    if (additional_amount <= 0) return;
    var want: usize = @intCast(additional_amount);
    want = @min(want, self.render_buf.len);
    want = (want / FRAME_BYTES) * FRAME_BYTES;
    if (want == 0) return;
    self.render(s, self.render_buf[0..want]);
}

/// Fixed ~100 Hz tone for the channel sweep test.
fn testTone(phase: *f32) i16 {
    phase.* += 2.0 * std.math.pi * 100.0 / @as(f32, @floatFromInt(SAMPLE_RATE));
    if (phase.* > 2.0 * std.math.pi) phase.* -= 2.0 * std.math.pi;
    return @intFromFloat(@sin(phase.*) * 20000.0);
}

/// One sample of the per-channel pipeline; returns -1..1.
fn renderChannel(self: *AudioHaptics, ch: *ChanState, amp_target: f32, freq_target: f32, fresh: f32) f32 {
    // Gamma curve boosts low intensities so weak vibration stays perceptible.
    const a = std.math.clamp(finiteOrZero(amp_target), 0, 1);
    const boosted = std.math.pow(f32, a, 1.0 / GAMMA);
    ch.amp += (if (boosted > ch.amp) ATTACK_COEFF else RELEASE_COEFF) * (boosted - ch.amp);
    if (ch.amp < 0.0005) {
        ch.amp = 0;
        ch.freq = 0;
        ch.phase = 0;
        ch.lp = 0;
        return 0;
    }

    // Ramp toward the target frequency so jumps don't click.
    ch.freq += FREQ_COEFF * (finiteOrZero(freq_target) - ch.freq);
    if (ch.freq < 1) ch.freq = 1;

    // Low-passed noise plus harmonic tone reads as vibration, not a sine.
    self.noise_state = self.noise_state *% 1664525 +% 1013904223;
    const noise = @as(f32, @floatFromInt(@as(i32, @bitCast(self.noise_state)) >> 8)) / 8388608.0;
    ch.lp += 0.12 * (noise - ch.lp);

    ch.phase += 2.0 * std.math.pi * ch.freq / @as(f32, @floatFromInt(SAMPLE_RATE));
    if (ch.phase > 2.0 * std.math.pi) ch.phase -= 2.0 * std.math.pi;

    var tone: f32 = 0;
    for (HARMONICS, 0..) |weight, i| {
        tone += weight * @sin(ch.phase * @as(f32, @floatFromInt(i + 1)));
    }
    const tone_norm = tone / (HARMONICS[0] + HARMONICS[1] + HARMONICS[2]);

    const s = (0.55 * ch.lp + 0.45 * tone_norm) * ch.amp * fresh;
    return std.math.clamp(s, -1, 1);
}

fn nowMillis(io: std.Io) i64 {
    return platform.nowMillis(io);
}

fn sdlError() []const u8 {
    return if (c.SDL_GetError()) |p| std.mem.span(p) else "unknown SDL error";
}

fn finiteOrZero(value: f32) f32 {
    return if (std.math.isFinite(value)) value else 0;
}
