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

/// Maximum replay delay for a gap between captured telemetry frames.
const MAX_FRAME_GAP_MS: u32 = 250;

/// Set by the SIGINT/SIGTERM handler (async-signal-safe: atomic store only).
/// Polled by the consumer loop, which then tears down cleanly.
var g_stop = std.atomic.Value(bool).init(false);

/// Async-signal-safe: no allocation, no locks, no I/O — just a store.
fn handleSignal(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    g_stop.store(true, .release);
}

/// Replaces the default SIGINT/SIGTERM dispositions (SIGINT is inherited as
/// SIG_IGN in background jobs, which is why Ctrl-C did nothing before).
fn installSignalHandlers() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

/// App-owned runtime state: the audio backend must outlive the haptics object
/// that references it, so both live on the caller's stack and are wired up
/// with the internal `&` pointers only after this struct's address is fixed.
const App = struct {
    hap: haptics.Haptics = .{},
    audio: audio.AudioHaptics = .{},
    cfg: config.Config = .{},
};

/// Latest-wins handoff between the UDP receiver thread (producer) and the
/// main thread (consumer). The receiver never blocks and never does slow
/// work: it publishes a parsed frame under the mutex. Stale frames are
/// silently overwritten — for telemetry that is correct, because processing
/// an old frame while a fresh one waits is pure waste.
///
/// Generic over the parsed frame type: each game plugs in its own parser
/// and frame struct.
fn LatestFrame(comptime Frame: type) type {
    return struct {
        io: std.Io,
        mutex: std.Io.Mutex = std.Io.Mutex.init,
        frame: Frame = undefined,
        /// Bumped on every publish; consumer skips frames it has already seen.
        /// Wraps with +% — equality compares are still correct.
        epoch: u64 = 0,
        /// Set by `stop`; wakes the consumer so it can exit its wait.
        done: bool = false,

        const Self = @This();

        /// Producer (receiver thread). Publishes a parsed frame; never blocks
        /// and never allocates. Drops the previous frame if the consumer is
        /// behind — latest-wins.
        fn publish(self: *Self, frame: *const Frame) void {
            self.mutex.lock(self.io) catch return;
            defer self.mutex.unlock(self.io);
            self.frame = frame.*;
            self.epoch +%= 1;
        }

        /// Consumer (main thread). Non-blocking: returns the newest frame
        /// if one arrived since `seen`, otherwise a no-change marker. The
        /// consumer polls at ~10 ms — matching the telemetry cadence — so
        /// this stays lock-free-ish (one mutex hop) and shutdown latency is
        /// bounded without a timed cond wait.
        fn waitFrame(self: *Self, seen: u64) struct { frame: Frame, epoch: u64, done: bool } {
            self.mutex.lock(self.io) catch return .{ .frame = undefined, .epoch = seen, .done = true };
            defer self.mutex.unlock(self.io);
            if (self.epoch == seen) {
                return .{ .frame = undefined, .epoch = seen, .done = self.done };
            }
            return .{ .frame = self.frame, .epoch = self.epoch, .done = self.done };
        }

        /// Producer/consumer-agnostic wake: marks done. The consumer polls
        /// `done` via `waitFrame`; no cond signal needed.
        fn stop(self: *Self) void {
            self.mutex.lock(self.io) catch return;
            defer self.mutex.unlock(self.io);
            self.done = true;
        }
    };
}

/// Forza Horizon telemetry: 324-byte datagrams on UDP 8800, parsed on the
/// receiver thread (µs, deterministic), published to the consumer.
const ForzaChannel = LatestFrame(parser.HorizonFrame);

/// Forza-specific receiver-thread handler: validates the datagram size,
/// parses it, and publishes the frame. Everything slow (haptics update,
/// USB writes, audio) happens on the consumer thread, never here.
///
/// Other games add their own handler like this one, sharing the same
/// generic listener and channel; only the parser and frame type differ.
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

/// Runs the selected runtime mode.
pub fn main(init: std.process.Init) !void {
    const args = utils.parseCommandLine(init) catch |err| {
        std.debug.print("Argument error: {s}", .{@errorName(err)});
        return;
    };
    if (args.help) {
        utils.printHelp();
        return;
    }
    installSignalHandlers();
    // if (args.replay) {
    //     return replay(init, args);
    // }
    // if (args.audio_test != null) {
    //     return audioTest(init, args);
    // }
    // if (args.record_only) {
    //     return recordOnly(init, listen_options);
    // }

    var app: App = .{};
    try setupApp(init, &app, args);
    defer app.audio.stop();
    defer app.hap.shutdown();

    // Receiver thread: recv -> validate -> parse -> publish. Nothing slow.
    // Main thread: consume latest frame -> haptics (USB HID, audio).
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
    // Shutdown order matters: stop the producer, join it (receiver loop
    // anything it touches (socket, audio, haptics). The consumer is this
    // main thread; it leaves the loop before these defers run.
    //
    // LIFO at teardown: audio.stop -> hap.shutdown -> latest.stop ->
    // listener.stop -> listener_thread.join -> listener.close.
    // close AFTER join: the receiver thread may still be inside
    // receiveTimeout on the socket fd; closing first makes its next
    // syscall EBADF (panic in debug builds).
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
    while (!g_stop.load(.acquire)) {
        const up = latest.waitFrame(seen);
        if (up.done) break;
        if (up.epoch != seen) {
            seen = up.epoch;
            app.hap.update(init.io, &up.frame);
        }
        // Poll at the telemetry cadence; keeps shutdown latency <= ~10 ms
        // and lets the consumer pick up newly published frames.
        std.Io.sleep(init.io, std.Io.Duration.fromMilliseconds(10), .boot) catch break;
    }
    std.debug.print("shutting down\n", .{});
}

/// Loads configuration, applies command-line overrides, and starts the audio
/// backend when audio motor mode is selected.
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

/// Applies command-line configuration values over the loaded config file.
fn applyCommandLineOverrides(args: utils.CommandLineArgs, cfg: *config.Config) !void {
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

/// Emits a fixed test tone on one audio channel so each actuator can be
/// identified by ear (FL=0, FR=1, RL=2/speaker, RR=3). `--audio-test [0..3]`.
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

/// Replays the captured fh5_packets/packet-*.fh5tel frames through the DualSense, paced
/// by each packet's own TimestampMS (≈100 Hz). Add --loop to repeat forever;
/// --speed <factor> scales the playback rate (1.0 = original cadence).
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
                    const scaled = @max(@as(f64, 1.0), ns / speed); // min 1ms to avoid a busy loop
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
