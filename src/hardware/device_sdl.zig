// SPDX-License-Identifier: AGPL-3.0-or-later

//! Cross-platform DualSense HID access through SDL3 HIDAPI.

const std = @import("std");
const sdl = @import("sdl_c");
const c = sdl.c;
const ds = @import("dualsense.zig");

/// Errors returned by SDL HID discovery and report writes.
pub const Error = ds.Error;

/// SDL HID device handle and DualSense transport state.
pub const Device = struct {
    handle: ?*c.SDL_hid_device = null,
    bus: ds.Bus = .usb,
    bt_sequence: u8 = 0,

    /// Reports whether the SDL HID handle is open.
    pub fn connected(self: *const Device) bool {
        return self.handle != null;
    }

    /// Enumerates and opens the first supported DualSense HID interface.
    pub fn open(io: std.Io) Error!Device {
        _ = io;
        if (c.SDL_hid_init() < 0) return error.DeviceNotFound;

        const devices = c.SDL_hid_enumerate(ds.VENDOR_ID, 0) orelse {
            _ = c.SDL_hid_exit();
            return error.DeviceNotFound;
        };
        defer c.SDL_hid_free_enumeration(devices);

        var info: ?*c.SDL_hid_device_info = devices;
        while (info) |entry| {
            const bus = mapBus(entry.bus_type) orelse {
                info = entry.next;
                continue;
            };
            if (std.mem.indexOfScalar(u16, &ds.PRODUCT_IDS, entry.product_id) == null) {
                info = entry.next;
                continue;
            }

            const handle = c.SDL_hid_open_path(entry.path) orelse {
                info = entry.next;
                continue;
            };
            return .{ .handle = handle, .bus = bus };
        }

        _ = c.SDL_hid_exit();
        return error.DeviceNotFound;
    }

    /// Writes a USB report directly or wraps it in a Bluetooth report.
    pub fn writeReport(self: *Device, report: *const ds.UsbOutputReport) Error!void {
        const handle = self.handle orelse return error.DeviceNotFound;
        switch (self.bus) {
            .usb => return self.writeBytes(handle, std.mem.asBytes(report)),
            .bluetooth => {
                var bt_report = ds.BtOutputReport.fromUsb(report, self.bt_sequence);
                try self.writeBytes(handle, std.mem.asBytes(&bt_report));
                self.bt_sequence = (self.bt_sequence + 1) & 0x0F;
            },
        }
    }

    /// Closes the SDL HID handle and releases HIDAPI state.
    pub fn close(self: *Device) void {
        if (self.handle) |handle| {
            _ = c.SDL_hid_close(handle);
            self.handle = null;
            _ = c.SDL_hid_exit();
        }
    }

    /// Writes one complete report through SDL HIDAPI.
    fn writeBytes(self: *const Device, handle: *c.SDL_hid_device, bytes: []const u8) Error!void {
        _ = self;
        const written = c.SDL_hid_write(handle, @ptrCast(bytes.ptr), bytes.len);
        if (written != bytes.len) return error.WriteFailed;
    }
};

/// Converts SDL's HID bus enum to the project's transport enum.
fn mapBus(bus: c.SDL_hid_bus_type) ?ds.Bus {
    return switch (bus) {
        c.SDL_HID_API_BUS_USB => .usb,
        c.SDL_HID_API_BUS_BLUETOOTH => .bluetooth,
        else => null,
    };
}

test "maps SDL HID transport buses" {
    try std.testing.expectEqual(ds.Bus.usb, mapBus(c.SDL_HID_API_BUS_USB));
    try std.testing.expectEqual(ds.Bus.bluetooth, mapBus(c.SDL_HID_API_BUS_BLUETOOTH));
    try std.testing.expectEqual(null, mapBus(c.SDL_HID_API_BUS_UNKNOWN));
}
