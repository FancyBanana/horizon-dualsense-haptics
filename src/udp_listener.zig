// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const net = std.Io.net;
const parser = @import("packet_parser.zig");
const print = std.debug.print;

/// Callback state and function used to process valid telemetry packets.
pub const Handler = struct {
    /// Opaque state passed to the packet callback.
    context: *anyopaque,
    /// Called with each raw telemetry datagram.
    process: *const fn (ctx: *anyopaque, io: std.Io, data: []const u8) anyerror!void,
};

/// Controls packet persistence for a listener session.
pub const Options = struct {
    /// Local IP address to bind.
    ip_address: []const u8 = DEFAULT_IP_ADDRESS,
    /// Local UDP port to bind.
    port: u16 = DEFAULT_PORT,
    /// Whether valid packets should also be written under fh5_packets/.
    save_packets: bool = false,
    /// Maximum number of packet files to write during this session.
    max_saved_packets: u32 = DEFAULT_MAX_SAVED_PACKETS,
};

/// Default local address for Forza telemetry.
pub const DEFAULT_IP_ADDRESS = "127.0.0.1";
/// Default UDP port for Forza telemetry.
pub const DEFAULT_PORT: u16 = 8800;
/// Default capture limit used by --save-packets without --capture-count.
pub const DEFAULT_MAX_SAVED_PACKETS: u32 = 1000;

/// Receives valid Forza telemetry datagrams and dispatches them to a handler.
pub fn listen(init: std.process.Init, handler: Handler, options: Options) !void {
    const io = init.io;
    const addr = try net.IpAddress.parse(options.ip_address, options.port);

    const sock = try addr.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer sock.close(io);

    // One extra byte lets us distinguish an oversized datagram from a full
    // packet that exactly fills the receive buffer.
    var buf: [parser.PACKET_SIZE + 1]u8 = undefined;

    var packet_counter: u32 = 0;

    const arena = init.arena.allocator();

    print("listen on {f}\n", .{addr});
    while (true) {
        const msg = try sock.receive(io, &buf);
        if (msg.data.len != parser.PACKET_SIZE) {
            print("ignoring telemetry packet of {d} bytes\n", .{msg.data.len});
            continue;
        }
        packet_counter += 1;
        try handler.process(handler.context, io, msg.data);
        if (options.save_packets and packet_counter <= options.max_saved_packets) {
            const path = try std.fmt.allocPrint(arena, "fh5_packets/packet-{d}.fh5tel", .{packet_counter});
            const file = try std.Io.Dir.cwd().createFile(io, path, .{});
            defer file.close(io);
            try file.writeStreamingAll(io, msg.data);
        }
    }
}
