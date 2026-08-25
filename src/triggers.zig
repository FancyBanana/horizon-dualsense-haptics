// SPDX-License-Identifier: AGPL-3.0-or-later

//! Trigger effect mapping: telemetry -> L2/R2 adaptive trigger effects.

const std = @import("std");
const parser = @import("fh5_packet_parser.zig");
const ds = @import("hardware/dualsense-util.zig");
const config = @import("config.zig");

const Params = config.Params;

/// Tracks gear-change state for the shift-burst trigger effect.
pub const TriggerState = struct {
    prev_gear: ?u8 = null,
    shift_until_ms: i64 = 0,

    /// Must be set by the caller to the Params.shift_burst_ms value.
    /// Avoids a Params pointer dependency; the orchestrator copies it in.
    config_params_shift_burst_ms: i64 = 80,

    pub fn updateGearShift(self: *TriggerState, frame: *const parser.HorizonFrame, now_ms: i64) void {
        if (self.prev_gear) |prev| {
            if (prev != frame.Gear) {
                self.shift_until_ms = now_ms + self.config_params_shift_burst_ms;
            }
        }
        self.prev_gear = frame.Gear;
    }

    /// L2 = brake.
    pub fn leftTrigger(self: *const TriggerState, params: *const Params, frame: *const parser.HorizonFrame, now_ms: i64) ds.TriggerEffect {
        if (frame.IsRaceOn == 0) return ds.TriggerEffect.off();

        if (now_ms < self.shift_until_ms) return ds.TriggerEffect.vibrate(params.shift_burst_freq, params.shift_burst_amp);

        if (frame.HandBrake > 0) return ds.TriggerEffect.rigid(params.handbrake_force);

        if (frame.Brake >= params.abs_brake_threshold and isLockingUp(params, frame)) {
            return ds.TriggerEffect.vibrate(params.abs_freq, params.abs_amp);
        }

        // Resistance rises with pull depth, like a hydraulic pedal.
        const mag = ramp(frame.Brake, params.brake_deadzone, params.brake_zone_max);
        if (mag == 0) return ds.TriggerEffect.off();
        return ds.TriggerEffect.rigidZones(ds.risingZones(mag));
    }

    /// R2 = throttle.
    pub fn rightTrigger(self: *const TriggerState, params: *const Params, frame: *const parser.HorizonFrame, now_ms: i64) ds.TriggerEffect {
        if (frame.IsRaceOn == 0) return ds.TriggerEffect.off();

        if (now_ms < self.shift_until_ms) return ds.TriggerEffect.vibrate(params.shift_burst_freq, params.shift_burst_amp);

        if (frame.EngineMaxRpm > 0 and frame.CurrentEngineRpm >= frame.EngineMaxRpm * params.rev_limit_ratio) {
            return ds.TriggerEffect.vibrateZones(ds.zoneBand(params.rev_limit_zone_start, ds.zoneAmp(params.rev_limit_amp)), params.rev_limit_freq);
        }

        if (frame.Accel >= params.wheelspin_accel_threshold and wheelSpinning(params, frame)) {
            return ds.TriggerEffect.vibrateZones(
                ds.zoneBand(params.wheelspin_zone_start, ds.zoneAmp(params.wheelspin_amp)),
                wheelspinFreq(params, frame),
            );
        }

        return ds.TriggerEffect.rigid(ramp(frame.Accel, params.throttle_deadzone, params.throttle_max_force));
    }
};

fn isLockingUp(p: *const Params, frame: *const parser.HorizonFrame) bool {
    return maxAbs4(frame.TireSlipRatioFl, frame.TireSlipRatioFr, frame.TireSlipRatioRl, frame.TireSlipRatioRr) >= p.abs_slip_ratio_threshold or
        maxAbs4(frame.TireCombinedSlipFl, frame.TireCombinedSlipFr, frame.TireCombinedSlipRl, frame.TireCombinedSlipRr) >= p.abs_combined_slip_threshold;
}

/// Slip at speed; raw wheel rotation at standstill (slip degenerates there).
fn wheelSpinning(p: *const Params, frame: *const parser.HorizonFrame) bool {
    if (frame.Speed > p.low_speed_mps) {
        return maxAbs4(frame.TireCombinedSlipFl, frame.TireCombinedSlipFr, frame.TireCombinedSlipRl, frame.TireCombinedSlipRr) >= p.wheelspin_slip_threshold;
    }
    return maxAbs4(frame.WheelRotationSpeedFl, frame.WheelRotationSpeedFr, frame.WheelRotationSpeedRl, frame.WheelRotationSpeedRr) >= p.burnout_rot_threshold;
}

fn wheelspinFreq(p: *const Params, frame: *const parser.HorizonFrame) u8 {
    const slip = maxAbs4(frame.TireCombinedSlipFl, frame.TireCombinedSlipFr, frame.TireCombinedSlipRl, frame.TireCombinedSlipRr);
    const t = std.math.clamp(slip - p.wheelspin_slip_threshold, 0, 1);
    return p.wheelspin_freq_min + @as(u8, @intFromFloat(t * (p.wheelspin_freq_max - p.wheelspin_freq_min)));
}

/// value 0..255 -> 0..max_force above the deadzone.
pub fn ramp(value: u8, deadzone: u8, max_force: u8) u8 {
    if (value <= deadzone) return 0;
    const span: u32 = 255 - deadzone;
    const f = @as(u32, max_force) * @as(u32, value - deadzone) / span;
    return @intCast(f);
}

fn max2(a: f32, b: f32) f32 {
    const left = finiteOrZero(a);
    const right = finiteOrZero(b);
    return if (left > right) left else right;
}

fn finiteOrZero(value: f32) f32 {
    return if (std.math.isFinite(value)) value else 0;
}

fn maxAbs4(a: f32, b: f32, c: f32, d: f32) f32 {
    return max2(max2(@abs(a), @abs(b)), max2(@abs(c), @abs(d)));
}

test "trigger zone helpers" {
    const r = ds.risingZones(8);
    try std.testing.expectEqual(@as(u8, 0), r[0]);
    try std.testing.expectEqual(@as(u8, 8), r[9]);
    for (r, 0..) |v, i| {
        if (i > 0) try std.testing.expect(v >= r[i - 1]);
    }
    const off = ds.risingZones(0);
    for (off) |v| try std.testing.expectEqual(@as(u8, 0), v);

    const band = ds.zoneBand(5, 6);
    try std.testing.expectEqual(@as(u8, 0), band[4]);
    try std.testing.expectEqual(@as(u8, 6), band[5]);
    try std.testing.expectEqual(@as(u8, 6), band[9]);

    const empty = ds.zoneBand(255, 6);
    for (empty) |v| try std.testing.expectEqual(@as(u8, 0), v);

    try std.testing.expectEqual(@as(u8, 8), ds.zoneAmp(255));
    try std.testing.expectEqual(@as(u8, 1), ds.zoneAmp(1));
}

test "brake uses rising rigid zones, throttle uses uniform rigid" {
    var state: TriggerState = .{};
    var params: Params = .{};
    const now: i64 = 0;

    var frame = parser.HorizonFrame{};
    frame.IsRaceOn = 1;
    frame.Brake = 200; // hard brake, not locking up
    const brake = state.leftTrigger(&params, &frame, now);
    try std.testing.expectEqual(@intFromEnum(ds.EffectMode.rigid_zones), brake.data[0]);

    frame.Brake = 0;
    frame.Accel = 200; // full throttle, no slip
    const throttle = state.rightTrigger(&params, &frame, now);
    try std.testing.expectEqual(@intFromEnum(ds.EffectMode.rigid), throttle.data[0]);
}

test "wheelspin and rev-limit use vibrate zones" {
    var state: TriggerState = .{};
    var params: Params = .{};
    const now: i64 = 0;

    // rev limit: high rpm at full throttle
    var frame = parser.HorizonFrame{};
    frame.IsRaceOn = 1;
    frame.EngineMaxRpm = 7000;
    frame.CurrentEngineRpm = 7000;
    frame.Accel = 200;
    const rev = state.rightTrigger(&params, &frame, now);
    try std.testing.expectEqual(@intFromEnum(ds.EffectMode.vibrate_zones), rev.data[0]);

    // wheelspin: high accel + slip while moving
    frame.CurrentEngineRpm = 4000;
    frame.Speed = 30;
    frame.TireCombinedSlipFl = 1.2;
    frame.TireCombinedSlipFr = 1.2;
    frame.TireCombinedSlipRl = 1.2;
    frame.TireCombinedSlipRr = 1.2;
    const spin = state.rightTrigger(&params, &frame, now);
    try std.testing.expectEqual(@intFromEnum(ds.EffectMode.vibrate_zones), spin.data[0]);
}
