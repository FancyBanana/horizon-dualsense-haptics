// SPDX-License-Identifier: AGPL-3.0-or-later

//! Rumble emulation: telemetry -> grip-coil rumble bytes.
//!
/// "Classic rumble" is firmware-emulated on the same voice coils that PCM
/// haptics drive, so this module and voicecoil.zig are mutually exclusive
/// actuator drivers.
const std = @import("std");
const parser = @import("fh5_packet_parser.zig");
const ds = @import("hardware/dualsense-util.zig");
const config = @import("config.zig");

/// Surface rumble -> rumble-emulation grip-coil strengths (simple mode
/// only).  Sets only the Flag0.RUMBLE bits on the builder; other features
/// compose independently.
pub fn updateRumble(motor_mode: config.MotorMode, frame: *const parser.HorizonFrame, builder: *ds.ReportBuilder) void {
    // SurfaceRumble is a 0..1 per-wheel force.
    const l = max2(frame.SurfaceRumbleFl, frame.SurfaceRumbleRl);
    const r = max2(frame.SurfaceRumbleFr, frame.SurfaceRumbleRr);
    switch (motor_mode) {
        .simple => builder.setMotorsNorm(l, r),
        // Audio mode drives the actuators via the audio stream instead.
        .audio => {},
    }
}

fn max2(a: f32, b: f32) f32 {
    const left = finiteOrZero(a);
    const right = finiteOrZero(b);
    return if (left > right) left else right;
}

fn finiteOrZero(value: f32) f32 {
    return if (std.math.isFinite(value)) value else 0;
}

test "simple mode enables rumble emulation flags" {
    var frame = parser.HorizonFrame{};
    frame.IsRaceOn = 1;
    frame.SurfaceRumbleFl = 1.0;
    frame.SurfaceRumbleFr = 0.5;

    var b: ds.ReportBuilder = .{};
    updateRumble(.simple, &frame, &b);
    const report = try b.toReport();
    try std.testing.expectEqual(ds.Flag0.RUMBLE, report.common.valid_flag0);
    try std.testing.expectEqual(ds.FLAG2_RUMBLE_V2, report.common.valid_flag2);
    try std.testing.expectEqual(@as(u8, 0), report.common.valid_flag1);
    try std.testing.expect(report.common.motor_left > report.common.motor_right);
    try std.testing.expect(report.common.motor_right > 0);
}
