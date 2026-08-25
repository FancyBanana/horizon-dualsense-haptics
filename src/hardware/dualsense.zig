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
//!
//! For building output reports, prefer the high-level API in
//! `dualsense-util.zig` (`ReportBuilder`, trigger effect constructors); this
//! module is the raw wire-format reference it compiles down to.

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

// Output reports.  `USB_REPORT_*` are the short 48-byte form used by this
// app (also used by SDL); the controller additionally accepts the full
// 63-byte form (`FullUsbOutputReport`) used by the kernel driver and
// dualsensectl — both wire formats are valid on USB.
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

/// Offset of the little-endian u16 "update version" inside the firmware
/// feature report (0x20). The controller gates improved rumble emulation
/// (FLAG2_RUMBLE_V2) on this version.
pub const FEATURE_FIRMWARE_VERSION_OFFSET: usize = 44;

// ---------------------------------------------------------------------------
// Output-report flag bits
// ---------------------------------------------------------------------------

/// valid_flag0 (byte 1 of the common output payload).  Kernel names in
/// parentheses (hid-playstation.c).
pub const Flag0 = struct {
    /// Apply the rumble motor strengths (kernel `COMPATIBLE_VIBRATION`).
    pub const RUMBLE_ENABLE: u8 = 0x01;
    /// Select the classic-rumble actuator mode instead of voice-coil haptics
    /// (kernel `HAPTICS_SELECT`; despite its name, hid-playstation.c sets
    /// this bit for classic rumble together with `COMPATIBLE_VIBRATION`).
    pub const RUMBLE_CLASSIC: u8 = 0x02;
    pub const RUMBLE: u8 = RUMBLE_ENABLE | RUMBLE_CLASSIC;

    pub const RIGHT_TRIGGER: u8 = 0x04;
    pub const LEFT_TRIGGER: u8 = 0x08;

    /// Audio-volume and audio-control enable bits. Each applies the matching
    /// byte in the common output report.
    pub const HEADPHONE_VOLUME: u8 = 0x10;
    pub const SPEAKER_VOLUME: u8 = 0x20;
    pub const MIC_VOLUME: u8 = 0x40;
    pub const APPLY_AUDIO_CONTROL: u8 = 0x80;

    /// Default simple-mode flags: rumble emulation plus adaptive triggers.
    pub const RUMBLE_AND_TRIGGERS: u8 = RUMBLE | RIGHT_TRIGGER | LEFT_TRIGGER;
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

    /// Selects which sinks receive the L/R channel sources (bits 4-5 of
    /// `audio_enable_bits`; table from hid-playstation.c; columns are
    /// sinks, entries are the source routed to each):
    ///
    ///        HP-left  HP-right Speaker
    ///   0:   L        R        X (unrouted)
    ///   1:   L        L        X
    ///   2:   L        L        R
    ///   3:   X        X        R   <- `PATH_SEL_INTERNAL_SPEAKER`
    ///
    /// NOTE: the haptic actuators are NOT a sink in this table — over USB
    /// they are driven by the rear-left/right channels of the 4-channel
    /// audio interface, independently of this nibble.
    /// Path select 0 (power-on default): L -> headphone left,
    /// R -> headphone right, internal speaker unrouted/muted.
    pub const PATH_SEL_HEADPHONES: u8 = 0x00;

    /// Path select 3: HP-left/HP-right sinks muted, R source routed to the
    /// internal mono speaker.
    pub const PATH_SEL_INTERNAL_SPEAKER: u8 = 0x30;

    /// Byte 38: speaker preamp gain +6 dB (bits 0-2 of audio_control2).
    pub const SP_PREAMP_GAIN_6DB: u8 = 0x02;

    // Microphone input flags for byte 8 (dualsensectl "audio_flags"):
    pub const FORCE_INTERNAL_MIC: u8 = 0x01;
    pub const FORCE_HEADSET_MIC: u8 = 0x02;
    pub const ECHO_CANCEL: u8 = 0x04;
    pub const NOISE_CANCEL: u8 = 0x08;

    /// Mic input path select (bits 6-7 of byte 8): voice-chat processing.
    pub const INPUT_PATH_CHAT: u8 = 1 << 6;
    /// Mic input path select (bits 6-7 of byte 8): ASR/raw path.
    pub const INPUT_PATH_ASR: u8 = 2 << 6;
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
pub const FLAG2_RUMBLE_V2: u8 = 0x04; // improved rumble emulation; update version >= 2.21

/// lightbar_setup (byte 42 of the common output payload).
pub const LIGHTBAR_SETUP_NO_CHANGE: u8 = 0x00; // 0 keeps the current setup
pub const LIGHTBAR_SETUP_LIGHT_ON: u8 = 0x01;
pub const LIGHTBAR_SETUP_LIGHT_OUT: u8 = 0x02;

/// haptics_flags (byte 40 of the common output payload).
pub const HAPTICS_FLAG_LOW_PASS_FILTER: u8 = 0x01;

/// Player-indicator LED patterns indexed by player number 0..5.
///
/// Current firmware uses the byte directly: bit 0 and bit 4 are the outer
/// LEDs, bit 2 is the center LED. Patterns match the Linux hid-playstation
/// mapping; entries 6-7 are the extra non-player patterns from dualsensectl.
pub const PLAYER_LED_PATTERNS = [_]u8{
    0x00, // 0 = off
    0x04, // 1: center
    0x0A, // 2: inner pair
    0x15, // 3: center + outer pair
    0x1B, // 4: inner + outer pair
    0x1F, // 5: all
    0x11, // 6: outer pair
    0x0E, // 7: inner three
};

/// Bit 5 of the player_leds byte: apply the pattern instantly instead of
/// with the fade animation.
pub const PLAYER_LEDS_INSTANT: u8 = 0x20;

/// Mute-button LED modes (mic_light_mode / mute_button_led).
pub const MuteLedMode = enum(u8) {
    off = 0,
    on = 1,
    pulse = 2,
};

/// Whether the controller firmware supports improved rumble emulation
/// (FLAG2_RUMBLE_V2): true for update version >= 2.21 (the value read from
/// feature report 0x20 at `FEATURE_FIRMWARE_VERSION_OFFSET`).
pub fn rumbleV2Supported(update_version: u16) bool {
    return update_version >= (2 << 8 | 21);
}

// ---------------------------------------------------------------------------
// Output-report packet layouts
// ---------------------------------------------------------------------------

/// The 47-byte payload that is shared between USB and Bluetooth output reports.
/// This is the authoritative layout used by `dualsensectl` and SDL.
pub const OutputReportCommon = extern struct {
    valid_flag0: u8 = Flag0.RUMBLE_AND_TRIGGERS,
    valid_flag1: u8 = 0,
    motor_right: u8 = 0,
    motor_left: u8 = 0,
    headphone_volume: u8 = 0,
    /// Kernel marks the byte 0x0..0xff; practical window is ~0x3d..0x64
    /// and 0x64 (100%) is what the kernel writes when routing to the
    /// internal speaker.
    speaker_volume: u8 = 0,
    microphone_volume: u8 = 0,
    audio_enable_bits: u8 = 0,
    mic_light_mode: u8 = 0,
    /// Power-save and mute control (byte 10). Bits 0-3 selectively disable
    /// features when idle, bits 4-7 mute outputs. Gated by
    /// `Flag1.POWER_SAVE_CONTROL_ENABLE`. See `PowerSave` for the bit layout.
    power_save_mute_control: u8 = 0,
    right_trigger_effect: [11]u8 = [_]u8{0} ** 11,
    left_trigger_effect: [11]u8 = [_]u8{0} ** 11,
    host_timestamp: [4]u8 = [_]u8{0} ** 4,
    /// Vibration attenuation (byte 37): scales down classic-rumble strength
    /// (bits 0-2) and trigger vibration strength (bits 4-6), each 0..7.
    /// Gated by `Flag1.VIBRATION_ATTENUATION_ENABLE`; see
    /// `ReportBuilder.setVibrationAttenuation` in dualsense-util.zig.
    motor_power_level: u8 = 0,
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

    /// Serialize to the 48-byte wire format.
    pub fn toBytes(self: *const UsbOutputReport) [USB_REPORT_SIZE]u8 {
        return std.mem.asBytes(self)[0..USB_REPORT_SIZE].*;
    }
};

/// The kernel's full 63-byte USB output report.  Identical to the short form
/// followed by 15 padding bytes.
pub const FullUsbOutputReport = extern struct {
    report_id: u8 = USB_REPORT_ID,
    common: OutputReportCommon = .{},
    reserved: [15]u8 = [_]u8{0} ** 15,

    /// Serialize to the 63-byte wire format.
    pub fn toBytes(self: *const FullUsbOutputReport) [USB_OUTPUT_REPORT_FULL_SIZE]u8 {
        return std.mem.asBytes(self)[0..USB_OUTPUT_REPORT_FULL_SIZE].*;
    }
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

    /// Serialize to the 78-byte wire format.  The CRC32-LE over the first
    /// 74 bytes is (re)written into the last four bytes, so the result is
    /// always a valid packet even if fields were mutated after construction.
    pub fn toBytes(self: *const BtOutputReport) [BT_REPORT_SIZE]u8 {
        var bytes: [BT_REPORT_SIZE]u8 = std.mem.asBytes(self)[0..BT_REPORT_SIZE].*;
        const checksum = crc32Le(BT_CRC_SEED, bytes[0..74]);
        std.mem.writeInt(u32, bytes[74..78], checksum, .little);
        return bytes;
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
// Adaptive trigger effects (raw encodings; constructors in dualsense-util.zig)
// ---------------------------------------------------------------------------

/// Trigger effect mode byte (byte 0 of the 11-byte effect section).
/// Canonical community names (Nielk1/Sony API) in parentheses:
/// `rigid_zones` = Feedback, `weapon` = SemiAutomaticGun, `vibrate_zones` =
/// AutomaticGun, `rigid` = Simple_Feedback, `section` = Simple_Weapon,
/// `vibrate` = Simple_Vibration.
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

    /// Parse a full 64-byte USB input report.  Returns null when the buffer
    /// has the wrong length or report ID.
    pub fn fromBytes(bytes: []const u8) ?UsbInputReport {
        if (bytes.len != USB_INPUT_REPORT_SIZE) return null;
        if (bytes[0] != USB_INPUT_REPORT_ID) return null;
        var report: UsbInputReport = undefined;
        @memcpy(std.mem.asBytes(&report), bytes);
        return report;
    }
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

    /// Parse a full 78-byte Bluetooth input report.  Returns null when the
    /// buffer has the wrong length or report ID.  Callers should also run
    /// `verifyCrc` on the result before trusting the data.
    pub fn fromBytes(bytes: []const u8) ?BtInputReport {
        if (bytes.len != BT_INPUT_REPORT_SIZE) return null;
        if (bytes[0] != BT_INPUT_REPORT_ID) return null;
        var report: BtInputReport = undefined;
        @memcpy(std.mem.asBytes(&report), bytes);
        return report;
    }
};

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

test "input report fromBytes" {
    // USB round-trip.
    var usb_bytes: [USB_INPUT_REPORT_SIZE]u8 = [_]u8{0} ** USB_INPUT_REPORT_SIZE;
    usb_bytes[0] = USB_INPUT_REPORT_ID;
    usb_bytes[1] = 128; // left_stick_x
    const usb_report = UsbInputReport.fromBytes(&usb_bytes).?;
    try std.testing.expectEqual(USB_INPUT_REPORT_ID, usb_report.report_id);
    try std.testing.expectEqual(@as(u8, 128), usb_report.common.left_stick_x);

    try std.testing.expect(UsbInputReport.fromBytes(usb_bytes[1..]) == null);
    usb_bytes[0] = 0xFF;
    try std.testing.expect(UsbInputReport.fromBytes(&usb_bytes) == null);

    // Bluetooth round-trip.
    var bt_bytes: [BT_INPUT_REPORT_SIZE]u8 = [_]u8{0} ** BT_INPUT_REPORT_SIZE;
    bt_bytes[0] = BT_INPUT_REPORT_ID;
    bt_bytes[2] = 64; // left_stick_x
    const bt_report = BtInputReport.fromBytes(&bt_bytes).?;
    try std.testing.expectEqual(BT_INPUT_REPORT_ID, bt_report.report_id);
    try std.testing.expectEqual(@as(u8, 64), bt_report.common.left_stick_x);

    try std.testing.expect(BtInputReport.fromBytes(bt_bytes[1..]) == null);
    bt_bytes[0] = 0xFF;
    try std.testing.expect(BtInputReport.fromBytes(&bt_bytes) == null);
}

test "output report toBytes round-trip and checksum" {
    var usb: UsbOutputReport = .{};
    usb.common.motor_left = 0x42;
    const usb_bytes = usb.toBytes();
    try std.testing.expectEqual(USB_REPORT_SIZE, usb_bytes.len);
    try std.testing.expectEqual(USB_REPORT_ID, usb_bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x42), usb_bytes[4]); // motor_left

    var full: FullUsbOutputReport = .{};
    full.common.motor_right = 0x11;
    const full_bytes = full.toBytes();
    try std.testing.expectEqual(USB_OUTPUT_REPORT_FULL_SIZE, full_bytes.len);
    try std.testing.expectEqual(USB_REPORT_ID, full_bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x11), full_bytes[3]); // motor_right
    try std.testing.expectEqual(@as(u8, 0), full_bytes[62]); // padding

    var bt: BtOutputReport = .{ .sequence = (5 & 0x0F) << 4 };
    bt.common[2] = 0x99;
    bt.crc = [_]u8{0xAA} ** 4; // stale checksum must be overwritten
    const bt_bytes = bt.toBytes();
    try std.testing.expectEqual(BT_REPORT_SIZE, bt_bytes.len);
    try std.testing.expectEqual(BT_REPORT_ID, bt_bytes[0]);
    try std.testing.expectEqual(BT_OUTPUT_TAG, bt_bytes[2]);
    try std.testing.expectEqual(@as(u8, 0x99), bt_bytes[5]); // common[2]
    var checksum: u32 = bt_bytes[74];
    checksum |= @as(u32, bt_bytes[75]) << 8;
    checksum |= @as(u32, bt_bytes[76]) << 16;
    checksum |= @as(u32, bt_bytes[77]) << 24;
    try std.testing.expectEqual(checksum, crc32Le(BT_CRC_SEED, bt_bytes[0..74]));
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
    // Rigid mode (0x01), force 180, at byte offsets 0 and 2 of the section.
    usb.common.left_trigger_effect = .{ @intFromEnum(EffectMode.rigid), 0, 180 } ++ [_]u8{0} ** 8;

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
