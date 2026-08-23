// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const net = std.Io.net;

/// Largest possible UDP datagram payload (IPv4).
pub const MAX_DATAGRAM_SIZE: usize = 65507;
pub const DEFAULT_IP_ADDRESS = "127.0.0.1";
pub const DEFAULT_PORT: u16 = 8800;

/// Listener configuration (set once at `init`).
pub const Options = struct {
    ip_address: []const u8 = DEFAULT_IP_ADDRESS,
    port: u16 = DEFAULT_PORT,
};

/// Receives telemetry datagrams. Callers poll and process the returned data.
pub const Listener = struct {
    io: std.Io,
    options: Options = .{},
    socket: ?net.Socket = null,

    pub fn init(io: std.Io) Listener {
        return .{ .io = io };
    }

    /// Binds the UDP socket.
    pub fn bind(self: *Listener, options: ?Options) !void {
        if (options) |opts| {
            self.options = opts;
        }
        const addr = try net.IpAddress.parse(self.options.ip_address, self.options.port);
        self.socket = try addr.bind(self.io, .{ .mode = .dgram, .protocol = .udp });
        std.debug.print("Listening on {f}\n", .{addr});
    }

    /// Closes the bound socket. Idempotent.
    pub fn close(self: *Listener) void {
        if (self.socket) |s| s.close(self.io);
        self.socket = null;
    }

    /// One receive cycle with a short timeout. Returns a slice of `buf`
    /// containing the received datagram, or `null` on timeout. Returns an
    /// error only on fatal socket failure.
    pub fn poll(self: *Listener, buf: []u8) !?[]const u8 {
        const sock = self.socket orelse return null;
        const msg = sock.receiveTimeout(
            self.io,
            buf,
            .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } },
        ) catch |err| switch (err) {
            error.Timeout => return null,
            // Transient: the socket is still usable.
            error.MessageOversize,
            error.ConnectionResetByPeer,
            error.NetworkDown,
            error.PortUnreachable,
            => {
                std.log.warn("listener: transient receive error {s}", .{@errorName(err)});
                return null;
            },
            else => return err,
        };
        return msg.data;
    }
};
