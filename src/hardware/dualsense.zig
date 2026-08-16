// SPDX-License-Identifier: AGPL-3.0-or-later

//! Complete DualSense USB/Bluetooth HID protocol reference.
//!
//! Covers output reports (rumble, adaptive triggers, audio, LEDs, player LEDs),
//! input reports (sticks, buttons, triggers, IMU, touchpad, battery), and the
//! main feature-report IDs.  Packet layouts are derived from the Linux
//! `hid-playstation` driver, SDL's `SDL_hidapi_ps5.c`, `dualsensectl`, and
//! community reverse engineering.
//!
//! The `UsbOutputReport` and `BtOutputReport` types keep the same shape the
//! rest of the app already uses.  The larger `FullUsbOutputReport`,
//! `OutputReportCommon`, and input-report types are included as a reference.

const std = @import("std");

// ---------------------------------------------------------------------------
// Device and report IDs
// ---------------------------------------------------------------------------

pub const VENDOR_ID: u16 = 0x054C;
pub const PRODUCT_IDS = [_]u16{ 0x0CE6, 0x0DF2 };

pub const Bus = enum {
    usb,
    bluetooth,
};

// Output reports.  `USB_REPORT_*` are the short 48-byte form used by this app.
pub const USB_REPORT_ID: u8 = 0x02;
pub const USB_REPORT_SIZE: usize = 48;
pub const USB_OUTPUT_REPORT_FULL_SIZE: usize = 63;

pub const BT_REPORT_ID: u8 = 0x31;
pub const BT_REPORT_SIZE: usize = 78;
pub const BT_OUTPUT_TAG: u8 = 0x10;
pub const BT_CRC_SEED: u8 = 0xA2;

// Input reports.
pub const USB_INPUT_REPORT_ID: u8 = 0x01;
pub const USB_INPUT_REPORT_SIZE: usize = 64;
pub const BT_INPUT_REPORT_ID: u8 = 0x31;
pub const BT_INPUT_REPORT_SIZE: usize = 78;
pub const BT_INPUT_CRC_SEED: u8 = 0xA1;

// Feature reports (IDs and sizes only; CRC seed is 0xA3 for Bluetooth).
pub const FEATURE_CALIBRATION_ID: u8 = 0x05;
pub const FEATURE_CALIBRATION_SIZE: usize = 41;
pub const FEATURE_PAIRING_ID: u8 = 0x09;
pub const FEATURE_PAIRING_SIZE: usize = 20;
pub const FEATURE_FIRMWARE_ID: u8 = 0x20;
pub const FEATURE_FIRMWARE_SIZE: usize = 64;
pub const FEATURE_BLUETOOTH_CONTROL_ID: u8 = 0x08;
pub const FEATURE_BLUETOOTH_CONTROL_SIZE: usize = 47;
pub const FEATURE_CRC_SEED: u8 = 0xA3;

// ---------------------------------------------------------------------------
// Output-report flag bits
// ---------------------------------------------------------------------------

/// valid_flag0 (byte 1 of the common output payload).
///
/// Bit 0/1 select the rumble path.  Classic rumble uses both bits; haptic
/// audio uses the trigger/audio bits and keeps the rumble bits clear.
pub const Flag0 = struct {
    pub const COMPATIBLE_VIBRATION: u8 = 0x01; // classic rumble motors
    pub const HAPTICS_SELECT: u8 = 0x02; // 0 = classic motors, 1 = voice coils
    pub const RUMBLE: u8 = COMPATIBLE_VIBRATION | HAPTICS_SELECT;
    pub const RIGHT_TRIGGER: u8 = 0x04;
    pub const LEFT_TRIGGER: u8 = 0x08;
    pub const HEADPHONE_VOLUME: u8 = 0x10;
    pub const SPEAKER_VOLUME: u8 = 0x20;
    pub const MIC_VOLUME: u8 = 0x40;
    pub const AUDIO_CONTROL: u8 = 0x80;

    pub const ALL: u8 = RUMBLE | RIGHT_TRIGGER | LEFT_TRIGGER;
    /// Native audio-haptics: triggers + audio control, no rumble bits.
    /// Rumble bits switch to classic emulation and silence the voice coils.
    pub const AUDIO_HAPTICS: u8 = RIGHT_TRIGGER | LEFT_TRIGGER | HEADPHONE_VOLUME |
        SPEAKER_VOLUME | MIC_VOLUME | AUDIO_CONTROL;
};

/// valid_flag1 (byte 2 of the common output payload).
pub const Flag1 = struct {
    pub const MIC_MUTE_LED_CONTROL_ENABLE: u8 = 0x01;
    pub const POWER_SAVE_CONTROL_ENABLE: u8 = 0x02;
    pub const LIGHTBAR_CONTROL_ENABLE: u8 = 0x04;
    pub const RELEASE_LEDS: u8 = 0x08;
    pub const PLAYER_INDICATOR_CONTROL_ENABLE: u8 = 0x10;
    pub const HAPTIC_LOW_PASS_FILTER_ENABLE: u8 = 0x20;
    pub const VIBRATION_ATTENUATION_ENABLE: u8 = 0x40;
    pub const AUDIO_CONTROL2_ENABLE: u8 = 0x80;
};

/// Audio-control fields (bytes 5-8 and 38 of the common output payload).
pub const Audio = struct {
    pub const HEADPHONE_VOLUME_MAX: u8 = 0x7F;
    pub const SPEAKER_VOLUME_MAX: u8 = 0x64;
    pub const MIC_VOLUME_MAX: u8 = 0x40;

    /// Byte 8: un-mute internal speaker (output path sel = 3) and route
    /// RL/RR to the haptic actuators.
    pub const PATH_SEL_INTERNAL_SPEAKER: u8 = 0x30;

    /// Byte 38: speaker preamp gain +6 dB (bits 0-2 of audio_control2).
    pub const SP_PREAMP_GAIN_6DB: u8 = 0x02;
};

/// Power-save control bits (byte 10 of the common output payload).
pub const PowerSave = struct {
    pub const TOUCH: u8 = 0x01;
    pub const MOTION: u8 = 0x02;
    pub const HAPTICS: u8 = 0x04;
    pub const AUDIO: u8 = 0x08;
    pub const MIC_MUTE: u8 = 0x10;
    pub const SPEAKER_MUTE: u8 = 0x20;
    pub const HEADPHONES_MUTE: u8 = 0x40;
    pub const HAPTICS_MUTE: u8 = 0x80;
};

/// valid_flag2 (byte 39 of the common output payload).
pub const FLAG2_LED_BRIGHTNESS_CONTROL_ENABLE: u8 = 0x01;
pub const FLAG2_LIGHTBAR_SETUP_CONTROL_ENABLE: u8 = 0x02;
pub const FLAG2_RUMBLE_V2: u8 = 0x04; // improved rumble emulation, firmware 2.24+

/// lightbar_setup (byte 41 of the common output payload).
pub const LIGHTBAR_SETUP_LIGHT_ON: u8 = 0x01;
pub const LIGHTBAR_SETUP_LIGHT_OUT: u8 = 0x02;

/// Player-indicator LED patterns indexed by player number 0..7.
/// Bit 0 = right-most LED, bit 4 = left-most LED.
pub const PLAYER_LED_PATTERNS = [_]u8{
    0x00, // 0 = off
    0x04, // 1
    0x0A, // 2
    0x15, // 3
    0x1B, // 4
    0x1F, // 5
    0x11, // 6 (left + right only)
    0x0E, // 7 (center three)
};

/// Mute-button LED modes (mic_light_mode / mute_button_led).
pub const MuteLedMode = enum(u8) {
    off = 0,
    on = 1,
    pulse = 2,
};

// ---------------------------------------------------------------------------
// Output-report packet layouts
// ---------------------------------------------------------------------------

/// The 47-byte payload that is shared between USB and Bluetooth output reports.
/// This is the authoritative layout used by `dualsensectl` and SDL.
pub const OutputReportCommon = extern struct {
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
    host_timestamp: [4]u8 = [_]u8{0} ** 4,
    reduce_motor_power: u8 = 0,
    audio_control2: u8 = 0,
    valid_flag2: u8 = FLAG2_RUMBLE_V2,
    haptics_flags: u8 = 0,
    reserved: u8 = 0,
    lightbar_setup: u8 = 0,
    led_brightness: u8 = 0,
    player_leds: u8 = 0,
    led_red: u8 = 0,
    led_green: u8 = 0,
    led_blue: u8 = 0,
};

/// The 48-byte USB main output report (report ID 0x02).
/// Wraps the 47-byte `OutputReportCommon` payload that is also used for
/// Bluetooth.
pub const UsbOutputReport = extern struct {
    report_id: u8 = USB_REPORT_ID,
    common: OutputReportCommon = .{},

    pub fn fromCommon(common_report: *const OutputReportCommon) UsbOutputReport {
        return .{ .common = common_report.* };
    }
};

/// The kernel's full 63-byte USB output report.  Identical to the short form
/// followed by 15 padding bytes.
pub const FullUsbOutputReport = extern struct {
    report_id: u8 = USB_REPORT_ID,
    common: OutputReportCommon = .{},
    reserved: [15]u8 = [_]u8{0} ** 15,
};

/// Bluetooth output report: the 47-byte common section wrapped in a
/// sequence nibble, transport tag, padding, and CRC32-LE checksum.
pub const BtOutputReport = extern struct {
    report_id: u8 = BT_REPORT_ID,
    sequence: u8 = 0,
    tag: u8 = BT_OUTPUT_TAG,
    common: [47]u8 = [_]u8{0} ** 47,
    reserved: [24]u8 = [_]u8{0} ** 24,
    crc: [4]u8 = [_]u8{0} ** 4,

    pub fn fromUsb(report: *const UsbOutputReport, sequence: u8) BtOutputReport {
        var bt: BtOutputReport = .{ .sequence = (sequence & 0x0F) << 4 };
        @memcpy(&bt.common, std.mem.asBytes(&report.common));

        const checksum = crc32Le(BT_CRC_SEED, std.mem.asBytes(&bt)[0..74]);
        bt.crc[0] = @truncate(checksum);
        bt.crc[1] = @truncate(checksum >> 8);
        bt.crc[2] = @truncate(checksum >> 16);
        bt.crc[3] = @truncate(checksum >> 24);
        return bt;
    }
};

// ---------------------------------------------------------------------------
// CRC32
// ---------------------------------------------------------------------------

/// Verify a Bluetooth input report CRC.  `bytes` must be the full 78-byte
/// report; the last four bytes are the expected CRC.
pub fn verifyBluetoothInputCrc(bytes: []const u8) bool {
    if (bytes.len < 4) return false;
    const offset = bytes.len - 4;
    const expected = std.mem.readInt(u32, bytes[offset..][0..4], .little);
    return crc32Le(BT_INPUT_CRC_SEED, bytes[0..offset]) == expected;
}

fn crc32Le(seed: u8, bytes: []const u8) u32 {
    var crc = crc32LeUpdate(0xFFFFFFFF, &.{seed});
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

// ---------------------------------------------------------------------------
// Adaptive trigger effects
// ---------------------------------------------------------------------------

/// Trigger effect mode byte (byte 0 of the 11-byte effect section).
/// Note: `rigid_zones` is the community name for the feedback effect (0x21)
/// and `vibrate_zones` is the per-zone vibration effect (0x26).
pub const EffectMode = enum(u8) {
    rigid = 0x01, // uniform resistance: [start_pos, force]
    section = 0x02, // section/pulse resistance
    reset = 0x05, // release the actuator
    vibrate = 0x06, // single-point vibration
    rigid_zones = 0x21, // per-zone resistance, 10 zones x 3 bits
    bow = 0x22, // bow effect
    galloping = 0x23, // galloping effect
    weapon = 0x25, // weapon/trigger effect
    vibrate_zones = 0x26, // per-zone vibration
    machine = 0x27, // alternating vibration
    calibrate = 0xFC,
};

/// Eleven-byte trigger effect payload.
pub const TriggerEffect = [11]u8;

pub fn triggerEffectOff() TriggerEffect {
    return makeEffect(.reset, &.{0});
}

/// Uniform resistance; `force` 0..255 (0 is low force, not off).
pub fn triggerEffectRigid(force: u8) TriggerEffect {
    return makeEffect(.rigid, &.{ 0, force });
}

/// Single-point vibration; `freq` and `amp` are 0..255.
pub fn triggerEffectVibrate(freq: u8, amp: u8) TriggerEffect {
    return makeEffect(.vibrate, &.{ freq, amp });
}

/// Per-zone resistance; 10 zones, 0 = inactive, 1..8 = strength.
pub fn triggerEffectRigidZones(zones: [10]u8) TriggerEffect {
    var e = makeEffect(.rigid_zones, &.{});
    e[1..7].* = packZones(zones);
    return e;
}

/// Per-zone vibration; 10 zones, 0 = inactive, 1..8 = amplitude.
pub fn triggerEffectVibrateZones(zones: [10]u8, freq: u8) TriggerEffect {
    var e = makeEffect(.vibrate_zones, &.{});
    e[1..7].* = packZones(zones);
    e[9] = freq;
    return e;
}

/// Feedback effect with resistance starting at `position` (0..9) and strength
/// 1..8 applied to every zone from `position` to the end.
pub fn triggerEffectFeedback(position: u8, strength: u8) TriggerEffect {
    var zones = [_]u8{0} ** 10;
    const pos = @min(position, 9);
    const s = @min(strength, 8);
    for (pos..10) |i| zones[i] = s;
    return triggerEffectRigidZones(zones);
}

/// Weapon effect: resistance between `start` and `end` positions (0..8/9).
pub fn triggerEffectWeapon(start: u8, end: u8, strength: u8) TriggerEffect {
    var e = makeEffect(.weapon, &.{});
    const mask = startStopZones(start, end);
    e[1] = @truncate(mask);
    e[2] = @truncate(mask >> 8);
    e[3] = @min(strength, 8) -| 1;
    return e;
}

/// Bow effect: resistance between `start` and `end` with `strength` and
/// `snap_force` (both 1..8).
pub fn triggerEffectBow(start: u8, end: u8, strength: u8, snap_force: u8) TriggerEffect {
    var e = makeEffect(.bow, &.{});
    const mask = startStopZones(start, end);
    const pair = forcePair(strength -| 1, snap_force -| 1);
    e[1] = @truncate(mask);
    e[2] = @truncate(mask >> 8);
    e[3] = @truncate(pair);
    return e;
}

/// Galloping effect between `start` and `end` with two foot strengths and a
/// frequency (all 1..255).
pub fn triggerEffectGalloping(start: u8, end: u8, first_foot: u8, second_foot: u8, frequency: u8) TriggerEffect {
    var e = makeEffect(.galloping, &.{});
    const mask = startStopZones(start, end);
    const pair = forcePair(second_foot, first_foot);
    e[1] = @truncate(mask);
    e[2] = @truncate(mask >> 8);
    e[3] = @truncate(pair);
    e[4] = frequency;
    return e;
}

/// Machine effect that alternates between `strength_a` and `strength_b`
/// (0..7) at `frequency` and `period`.
pub fn triggerEffectMachine(start: u8, end: u8, strength_a: u8, strength_b: u8, frequency: u8, period: u8) TriggerEffect {
    var e = makeEffect(.machine, &.{});
    const mask = startStopZones(start, end);
    const pair = forcePair(strength_a, strength_b);
    e[1] = @truncate(mask);
    e[2] = @truncate(mask >> 8);
    e[3] = @truncate(pair);
    e[4] = frequency;
    e[5] = period;
    return e;
}

fn makeEffect(mode: EffectMode, params: []const u8) TriggerEffect {
    var e: TriggerEffect = [_]u8{0} ** 11;
    e[0] = @intFromEnum(mode);
    for (params, 1..) |p, i| e[i] = p;
    return e;
}

fn startStopZones(start: u8, end: u8) u16 {
    const s = @min(start, 9);
    const e = @min(end, 9);
    return (@as(u16, 1) << @intCast(s)) | (@as(u16, 1) << @intCast(e));
}

fn forcePair(a: u8, b: u8) u8 {
    return (a & 0x07) | ((b & 0x07) << 3);
}

/// Packs 10 zone levels into the 6-byte active-mask + 3-bits-per-zone
/// payload (kernel/SDL encoding).
fn packZones(zones: [10]u8) [6]u8 {
    var active: u16 = 0;
    var packed_bits: u32 = 0;
    for (zones, 0..) |z, i| {
        const level = @min(z, 8);
        if (level > 0) {
            active |= @as(u16, 1) << @intCast(i);
            packed_bits |= @as(u32, level - 1) << @intCast(3 * i);
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

// ---------------------------------------------------------------------------
// Input reports
// ---------------------------------------------------------------------------

/// Touchpad dimensions.
pub const TOUCHPAD_WIDTH = 1920;
pub const TOUCHPAD_HEIGHT = 1080;

/// A single touch point from the touchpad (4 bytes).
pub const TouchPoint = extern struct {
    contact: u8,
    x_lo: u8,
    nibble: u8, // low nibble = x_hi, high nibble = y_lo
    y_hi: u8,

    pub fn active(self: *const TouchPoint) bool {
        return self.contact & DS_TOUCH_POINT_INACTIVE == 0;
    }

    pub fn id(self: *const TouchPoint) u8 {
        return self.contact & 0x7F;
    }

    pub fn x(self: *const TouchPoint) u12 {
        const hi: u12 = @as(u12, self.nibble & 0x0F) << 8;
        return hi | self.x_lo;
    }

    pub fn y(self: *const TouchPoint) u12 {
        const lo: u12 = @as(u12, self.nibble >> 4);
        return (@as(u12, self.y_hi) << 4) | lo;
    }
};

pub const DS_TOUCH_POINT_INACTIVE: u8 = 0x80;

/// Button masks for bytes 7-9 of the common input report.
pub const Buttons0 = struct {
    pub const HAT_SWITCH: u8 = 0x0F;
    pub const SQUARE: u8 = 0x10;
    pub const CROSS: u8 = 0x20;
    pub const CIRCLE: u8 = 0x40;
    pub const TRIANGLE: u8 = 0x80;
};

pub const Buttons1 = struct {
    pub const L1: u8 = 0x01;
    pub const R1: u8 = 0x02;
    pub const L2: u8 = 0x04;
    pub const R2: u8 = 0x08;
    pub const CREATE: u8 = 0x10;
    pub const OPTIONS: u8 = 0x20;
    pub const L3: u8 = 0x40;
    pub const R3: u8 = 0x80;
};

pub const Buttons2 = struct {
    pub const PS_HOME: u8 = 0x01;
    pub const TOUCHPAD: u8 = 0x02;
    pub const MIC_MUTE: u8 = 0x04;
};

/// DualSense Edge extra buttons in byte 9, bits 4-7.
pub const EdgeButtons = struct {
    pub const FN1: u8 = 0x10;
    pub const FN2: u8 = 0x20;
    pub const LEFT_PADDLE: u8 = 0x40;
    pub const RIGHT_PADDLE: u8 = 0x80;
};

/// 2D hat-switch value where each axis is -1, 0, or +1.
pub const Hat = struct { x: i2, y: i2 };

/// Hat-switch lookup table.  Index 8 (and any invalid value) maps to neutral.
pub const hat_switch = [16]Hat{
    .{ .x = 0, .y = -1 }, .{ .x = 1, .y = -1 }, .{ .x = 1, .y = 0 },  .{ .x = 1, .y = 1 },
    .{ .x = 0, .y = 1 },  .{ .x = -1, .y = 1 }, .{ .x = -1, .y = 0 }, .{ .x = -1, .y = -1 },
    .{ .x = 0, .y = 0 },  .{ .x = 0, .y = 0 },  .{ .x = 0, .y = 0 },  .{ .x = 0, .y = 0 },
    .{ .x = 0, .y = 0 },  .{ .x = 0, .y = 0 },  .{ .x = 0, .y = 0 },  .{ .x = 0, .y = 0 },
};

/// Status bytes in the common input report.
pub const Status0 = struct {
    pub const BATTERY_CAPACITY: u8 = 0x0F;
    pub const CHARGING: u8 = 0xF0;
    pub const CHARGING_SHIFT = 4;
};

pub const Status1 = struct {
    pub const HP_DETECT: u8 = 0x01;
    pub const MIC_DETECT: u8 = 0x02;
    pub const JACK_DETECT: u8 = HP_DETECT | MIC_DETECT;
    pub const MIC_MUTE: u8 = 0x04;
};

pub const BatteryStatus = enum(u8) {
    discharging = 0x0,
    charging = 0x1,
    full = 0x2,
    not_charging_voltage = 0xa,
    not_charging_temp = 0xb,
    failure = 0xf,
};

/// IMU scaling constants.
pub const ACC_RES_PER_G: i16 = 8192;
pub const GYRO_RES_PER_DEG_S: i16 = 1024;

/// The 63-byte payload shared by USB and Bluetooth input reports.
/// Multi-byte values are split into bytes so the `extern struct` has no
/// padding and matches the controller's wire format exactly.
pub const InputReportCommon = extern struct {
    left_stick_x: u8,
    left_stick_y: u8,
    right_stick_x: u8,
    right_stick_y: u8,
    left_trigger: u8,
    right_trigger: u8,
    seq_number: u8,
    buttons0: u8,
    buttons1: u8,
    buttons2: u8,
    buttons3: u8,
    _reserved0_0: u8,
    _reserved0_1: u8,
    _reserved0_2: u8,
    _reserved0_3: u8,
    gyro_x_lo: u8,
    gyro_x_hi: u8,
    gyro_y_lo: u8,
    gyro_y_hi: u8,
    gyro_z_lo: u8,
    gyro_z_hi: u8,
    accel_x_lo: u8,
    accel_x_hi: u8,
    accel_y_lo: u8,
    accel_y_hi: u8,
    accel_z_lo: u8,
    accel_z_hi: u8,
    sensor_timestamp_0: u8,
    sensor_timestamp_1: u8,
    sensor_timestamp_2: u8,
    sensor_timestamp_3: u8,
    _reserved1: u8,
    touch0_contact: u8,
    touch0_x_lo: u8,
    touch0_nibble: u8,
    touch0_y_hi: u8,
    touch1_contact: u8,
    touch1_x_lo: u8,
    touch1_nibble: u8,
    touch1_y_hi: u8,
    _reserved2_0: u8,
    _reserved2_1: u8,
    _reserved2_2: u8,
    _reserved2_3: u8,
    _reserved2_4: u8,
    _reserved2_5: u8,
    _reserved2_6: u8,
    _reserved2_7: u8,
    _reserved2_8: u8,
    _reserved2_9: u8,
    _reserved2_10: u8,
    _reserved2_11: u8,
    status0: u8,
    status1: u8,
    status2: u8,
    _reserved3_0: u8,
    _reserved3_1: u8,
    _reserved3_2: u8,
    _reserved3_3: u8,
    _reserved3_4: u8,
    _reserved3_5: u8,
    _reserved3_6: u8,
    _reserved3_7: u8,
};

/// USB input report: report ID 0x01 followed by the 63-byte common payload.
pub const UsbInputReport = extern struct {
    report_id: u8 = USB_INPUT_REPORT_ID,
    common: InputReportCommon,
};

/// Bluetooth input report: report ID 0x31, one header byte, the 63-byte
/// common payload, 9 reserved bytes, and a CRC32-LE checksum.
pub const BtInputReport = extern struct {
    report_id: u8 = BT_INPUT_REPORT_ID,
    sequence_tag: u8 = 0,
    common: InputReportCommon,
    bt_reserved0: u8 = 0,
    bt_reserved1: u8 = 0,
    bt_reserved2: u8 = 0,
    bt_reserved3: u8 = 0,
    bt_reserved4: u8 = 0,
    bt_reserved5: u8 = 0,
    bt_reserved6: u8 = 0,
    bt_reserved7: u8 = 0,
    bt_reserved8: u8 = 0,
    crc0: u8 = 0,
    crc1: u8 = 0,
    crc2: u8 = 0,
    crc3: u8 = 0,

    pub fn verifyCrc(self: *const BtInputReport) bool {
        const bytes = std.mem.asBytes(self);
        return verifyBluetoothInputCrc(bytes);
    }
};

/// Decoded controller state.
pub const InputState = struct {
    left_stick: struct { x: u8, y: u8 },
    right_stick: struct { x: u8, y: u8 },
    left_trigger: u8,
    right_trigger: u8,
    square: bool,
    cross: bool,
    circle: bool,
    triangle: bool,
    l1: bool,
    r1: bool,
    l2: bool,
    r2: bool,
    create: bool,
    options: bool,
    l3: bool,
    r3: bool,
    ps: bool,
    touchpad: bool,
    mic_mute: bool,
    fn1: bool,
    fn2: bool,
    left_paddle: bool,
    right_paddle: bool,
    hat: Hat,
    gyro: [3]f32, // degrees per second
    accel: [3]f32, // g
    sensor_timestamp: u32,
    touch: [2]struct { active: bool, id: u8, x: u12, y: u12 },
    battery_capacity: u8, // 0..100
    battery_status: BatteryStatus,
    headphone: bool,
    microphone: bool,
    mic_mute_led: bool,
};

/// Decode the common 63-byte input payload into a high-level state.
pub fn decodeInput(report: *const InputReportCommon) InputState {
    const b0 = report.buttons0;
    const b1 = report.buttons1;
    const b2 = report.buttons2;
    const hat = b0 & Buttons0.HAT_SWITCH;
    const cap = report.status0 & Status0.BATTERY_CAPACITY;
    const charging = (report.status0 & Status0.CHARGING) >> Status0.CHARGING_SHIFT;
    const touch0: TouchPoint = .{
        .contact = report.touch0_contact,
        .x_lo = report.touch0_x_lo,
        .nibble = report.touch0_nibble,
        .y_hi = report.touch0_y_hi,
    };
    const touch1: TouchPoint = .{
        .contact = report.touch1_contact,
        .x_lo = report.touch1_x_lo,
        .nibble = report.touch1_nibble,
        .y_hi = report.touch1_y_hi,
    };
    const gyro_x = std.mem.readInt(i16, &.{ report.gyro_x_lo, report.gyro_x_hi }, .little);
    const gyro_y = std.mem.readInt(i16, &.{ report.gyro_y_lo, report.gyro_y_hi }, .little);
    const gyro_z = std.mem.readInt(i16, &.{ report.gyro_z_lo, report.gyro_z_hi }, .little);
    const accel_x = std.mem.readInt(i16, &.{ report.accel_x_lo, report.accel_x_hi }, .little);
    const accel_y = std.mem.readInt(i16, &.{ report.accel_y_lo, report.accel_y_hi }, .little);
    const accel_z = std.mem.readInt(i16, &.{ report.accel_z_lo, report.accel_z_hi }, .little);
    const sensor_timestamp = std.mem.readInt(u32, &.{
        report.sensor_timestamp_0,
        report.sensor_timestamp_1,
        report.sensor_timestamp_2,
        report.sensor_timestamp_3,
    }, .little);
    return .{
        .left_stick = .{ .x = report.left_stick_x, .y = report.left_stick_y },
        .right_stick = .{ .x = report.right_stick_x, .y = report.right_stick_y },
        .left_trigger = report.left_trigger,
        .right_trigger = report.right_trigger,
        .square = b0 & Buttons0.SQUARE != 0,
        .cross = b0 & Buttons0.CROSS != 0,
        .circle = b0 & Buttons0.CIRCLE != 0,
        .triangle = b0 & Buttons0.TRIANGLE != 0,
        .l1 = b1 & Buttons1.L1 != 0,
        .r1 = b1 & Buttons1.R1 != 0,
        .l2 = b1 & Buttons1.L2 != 0,
        .r2 = b1 & Buttons1.R2 != 0,
        .create = b1 & Buttons1.CREATE != 0,
        .options = b1 & Buttons1.OPTIONS != 0,
        .l3 = b1 & Buttons1.L3 != 0,
        .r3 = b1 & Buttons1.R3 != 0,
        .ps = b2 & Buttons2.PS_HOME != 0,
        .touchpad = b2 & Buttons2.TOUCHPAD != 0,
        .mic_mute = b2 & Buttons2.MIC_MUTE != 0,
        .fn1 = b2 & EdgeButtons.FN1 != 0,
        .fn2 = b2 & EdgeButtons.FN2 != 0,
        .left_paddle = b2 & EdgeButtons.LEFT_PADDLE != 0,
        .right_paddle = b2 & EdgeButtons.RIGHT_PADDLE != 0,
        .hat = hat_switch[hat],
        .gyro = .{
            @as(f32, @floatFromInt(gyro_x)) / @as(f32, GYRO_RES_PER_DEG_S),
            @as(f32, @floatFromInt(gyro_y)) / @as(f32, GYRO_RES_PER_DEG_S),
            @as(f32, @floatFromInt(gyro_z)) / @as(f32, GYRO_RES_PER_DEG_S),
        },
        .accel = .{
            @as(f32, @floatFromInt(accel_x)) / @as(f32, ACC_RES_PER_G),
            @as(f32, @floatFromInt(accel_y)) / @as(f32, ACC_RES_PER_G),
            @as(f32, @floatFromInt(accel_z)) / @as(f32, ACC_RES_PER_G),
        },
        .sensor_timestamp = sensor_timestamp,
        .touch = .{
            .{
                .active = touch0.active(),
                .id = touch0.id(),
                .x = touch0.x(),
                .y = touch0.y(),
            },
            .{
                .active = touch1.active(),
                .id = touch1.id(),
                .x = touch1.x(),
                .y = touch1.y(),
            },
        },
        .battery_capacity = @min(cap * 10 + 5, 100),
        .battery_status = @enumFromInt(charging),
        .headphone = report.status1 & Status1.HP_DETECT != 0,
        .microphone = report.status1 & Status1.MIC_DETECT != 0,
        .mic_mute_led = report.status1 & Status1.MIC_MUTE != 0,
    };
}

// ---------------------------------------------------------------------------
// Errors shared by the platform HID implementations.
// ---------------------------------------------------------------------------

pub const Error = error{ DeviceNotFound, AccessDenied, WriteFailed, WouldBlock };

// ---------------------------------------------------------------------------
// Compile-time size checks
// ---------------------------------------------------------------------------

comptime {
    if (@sizeOf(UsbOutputReport) != USB_REPORT_SIZE) {
        @compileError("UsbOutputReport must be exactly 48 bytes");
    }
    if (@sizeOf(FullUsbOutputReport) != USB_OUTPUT_REPORT_FULL_SIZE) {
        @compileError("FullUsbOutputReport must be exactly 63 bytes");
    }
    if (@sizeOf(OutputReportCommon) != 47) {
        @compileError("OutputReportCommon must be exactly 47 bytes");
    }
    if (@sizeOf(BtOutputReport) != BT_REPORT_SIZE) {
        @compileError("BtOutputReport must be exactly 78 bytes");
    }
    if (@sizeOf(InputReportCommon) != USB_INPUT_REPORT_SIZE - 1) {
        @compileError("InputReportCommon must be exactly 63 bytes");
    }
    if (@sizeOf(UsbInputReport) != USB_INPUT_REPORT_SIZE) {
        @compileError("UsbInputReport must be exactly 64 bytes");
    }
    if (@sizeOf(BtInputReport) != BT_INPUT_REPORT_SIZE) {
        @compileError("BtInputReport must be exactly 78 bytes");
    }
    if (@sizeOf(TouchPoint) != 4) {
        @compileError("TouchPoint must be exactly 4 bytes");
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "output report size" {
    try std.testing.expectEqual(USB_REPORT_SIZE, @sizeOf(UsbOutputReport));
    try std.testing.expectEqual(USB_OUTPUT_REPORT_FULL_SIZE, @sizeOf(FullUsbOutputReport));
    try std.testing.expectEqual(BT_REPORT_SIZE, @sizeOf(BtOutputReport));
}

test "input report size" {
    try std.testing.expectEqual(USB_INPUT_REPORT_SIZE, @sizeOf(UsbInputReport));
    try std.testing.expectEqual(BT_INPUT_REPORT_SIZE, @sizeOf(BtInputReport));
    try std.testing.expectEqual(USB_INPUT_REPORT_SIZE - 1, @sizeOf(InputReportCommon));
}

test "bluetooth report wraps USB fields and checksum" {
    var usb: UsbOutputReport = .{};
    usb.common.motor_left = 0x12;
    usb.common.motor_right = 0x34;
    usb.common.left_trigger_effect = triggerEffectRigid(180);

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
    try std.testing.expectEqual(checksum, crc32Le(BT_CRC_SEED, bytes[0..74]));
}

test "crc32 little-endian known vector" {
    var crc = crc32LeUpdate(0xFFFFFFFF, "123456789");
    crc = ~crc;
    try std.testing.expectEqual(0xCBF43926, crc);
}

test "trigger effect encodings" {
    const off = triggerEffectOff();
    try std.testing.expectEqual(@intFromEnum(EffectMode.reset), off[0]);

    const rigid = triggerEffectRigid(180);
    try std.testing.expectEqual(@intFromEnum(EffectMode.rigid), rigid[0]);
    try std.testing.expectEqual(0, rigid[1]);
    try std.testing.expectEqual(180, rigid[2]);

    const vibrate = triggerEffectVibrate(20, 130);
    try std.testing.expectEqual(@intFromEnum(EffectMode.vibrate), vibrate[0]);
    try std.testing.expectEqual(20, vibrate[1]);
    try std.testing.expectEqual(130, vibrate[2]);

    // top 2 zones maxed -> active = 0x0300
    const zones = triggerEffectRigidZones(.{ 0, 0, 0, 0, 0, 0, 0, 0, 8, 8 });
    try std.testing.expectEqual(@intFromEnum(EffectMode.rigid_zones), zones[0]);
    try std.testing.expectEqual(0x00, zones[1]); // active mask low byte
    try std.testing.expectEqual(0x03, zones[2]); // active mask high byte
    try std.testing.expectEqual(0x00, zones[3]); // packed bits 0-7 (zones 0-2)
    try std.testing.expectEqual(0x00, zones[4]); // packed bits 8-15 (zones 3-5)
    try std.testing.expectEqual(0x00, zones[5]); // packed bits 16-23 (zones 6-7)
    try std.testing.expectEqual(0x3F, zones[6]); // packed bits 24-29 (zones 8-9)

    // all zones maxed -> 30-bit packed field all ones, freq at byte 9
    const all = triggerEffectVibrateZones(.{ 8, 8, 8, 8, 8, 8, 8, 8, 8, 8 }, 20);
    try std.testing.expectEqual(@intFromEnum(EffectMode.vibrate_zones), all[0]);
    try std.testing.expectEqual(0xFF, all[1]);
    try std.testing.expectEqual(0x03, all[2]);
    try std.testing.expectEqual(0xFF, all[3]);
    try std.testing.expectEqual(0xFF, all[4]);
    try std.testing.expectEqual(0xFF, all[5]);
    try std.testing.expectEqual(0x3F, all[6]);
    try std.testing.expectEqual(20, all[9]);

    const clamped = triggerEffectRigidZones(.{ 9, 9, 9, 9, 9, 9, 9, 9, 9, 9 });
    try std.testing.expectEqual(0x3F, clamped[6]);
}

test "advanced trigger effect constructors" {
    const weapon = triggerEffectWeapon(2, 8, 8);
    try std.testing.expectEqual(@intFromEnum(EffectMode.weapon), weapon[0]);
    try std.testing.expectEqual(0x04, weapon[1]); // bit 2
    try std.testing.expectEqual(0x01, weapon[2]); // bit 8
    try std.testing.expectEqual(7, weapon[3]); // strength - 1

    const bow = triggerEffectBow(1, 8, 8, 1);
    try std.testing.expectEqual(@intFromEnum(EffectMode.bow), bow[0]);

    const gallop = triggerEffectGalloping(0, 9, 0, 7, 3);
    try std.testing.expectEqual(@intFromEnum(EffectMode.galloping), gallop[0]);
    try std.testing.expectEqual(3, gallop[4]);

    const machine = triggerEffectMachine(1, 9, 7, 7, 5, 10);
    try std.testing.expectEqual(@intFromEnum(EffectMode.machine), machine[0]);
    try std.testing.expectEqual(5, machine[4]);
    try std.testing.expectEqual(10, machine[5]);
}

test "touch point decoding" {
    const tp = TouchPoint{
        .contact = 0x05,
        .x_lo = 0x34,
        .nibble = 0xA1, // x_hi = 1, y_lo = 0xA
        .y_hi = 0x02,
    };
    try std.testing.expect(tp.active());
    try std.testing.expectEqual(@as(u8, 5), tp.id());
    try std.testing.expectEqual(@as(u12, 0x134), tp.x());
    try std.testing.expectEqual(@as(u12, 0x2A), tp.y());

    const inactive = TouchPoint{ .contact = 0x85, .x_lo = 0, .nibble = 0, .y_hi = 0 };
    try std.testing.expect(!inactive.active());
}

test "input state decoding" {
    var common: InputReportCommon = std.mem.zeroes(InputReportCommon);
    common.left_stick_x = 128;
    common.left_trigger = 64;
    common.buttons0 = Buttons0.CIRCLE | 2; // hat = 2 (east)
    common.buttons1 = Buttons1.L1 | Buttons1.OPTIONS;
    common.buttons2 = Buttons2.PS_HOME | EdgeButtons.LEFT_PADDLE;
    common.gyro_x_lo = 0x00;
    common.gyro_x_hi = 0x04; // 1024 little-endian
    common.accel_x_lo = 0x00;
    common.accel_x_hi = 0x20; // 8192 little-endian
    common.sensor_timestamp_0 = 0x78;
    common.sensor_timestamp_1 = 0x56;
    common.sensor_timestamp_2 = 0x34;
    common.sensor_timestamp_3 = 0x12;
    common.status0 = 5 | (@as(u8, 1) << 4); // 50% + charging
    common.status1 = Status1.HP_DETECT | Status1.MIC_MUTE;

    const state = decodeInput(&common);
    try std.testing.expectEqual(@as(u8, 128), state.left_stick.x);
    try std.testing.expectEqual(@as(u8, 64), state.left_trigger);
    try std.testing.expect(state.circle);
    try std.testing.expect(state.l1);
    try std.testing.expect(state.options);
    try std.testing.expect(state.ps);
    try std.testing.expect(state.left_paddle);
    try std.testing.expectEqual(@as(i2, 1), state.hat.x);
    try std.testing.expectEqual(@as(i2, 0), state.hat.y);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), state.gyro[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), state.accel[0], 0.001);
    try std.testing.expectEqual(@as(u32, 0x12345678), state.sensor_timestamp);
    try std.testing.expectEqual(@as(u8, 55), state.battery_capacity); // 5*10+5
    try std.testing.expectEqual(BatteryStatus.charging, state.battery_status);
    try std.testing.expect(state.headphone);
    try std.testing.expect(state.mic_mute_led);
}
