// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

// The DualSense USB/Bluetooth HID protocols and trigger-effect encodings.
// Platform-specific device access lives in device.zig.

pub const VENDOR_ID: u16 = 0x054C;
pub const PRODUCT_IDS = [_]u16{ 0x0CE6, 0x0DF2 }; // DualSense, DualSense Edge

pub const Bus = enum {
    usb,
    bluetooth,
};

pub const USB_REPORT_ID: u8 = 0x02;
pub const USB_REPORT_SIZE: usize = 48;
pub const BT_REPORT_ID: u8 = 0x31;
pub const BT_REPORT_SIZE: usize = 78;
pub const BT_OUTPUT_TAG: u8 = 0x10;
const BT_CRC_SEED: u8 = 0xA2;

/// valid_flag0 (report byte 1) bits. Each bit says which group of fields this
/// packet is allowed to change.
pub const Flag0 = struct {
    pub const RUMBLE: u8 = 0x01 | 0x02; // classic vibration: main motors
    pub const RIGHT_TRIGGER: u8 = 0x04;
    pub const LEFT_TRIGGER: u8 = 0x08;
    pub const AUDIO_VOLUME: u8 = 0x10; // apply the headphone/speaker/mic volume bytes
    pub const INTERNAL_SPEAKER: u8 = 0x20; // apply the internal-speaker routing byte
    pub const MIC_VOLUME: u8 = 0x40;
    pub const INTERNAL_MIC: u8 = 0x80;
    pub const ALL: u8 = RUMBLE | RIGHT_TRIGGER | LEFT_TRIGGER;
    /// Native audio-haptics mode (0xFC): triggers + audio control, but no
    /// rumble bits. Setting the rumble bits puts the controller in classic
    /// rumble emulation, which silences the voice-coil haptics path (the state
    /// DS4Windows/PCGamingWiki call `UseRumbleNotHaptics = 0xFF` vs `0xFC`).
    pub const AUDIO_HAPTICS: u8 = RIGHT_TRIGGER | LEFT_TRIGGER | AUDIO_VOLUME |
        INTERNAL_SPEAKER | MIC_VOLUME | INTERNAL_MIC;
};

/// valid_flag1 (report byte 2) bits.
pub const Flag1 = struct {
    /// Apply the `audio_control2` byte (report byte 38). The kernel driver
    /// sets this alongside Flag0.AUDIO_HAPTICS when enabling the
    /// internal-speaker preamp gain (+6 dB), which boosts the haptic path.
    pub const AUDIO_CONTROL2_ENABLE: u8 = 0x80;
};

/// Audio-control fields (report bytes 5-8, 38).
pub const Audio = struct {
    /// Internal-speaker routing in `audio_enable_bits` (byte 8): enable the
    /// internal speaker and mute the headphone jack. Sony's firmware mutes the
    /// internal output by default; this byte (OUTPUT_PATH_SEL = 3) un-mutes it,
    /// which is also what routes RL/RR to the haptic actuators.
    pub const PATH_SEL_INTERNAL_SPEAKER: u8 = 0x30;
    /// Speaker/haptics volume (byte 6). The PS5 firmware only honours the
    /// 0x3d..0x64 range; 0x64 = 100%.
    pub const SPEAKER_VOLUME_MAX: u8 = 0x64;
    pub const HEADPHONE_VOLUME_MAX: u8 = 0x7f;
    pub const MIC_VOLUME_MID: u8 = 0x40;
    /// SP preamp gain +6 dB (byte 38, `audio_control2`).
    pub const SP_PREAMP_GAIN_6DB: u8 = 0x02;
};

/// valid_flag2 (report byte 39) bits.
pub const FLAG2_RUMBLE_V2: u8 = 0x04; // improved rumble emulation, firmware 2.24+

/// Trigger effect mode bytes (byte 0 of the 11-byte effect section).
pub const EffectMode = enum(u8) {
    stop = 0x00, // stop the effect, leave the actuator where it is
    reset = 0x05, // disengage the effect and withdraw the actuator
    rigid = 0x01, // uniform resistance: [start_pos, force]
    vibrate = 0x06, // vibration: [freq, amp, start_pos]
    rigid_zones = 0x21, // per-zone resistance, 10 zones x 3 bits
    vibrate_zones = 0x26, // per-zone vibration: [packed, 0, 0, freq, 0]
};

/// The 48-byte USB main output report (report ID 0x02).
pub const OutputReport = extern struct {
    report_id: u8 = USB_REPORT_ID,
    valid_flag0: u8 = Flag0.ALL,
    valid_flag1: u8 = 0,
    motor_right: u8 = 0,
    motor_left: u8 = 0,
    headphone_volume: u8 = 0,
    speaker_volume: u8 = 0,
    microphone_volume: u8 = 0,
    audio_enable_bits: u8 = 0,
    mic_light_mode: u8 = 0,
    audio_mute_bits: u8 = 0,
    right_trigger_effect: [11]u8 = [_]u8{0} ** 11,
    left_trigger_effect: [11]u8 = [_]u8{0} ** 11,
    unknown1: [5]u8 = [_]u8{0} ** 5,
    audio_control2: u8 = 0, // byte 38: internal-speaker preamp gain (+6 dB)
    valid_flag2: u8 = FLAG2_RUMBLE_V2,
    unknown2: [2]u8 = [_]u8{0} ** 2,
    led_animation: u8 = 0,
    led_brightness: u8 = 0,
    player_leds: u8 = 0,
    led_red: u8 = 0,
    led_green: u8 = 0,
    led_blue: u8 = 0,
};

/// The Bluetooth output report wraps the USB report's 47-byte common section
/// with a sequence nibble, transport tag, padding, and a CRC32-LE checksum.
pub const BtOutputReport = extern struct {
    report_id: u8 = BT_REPORT_ID,
    sequence: u8 = 0,
    tag: u8 = BT_OUTPUT_TAG,
    common: [47]u8 = [_]u8{0} ** 47,
    reserved: [24]u8 = [_]u8{0} ** 24,
    crc: [4]u8 = [_]u8{0} ** 4,

    pub fn fromUsb(report: *const OutputReport, sequence: u8) BtOutputReport {
        var bt: BtOutputReport = .{ .sequence = (sequence & 0x0F) << 4 };
        const usb_bytes = std.mem.asBytes(report);
        @memcpy(&bt.common, usb_bytes[1..48]);

        const checksum = bluetoothCrc(std.mem.asBytes(&bt)[0..74]);
        bt.crc[0] = @truncate(checksum);
        bt.crc[1] = @truncate(checksum >> 8);
        bt.crc[2] = @truncate(checksum >> 16);
        bt.crc[3] = @truncate(checksum >> 24);
        return bt;
    }
};

comptime {
    if (@sizeOf(OutputReport) != USB_REPORT_SIZE) {
        @compileError("OutputReport must be exactly 48 bytes");
    }
    if (@sizeOf(BtOutputReport) != BT_REPORT_SIZE) {
        @compileError("BtOutputReport must be exactly 78 bytes");
    }
}

/// Matches the kernel's crc32_le(~0, {0xA2}, 1) seed and final complement.
fn bluetoothCrc(bytes: []const u8) u32 {
    var crc = crc32LeUpdate(0xFFFFFFFF, &.{BT_CRC_SEED});
    crc = crc32LeUpdate(crc, bytes);
    return ~crc;
}

fn crc32LeUpdate(initial: u32, bytes: []const u8) u32 {
    var crc = initial;
    for (bytes) |byte| {
        crc ^= byte;
        for (0..8) |_| {
            const mask = @as(u32, 0) -% (crc & 1);
            crc = (crc >> 1) ^ (0xEDB88320 & mask);
        }
    }
    return crc;
}

pub const Effect = [11]u8;

pub fn effectOff() Effect {
    return makeEffect(.reset, &.{});
}

pub fn effectStop() Effect {
    return makeEffect(.stop, &.{});
}

/// Uniform resistance. `force` 0..255; 0 is a low force, not off.
pub fn effectRigid(force: u8) Effect {
    return makeEffect(.rigid, &.{ 0, force });
}

/// Vibration. `freq` in Hz (0..255), `amp` 0..255.
pub fn effectVibrate(freq: u8, amp: u8) Effect {
    return makeEffect(.vibrate, &.{ freq, amp });
}

/// Per-zone resistance. `zones` holds 10 strengths, 0 = inactive, 1..8 = resistance.
pub fn effectRigidZones(zones: [10]u8) Effect {
    var e = makeEffect(.rigid_zones, &.{});
    e[1..7].* = packZones(zones);
    return e;
}

/// Per-zone vibration. `zones` holds 10 amplitudes, 0 = inactive, 1..8 = amplitude.
pub fn effectVibrateZones(zones: [10]u8, freq: u8) Effect {
    var e = makeEffect(.vibrate_zones, &.{});
    e[1..7].* = packZones(zones);
    e[9] = freq;
    return e;
}

fn makeEffect(mode: EffectMode, params: []const u8) Effect {
    var e: Effect = [_]u8{0} ** 11;
    e[0] = @intFromEnum(mode);
    for (params, 1..) |p, i| e[i] = p;
    return e;
}

/// Packs 10 zone strengths into the 6-byte (active mask + 3-bit-per-zone)
/// payload shared by the zone effect modes. Mirrors the kernel/SDL encoding.
fn packZones(zones: [10]u8) [6]u8 {
    var active: u16 = 0;
    var packed_bits: u32 = 0;
    for (zones, 0..) |z, i| {
        if (z > 0) {
            active |= @as(u16, 1) << @intCast(i);
            packed_bits |= @as(u32, z - 1) << @intCast(3 * i);
        }
    }
    return .{
        @truncate(active),
        @truncate(active >> 8),
        @truncate(packed_bits),
        @truncate(packed_bits >> 8),
        @truncate(packed_bits >> 16),
        @truncate(packed_bits >> 24),
    };
}

pub const Error = error{ DeviceNotFound, AccessDenied, WriteFailed, WouldBlock };

test "output report size" {
    try std.testing.expectEqual(USB_REPORT_SIZE, @sizeOf(OutputReport));
}

test "bluetooth report wraps USB fields and checksum" {
    var usb: OutputReport = .{};
    usb.motor_left = 0x12;
    usb.motor_right = 0x34;
    usb.left_trigger_effect = effectRigid(180);

    const bt = BtOutputReport.fromUsb(&usb, 3);
    try std.testing.expectEqual(BT_REPORT_ID, bt.report_id);
    try std.testing.expectEqual(0x30, bt.sequence);
    try std.testing.expectEqual(BT_OUTPUT_TAG, bt.tag);
    try std.testing.expectEqual(0x12, bt.common[3]);
    try std.testing.expectEqual(0x34, bt.common[2]);
    try std.testing.expectEqual(0, bt.reserved[0]);
    try std.testing.expectEqual(0, bt.reserved[23]);

    const bytes = std.mem.asBytes(&bt);
    var checksum: u32 = bytes[74];
    checksum |= @as(u32, bytes[75]) << 8;
    checksum |= @as(u32, bytes[76]) << 16;
    checksum |= @as(u32, bytes[77]) << 24;
    try std.testing.expectEqual(checksum, bluetoothCrc(bytes[0..74]));
}

test "crc32 little-endian known vector" {
    var crc = crc32LeUpdate(0xFFFFFFFF, "123456789");
    crc = ~crc;
    try std.testing.expectEqual(0xCBF43926, crc);
}

test "trigger effect encodings" {
    const off = effectOff();
    try std.testing.expectEqual(@intFromEnum(EffectMode.reset), off[0]);

    const rigid = effectRigid(180);
    try std.testing.expectEqual(@intFromEnum(EffectMode.rigid), rigid[0]);
    try std.testing.expectEqual(0, rigid[1]);
    try std.testing.expectEqual(180, rigid[2]);

    const vibrate = effectVibrate(20, 130);
    try std.testing.expectEqual(@intFromEnum(EffectMode.vibrate), vibrate[0]);
    try std.testing.expectEqual(20, vibrate[1]);
    try std.testing.expectEqual(130, vibrate[2]);

    // top 2 zones maxed -> active mask bits 8 and 9 -> active = 0x0300
    const zones = effectRigidZones(.{ 0, 0, 0, 0, 0, 0, 0, 0, 8, 8 });
    try std.testing.expectEqual(@intFromEnum(EffectMode.rigid_zones), zones[0]);
    try std.testing.expectEqual(0x00, zones[1]); // active mask low byte
    try std.testing.expectEqual(0x03, zones[2]); // active mask high byte
    try std.testing.expectEqual(0x00, zones[3]); // packed bits 0-7 (zones 0-2)
    try std.testing.expectEqual(0x00, zones[4]); // packed bits 8-15 (zones 3-5)
    try std.testing.expectEqual(0x00, zones[5]); // packed bits 16-23 (zones 6-7)
    try std.testing.expectEqual(0x3F, zones[6]); // packed bits 24-29 (zones 8-9, 7+7)

    // all zones maxed -> the 30-bit packed field is all ones, freq lands at 9
    const all = effectVibrateZones(.{ 8, 8, 8, 8, 8, 8, 8, 8, 8, 8 }, 20);
    try std.testing.expectEqual(@intFromEnum(EffectMode.vibrate_zones), all[0]);
    try std.testing.expectEqual(0xFF, all[1]); // active mask low byte
    try std.testing.expectEqual(0x03, all[2]); // active mask high byte
    try std.testing.expectEqual(0xFF, all[3]); // packed bits 0-7
    try std.testing.expectEqual(0xFF, all[4]); // packed bits 8-15
    try std.testing.expectEqual(0xFF, all[5]); // packed bits 16-23
    try std.testing.expectEqual(0x3F, all[6]); // packed bits 24-29 (30 bits)
    try std.testing.expectEqual(20, all[9]); // frequency byte
}
