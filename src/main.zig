// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Io = std.Io;
const listener = @import("udp_listener.zig");
const parser = @import("packet_parser.zig");
const haptics = @import("haptics.zig");
const audio = @import("audio.zig");
const config = @import("config.zig");

const print = std.debug.print;

/// Maximum replay delay for a gap between captured telemetry frames.
const MAX_FRAME_GAP_MS: u32 = 250;

/// App-owned runtime state: the audio backend must outlive the haptics object
/// that references it, so both live on the caller's stack and are wired up
/// with the internal `&` pointers only after this struct's address is fixed.
const App = struct {
    hap: haptics.Haptics = .{},
    audio: audio.AudioHaptics = .{},
    cfg: config.Config = .{},
};

/// Parsed command-line flags and values shared by all runtime modes.
const CommandLineArgs = struct {
    /// Print a bundled packet and exit.
    selftest: bool = false,
    /// Replay captured packets through the controller.
    replay: bool = false,
    /// Emit an audio channel test tone.
    audio_test: bool = false,
    /// Optional channel number for `--audio-test`.
    audio_test_channel: ?[]const u8 = null,
    /// Repeat replay mode indefinitely.
    loop: bool = false,
    /// Requested `simple` or `audio` motor mode.
    motor_mode: ?[]const u8 = null,
    /// Force simple rumble mode for a Bluetooth controller.
    bluetooth: bool = false,
    /// Substring used to select the SDL audio device.
    audio_sink: ?[]const u8 = null,
    /// Audio output gain before rendering.
    audio_gain: ?[]const u8 = null,
    /// Replay speed multiplier.
    speed: ?[]const u8 = null,
    /// Save received telemetry packets using the default limit.
    save_packets: bool = false,
    /// Maximum number of packets to save.
    capture_count: ?u32 = null,
};

/// Runs the selected runtime mode.
pub fn main(init: std.process.Init) !void {
    const args = try parseCommandLine(init);
    if (args.selftest) {
        return selftest(init);
    }
    if (args.replay) {
        return replay(init, args);
    }
    if (args.audio_test) {
        return audioTest(init, args);
    }

    var app: App = .{};
    try setupApp(init, &app, args);
    defer app.audio.stop();
    defer app.hap.shutdown();
    try listener.listen(init, .{
        .context = &app.hap,
        .process = processFrame,
    }, .{
        .save_packets = args.save_packets or args.capture_count != null,
        .max_saved_packets = args.capture_count orelse listener.DEFAULT_MAX_SAVED_PACKETS,
    });
}

/// Parses one validated telemetry datagram and sends its effects to the device.
fn processFrame(ctx: *anyopaque, io: Io, data: []const u8) anyerror!void {
    const self: *haptics.Haptics = @ptrCast(@alignCast(ctx));
    var packet: [parser.PACKET_SIZE]u8 = undefined;
    @memcpy(&packet, data);
    const frame = parser.parseHorizonPacket(packet);
    self.update(io, &frame);
}

/// Loads configuration, applies command-line overrides, and starts the audio
/// backend when audio motor mode is selected.
fn setupApp(init: std.process.Init, app: *App, args: CommandLineArgs) !void {
    app.cfg = config.Config.load(init.io, init.arena.allocator(), config.DEFAULT_CONFIG_PATH);
    try applyCommandLineOverrides(args, &app.cfg);

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

/// Applies command-line configuration values over the loaded config file.
fn applyCommandLineOverrides(args: CommandLineArgs, cfg: *config.Config) !void {
    if (args.motor_mode) |v| {
        cfg.mode = config.MotorMode.parse(v) orelse {
            print("invalid --motor-mode '{s}' (expected simple|audio)\n", .{v});
            return error.InvalidMotorMode;
        };
    }
    if (args.bluetooth) {
        // Bluetooth exposes rumble and trigger HID reports, but not the USB
        // audio stream used by the native audio-haptics backend.
        cfg.mode = .simple;
    }
    if (args.audio_sink) |v| cfg.audio_sink = v;
    if (args.audio_gain) |v| {
        const gain = try std.fmt.parseFloat(f32, v);
        if (!std.math.isFinite(gain)) return error.InvalidAudioGain;
        cfg.audio_gain = std.math.clamp(gain, 0, 1);
    }
}

/// Parses argv once and returns values shared by all application modes.
fn parseCommandLine(init: std.process.Init) !CommandLineArgs {
    var args = CommandLineArgs{};
    var it = std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa) catch return error.OutOfMemory;
    defer it.deinit();

    _ = it.next(); // argv[0]
    var pending: ?[]const u8 = null;
    while (nextArgument(&it, &pending)) |arg| {
        if (std.mem.eql(u8, arg, "--selftest")) {
            args.selftest = true;
        } else if (std.mem.eql(u8, arg, "--replay")) {
            args.replay = true;
        } else if (std.mem.eql(u8, arg, "--audio-test")) {
            args.audio_test = true;
            if (optionValue(&it, &pending)) |value| args.audio_test_channel = try copyArg(init, value);
        } else if (std.mem.eql(u8, arg, "--loop")) {
            args.loop = true;
        } else if (std.mem.eql(u8, arg, "--bluetooth")) {
            args.bluetooth = true;
        } else if (std.mem.eql(u8, arg, "--save-packets")) {
            args.save_packets = true;
        } else if (std.mem.eql(u8, arg, "--motor-mode")) {
            if (optionValue(&it, &pending)) |value| args.motor_mode = try copyArg(init, value);
        } else if (std.mem.eql(u8, arg, "--audio-sink")) {
            if (optionValue(&it, &pending)) |value| args.audio_sink = try copyArg(init, value);
        } else if (std.mem.eql(u8, arg, "--audio-gain")) {
            if (optionValue(&it, &pending)) |value| args.audio_gain = try copyArg(init, value);
        } else if (std.mem.eql(u8, arg, "--speed")) {
            if (optionValue(&it, &pending)) |value| args.speed = try copyArg(init, value);
        } else if (std.mem.eql(u8, arg, "--capture-count")) {
            if (optionValue(&it, &pending)) |value| {
                const count = std.fmt.parseInt(u32, value, 10) catch return error.InvalidCaptureCount;
                if (count == 0) return error.InvalidCaptureCount;
                args.capture_count = count;
            }
        }
    }
    return args;
}

/// Returns the next argument, including one deferred by optionValue().
fn nextArgument(it: *std.process.Args.Iterator, pending: *?[]const u8) ?[]const u8 {
    if (pending.*) |arg| {
        pending.* = null;
        return arg;
    }
    return it.next();
}

/// Reads an option value without consuming the next option as its value.
fn optionValue(it: *std.process.Args.Iterator, pending: *?[]const u8) ?[]const u8 {
    const value = nextArgument(it, pending) orelse return null;
    if (std.mem.startsWith(u8, value, "--")) {
        pending.* = value;
        return null;
    }
    return value;
}

/// Copies an argument into the process arena for use after iterator cleanup.
fn copyArg(init: std.process.Init, value: []const u8) ![]const u8 {
    return init.arena.allocator().dupe(u8, value);
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
fn audioTest(init: std.process.Init, args: CommandLineArgs) !void {
    var app: App = .{};
    try setupApp(init, &app, args);
    defer app.audio.stop();
    if (app.cfg.mode != .audio) {
        print("audio backend unavailable; cannot run the audio test\n", .{});
        return error.AudioUnavailable;
    }

    var channel: i32 = 0;
    if (args.audio_test_channel) |v| {
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
fn replay(init: std.process.Init, args: CommandLineArgs) !void {
    const io = init.io;
    var app: App = .{};
    try setupApp(init, &app, args);
    defer app.audio.stop();
    defer app.hap.shutdown();
    const hap = &app.hap;

    const loop_forever = args.loop;
    var speed: f32 = 1.0;
    if (args.speed) |v| {
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
