// SPDX-License-Identifier: AGPL-3.0-or-later

//! Audio-based DualSense haptics via SDL3.
//!
//! The controller's voice-coil actuators are driven by its USB audio stream
//! (4 channels at 48 kHz / 16-bit). The DualSense exposes itself as a 4-channel
//! device where the front channels are the built-in speaker and the *rear*
//! channels are the haptic motors: FL=left speaker, FR=right speaker,
//! RL=left haptic, RR=right haptic. This module streams synthesized PCM to the
//! controller over SDL3 audio (PipeWire/ALSA on Linux, WASAPI on Windows), so
//! the telemetry loop only has to publish per-channel intensities and the
//! renderer produces the waveform.
//!
//! The DualSense playback device is located by matching a substring of its SDL
//! device name (default "dualsense"), overridable with `--audio-sink`.
//!
//! Rendering pipeline per channel: clamp -> gamma low-boost -> attack/release
//! envelope -> freshness envelope -> textured harmonic oscillator -> clamp.
//! The freshness envelope fades the stream to silence a fixed time after the
//! last published intensity, so a dead telemetry source can't leave the
//! controller buzzing.

const std = @import("std");
const sdl = @import("sdl_c.zig");
const c = sdl.c;
const platform = @import("platform.zig");
const config = @import("config.zig");

const print = std.debug.print;

const SAMPLE_RATE: u32 = 48_000;
const CHANNELS: u32 = 4;
const SAMPLE_BYTES: u32 = 2; // S16LE
const FRAME_BYTES: u32 = CHANNELS * SAMPLE_BYTES;

/// Fade the stream to silence this long after the last published intensity.
const FRESH_TIMEOUT_MS: i64 = 250;

// Synthesis pipeline constants.
const GAMMA: f32 = 2.2; // perceptual low-boost: output = input^(1/GAMMA)
const ATTACK_COEFF: f32 = 0.02; // amp attack (~1 ms time constant)
const RELEASE_COEFF: f32 = 0.004; // amp release (~5 ms)
const FREQ_COEFF: f32 = 0.008; // oscillator frequency smoothing (~2.6 ms)
const FRESH_COEFF: f32 = 0.002; // freshness envelope (~10 ms)
const HARMONICS = [_]f32{ 1.0, 0.35, 0.12 }; // fundamental, 2nd, 3rd harmonic

/// Per-channel render state for the smoothed oscillator and envelope. Touched
/// only by the SDL audio thread.
const ChanState = struct {
    phase: f32 = 0,
    freq: f32 = 0,
    amp: f32 = 0,
    lp: f32 = 0, // low-passed noise state for texture
};

pub const AudioHaptics = struct {
    io: std.Io = undefined,
    stream: ?*c.SDL_AudioStream = null,
    sdl_inited: bool = false,

    sink_name: []const u8 = config.DEFAULT_AUDIO_SINK,
    gain: f32 = 0.75,

    // published by the telemetry thread, read by the SDL audio thread
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

    /// Monotonic ms of the last published intensity; drives the freshness
    /// timeout that fades the stream to silence if telemetry stops.
    last_update: std.atomic.Value(i64) = std.atomic.Value(i64).init(-1_000_000),

    /// >= 0: emit a fixed test tone on this channel only (0=FL..3=RR).
    test_channel: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),

    /// Render scratch buffer, touched only by the SDL audio thread. The SDL
    /// callback asks for up to ~10 ms at a time, well under this size.
    render_buf: [8192]u8 align(2) = [_]u8{0} ** 8192,

    pub fn start(self: *AudioHaptics, io: std.Io) bool {
        self.io = io;
        // Don't let SDL install SIGINT/SIGTERM handlers: those would swallow
        // Ctrl-C/systemd's TERM and turn them into a quit event we never poll,
        // leaving the process unkillable.
        _ = c.SDL_SetHint("SDL_NO_SIGNAL_HANDLERS", "1");
        if (!c.SDL_InitSubSystem(c.SDL_INIT_AUDIO)) {
            print("audio: SDL_InitSubSystem(SDL_INIT_AUDIO) failed: {s}\n", .{sdlError()});
            return false;
        }
        self.sdl_inited = true;

        const phys = self.findDevice() orelse {
            return false;
        };

        var spec: c.SDL_AudioSpec = .{
            .format = c.SDL_AUDIO_S16,
            .channels = @intCast(CHANNELS),
            .freq = @intCast(SAMPLE_RATE),
        };

        // The stream takes our S16 4ch 48k data and SDL resamples/remixes it
        // to whatever the physical device needs.
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

    /// Publish per-channel intensities (0..1) and frequencies (Hz) for the
    /// next render period. Safe to call from any thread.
    pub fn setIntensity(self: *AudioHaptics, l: f32, r: f32) void {
        self.l_amp.store(std.math.clamp(finiteOrZero(l), 0, 1), .monotonic);
        self.r_amp.store(std.math.clamp(finiteOrZero(r), 0, 1), .monotonic);
        self.last_update.store(nowMillis(self.io), .monotonic);
    }

    pub fn setFrequency(self: *AudioHaptics, l: f32, r: f32) void {
        self.l_freq.store(finiteOrZero(l), .monotonic);
        self.r_freq.store(finiteOrZero(r), .monotonic);
        self.last_update.store(nowMillis(self.io), .monotonic);
    }

    pub fn setActive(self: *AudioHaptics, on: bool) void {
        self.active.store(on, .monotonic);
        if (on) self.last_update.store(nowMillis(self.io), .monotonic);
    }

    /// Emit a fixed test tone on a single channel (0..3), or -1 for normal
    /// haptics rendering. For verifying which physical actuator each channel
    /// drives.
    pub fn setTestChannel(self: *AudioHaptics, channel: i32) void {
        self.test_channel.store(channel, .monotonic);
    }

    /// Picks the DualSense playback device by name substring. On failure,
    /// lists the available playback devices so `--audio-sink` can be chosen.
    fn findDevice(self: *AudioHaptics) ?c.SDL_AudioDeviceID {
        var count: c_int = 0;
        const devs = c.SDL_GetAudioPlaybackDevices(&count) orelse {
            print("audio: SDL_GetAudioPlaybackDevices failed: {s}\n", .{sdlError()});
            return null;
        };
        defer c.SDL_free(@ptrCast(devs));

        var i: c_int = 0;
        while (i < count) : (i += 1) {
            const name = c.SDL_GetAudioDeviceName(devs[@intCast(i)]) orelse continue;
            if (containsIgnoreCase(std.mem.span(name), self.sink_name)) {
                print("audio: using playback device '{s}'\n", .{std.mem.span(name)});
                return devs[@intCast(i)];
            }
        }

        print("audio: no playback device matching '{s}' (use --audio-sink <substring>)\n", .{self.sink_name});
        i = 0;
        while (i < count) : (i += 1) {
            if (c.SDL_GetAudioDeviceName(devs[@intCast(i)])) |name| {
                print("audio:   device: {s}\n", .{std.mem.span(name)});
            }
        }
        return null;
    }

    /// Render `buf.len` bytes (a multiple of FRAME_BYTES) and push them into
    /// the SDL stream. Runs on the SDL audio thread.
    fn render(self: *AudioHaptics, stream: *c.SDL_AudioStream, buf: []u8) void {
        const n_frames = buf.len / FRAME_BYTES;

        const active = self.active.load(.monotonic);
        const l_amp = self.l_amp.load(.monotonic);
        const r_amp = self.r_amp.load(.monotonic);
        const l_freq = self.l_freq.load(.monotonic);
        const r_freq = self.r_freq.load(.monotonic);
        const test_channel = self.test_channel.load(.monotonic);

        // Freshness envelope: fade to silence shortly after the telemetry
        // thread stops publishing (game paused, process died, ...).
        const elapsed_ms = nowMillis(self.io) - self.last_update.load(.monotonic);
        const fresh_target: f32 = if (elapsed_ms < FRESH_TIMEOUT_MS) 1.0 else 0.0;
        self.fresh_env += FRESH_COEFF * (fresh_target - self.fresh_env);
        const fresh = self.fresh_env;

        var i: usize = 0;
        const dst: [*]i16 = @ptrCast(@alignCast(buf.ptr));
        while (i < n_frames) : (i += 1) {
            var v: [4]i16 = .{ 0, 0, 0, 0 };
            if (test_channel >= 0) {
                const chan: usize = @intCast(@min(test_channel, 3));
                v[chan] = testTone(&self.chan_l.phase);
            } else {
                // Inactive channels still run through the pipeline with a zero
                // target so the envelopes decay instead of clicking off.
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

/// One sample of the haptic render pipeline: clamp -> gamma low-boost ->
/// attack/release envelope -> freshness -> textured harmonic oscillator ->
/// clamp. Returns -1..1.
fn renderChannel(self: *AudioHaptics, ch: *ChanState, amp_target: f32, freq_target: f32, fresh: f32) f32 {
    // Amp chain: clamp to [0,1], then a gamma curve that boosts low
    // intensities so weak road vibration stays perceptible.
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

    // Smoothed oscillator: ramp toward the target frequency so telemetry
    // frequency jumps don't click.
    ch.freq += FREQ_COEFF * (finiteOrZero(freq_target) - ch.freq);
    if (ch.freq < 1) ch.freq = 1;

    // Cheap textured waveform: low-passed noise plus a soft harmonic tone, so
    // it reads as vibration rather than a pure sine.
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

/// Case-insensitive substring match for SDL device names.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matches = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

fn finiteOrZero(value: f32) f32 {
    return if (std.math.isFinite(value)) value else 0;
}
