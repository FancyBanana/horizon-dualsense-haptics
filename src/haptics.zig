const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const parser = @import("packet_parser.zig");
const ds = @import("dualsense.zig");

const print = std.debug.print;

/// Tunables for the telemetry -> DualSense mapping.
pub const Params = struct {
    // L2 (brake)
    brake_deadzone: u8 = 40,
    brake_max_force: u8 = 200,
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

    // shared
    shift_burst_freq: u8 = 20,
    shift_burst_amp: u8 = 130,
    shift_burst_ms: i128 = 80,
    low_speed_ms: f32 = 5.0, // m/s: below this trust wheel rotation, not slip
};

pub const Haptics = struct {
    device: ds.Device = .{},
    params: Params = .{},
    prev_gear: ?u8 = null,
    shift_until_ms: i128 = 0,
    last_open_attempt_ms: i128 = -1_000_000,
    reconnect_interval_ms: i128 = 1_000,
    waiting_hinted: bool = false,

    /// Parse is done by the caller; this maps a frame to the controller.
    /// Errors are swallowed: the device is re-opened lazily on the next tick.
    pub fn update(self: *Haptics, io: Io, frame: *const parser.HorizonFrame) void {
        self.ensureConnected(io);
        if (!self.device.connected()) return;

        const report = self.buildReport(frame);

        self.device.writeReport(&report) catch |err| switch (err) {
            error.WouldBlock => {}, // nonblocking: drop this frame
            else => {
                print("DualSense disconnected\n", .{});
                self.device.close();
            },
        };
    }

    /// Runs the telemetry -> effects mapping without touching any hardware.
    /// This is what the offline replay test (`zig build test`) exercises.
    pub fn buildReport(self: *Haptics, frame: *const parser.HorizonFrame) ds.OutputReport {
        var report: ds.OutputReport = .{};

        self.updateMotors(frame, &report);

        const now_ms = nowMillis();
        self.updateGearShift(frame, now_ms);
        report.right_trigger_effect = self.rightTrigger(frame, now_ms);
        report.left_trigger_effect = self.leftTrigger(frame, now_ms);

        return report;
    }

    fn ensureConnected(self: *Haptics, io: Io) void {
        if (!self.device.connected()) {
            const now = nowMillis();
            if (now - self.last_open_attempt_ms < self.reconnect_interval_ms) return;
            self.last_open_attempt_ms = now;
            self.device = ds.Device.open(io) catch {
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
        if (!self.device.connected()) return;
        var report: ds.OutputReport = .{};
        report.right_trigger_effect = ds.effectOff();
        report.left_trigger_effect = ds.effectOff();
        _ = self.device.writeReport(&report) catch {};
        self.device.close();
    }

    fn updateMotors(self: *const Haptics, frame: *const parser.HorizonFrame, report: *ds.OutputReport) void {
        _ = self;
        // Forza SurfaceRumble is a 0..1 per-wheel road-surface force.
        report.motor_right = scaleMotor(max2(frame.SurfaceRumbleFr, frame.SurfaceRumbleRr));
        report.motor_left = scaleMotor(max2(frame.SurfaceRumbleFl, frame.SurfaceRumbleRl));
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

        return ds.effectRigid(ramp(frame.Brake, p.brake_deadzone, p.brake_max_force));
    }

    /// Right trigger = R2 = throttle.
    fn rightTrigger(self: *Haptics, frame: *const parser.HorizonFrame, now_ms: i128) ds.Effect {
        const p = self.params;
        if (frame.IsRaceOn == 0) return ds.effectOff();

        if (now_ms < self.shift_until_ms) return ds.effectVibrate(p.shift_burst_freq, p.shift_burst_amp);

        if (frame.EngineMaxRpm > 0 and frame.CurrentEngineRpm >= frame.EngineMaxRpm * p.rev_limit_ratio) {
            return ds.effectVibrate(p.rev_limit_freq, p.rev_limit_amp);
        }

        if (frame.Accel >= p.wheelspin_accel_threshold) {
            if (self.wheelSpinning(frame)) {
                return ds.effectVibrate(self.wheelspinFreq(frame), p.wheelspin_amp);
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

fn max2(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}

fn maxAbs4(a: f32, b: f32, c: f32, d: f32) f32 {
    return max2(max2(@abs(a), @abs(b)), max2(@abs(c), @abs(d)));
}

fn nowMillis() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

const CAPTURED_PACKET_SIZE = 324;

// Offline replay: run every captured packet through the mapping and check the
// produced report is structurally sane. No DualSense required.
test "replay all captured packets through the mapping" {
    var hap: Haptics = .{};

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
        const report = hap.buildReport(&frame);

        try std.testing.expectEqual(ds.Flag0.ALL, report.valid_flag0);

        // the trigger effects may only be one of the three modes we emit
        const valid_modes = [_]u8{
            @intFromEnum(ds.EffectMode.reset),
            @intFromEnum(ds.EffectMode.rigid),
            @intFromEnum(ds.EffectMode.vibrate),
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
