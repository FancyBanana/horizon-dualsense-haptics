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

/// Telemetry -> DualSense mapping tunables.
pub const Params = struct {
    // L2 (brake)
    brake_deadzone: u8 = 40,
    brake_zone_max: u8 = 8, // top zone resistance (1..8) at full brake
    handbrake_force: u8 = 220,
    abs_brake_threshold: u8 = 100,
    abs_slip_ratio_threshold: f32 = 0.3,
    abs_combined_slip_threshold: f32 = 0.7,
    abs_freq: u8 = 12,
    abs_amp: u8 = 160,

    // R2 (throttle)
    throttle_deadzone: u8 = 30,
    throttle_max_force: u8 = 160,
    wheelspin_accel_threshold: u8 = 30,
    wheelspin_freq_min: u8 = 60,
    wheelspin_freq_max: u8 = 160,
    wheelspin_amp: u8 = 180,
    wheelspin_slip_threshold: f32 = 1.0,
    burnout_rot_threshold: f32 = 30.0, // rad/s at standstill
    rev_limit_ratio: f32 = 0.96,
    rev_limit_freq: u8 = 110,
    rev_limit_amp: u8 = 150,
    wheelspin_zone_start: u8 = 5,
    rev_limit_zone_start: u8 = 8,

    // shared
    shift_burst_freq: u8 = 20,
    shift_burst_amp: u8 = 130,
    shift_burst_ms: i64 = 80,
    low_speed_mps: f32 = 5.0, // below this trust wheel rotation, not slip
};

/// Static configuration; runtime state lives in `Haptics`.
pub const HapticsConfig = struct {
    params: Params = .{},
    motor_mode: MotorMode = .simple,
    reconnect_interval_ms: i64 = 1_000,
    lightbar_enabled: bool = false,
    leds_enabled: bool = false,
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
