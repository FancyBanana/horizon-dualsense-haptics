// SPDX-License-Identifier: AGPL-3.0-or-later

//! Portable DualSense HID access through SDL3 HIDAPI.

const std = @import("std");
const impl = @import("device_sdl.zig");
const ds = @import("dualsense.zig");

/// Errors returned by the shared SDL HID backend.
pub const Error = impl.Error;

pub const Device = impl.Device;

/// Opens the first supported DualSense device found by the platform backend.
pub inline fn open(io: std.Io) Error!Device {
    return impl.Device.open(io);
}
