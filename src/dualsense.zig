const builtin = @import("builtin");
const std = @import("std");
const linux = std.os.linux;
const Io = std.Io;

comptime {
    if (builtin.os.tag != .linux) {
        @compileError("dualsense.zig only supports Linux (/dev/hidraw)");
    }
}

pub const VENDOR_ID: u16 = 0x054C;
pub const PRODUCT_IDS = [_]u16{ 0x0CE6, 0x0DF2 }; // DualSense, DualSense Edge

pub const USB_REPORT_ID: u8 = 0x02;
pub const USB_REPORT_SIZE: usize = 48;

/// valid_flag0 (report byte 1) bits.
pub const Flag0 = struct {
    pub const RUMBLE: u8 = 0x01 | 0x02; // classic vibration: main motors
    pub const RIGHT_TRIGGER: u8 = 0x04;
    pub const LEFT_TRIGGER: u8 = 0x08;
    pub const ALL: u8 = RUMBLE | RIGHT_TRIGGER | LEFT_TRIGGER;
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
    unknown1: [6]u8 = [_]u8{0} ** 6,
    valid_flag2: u8 = FLAG2_RUMBLE_V2,
    unknown2: [2]u8 = [_]u8{0} ** 2,
    led_animation: u8 = 0,
    led_brightness: u8 = 0,
    player_leds: u8 = 0,
    led_red: u8 = 0,
    led_green: u8 = 0,
    led_blue: u8 = 0,
};

comptime {
    if (@sizeOf(OutputReport) != USB_REPORT_SIZE) {
        @compileError("OutputReport must be exactly 48 bytes");
    }
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

const O_RDWR_NONBLOCK = linux.O{ .ACCMODE = .RDWR, .NONBLOCK = true };

pub const Device = struct {
    fd: linux.fd_t = -1,

    pub fn connected(self: *const Device) bool {
        return self.fd >= 0;
    }

    /// Scans /dev/hidraw* and opens the first node whose sysfs uevent reports
    /// a DualSense VID/PID. On some kernels the controller exposes several
    /// hidraw nodes (gamepad, sensors, audio); the first one that opens is
    /// used, which is the gamepad interface.
    pub fn open(io: Io) Error!Device {
        var minor: u32 = 0;
        while (minor < 64) : (minor += 1) {
            if (!isDualSenseNode(io, minor)) continue;

            var path_buf: [32]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "/dev/hidraw{d}", .{minor}) catch unreachable;

            const rc = linux.open(path, O_RDWR_NONBLOCK, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => return .{ .fd = @intCast(rc) },
                .ACCES => return error.AccessDenied,
                else => continue,
            }
        }
        return error.DeviceNotFound;
    }

    pub fn writeReport(self: *const Device, report: *const OutputReport) Error!void {
        const rc = linux.write(self.fd, @ptrCast(report), USB_REPORT_SIZE);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return error.WouldBlock, // drop this frame
            else => return error.WriteFailed,
        }
    }

    pub fn close(self: *Device) void {
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
    }
};

/// Returns true if the hidraw node at `minor` is a DualSense gamepad
/// interface. Errors (node missing, unreadable sysfs) are treated as no match.
fn isDualSenseNode(io: Io, minor: u32) bool {
    var path_buf: [96]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/sys/class/hidraw/hidraw{d}/device/uevent", .{minor}) catch return false;

    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return false;
    defer file.close(io);

    var read_buf: [1024]u8 = undefined;
    const n = file.readStreaming(io, &.{read_buf[0..]}) catch return false;
    return matchesHidId(read_buf[0..n]);
}

fn matchesHidId(contents: []const u8) bool {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "HID_ID=")) {
            var it = std.mem.splitScalar(u8, line["HID_ID=".len..], ':');
            _ = it.next() orelse return false; // bus
            const vid = it.next() orelse return false;
            const pid = it.next() orelse return false;
            const vid_u = std.fmt.parseInt(u16, vid, 16) catch return false;
            const pid_u = std.fmt.parseInt(u16, pid, 16) catch return false;
            return vid_u == VENDOR_ID and std.mem.indexOfScalar(u16, &PRODUCT_IDS, pid_u) != null;
        }
    }
    return false;
}

test "output report size" {
    try std.testing.expectEqual(USB_REPORT_SIZE, @sizeOf(OutputReport));
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
    try std.testing.expectEqual(0x00, zones[1]); // active low byte
    try std.testing.expectEqual(0x03, zones[2]); // active high byte
    try std.testing.expectEqual(0xFF, zones[5]); // packed bytes 16-23
    try std.testing.expectEqual(0xFF, zones[6]); // packed bytes 24-29
}
