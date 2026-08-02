// SPDX-License-Identifier: AGPL-3.0-or-later

//! Windows DualSense device layer. Stub: hidapi/windows HID support is not
//! implemented yet. The interface mirrors device_linux.zig so the rest of the
//! app (and the compile-time selection in device.zig) is already portable.

const std = @import("std");
const ds = @import("dualsense.zig");

/// Errors returned by the Windows HID backend stub.
pub const Error = error{ DeviceNotFound, AccessDenied, WriteFailed, WouldBlock };

/// Placeholder Windows HID device implementation.
pub const Device = struct {
    /// Windows HID support is not implemented, so this always reports false.
    pub fn connected(self: *const Device) bool {
        _ = self;
        return false;
    }

    /// Returns DeviceNotFound until the Windows backend is implemented.
    pub fn open(io: std.Io) Error!Device {
        _ = io;
        return error.DeviceNotFound;
    }

    /// Returns WriteFailed until the Windows backend is implemented.
    pub fn writeReport(self: *Device, report: *const ds.OutputReport) Error!void {
        _ = self;
        _ = report;
        return error.WriteFailed;
    }

    /// Closes the device; currently there is no Windows handle to release.
    pub fn close(self: *Device) void {
        _ = self;
    }
};
