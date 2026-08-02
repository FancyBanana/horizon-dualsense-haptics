// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const net = std.Io.net;
const print = std.debug.print;

pub const Handler = struct {
    context: *anyopaque,
    /// Called with each raw telemetry datagram.
    process: *const fn (ctx: *anyopaque, io: std.Io, data: []const u8) anyerror!void,
};

pub const Options = struct {
    save_packets: bool = false,
};

pub fn udp_listen(init: std.process.Init, handler: Handler, options: Options) !void {
    const io = init.io;
    const addr = try net.IpAddress.parse("127.0.0.1", 8800);

    const sock = try addr.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer sock.close(io);

    const FORZA_HORIZON_PACKET_SIZE = 324;

    var buf: [FORZA_HORIZON_PACKET_SIZE]u8 = undefined;

    var packet_counter: u32 = 0;

    const arena = init.arena.allocator();

    print("listen on {f}\n", .{addr});
    while (true) {
        packet_counter += 1;
        const msg = try sock.receive(io, &buf);
        try handler.process(handler.context, io, msg.data);
        if (options.save_packets and packet_counter <= 1000) {
            const path = try std.fmt.allocPrint(arena, "data/packet-{d}.udp", .{packet_counter});
            const file = try std.Io.Dir.cwd().createFile(io, path, .{});
            try file.writeStreamingAll(io, msg.data);
            file.close(io);
        }
    }
}
