// SPDX-License-Identifier: AGPL-3.0-or-later

//! Platform-independent SDL audio-device discovery.
//!
//! SDL presents the same playback-device API on each supported host, so this
//! matching logic does not need separate Linux and Windows implementations.

const std = @import("std");
const sdl = @import("sdl_c.zig");
const c = sdl.c;

/// Finds the SDL playback device whose name contains `sink_name`.
pub fn findDevice(sink_name: []const u8) ?c.SDL_AudioDeviceID {
    var count: c_int = 0;
    const devs = c.SDL_GetAudioPlaybackDevices(&count) orelse {
        std.debug.print("audio: SDL_GetAudioPlaybackDevices failed: {s}\n", .{sdlError()});
        return null;
    };
    defer c.SDL_free(@ptrCast(devs));

    var i: c_int = 0;
    while (i < count) : (i += 1) {
        const name = c.SDL_GetAudioDeviceName(devs[@intCast(i)]) orelse continue;
        if (containsIgnoreCase(std.mem.span(name), sink_name)) {
            std.debug.print("audio: using playback device '{s}'\n", .{std.mem.span(name)});
            return devs[@intCast(i)];
        }
    }

    std.debug.print("audio: no playback device matching '{s}' (use --audio-sink <substring>)\n", .{sink_name});
    i = 0;
    while (i < count) : (i += 1) {
        if (c.SDL_GetAudioDeviceName(devs[@intCast(i)])) |name| {
            std.debug.print("audio:   device: {s}\n", .{std.mem.span(name)});
        }
    }
    return null;
}

/// Performs a case-insensitive substring match for an SDL device name.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matches = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

/// Returns SDL's current error message or a fallback string.
fn sdlError() []const u8 {
    return if (c.SDL_GetError()) |p| std.mem.span(p) else "unknown SDL error";
}
