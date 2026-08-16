// SPDX-License-Identifier: AGPL-3.0-or-later

//! Simple rumble: telemetry -> classic DualSense motor bytes.

const std = @import("std");
const parser = @import("fh5_packet_parser.zig");
const ds = @import("hardware/dualsense.zig");
const config = @import("config.zig");

/// Surface rumble -> classic motor bytes (simple mode only).
pub fn updateMotors(motor_mode: config.MotorMode, frame: *const parser.HorizonFrame, report: *ds.UsbOutputReport) void {
    // SurfaceRumble is a 0..1 per-wheel force.
    const l = max2(frame.SurfaceRumbleFl, frame.SurfaceRumbleRl);
    const r = max2(frame.SurfaceRumbleFr, frame.SurfaceRumbleRr);
    switch (motor_mode) {
        .simple => {
            report.common.motor_right = scaleMotor(r);
            report.common.motor_left = scaleMotor(l);
        },
        // Audio mode drives the actuators via the audio stream instead.
        .audio => {},
    }
}

fn scaleMotor(v: f32) u8 {
    return @intFromFloat(std.math.clamp(finiteOrZero(v), 0, 1) * 255.0);
}

fn max2(a: f32, b: f32) f32 {
    const left = finiteOrZero(a);
    const right = finiteOrZero(b);
    return if (left > right) left else right;
}

fn finiteOrZero(value: f32) f32 {
    return if (std.math.isFinite(value)) value else 0;
}

test "simple mode enables classic rumble flags" {
    var frame = parser.HorizonFrame{};
    frame.IsRaceOn = 1;
    frame.SurfaceRumbleFl = 1.0;
    frame.SurfaceRumbleFr = 0.5;

    var report: ds.UsbOutputReport = .{};
    updateMotors(.simple, &frame, &report);
    try std.testing.expectEqual(ds.Flag0.ALL, report.common.valid_flag0);
    try std.testing.expectEqual(@as(u8, 0), report.common.valid_flag1);
    try std.testing.expect(report.common.motor_left > report.common.motor_right);
    try std.testing.expect(report.common.motor_right > 0);
}
