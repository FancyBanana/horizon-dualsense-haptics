// SPDX-License-Identifier: AGPL-3.0-or-later

//! Portable DualSense hidraw access. The concrete implementation is selected
//! at compile time, so a future Windows port only needs a new device_*.zig
//! implementation and a branch below; nothing else in the app changes.

const std = @import("std");
const builtin = @import("builtin");
const ds = @import("dualsense.zig");

pub const Error = ds.Error;

const impl = switch (builtin.os.tag) {
    .linux => @import("device_linux.zig"),
    .windows => @import("device_windows.zig"),
    else => @compileError("unsupported OS for the DualSense device layer"),
};

pub const Device = impl.Device;

pub inline fn open(io: std.Io) Error!Device {
    return impl.Device.open(io);
}
