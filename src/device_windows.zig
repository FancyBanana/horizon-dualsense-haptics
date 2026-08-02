// SPDX-License-Identifier: AGPL-3.0-or-later

//! Windows DualSense device layer. Stub: hidapi/windows HID support is not
//! implemented yet. The interface mirrors device_linux.zig so the rest of the
//! app (and the compile-time selection in device.zig) is already portable.

const std = @import("std");
const ds = @import("dualsense.zig");

pub const Error = error{ DeviceNotFound, AccessDenied, WriteFailed, WouldBlock };

pub const Device = struct {
    pub fn connected(self: *const Device) bool {
        _ = self;
        return false;
    }

    pub fn open(io: std.Io) Error!Device {
        _ = io;
        return error.DeviceNotFound;
    }

    pub fn writeReport(self: *Device, report: *const ds.OutputReport) Error!void {
        _ = self;
        _ = report;
        return error.WriteFailed;
    }

    pub fn close(self: *Device) void {
        _ = self;
    }
};
