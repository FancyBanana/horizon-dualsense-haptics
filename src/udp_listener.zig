// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const net = std.Io.net;

/// Largest possible UDP datagram payload (IPv4).
pub const MAX_DATAGRAM_SIZE: usize = 65507;
pub const DEFAULT_IP_ADDRESS = "127.0.0.1";
pub const DEFAULT_PORT: u16 = 8800;

/// Per-datagram callback; the listener stays game-agnostic.
pub const Handler = struct {
    context: *const anyopaque,
    process: *const fn (ctx: *const anyopaque, data: []const u8) anyerror!void,
};

/// Listener configuration (set once at `init`).
pub const Options = struct {
    ip_address: []const u8 = DEFAULT_IP_ADDRESS,
    port: u16 = DEFAULT_PORT,
};

/// Receives telemetry datagrams and dispatches them to a `Handler`.
pub const Listener = struct {
    io: std.Io,
    options: Options = .{},
    socket: ?net.Socket = null,
    packet_counter: usize = 0,
    should_continue: std.atomic.Value(bool) = .init(true),
    /// Written before the receive loop returns; read after `join`.
    last_error: ?anyerror = null,

    pub fn init(io: std.Io) Listener {
        return .{ .io = io };
    }

    /// Binds the UDP socket; errors surface before the thread starts.
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

    /// Logs failures so a thread's death is never silent.
    fn fail(self: *Listener, err: anyerror) void {
        self.last_error = err;
        std.log.err("listener: {s}", .{@errorName(err)});
    }

    /// Dispatches datagrams until `stop` or a fatal receive error.
    /// Requires `bind` first.
    pub fn listen(self: *Listener, handler: Handler) void {
        const sock = self.socket orelse {
            std.log.err("listener: listen called before bind", .{});
            return;
        };
        defer self.close();
        while (self.should_continue.load(.unordered)) {
            var buf: [MAX_DATAGRAM_SIZE]u8 = undefined;
            // Short timeout keeps shutdown latency low (~100 Hz poll).
            const msg = sock.receiveTimeout(
                self.io,
                &buf,
                .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .boot } },
            ) catch |err| switch (err) {
                error.Timeout => continue,
                // Transient: the socket is still usable.
                error.MessageOversize,
                error.ConnectionResetByPeer,
                error.NetworkDown,
                error.PortUnreachable,
                => {
                    std.log.warn("listener: transient receive error {s}", .{@errorName(err)});
                    continue;
                },
                // Fatal: the socket can no longer accept packets.
                else => return self.fail(err),
            };
            self.packet_counter += 1;
            handler.process(handler.context, msg.data) catch |err| {
                std.log.err("packet handler: {s}", .{@errorName(err)});
                continue;
            };
        }
    }

    /// Requests `listen` to exit; safe from any thread.
    pub fn stop(self: *Listener) void {
        self.should_continue.store(false, .unordered);
    }
};
