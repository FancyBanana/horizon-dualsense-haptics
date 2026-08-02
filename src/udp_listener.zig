const std = @import("std");
const net = std.Io.net;
const print = std.debug.print;

// This function opens an UDP socket and listens for packets
// TODO: I've already managed to get data from game,
//       now I need to change the interface to accept config
//       and a processing function
pub fn udp_listen(init: std.process.Init) !void {
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
        print("#{d} received {d} byte(s) from {f};\n", .{ packet_counter, msg.data.len, msg.from });
        if (packet_counter <= 1000) {
            const path = try std.fmt.allocPrint(arena, "data/packet-{d}.udp", .{packet_counter});
            const file = try std.Io.Dir.cwd().createFile(io, path, .{});
            try file.writeStreamingAll(io, msg.data);
            file.close(io);
        }
    }
}
