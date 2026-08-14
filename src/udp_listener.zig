// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const net = std.Io.net;

/// Largest possible UDP datagram payload (IPv4).
/// The listener forwards raw datagrams; the game-specific parser lives in the consumer.
pub const MAX_DATAGRAM_SIZE: usize = 65507;
/// Default local address for Forza telemetry.
pub const DEFAULT_IP_ADDRESS = "127.0.0.1";
/// Default UDP port for Forza telemetry.
pub const DEFAULT_PORT: u16 = 8800;

/// Callback state and function used to process each received datagram.
/// The listener is game-agnostic; parsing and dispatch are the handler's job.
pub const Handler = struct {
    /// Opaque state passed to the datagram callback.
    context: *const anyopaque,
    /// Called with each raw datagram.
    process: *const fn (ctx: *const anyopaque, data: []const u8) anyerror!void,
};

/// Listener configuration (set once at `init`).
pub const Options = struct {
    /// Local IP address to bind.
    ip_address: []const u8 = DEFAULT_IP_ADDRESS,
    /// Local UDP port to bind.
    port: u16 = DEFAULT_PORT,
};

/// Receives Forza Horizon telemetry datagrams and dispatches them to a `Handler`.
/// Runtime state lives in the struct; the handler is passed per `listen` call.
pub const Listener = struct {
    io: std.Io,
    options: Options = .{},
    /// Bound socket; set by `bind`, owned until `deinit`/`close`.
    socket: ?net.Socket = null,
    /// Valid packets received during the current session.
    packet_counter: usize = 0,
    /// Set to false from a signal handler to stop `listen` cleanly.
    should_continue: std.atomic.Value(bool) = .init(true),
    /// Error that caused the receive loop to exit; written before it returns,
    /// read after `join` — no data race.
    last_error: ?anyerror = null,

    pub fn init(io: std.Io) Listener {
        return .{ .io = io };
    }

    /// Parses the address and binds the UDP socket. Errors propagate to the
    /// caller, so a bad address/port is caught synchronously before the
    /// listener thread starts.
    pub fn bind(self: *Listener, options: ?Options) !void {
        if (options) |opts| {
            self.options = opts;
        }
        const addr = try net.IpAddress.parse(self.options.ip_address, self.options.port);
        self.socket = try addr.bind(self.io, .{ .mode = .dgram, .protocol = .udp });
        std.debug.print("Listening on {f}\n", .{addr});
    }

    /// Closes the bound socket, if any. Idempotent.
    pub fn close(self: *Listener) void {
        if (self.socket) |s| s.close(self.io);
        self.socket = null;
    }

    /// Marks the listener as failed and logs the error, so a thread's
    /// failure is not silent even if the caller never reads `last_error`.
    fn fail(self: *Listener, err: anyerror) void {
        self.last_error = err;
        std.log.err("listener: {s}", .{@errorName(err)});
    }

    /// Dispatches every datagram to `handler` until `should_continue`
    /// goes false (or a fatal receive error). Never returns an error union,
    /// so it can run in a thread directly. Requires `bind` to have been
    /// called first; missing binding is a caller error.
    pub fn listen(self: *Listener, handler: Handler) void {
        const sock = self.socket orelse {
            std.log.err("listener: listen called before bind", .{});
            return;
        };
        defer self.close();
        while (self.should_continue.load(.unordered)) {
            var buf: [MAX_DATAGRAM_SIZE]u8 = undefined;
            // Short timeout so `should_continue` is polled at a brisk rate
            // (~100 Hz) and transient errors don't stall shutdown.
            const msg = sock.receiveTimeout(
                self.io,
                &buf,
                .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .boot } },
            ) catch |err| switch (err) {
                // No datagram within the timeout: normal, keep waiting.
                error.Timeout => continue,
                // Transient per-datagram conditions: the socket is still usable.
                error.MessageOversize,
                error.ConnectionResetByPeer,
                error.NetworkDown,
                error.PortUnreachable,
                => {
                    std.log.warn("listener: transient receive error {s}", .{@errorName(err)});
                    continue;
                },
                // The socket can no longer accept packets: give up.
                else => return self.fail(err),
            };
            self.packet_counter += 1;
            handler.process(handler.context, msg.data) catch |err| {
                std.log.err("packet handler: {s}", .{@errorName(err)});
                continue;
            };
        }
    }

    /// Requests `listen` to return at its next loop iteration.
    /// Safe to call from another thread (e.g. a signal handler).
    pub fn stop(self: *Listener) void {
        self.should_continue.store(false, .unordered);
    }
};
