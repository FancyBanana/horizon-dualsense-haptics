const std = @import("std");
const Io = std.Io;
const listener = @import("udp_listener.zig");
const parser = @import("packet_parser.zig");
const haptics = @import("haptics.zig");

const print = std.debug.print;

fn processFrame(ctx: *anyopaque, io: Io, data: []const u8) anyerror!void {
    const self: *haptics.Haptics = @ptrCast(@alignCast(ctx));
    var reader = Io.Reader.fixed(data);
    const frame = try parser.parse_packet(&reader);
    self.update(io, &frame);
}

pub fn main(init: std.process.Init) !void {
    if (hasArg(init, "--selftest")) {
        return selftest(init);
    }
    if (hasArg(init, "--replay")) {
        return replay(init);
    }

    var hap: haptics.Haptics = .{};
    try listener.udp_listen(init, .{
        .context = &hap,
        .process = processFrame,
    }, .{ .save_packets = hasArg(init, "--save-packets") });
}

/// Parses a captured packet and prints it. Regression check for the parser.
fn selftest(init: std.process.Init) !void {
    const io = init.io;

    const file = try std.Io.Dir.cwd().openFile(io, "data/packet-300.udp", .{ .mode = .read_only });
    defer file.close(io);

    var file_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);
    const data = try parser.parse_packet(&file_reader.interface);

    std.debug.print("Packet data:\n{any}", .{data});
}

const CAPTURED_PACKET_SIZE = 324;
const MAX_FRAME_GAP_MS: u32 = 250; // don't stall on pauses in the capture

/// Replays the captured data/packet-*.udp frames through the DualSense, paced
/// by each packet's own TimestampMS (≈100 Hz). Add --loop to repeat forever;
/// --speed <factor> scales the playback rate (1.0 = original cadence).
fn replay(init: std.process.Init) !void {
    const io = init.io;
    var hap: haptics.Haptics = .{};

    const loop_forever = hasArg(init, "--loop");
    var speed: f32 = 1.0;
    if (argValue(init, "--speed")) |v| {
        speed = try std.fmt.parseFloat(f32, v);
        if (speed <= 0) return error.InvalidSpeed;
    }

    print("replay: sending captured frames to the DualSense (Ctrl-C to stop)\n", .{});
    var total: usize = 0;
    while (true) {
        var index: usize = 1;
        var prev_ts: ?u32 = null;
        var count: usize = 0;
        while (true) : (index += 1) {
            var path_buf: [64]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "data/packet-{d}.udp", .{index}) catch unreachable;
            const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch break;
            defer file.close(io);

            var buf: [CAPTURED_PACKET_SIZE]u8 = undefined;
            const n = try file.readStreaming(io, &.{buf[0..]});
            if (n != CAPTURED_PACKET_SIZE) break;

            var reader = Io.Reader.fixed(buf[0..n]);
            const frame = try parser.parse_packet(&reader);

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

        total += count;
        print("replayed {d} frames\n", .{count});
        if (!loop_forever) break;
    }

    hap.shutdown();
}

fn hasArg(init: std.process.Init, needle: []const u8) bool {
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next(); // argv[0]
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

fn argValue(init: std.process.Init, needle: []const u8) ?[]const u8 {
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next(); // argv[0]
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, needle)) return it.next();
    }
    return null;
}
