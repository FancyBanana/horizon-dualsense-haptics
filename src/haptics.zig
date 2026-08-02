// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Io = std.Io;
const parser = @import("packet_parser.zig");
const ds = @import("dualsense.zig");
const device = @import("device.zig");
const audio = @import("audio.zig");
const config = @import("config.zig");
const platform = @import("platform.zig");

const print = std.debug.print;

/// Tunables for the telemetry -> DualSense mapping.
pub const Params = struct {
    // L2 (brake)
    brake_deadzone: u8 = 40,
    brake_max_force: u8 = 200,
    brake_zone_max: u8 = 8, // top zone resistance level (1..8) at full brake
    handbrake_force: u8 = 220,
    abs_brake_threshold: u8 = 100,
    abs_slip_ratio_threshold: f32 = 0.3,
    abs_combined_slip_threshold: f32 = 0.7,
    abs_freq: u8 = 12,
    abs_amp: u8 = 160,

    // R2 (throttle)
    throttle_deadzone: u8 = 30,
    throttle_max_force: u8 = 160,
    wheelspin_accel_threshold: u8 = 30,
    wheelspin_freq_min: u8 = 60,
    wheelspin_freq_max: u8 = 160,
    wheelspin_amp: u8 = 180,
    wheelspin_slip_threshold: f32 = 1.0,
    burnout_rot_threshold: f32 = 30.0, // rad/s, wheel spun up at standstill
    rev_limit_ratio: f32 = 0.96,
    rev_limit_freq: u8 = 110,
    rev_limit_amp: u8 = 150,
    wheelspin_zone_start: u8 = 5, // zone where wheelspin vibration begins
    rev_limit_zone_start: u8 = 8, // zone where rev-limit vibration begins

    // shared
    shift_burst_freq: u8 = 20,
    shift_burst_amp: u8 = 130,
    shift_burst_ms: i128 = 80,
    low_speed_ms: f32 = 5.0, // m/s: below this trust wheel rotation, not slip
};

const AudioCue = struct {
    amp: f32 = 0,
    freq: f32 = 90,
};

fn sideAudioCue(surface: f32, wheel_rotation: f32, combined_slip: f32, on_strip: bool, puddle: f32) AudioCue {
    const slip = std.math.clamp(combined_slip, 0, 3);
    const strip_amp: f32 = if (on_strip) 0.22 else 0;
    const puddle_amp = std.math.clamp(puddle, 0, 1) * 0.08;
    const amp = std.math.clamp(std.math.clamp(surface, 0, 1) + slip * 0.10 + strip_amp + puddle_amp, 0, 1);

    const strip_freq: f32 = if (on_strip) 30 else 0;
    const puddle_freq = std.math.clamp(puddle, 0, 1) * 10;
    const freq = std.math.clamp(
        45 + std.math.clamp(wheel_rotation, 0, 120) * 1.1 + slip * 18 + strip_freq - puddle_freq,
        45,
        220,
    );
    return .{ .amp = amp, .freq = freq };
}

pub const Haptics = struct {
    device: device.Device = .{},
    params: Params = .{},
    prev_gear: ?u8 = null,
    shift_until_ms: i128 = 0,
    last_open_attempt_ms: i128 = -1_000_000,
    reconnect_interval_ms: i128 = 1_000,
    waiting_hinted: bool = false,

    /// How the main motors are driven. `audio` publishes intensities to the
    /// SDL3-backed AudioHaptics stream (motors in the hidraw report stay 0);
    /// `simple` encodes them as classic rumble bytes in the report.
    motor_mode: config.MotorMode = .simple,
    audio: ?*audio.AudioHaptics = null,

    /// Parse is done by the caller; this maps a frame to the controller.
    /// Errors are swallowed: the device is re-opened lazily on the next tick.
    pub fn update(self: *Haptics, io: Io, frame: *const parser.HorizonFrame) void {
        self.ensureConnected(io);
        self.updateAudio(frame);
        if (!self.device.connected()) return;

        const report = self.buildReport(io, frame);

        self.device.writeReport(&report) catch |err| switch (err) {
            error.WouldBlock => {}, // nonblocking: drop this frame
            else => {
                print("DualSense disconnected\n", .{});
                self.device.close();
            },
        };
    }

    /// Publishes side-specific road, slip, rumble-strip, and wheel-speed cues
    /// to the audio backend, if enabled. Amplitude follows the game's surface
    /// force while frequency follows the physical wheel state, which keeps
    /// the audio haptics from becoming one undifferentiated 90 Hz buzz.
    /// Called even when the hidraw device is not connected, so the audio
    /// haptics keep working whenever the game is streaming.
    fn updateAudio(self: *Haptics, frame: *const parser.HorizonFrame) void {
        if (self.motor_mode != .audio) return;
        const a = self.audio orelse return;
        const racing = frame.IsRaceOn != 0;
        const l = if (racing) sideAudioCue(
            max2(frame.SurfaceRumbleFl, frame.SurfaceRumbleRl),
            max2(@abs(frame.WheelRotationSpeedFl), @abs(frame.WheelRotationSpeedRl)),
            max2(@abs(frame.TireCombinedSlipFl), @abs(frame.TireCombinedSlipRl)),
            frame.WheelOnRumbleStripFl != 0 or frame.WheelOnRumbleStripRl != 0,
            max2(frame.WheelInPuddleDepthFl, frame.WheelInPuddleDepthRl),
        ) else AudioCue{};
        const r = if (racing) sideAudioCue(
            max2(frame.SurfaceRumbleFr, frame.SurfaceRumbleRr),
            max2(@abs(frame.WheelRotationSpeedFr), @abs(frame.WheelRotationSpeedRr)),
            max2(@abs(frame.TireCombinedSlipFr), @abs(frame.TireCombinedSlipRr)),
            frame.WheelOnRumbleStripFr != 0 or frame.WheelOnRumbleStripRr != 0,
            max2(frame.WheelInPuddleDepthFr, frame.WheelInPuddleDepthRr),
        ) else AudioCue{};
        a.setIntensity(l.amp, r.amp);
        a.setFrequency(l.freq, r.freq);
        a.setActive(racing);
    }

    /// Runs the telemetry -> effects mapping without touching any hardware.
    /// This is what the offline replay test (`zig build test`) exercises.
    pub fn buildReport(self: *Haptics, io: Io, frame: *const parser.HorizonFrame) ds.OutputReport {
        var report: ds.OutputReport = .{};

        self.updateMotors(frame, &report);

        if (self.motor_mode == .audio) {
            // Enable the native audio-haptics path. These are the exact flag
            // bits the kernel driver writes when it routes the internal
            // speaker and voice-coil actuators to the USB audio stream.
            report.valid_flag0 = ds.Flag0.AUDIO_HAPTICS;
            report.valid_flag1 = ds.Flag1.AUDIO_CONTROL2_ENABLE;
            report.audio_enable_bits = ds.Audio.PATH_SEL_INTERNAL_SPEAKER;
            report.speaker_volume = ds.Audio.SPEAKER_VOLUME_MAX;
            report.audio_control2 = ds.Audio.SP_PREAMP_GAIN_6DB;
        }

        const now_ms = nowMillis(io);
        self.updateGearShift(frame, now_ms);
        report.right_trigger_effect = self.rightTrigger(frame, now_ms);
        report.left_trigger_effect = self.leftTrigger(frame, now_ms);

        return report;
    }

    fn ensureConnected(self: *Haptics, io: Io) void {
        if (!self.device.connected()) {
            const now = nowMillis(io);
            if (now - self.last_open_attempt_ms < self.reconnect_interval_ms) return;
            self.last_open_attempt_ms = now;
            self.device = device.open(io) catch {
                if (!self.waiting_hinted) {
                    print("waiting for DualSense (install the udev rule if you see this forever)\n", .{});
                    self.waiting_hinted = true;
                }
                return;
            };
            self.waiting_hinted = false;
            print("DualSense connected\n", .{});
        }
    }

    /// Releases the triggers and motors, then closes the device.
    /// Safe to call when disconnected.
    pub fn shutdown(self: *Haptics) void {
        if (self.audio) |a| {
            a.setActive(false);
            a.setIntensity(0, 0);
        }
        if (!self.device.connected()) return;
        var report: ds.OutputReport = .{};
        report.right_trigger_effect = ds.effectOff();
        report.left_trigger_effect = ds.effectOff();
        _ = self.device.writeReport(&report) catch {};
        self.device.close();
    }

    fn updateMotors(self: *const Haptics, frame: *const parser.HorizonFrame, report: *ds.OutputReport) void {
        // Forza SurfaceRumble is a 0..1 per-wheel road-surface force.
        const l = max2(frame.SurfaceRumbleFl, frame.SurfaceRumbleRl);
        const r = max2(frame.SurfaceRumbleFr, frame.SurfaceRumbleRr);
        switch (self.motor_mode) {
            .simple => {
                report.motor_right = scaleMotor(r);
                report.motor_left = scaleMotor(l);
            },
            // In audio mode the voice-coil actuators are driven by the
            // synthesized stream; leave the classic rumble bytes zero.
            .audio => {},
        }
    }

    fn updateGearShift(self: *Haptics, frame: *const parser.HorizonFrame, now_ms: i128) void {
        if (self.prev_gear) |prev| {
            if (prev != frame.Gear) {
                self.shift_until_ms = now_ms + self.params.shift_burst_ms;
            }
        }
        self.prev_gear = frame.Gear;
    }

    /// Left trigger = L2 = brake.
    fn leftTrigger(self: *Haptics, frame: *const parser.HorizonFrame, now_ms: i128) ds.Effect {
        const p = self.params;
        if (frame.IsRaceOn == 0) return ds.effectOff();

        if (now_ms < self.shift_until_ms) return ds.effectVibrate(p.shift_burst_freq, p.shift_burst_amp);

        if (frame.HandBrake > 0) return ds.effectRigid(p.handbrake_force);

        if (frame.Brake >= p.abs_brake_threshold and self.isLockingUp(frame)) {
            return ds.effectVibrate(p.abs_freq, p.abs_amp);
        }

        // Resistance rises with pull depth so a hard, deep brake feels like a
        // real hydraulic pedal. `brake_zone_max` caps the top-zone level.
        const mag = ramp(frame.Brake, p.brake_deadzone, p.brake_zone_max);
        if (mag == 0) return ds.effectOff();
        return ds.effectRigidZones(risingZones(mag));
    }

    /// Right trigger = R2 = throttle.
    fn rightTrigger(self: *Haptics, frame: *const parser.HorizonFrame, now_ms: i128) ds.Effect {
        const p = self.params;
        if (frame.IsRaceOn == 0) return ds.effectOff();

        if (now_ms < self.shift_until_ms) return ds.effectVibrate(p.shift_burst_freq, p.shift_burst_amp);

        if (frame.EngineMaxRpm > 0 and frame.CurrentEngineRpm >= frame.EngineMaxRpm * p.rev_limit_ratio) {
            // Only felt at the top of the pull, where the limiter actually bites.
            return ds.effectVibrateZones(zoneBand(p.rev_limit_zone_start, zoneAmp(p.rev_limit_amp)), p.rev_limit_freq);
        }

        if (frame.Accel >= p.wheelspin_accel_threshold) {
            if (self.wheelSpinning(frame)) {
                return ds.effectVibrateZones(zoneBand(p.wheelspin_zone_start, zoneAmp(p.wheelspin_amp)), self.wheelspinFreq(frame));
            }
        }

        return ds.effectRigid(ramp(frame.Accel, p.throttle_deadzone, p.throttle_max_force));
    }

    fn isLockingUp(self: *const Haptics, frame: *const parser.HorizonFrame) bool {
        const p = self.params;
        return maxAbs4(frame.TireSlipRatioFl, frame.TireSlipRatioFr, frame.TireSlipRatioRl, frame.TireSlipRatioRr) >= p.abs_slip_ratio_threshold or
            maxAbs4(frame.TireCombinedSlipFl, frame.TireCombinedSlipFr, frame.TireCombinedSlipRl, frame.TireCombinedSlipRr) >= p.abs_combined_slip_threshold;
    }

    fn wheelSpinning(self: *const Haptics, frame: *const parser.HorizonFrame) bool {
        const p = self.params;
        if (frame.Speed > p.low_speed_ms) {
            return maxAbs4(frame.TireCombinedSlipFl, frame.TireCombinedSlipFr, frame.TireCombinedSlipRl, frame.TireCombinedSlipRr) >= p.wheelspin_slip_threshold;
        }
        // Slip ratios degenerate at standstill; trust raw wheel rotation.
        return maxAbs4(frame.WheelRotationSpeedFl, frame.WheelRotationSpeedFr, frame.WheelRotationSpeedRl, frame.WheelRotationSpeedRr) >= p.burnout_rot_threshold;
    }

    fn wheelspinFreq(self: *const Haptics, frame: *const parser.HorizonFrame) u8 {
        const p = self.params;
        const slip = maxAbs4(frame.TireCombinedSlipFl, frame.TireCombinedSlipFr, frame.TireCombinedSlipRl, frame.TireCombinedSlipRr);
        const t = std.math.clamp(slip - p.wheelspin_slip_threshold, 0, 1);
        return p.wheelspin_freq_min + @as(u8, @intFromFloat(t * (p.wheelspin_freq_max - p.wheelspin_freq_min)));
    }

    /// value 0..255 -> 0..max_force above the deadzone.
    fn ramp(value: u8, deadzone: u8, max_force: u8) u8 {
        if (value <= deadzone) return 0;
        const span = 255 - deadzone;
        const f = @as(u32, max_force) * @as(u32, value - deadzone) / span;
        return @intCast(f);
    }
};

fn scaleMotor(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0, 1) * 255.0);
}

/// Zones 0..9 with resistance rising 0..`mag` along the pull (0 => all off).
fn risingZones(mag: u8) [10]u8 {
    const m = std.math.clamp(mag, 0, 8);
    var zones: [10]u8 = undefined;
    for (0..10) |i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / 9.0;
        zones[i] = @intFromFloat(@round(t * @as(f32, @floatFromInt(m))));
    }
    return zones;
}

/// Vibration amplitude band from zone `start`..9 at level `amp` (1..8).
fn zoneBand(start: u8, amp: u8) [10]u8 {
    var zones = [_]u8{0} ** 10;
    const a = std.math.clamp(amp, 1, 8);
    for (zones[@as(usize, start)..]) |*z| z.* = a;
    return zones;
}

/// 0..255 amplitude byte -> 1..8 per-zone level.
fn zoneAmp(a: u8) u8 {
    return @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(a)) / 255.0 * 8.0, 1, 8));
}

fn max2(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}

fn maxAbs4(a: f32, b: f32, c: f32, d: f32) f32 {
    return max2(max2(@abs(a), @abs(b)), max2(@abs(c), @abs(d)));
}

fn nowMillis(io: Io) i128 {
    return @intCast(platform.nowMillis(io));
}

const CAPTURED_PACKET_SIZE = 324;

// Offline replay: run every captured packet through the mapping and check the
// produced report is structurally sane. No DualSense required.
test "replay all captured packets through the mapping" {
    var hap: Haptics = .{ .motor_mode = .audio };

    var count: usize = 0;
    var saw_racing = false;
    var saw_out_of_race = false;
    var saw_braking = false;

    var index: usize = 1;
    while (true) : (index += 1) {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "data/packet-{d}.udp", .{index});
        const file = std.Io.Dir.cwd().openFile(std.testing.io, path, .{ .mode = .read_only }) catch break;
        defer file.close(std.testing.io);

        var buf: [CAPTURED_PACKET_SIZE]u8 = undefined;
        const n = try file.readStreaming(std.testing.io, &.{buf[0..]});
        if (n != CAPTURED_PACKET_SIZE) return error.UnexpectedEndOfStream;

        var reader = Io.Reader.fixed(buf[0..n]);
        const frame = try parser.parse_packet(&reader);
        const report = hap.buildReport(std.testing.io, &frame);

        try std.testing.expectEqual(ds.Flag0.AUDIO_HAPTICS, report.valid_flag0);
        try std.testing.expectEqual(ds.Flag1.AUDIO_CONTROL2_ENABLE, report.valid_flag1);
        try std.testing.expectEqual(ds.Audio.PATH_SEL_INTERNAL_SPEAKER, report.audio_enable_bits);
        try std.testing.expectEqual(ds.Audio.SPEAKER_VOLUME_MAX, report.speaker_volume);
        try std.testing.expectEqual(ds.Audio.SP_PREAMP_GAIN_6DB, report.audio_control2);

        // the trigger effects may only be one of the modes we emit
        const valid_modes = [_]u8{
            @intFromEnum(ds.EffectMode.reset),
            @intFromEnum(ds.EffectMode.rigid),
            @intFromEnum(ds.EffectMode.vibrate),
            @intFromEnum(ds.EffectMode.rigid_zones),
            @intFromEnum(ds.EffectMode.vibrate_zones),
        };
        try std.testing.expect(std.mem.indexOfScalar(u8, &valid_modes, report.right_trigger_effect[0]) != null);
        try std.testing.expect(std.mem.indexOfScalar(u8, &valid_modes, report.left_trigger_effect[0]) != null);

        if (frame.IsRaceOn == 0) {
            saw_out_of_race = true;
            // out of race: both triggers must be released
            try std.testing.expectEqual(@intFromEnum(ds.EffectMode.reset), report.right_trigger_effect[0]);
            try std.testing.expectEqual(@intFromEnum(ds.EffectMode.reset), report.left_trigger_effect[0]);
        } else {
            saw_racing = true;
            if (frame.Brake > 0) saw_braking = true;
        }

        count += 1;
    }

    try std.testing.expectEqual(@as(usize, 1000), count);
    try std.testing.expect(saw_racing);
    try std.testing.expect(saw_out_of_race);
    try std.testing.expect(saw_braking);
}

test "simple mode enables classic rumble flags" {
    var hap: Haptics = .{ .motor_mode = .simple };
    var frame = parser.HorizonFrame{};
    frame.SurfaceRumbleFl = 1.0;
    frame.SurfaceRumbleFr = 0.5;

    const report = hap.buildReport(std.testing.io, &frame);
    try std.testing.expectEqual(ds.Flag0.ALL, report.valid_flag0);
    try std.testing.expectEqual(@as(u8, 0), report.valid_flag1);
    try std.testing.expect(report.motor_left > report.motor_right);
    try std.testing.expect(report.motor_right > 0);
}

test "trigger zone helpers" {
    // rising resistance: monotone up the pull, capped at mag
    const r = risingZones(8);
    try std.testing.expectEqual(@as(u8, 0), r[0]);
    try std.testing.expectEqual(@as(u8, 8), r[9]);
    for (r, 0..) |v, i| {
        if (i > 0) try std.testing.expect(v >= r[i - 1]);
    }
    // mag 0 -> all zones inactive (trigger free)
    const off = risingZones(0);
    for (off) |v| try std.testing.expectEqual(@as(u8, 0), v);

    // band: silent below start, flat level from start..9
    const band = zoneBand(5, 6);
    try std.testing.expectEqual(@as(u8, 0), band[4]);
    try std.testing.expectEqual(@as(u8, 6), band[5]);
    try std.testing.expectEqual(@as(u8, 6), band[9]);

    // amplitude byte -> zone level
    try std.testing.expectEqual(@as(u8, 8), zoneAmp(255));
    try std.testing.expectEqual(@as(u8, 1), zoneAmp(1));
}

test "brake uses rising rigid zones, throttle uses uniform rigid" {
    var hap: Haptics = .{};
    const now = nowMillis(std.testing.io);

    var frame = parser.HorizonFrame{};
    frame.IsRaceOn = 1;
    frame.Brake = 200; // hard brake, not locking up
    const brake = hap.leftTrigger(&frame, now);
    try std.testing.expectEqual(@intFromEnum(ds.EffectMode.rigid_zones), brake[0]);

    frame.Brake = 0;
    frame.Accel = 200; // full throttle, no slip
    const throttle = hap.rightTrigger(&frame, now);
    try std.testing.expectEqual(@intFromEnum(ds.EffectMode.rigid), throttle[0]);
}

test "wheelspin and rev-limit use vibrate zones" {
    var hap: Haptics = .{};
    const now = nowMillis(std.testing.io);

    // rev limit: high rpm at full throttle
    var frame = parser.HorizonFrame{};
    frame.IsRaceOn = 1;
    frame.EngineMaxRpm = 7000;
    frame.CurrentEngineRpm = 7000;
    frame.Accel = 200;
    const rev = hap.rightTrigger(&frame, now);
    try std.testing.expectEqual(@intFromEnum(ds.EffectMode.vibrate_zones), rev[0]);

    // wheelspin: high accel + wheel slip while moving
    frame.CurrentEngineRpm = 4000;
    frame.Speed = 30;
    frame.TireCombinedSlipFl = 1.2;
    frame.TireCombinedSlipFr = 1.2;
    frame.TireCombinedSlipRl = 1.2;
    frame.TireCombinedSlipRr = 1.2;
    const spin = hap.rightTrigger(&frame, now);
    try std.testing.expectEqual(@intFromEnum(ds.EffectMode.vibrate_zones), spin[0]);
}

test "audio cues vary with wheel state" {
    const calm = sideAudioCue(0.2, 10, 0, false, 0);
    const loaded = sideAudioCue(0.2, 80, 1.5, true, 0);

    try std.testing.expect(loaded.amp > calm.amp);
    try std.testing.expect(loaded.freq > calm.freq);
    try std.testing.expect(loaded.amp <= 1.0);
    try std.testing.expect(loaded.freq <= 220.0);
}
