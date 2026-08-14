// SPDX-License-Identifier: AGPL-3.0-or-later

//! Runtime configuration from a key=value file (default
//! `forza-haptics.conf`), overridable via CLI flags.

const std = @import("std");

pub const DEFAULT_CONFIG_PATH = "forza-haptics.conf";
pub const DEFAULT_AUDIO_SINK = "dualsense";

/// How the main haptic motors are driven.
pub const MotorMode = enum {
    simple,
    audio,

    pub fn parse(s: []const u8) ?MotorMode {
        if (std.mem.eql(u8, s, "simple")) return .simple;
        if (std.mem.eql(u8, s, "audio")) return .audio;
        return null;
    }
};

/// Settings loaded from the config file plus command-line overrides.
pub const Config = struct {
    mode: MotorMode = .audio,
    audio_gain: f32 = 0.75,
    audio_sink: []const u8 = DEFAULT_AUDIO_SINK,

    /// Loads key=value settings, falling back to defaults on errors.
    pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) Config {
        var cfg = Config{};
        const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024)) catch {
            return cfg;
        };
        defer allocator.free(contents);
        var owned_sink: ?[]u8 = null;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t\"");
            if (std.mem.eql(u8, key, "motor-mode")) {
                if (MotorMode.parse(value)) |m| cfg.mode = m;
            } else if (std.mem.eql(u8, key, "audio-gain")) {
                const g = std.fmt.parseFloat(f32, value) catch continue;
                if (!std.math.isFinite(g)) continue;
                cfg.audio_gain = std.math.clamp(g, 0.0, 1.0);
            } else if (std.mem.eql(u8, key, "audio-sink")) {
                const sink = allocator.dupe(u8, value) catch continue;
                if (owned_sink) |old| allocator.free(old);
                owned_sink = sink;
                cfg.audio_sink = sink;
            }
        }
        return cfg;
    }
};
