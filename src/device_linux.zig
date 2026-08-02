// SPDX-License-Identifier: AGPL-3.0-or-later

//! Linux DualSense device layer: /dev/hidraw. Mirrors the interface of
//! device_windows.zig so `device.zig` can select the implementation at
//! compile time.

const std = @import("std");
const linux = std.os.linux;
const ds = @import("dualsense.zig");

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
    pub fn open(io: std.Io) Error!Device {
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

    pub fn writeReport(self: *const Device, report: *const ds.OutputReport) Error!void {
        const rc = linux.write(self.fd, @ptrCast(report), ds.USB_REPORT_SIZE);
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
fn isDualSenseNode(io: std.Io, minor: u32) bool {
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
            return vid_u == ds.VENDOR_ID and std.mem.indexOfScalar(u16, &ds.PRODUCT_IDS, pid_u) != null;
        }
    }
    return false;
}
