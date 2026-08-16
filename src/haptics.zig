// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Io = std.Io;
const parser = @import("fh5_packet_parser.zig");
const ds = @import("hardware/dualsense.zig");
const device = @import("hardware/device.zig");
const audio = @import("audio.zig");
const config = @import("config.zig");
const platform = @import("hardware/platform.zig");
const triggers = @import("triggers.zig");
const voicecoil = @import("voicecoil.zig");
const rumble = @import("rumble.zig");
const leds = @import("leds.zig");

const print = std.debug.print;

/// Converts telemetry frames into DualSense HID and audio effects.
pub const Haptics = struct {
    device: device.Device = .{},
    config: config.HapticsConfig = .{},
    trigger_state: triggers.TriggerState = .{},
    last_open_attempt_ms: i64 = -1_000_000,
    waiting_hinted: bool = false,
    audio: ?*audio.AudioHaptics = null,

    /// Maps a parsed frame to the controller; errors just defer a reconnect.
    pub fn update(self: *Haptics, io: Io, frame: *const parser.HorizonFrame) void {
        self.ensureConnected(io);
        voicecoil.updateAudio(self.config.motor_mode, self.audio, frame);
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

    /// Pure telemetry -> report mapping, no hardware; used by the tests.
    pub fn buildReport(self: *Haptics, io: Io, frame: *const parser.HorizonFrame) ds.UsbOutputReport {
        if (frame.IsRaceOn == 0) return self.resetReport();

        var report: ds.UsbOutputReport = .{};

        rumble.updateMotors(self.config.motor_mode, frame, &report);

        voicecoil.configureAudioReport(self.config.motor_mode, &report);

        const now_ms = nowMillis(io);
        self.trigger_state.config_params_shift_burst_ms = self.config.params.shift_burst_ms;
        self.trigger_state.updateGearShift(frame, now_ms);
        report.common.right_trigger_effect = self.trigger_state.rightTrigger(&self.config.params, frame, now_ms);
        report.common.left_trigger_effect = self.trigger_state.leftTrigger(&self.config.params, frame, now_ms);
        leds.updateLeds(&self.config, frame, &report);

        return report;
    }

    /// Report releasing triggers, motors, and LEDs.
    fn resetReport(self: *const Haptics) ds.UsbOutputReport {
        var report: ds.UsbOutputReport = .{};
        voicecoil.configureAudioReport(self.config.motor_mode, &report);
        report.common.right_trigger_effect = ds.triggerEffectOff();
        report.common.left_trigger_effect = ds.triggerEffectOff();
        leds.resetLeds(&self.config, &report);
        return report;
    }

    /// Releases effects and closes the device. Safe when disconnected.
    pub fn shutdown(self: *Haptics) void {
        if (self.audio) |a| {
            a.setActive(false);
            a.setIntensity(0, 0);
        }
        if (!self.device.connected()) return;
        const report = self.resetReport();
        _ = self.device.writeReport(&report) catch {};
        self.device.close();
    }

    /// Opens the controller lazily, throttling discovery attempts.
    fn ensureConnected(self: *Haptics, io: Io) void {
        if (!self.device.connected()) {
            const now = nowMillis(io);
            if (now - self.last_open_attempt_ms < self.config.reconnect_interval_ms) return;
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
};

fn nowMillis(io: std.Io) i64 {
    return platform.nowMillis(io);
}

// Offline replay: run every captured packet through the mapping; no DualSense needed.
test "replay all captured packets through the mapping" {
    var hap: Haptics = .{ .config = .{ .motor_mode = .audio, .lightbar_enabled = true, .leds_enabled = true } };

    var count: usize = 0;
    var saw_racing = false;
    var saw_out_of_race = false;
    var saw_braking = false;

    var index: usize = 1;
    while (true) : (index += 1) {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "fh5_packets/packet-{d}.fh5tel", .{index});
        const file = std.Io.Dir.cwd().openFile(std.testing.io, path, .{ .mode = .read_only }) catch break;
        defer file.close(std.testing.io);

        var buf: [parser.PACKET_SIZE]u8 = undefined;
        const n = try file.readStreaming(std.testing.io, &.{buf[0..]});
        if (n != parser.PACKET_SIZE) return error.UnexpectedEndOfStream;

        const frame = parser.parseHorizonPacket(buf);
        const report = hap.buildReport(std.testing.io, &frame);

        try std.testing.expectEqual(ds.Flag0.AUDIO_HAPTICS, report.common.valid_flag0);
        try std.testing.expectEqual(
            ds.Flag1.AUDIO_CONTROL2_ENABLE |
                ds.Flag1.LIGHTBAR_CONTROL_ENABLE |
                ds.Flag1.PLAYER_INDICATOR_CONTROL_ENABLE,
            report.common.valid_flag1,
        );
        try std.testing.expectEqual(ds.Audio.PATH_SEL_INTERNAL_SPEAKER, report.common.audio_enable_bits);
        try std.testing.expectEqual(ds.Audio.SPEAKER_VOLUME_MAX, report.common.speaker_volume);
        try std.testing.expectEqual(ds.Audio.SP_PREAMP_GAIN_6DB, report.common.audio_control2);

        const valid_modes = [_]u8{
            @intFromEnum(ds.EffectMode.reset),
            @intFromEnum(ds.EffectMode.rigid),
            @intFromEnum(ds.EffectMode.vibrate),
            @intFromEnum(ds.EffectMode.rigid_zones),
            @intFromEnum(ds.EffectMode.vibrate_zones),
        };
        try std.testing.expect(std.mem.indexOfScalar(u8, &valid_modes, report.common.right_trigger_effect[0]) != null);
        try std.testing.expect(std.mem.indexOfScalar(u8, &valid_modes, report.common.left_trigger_effect[0]) != null);

        if (frame.IsRaceOn == 0) {
            saw_out_of_race = true;
            // out of race: triggers released
            try std.testing.expectEqual(@intFromEnum(ds.EffectMode.reset), report.common.right_trigger_effect[0]);
            try std.testing.expectEqual(@intFromEnum(ds.EffectMode.reset), report.common.left_trigger_effect[0]);
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

test "out-of-race report resets all effects" {
    var hap: Haptics = .{ .config = .{ .motor_mode = .simple } };
    var frame = parser.HorizonFrame{};
    frame.SurfaceRumbleFl = 1.0;
    frame.SurfaceRumbleFr = 1.0;
    frame.Gear = 10;

    const report = hap.buildReport(std.testing.io, &frame);
    try std.testing.expectEqual(@as(u8, 0), report.common.motor_left);
    try std.testing.expectEqual(@as(u8, 0), report.common.motor_right);
    try std.testing.expectEqual(@intFromEnum(ds.EffectMode.reset), report.common.left_trigger_effect[0]);
    try std.testing.expectEqual(@intFromEnum(ds.EffectMode.reset), report.common.right_trigger_effect[0]);
    try std.testing.expectEqual(@as(u8, 0), report.common.led_brightness);
    try std.testing.expectEqual(@as(u8, 0), report.common.player_leds);
    try std.testing.expectEqual(@as(u8, 0), report.common.led_red);
    try std.testing.expectEqual(@as(u8, 0), report.common.led_green);
    try std.testing.expectEqual(@as(u8, 0), report.common.led_blue);
}
