const std = @import("std");
const listener = @import("udp_listener.zig");
const Io = std.Io;
const parser = @import("packet_parser.zig");
const zig_forza_haptics = @import("zig_forza_haptics");

pub fn main(init: std.process.Init) !void {
    // Prints to stderr, unbuffered, ignoring potential errors.

    const io = init.io;

    const file = try std.Io.Dir.cwd().openFile(io, "data/packet-300.udp", .{ .mode = .read_only });
    defer file.close(io);

    var file_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);
    const data = try parser.parse_packet(&file_reader.interface);

    std.debug.print("Packet data:\n{any}", .{data});

    // try listener.udp_listen(init);
}
