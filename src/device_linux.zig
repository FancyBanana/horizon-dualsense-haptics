// SPDX-License-Identifier: AGPL-3.0-or-later

//! Linux DualSense device layer: /dev/hidraw over USB or Bluetooth. Mirrors
//! the interface of device_windows.zig so `device.zig` can select the
//! implementation at compile time.

const std = @import("std");
const linux = std.os.linux;
const ds = @import("dualsense.zig");

/// Errors returned by Linux HID discovery and report writes.
pub const Error = error{ DeviceNotFound, AccessDenied, WriteFailed, WouldBlock };

const O_RDWR_NONBLOCK = linux.O{ .ACCMODE = .RDWR, .NONBLOCK = true };

/// Linux DualSense device handle and transport state.
pub const Device = struct {
    fd: linux.fd_t = -1,
    bus: ds.Bus = .usb,
    bt_sequence: u8 = 0,

    /// Reports whether the hidraw file descriptor is open.
    pub fn connected(self: *const Device) bool {
        return self.fd >= 0;
    }

    /// Scans /dev/hidraw* and opens the first node whose sysfs uevent reports
    /// a DualSense VID/PID. On some kernels the controller exposes several
    /// hidraw nodes (gamepad, sensors, audio); the first matching node that
    /// opens is used.
    pub fn open(io: std.Io) Error!Device {
        var minor: u32 = 0;
        var access_denied = false;
        while (minor < 64) : (minor += 1) {
            const bus = dualsenseBus(io, minor) orelse continue;

            var path_buf: [32]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "/dev/hidraw{d}", .{minor}) catch unreachable;

            const rc = linux.open(path, O_RDWR_NONBLOCK, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => return .{ .fd = @intCast(rc), .bus = bus },
                .ACCES => access_denied = true,
                else => continue,
            }
        }
        if (access_denied) return error.AccessDenied;
        return error.DeviceNotFound;
    }

    /// Writes a USB report directly or wraps it in a Bluetooth report.
    pub fn writeReport(self: *Device, report: *const ds.OutputReport) Error!void {
        switch (self.bus) {
            .usb => return self.writeBytes(@ptrCast(report), ds.USB_REPORT_SIZE),
            .bluetooth => {
                var bt_report = ds.BtOutputReport.fromUsb(report, self.bt_sequence);
                try self.writeBytes(@ptrCast(&bt_report), ds.BT_REPORT_SIZE);
                self.bt_sequence = (self.bt_sequence + 1) & 0x0F;
            },
        }
    }

    /// Closes the hidraw descriptor if one is open.
    pub fn close(self: *Device) void {
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
    }

    /// Writes exactly one HID report, translating nonblocking errors.
    fn writeBytes(self: *const Device, bytes: [*]const u8, size: usize) Error!void {
        const rc = linux.write(self.fd, bytes, size);
        switch (linux.errno(rc)) {
            .SUCCESS => if (rc != size) return error.WriteFailed,
            .AGAIN => return error.WouldBlock, // drop this frame
            else => return error.WriteFailed,
        }
    }
};

/// Returns the transport bus for a DualSense hidraw node. Errors (node missing,
/// unreadable sysfs, or an unsupported bus) are treated as no match.
fn dualsenseBus(io: std.Io, minor: u32) ?ds.Bus {
    var path_buf: [96]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/sys/class/hidraw/hidraw{d}/device/uevent", .{minor}) catch return null;

    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return null;
    defer file.close(io);

    var read_buf: [1024]u8 = undefined;
    const n = file.readStreaming(io, &.{read_buf[0..]}) catch return null;
    return matchesHidId(read_buf[0..n]);
}

/// Matches a sysfs HID_ID line to a supported DualSense transport.
fn matchesHidId(contents: []const u8) ?ds.Bus {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "HID_ID=")) {
            var it = std.mem.splitScalar(u8, line["HID_ID=".len..], ':');
            const bus = it.next() orelse return null;
            const vid = it.next() orelse return null;
            const pid = it.next() orelse return null;
            const vid_u = std.fmt.parseInt(u16, vid, 16) catch return null;
            const pid_u = std.fmt.parseInt(u16, pid, 16) catch return null;
            if (vid_u != ds.VENDOR_ID or std.mem.indexOfScalar(u16, &ds.PRODUCT_IDS, pid_u) == null) return null;
            const bus_u = std.fmt.parseInt(u16, bus, 16) catch return null;
            return switch (bus_u) {
                0x03 => .usb,
                0x05 => .bluetooth,
                else => null,
            };
        }
    }
    return null;
}

test "detects DualSense HID transport bus" {
    try std.testing.expectEqual(ds.Bus.usb, matchesHidId("HID_ID=0003:054C:0CE6\n"));
    try std.testing.expectEqual(ds.Bus.bluetooth, matchesHidId("HID_ID=0005:054C:0DF2\n"));
    try std.testing.expectEqual(null, matchesHidId("HID_ID=0003:1234:0CE6\n"));
    try std.testing.expectEqual(null, matchesHidId("HID_ID=0006:054C:0CE6\n"));
}
