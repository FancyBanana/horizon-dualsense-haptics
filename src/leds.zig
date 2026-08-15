// SPDX-License-Identifier: AGPL-3.0-or-later

//! LED and lightbar effects: RPM -> lightbar color, gear -> player LEDs.

const std = @import("std");
const parser = @import("fh5_packet_parser.zig");
const ds = @import("hardware/dualsense.zig");
const config = @import("config.zig");

/// RPM -> green-to-red lightbar, gear -> player LEDs.
pub fn updateLeds(cfg: *const config.HapticsConfig, frame: *const parser.HorizonFrame, report: *ds.OutputReport) void {
    if (!cfg.lightbar_enabled and !cfg.leds_enabled) return;

    if (cfg.lightbar_enabled) {
        const rpm_ratio = if (frame.IsRaceOn != 0 and frame.EngineMaxRpm > 0)
            std.math.clamp(finiteOrZero(frame.CurrentEngineRpm / frame.EngineMaxRpm), 0, 1)
        else
            0;

        report.valid_flag1 |= ds.Flag1.LIGHTBAR_CONTROL_ENABLE;
        report.led_red = @intFromFloat(rpm_ratio * 255.0);
        report.led_green = @intFromFloat((1.0 - rpm_ratio) * 255.0);
        report.led_blue = 0;
    }

    if (cfg.leds_enabled) {
        report.valid_flag1 |= ds.Flag1.PLAYER_INDICATOR_CONTROL_ENABLE;
        report.led_brightness = 255;
        report.player_leds = gearLedMask(frame.Gear);
    }
}

/// Reset LEDs to off state.
pub fn resetLeds(cfg: *const config.HapticsConfig, report: *ds.OutputReport) void {
    if (cfg.lightbar_enabled) {
        report.valid_flag1 |= ds.Flag1.LIGHTBAR_CONTROL_ENABLE;
        report.valid_flag2 |= ds.FLAG2_LIGHTBAR_SETUP_CONTROL_ENABLE;
        report.lightbar_setup = ds.LIGHTBAR_SETUP_LIGHT_OUT;
        report.led_red = 0;
        report.led_green = 0;
        report.led_blue = 0;
    }
    if (cfg.leds_enabled) {
        report.valid_flag1 |= ds.Flag1.PLAYER_INDICATOR_CONTROL_ENABLE;
        report.led_brightness = 0;
        report.player_leds = 0;
    }
}

/// Gear -> player LED mask. The firmware mirrors `player_leds` around the
/// center bit, so only 3 independent channels exist; patterns grow with gear.
pub fn gearLedMask(gear: u8) u8 {
    const patterns = [_]u8{
        0b00100, // 1: center
        0b01010, // 2: inner pair
        0b10001, // 3: outer pair
        0b01110, // 4: center + inner
        0b10101, // 5: center + outer
        0b11011, // 6: inner + outer
        0b11111, // 7: all
        0b11111, // 8: all
        0b11111, // 9: all
        0b11111, // 10: all
    };
    if (gear == 0 or gear > patterns.len) return 0;
    return patterns[gear - 1];
}

fn finiteOrZero(value: f32) f32 {
    return if (std.math.isFinite(value)) value else 0;
}

test "lightbar follows rpm and gear LEDs" {
    var cfg: config.HapticsConfig = .{ .lightbar_enabled = true, .leds_enabled = true };
    var frame = parser.HorizonFrame{};
    frame.IsRaceOn = 1;
    frame.EngineMaxRpm = 8000;
    frame.CurrentEngineRpm = 0;
    frame.Gear = 1;

    var report: ds.OutputReport = .{};
    updateLeds(&cfg, &frame, &report);
    try std.testing.expectEqual(@as(u8, 0), report.led_red);
    try std.testing.expectEqual(@as(u8, 255), report.led_green);
    try std.testing.expectEqual(@as(u8, 0x04), report.player_leds);

    frame.CurrentEngineRpm = 8000;
    frame.Gear = 7;
    report = .{};
    updateLeds(&cfg, &frame, &report);
    try std.testing.expectEqual(@as(u8, 255), report.led_red);
    try std.testing.expectEqual(@as(u8, 0), report.led_green);
    try std.testing.expectEqual(@as(u8, 0x1F), report.player_leds);
}

test "gear LEDs use symmetric mirror-compatible patterns" {
    try std.testing.expectEqual(@as(u8, 0), gearLedMask(0));
    try std.testing.expectEqual(@as(u8, 0x04), gearLedMask(1));
    try std.testing.expectEqual(@as(u8, 0x0A), gearLedMask(2));
    try std.testing.expectEqual(@as(u8, 0x11), gearLedMask(3));
    try std.testing.expectEqual(@as(u8, 0x0E), gearLedMask(4));
    try std.testing.expectEqual(@as(u8, 0x15), gearLedMask(5));
    try std.testing.expectEqual(@as(u8, 0x1B), gearLedMask(6));
    try std.testing.expectEqual(@as(u8, 0x1F), gearLedMask(7));
    try std.testing.expectEqual(@as(u8, 0x1F), gearLedMask(10));
    try std.testing.expectEqual(@as(u8, 0), gearLedMask(11));
}
