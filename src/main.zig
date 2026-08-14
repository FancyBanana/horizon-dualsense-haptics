// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Io = std.Io;
const updlstn = @import("udp_listener.zig");
const parser = @import("fh5_packet_parser.zig");
const haptics = @import("haptics.zig");
const audio = @import("audio.zig");
const config = @import("config.zig");
const utils = @import("utils.zig");

const print = std.debug.print;

/// Max replay delay between captured frames.
const MAX_FRAME_GAP_MS: u32 = 250;

/// `audio` must outlive `hap`, which points at it.
const App = struct {
    hap: haptics.Haptics = .{},
    audio: audio.AudioHaptics = .{},
    cfg: config.Config = .{},
};

/// Latest-wins frame handoff: receiver thread publishes, main thread consumes.
/// Stale frames are overwritten.
fn LatestFrame(comptime Frame: type) type {
    return struct {
        io: std.Io,
        mutex: std.Io.Mutex = std.Io.Mutex.init,
        frame: Frame = undefined,
        epoch: u64 = 0,
        done: bool = false,

        const Self = @This();

        fn publish(self: *Self, frame: *const Frame) void {
            self.mutex.lock(self.io) catch return;
            defer self.mutex.unlock(self.io);
            self.frame = frame.*;
            self.epoch +%= 1;
        }

        /// Returns the newest frame if newer than `seen`, else a no-change marker.
        fn waitFrame(self: *Self, seen: u64) struct { frame: Frame, epoch: u64, done: bool } {
            self.mutex.lock(self.io) catch return .{ .frame = undefined, .epoch = seen, .done = true };
            defer self.mutex.unlock(self.io);
            if (self.epoch == seen) {
                return .{ .frame = undefined, .epoch = seen, .done = self.done };
            }
            return .{ .frame = self.frame, .epoch = self.epoch, .done = self.done };
        }

        fn stop(self: *Self) void {
            self.mutex.lock(self.io) catch return;
            defer self.mutex.unlock(self.io);
            self.done = true;
        }
    };
}

const ForzaChannel = LatestFrame(parser.HorizonFrame);

/// Receiver-thread handler: validate, parse, publish. Slow work stays on main.
fn publishForzaFrame(ctx: *const anyopaque, data: []const u8) anyerror!void {
    const latest: *ForzaChannel = @ptrCast(@alignCast(@constCast(ctx)));
    if (data.len != parser.PACKET_SIZE) {
        std.log.warn("fh5: wrong datagram size {d} (expected {d})", .{ data.len, parser.PACKET_SIZE });
        return;
    }
    var buf: [parser.PACKET_SIZE]u8 = undefined;
    @memcpy(&buf, data);
    const frame = parser.parseHorizonPacket(buf);
    latest.publish(&frame);
}

pub fn main(init: std.process.Init) !void {
    const args = utils.parseCommandLine(init) catch |err| {
        std.debug.print("Argument error: {s}", .{@errorName(err)});
        return;
    };
    if (args.help) {
        utils.printHelp();
        return;
    }
    utils.installSignalHandlers();
    // if (args.replay) return replay(init, args);
    // if (args.audio_test != null) return audioTest(init, args);

    var app: App = .{};
    try setupApp(init, &app, args);
    defer app.audio.stop();
    defer app.hap.shutdown();

    var latest: ForzaChannel = .{ .io = init.io };
    var listener = updlstn.Listener.init(init.io);
    try listener.bind(.{ .ip_address = args.ip_address orelse updlstn.DEFAULT_IP_ADDRESS, .port = args.port orelse updlstn.DEFAULT_PORT });
    defer listener.close();

    const listener_thread = std.Thread.spawn(.{}, updlstn.Listener.listen, .{
        &listener,
        updlstn.Handler{ .context = &latest, .process = publishForzaFrame },
    }) catch |err| {
        std.log.err("spawn listener: {s}", .{@errorName(err)});
        return err;
    };
    // LIFO teardown; close the socket only after join, or the receiver may
    // hit EBADF inside receiveTimeout.
    defer {
        listener.close();
    }
    defer {
        listener_thread.join();
    }
    defer {
        listener.stop();
    }
    defer {
        latest.stop();
    }
    defer {
        app.hap.shutdown();
    }
    defer {
        app.audio.stop();
    }

    std.debug.print("listening for telemetry on UDP {s}:{d} (Ctrl-C to stop)\n", .{ args.ip_address orelse updlstn.DEFAULT_IP_ADDRESS, args.port orelse updlstn.DEFAULT_PORT });
    var seen: u64 = 0;
    while (!utils.g_stop.load(.acquire)) {
        const up = latest.waitFrame(seen);
        if (up.done) break;
        if (up.epoch != seen) {
            seen = up.epoch;
            app.hap.update(init.io, &up.frame);
        }
        std.Io.sleep(init.io, std.Io.Duration.fromMilliseconds(10), .boot) catch break;
    }
    std.debug.print("shutting down\n", .{});
}

/// Loads config, applies CLI overrides, starts audio mode if selected.
fn setupApp(init: std.process.Init, app: *App, args: utils.CommandLineArgs) !void {
    app.cfg = config.Config.load(init.io, init.arena.allocator(), config.DEFAULT_CONFIG_PATH);
    try applyCommandLineOverrides(args, &app.cfg);

    app.hap.config.motor_mode = app.cfg.mode;
    app.hap.config.lightbar_enabled = args.lightbar;
    app.hap.config.leds_enabled = args.leds;
    if (app.cfg.mode == .audio) {
        app.audio = .{ .sink_name = app.cfg.audio_sink, .gain = app.cfg.audio_gain };
        app.hap.audio = &app.audio;
        if (!app.audio.start(init.io)) {
            print("audio: no DualSense USB sink, falling back to simple rumble\n", .{});
            app.hap.config.motor_mode = .simple;
        }
    }
}

fn applyCommandLineOverrides(args: utils.CommandLineArgs, cfg: *config.Config) !void {
    if (args.motor_mode) |v| {
        cfg.mode = config.MotorMode.parse(v) orelse {
            print("invalid --motor-mode '{s}' (expected simple|audio)\n", .{v});
            return error.InvalidMotorMode;
        };
    }
    if (args.bluetooth) {
        // No USB audio stream over Bluetooth, so audio mode is unavailable.
        cfg.mode = .simple;
    }
    if (args.audio_sink) |v| cfg.audio_sink = v;
    if (args.audio_gain) |v| {
        const gain = try std.fmt.parseFloat(f32, v);
        if (!std.math.isFinite(gain)) return error.InvalidAudioGain;
        cfg.audio_gain = std.math.clamp(gain, 0, 1);
    }
}

/// Test tone on one channel: 0=FL speaker, 1=FR speaker, 2=RL motor, 3=RR motor.
fn audioTest(init: std.process.Init, args: utils.CommandLineArgs) !void {
    var app: App = .{};
    try setupApp(init, &app, args);
    defer app.audio.stop();
    if (app.cfg.mode != .audio) {
        print("audio backend unavailable; cannot run the audio test\n", .{});
        return error.AudioUnavailable;
    }

    var channel: i32 = 0;
    if (args.audio_test) |v| {
        if (v.len > 0) {
            if (std.fmt.parseInt(i32, v, 10)) |c| channel = c else |_| {}
        }
    }
    channel = std.math.clamp(channel, 0, 3);

    app.audio.setTestChannel(channel);
    print("audio test: {d} Hz tone on channel {d} (0=FL speaker 1=FR speaker 2=RL left motor 3=RR right motor), Ctrl-C to stop\n", .{ 100, channel });
    while (true) try std.Io.sleep(init.io, .{ .nanoseconds = std.time.ns_per_s }, .boot);
}

/// Replays fh5_packets/packet-*.fh5tel at the captured cadence.
/// --loop repeats; --speed scales playback rate.
fn replay(init: std.process.Init, args: utils.CommandLineArgs) !void {
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
            const path = std.fmt.bufPrint(&path_buf, "fh5_packets/packet-{d}.fh5tel", .{index}) catch unreachable;
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
                    const scaled = @max(@as(f64, 1.0), ns / speed); // min 1ms, no busy loop
                    try std.Io.sleep(io, .{ .nanoseconds = @intFromFloat(scaled) }, .boot);
                }
            }
            prev_ts = frame.TimestampMS;

            hap.update(io, &frame);
            count += 1;
        }

        if (count == 0) {
            print("no captured packets found in fh5_packets/ (run `zig build run -- --save-packets`)\n", .{});
            return error.NoPackets;
        }

        print("replayed {d} frames\n", .{count});
        if (!loop_forever) break;
    }
}
