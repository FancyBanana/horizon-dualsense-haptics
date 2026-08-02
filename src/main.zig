// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Io = std.Io;
const listener = @import("udp_listener.zig");
const parser = @import("packet_parser.zig");
const haptics = @import("haptics.zig");
const audio = @import("audio.zig");
const config = @import("config.zig");

const print = std.debug.print;

const MAX_FRAME_GAP_MS: u32 = 250; // do not stall on pauses in a capture

/// App-owned runtime state: the audio backend must outlive the haptics object
/// that references it, so both live on the caller's stack and are wired up
/// with the internal `&` pointers only after this struct's address is fixed.
const App = struct {
    hap: haptics.Haptics = .{},
    audio: audio.AudioHaptics = .{},
    cfg: config.Config = .{},
};

pub fn main(init: std.process.Init) !void {
    if (hasArg(init, "--selftest")) {
        return selftest(init);
    }
    if (hasArg(init, "--replay")) {
        return replay(init);
    }
    if (hasArg(init, "--audio-test")) {
        return audioTest(init);
    }

    var app: App = .{};
    try setupApp(init, &app);
    defer app.audio.stop();
    defer app.hap.shutdown();
    try listener.listen(init, .{
        .context = &app.hap,
        .process = processFrame,
    }, .{ .save_packets = hasArg(init, "--save-packets") });
}

fn processFrame(ctx: *anyopaque, io: Io, data: []const u8) anyerror!void {
    const self: *haptics.Haptics = @ptrCast(@alignCast(ctx));
    var packet: [parser.PACKET_SIZE]u8 = undefined;
    @memcpy(&packet, data);
    const frame = parser.parseHorizonPacket(packet);
    self.update(io, &frame);
}

/// Loads configuration, applies command-line overrides, and starts the audio
/// backend when audio motor mode is selected.
fn setupApp(init: std.process.Init, app: *App) !void {
    app.cfg = config.Config.load(init.io, init.arena.allocator(), config.DEFAULT_CONFIG_PATH);
    try applyCommandLineOverrides(init, &app.cfg);

    app.hap.motor_mode = app.cfg.mode;
    if (app.cfg.mode == .audio) {
        app.audio = .{ .sink_name = app.cfg.audio_sink, .gain = app.cfg.audio_gain };
        app.hap.audio = &app.audio;
        if (!app.audio.start(init.io)) {
            print("audio: no DualSense USB sink, falling back to simple rumble\n", .{});
            app.hap.motor_mode = .simple;
        }
    }
}

fn applyCommandLineOverrides(init: std.process.Init, cfg: *config.Config) !void {
    if (argValue(init, "--motor-mode")) |v| {
        cfg.mode = config.MotorMode.parse(v) orelse {
            print("invalid --motor-mode '{s}' (expected simple|audio)\n", .{v});
            return error.InvalidMotorMode;
        };
    }
    if (hasArg(init, "--bluetooth")) {
        // Bluetooth exposes rumble and trigger HID reports, but not the USB
        // audio stream used by the native audio-haptics backend.
        cfg.mode = .simple;
    }
    if (argValue(init, "--audio-sink")) |v| cfg.audio_sink = v;
    if (argValue(init, "--audio-gain")) |v| {
        const gain = try std.fmt.parseFloat(f32, v);
        if (!std.math.isFinite(gain)) return error.InvalidAudioGain;
        cfg.audio_gain = std.math.clamp(gain, 0, 1);
    }
}

/// Parses a captured packet and prints it. Regression check for the parser.
fn selftest(init: std.process.Init) !void {
    const io = init.io;

    const file = try std.Io.Dir.cwd().openFile(io, "data/packet-300.udp", .{ .mode = .read_only });
    defer file.close(io);

    var packet: [parser.PACKET_SIZE]u8 = undefined;
    const n = try file.readStreaming(io, &.{packet[0..]});
    if (n != parser.PACKET_SIZE) return error.UnexpectedEndOfStream;
    const data = parser.parseHorizonPacket(packet);

    std.debug.print("Packet data:\n{any}", .{data});
}

/// Emits a fixed test tone on one audio channel so each actuator can be
/// identified by ear (FL=0, FR=1, RL=2/speaker, RR=3). `--audio-test [0..3]`.
fn audioTest(init: std.process.Init) !void {
    var app: App = .{};
    try setupApp(init, &app);
    defer app.audio.stop();
    if (app.cfg.mode != .audio) {
        print("audio backend unavailable; cannot run the audio test\n", .{});
        return error.AudioUnavailable;
    }

    var channel: i32 = 0;
    if (argValue(init, "--audio-test")) |v| {
        if (std.fmt.parseInt(i32, v, 10)) |c| channel = c else |_| {}
    }
    channel = std.math.clamp(channel, 0, 3);

    app.audio.setTestChannel(channel);
    print("audio test: {d} Hz tone on channel {d} (0=FL speaker 1=FR speaker 2=RL left motor 3=RR right motor), Ctrl-C to stop\n", .{ 100, channel });
    while (true) try std.Io.sleep(init.io, .{ .nanoseconds = std.time.ns_per_s }, .boot);
}

/// Replays the captured data/packet-*.udp frames through the DualSense, paced
/// by each packet's own TimestampMS (≈100 Hz). Add --loop to repeat forever;
/// --speed <factor> scales the playback rate (1.0 = original cadence).
fn replay(init: std.process.Init) !void {
    const io = init.io;
    var app: App = .{};
    try setupApp(init, &app);
    defer app.audio.stop();
    defer app.hap.shutdown();
    const hap = &app.hap;

    const loop_forever = hasArg(init, "--loop");
    var speed: f32 = 1.0;
    if (argValue(init, "--speed")) |v| {
        speed = try std.fmt.parseFloat(f32, v);
        if (!std.math.isFinite(speed) or speed <= 0) return error.InvalidSpeed;
    }

    print("replay: sending captured frames to the DualSense (Ctrl-C to stop)\n", .{});
    while (true) {
        var index: usize = 1;
        var prev_ts: ?u32 = null;
        var count: usize = 0;
        while (true) : (index += 1) {
            var path_buf: [64]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "data/packet-{d}.udp", .{index}) catch unreachable;
            const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch break;
            defer file.close(io);

            var buf: [parser.PACKET_SIZE]u8 = undefined;
            const n = try file.readStreaming(io, &.{buf[0..]});
            if (n != parser.PACKET_SIZE) break;

            const frame = parser.parseHorizonPacket(buf);

            if (prev_ts) |prev| {
                const delta_ms = @min(frame.TimestampMS -% prev, MAX_FRAME_GAP_MS);
                if (delta_ms > 0) {
                    const ns = @as(f64, @floatFromInt(@as(i64, delta_ms) * std.time.ns_per_ms));
                    const scaled = @max(@as(f64, 1.0), ns / speed); // min 1ms to avoid a busy loop
                    try std.Io.sleep(io, .{ .nanoseconds = @intFromFloat(scaled) }, .boot);
                }
            }
            prev_ts = frame.TimestampMS;

            hap.update(io, &frame);
            count += 1;
        }

        if (count == 0) {
            print("no captured packets found in data/ (run `zig build run -- --save-packets`)\n", .{});
            return error.NoPackets;
        }

        print("replayed {d} frames\n", .{count});
        if (!loop_forever) break;
    }
}

fn hasArg(init: std.process.Init, needle: []const u8) bool {
    var it = std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa) catch return false;
    defer it.deinit();
    _ = it.next(); // argv[0]
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

fn argValue(init: std.process.Init, needle: []const u8) ?[]const u8 {
    var it = std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa) catch return null;
    defer it.deinit();
    _ = it.next(); // argv[0]
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, needle)) {
            const value = it.next() orelse return null;
            return init.arena.allocator().dupe(u8, value) catch return null;
        }
    }
    return null;
}
