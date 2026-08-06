const std = @import("std");

/// Parsed command-line flags and values shared by all runtime modes.
pub const CommandLineArgs = struct {
    /// Print help and exit.
    help: bool = false,
    /// Replay captured packets through the controller.
    replay: bool = false,
    /// Optional channel number for an audio test tone; null disables the test.
    audio_test: ?[]const u8 = null,
    /// Repeat replay mode indefinitely.
    loop: bool = false,
    /// Requested `simple` or `audio` motor mode.
    motor_mode: ?[]const u8 = null,
    /// Force simple rumble mode for a Bluetooth controller.
    bluetooth: bool = false,
    /// Substring used to select the SDL audio device.
    audio_sink: ?[]const u8 = null,
    /// Audio output gain before rendering.
    audio_gain: ?[]const u8 = null,
    /// Replay speed multiplier.
    speed: ?[]const u8 = null,
    /// Save received telemetry packets using the default limit.
    save_packets: bool = false,
    /// Maximum number of packets to save.
    capture_count: ?u32 = null,
    /// Enable the RPM-driven RGB lightbar.
    lightbar: bool = false,
    /// Enable the gear-indicator player LEDs.
    leds: bool = false,
    /// Record packets without initializing audio or HID backends.
    record_only: bool = false,
    /// IP address on which to receive telemetry.
    ip_address: ?[]const u8 = null,
    /// UDP port on which to receive telemetry.
    port: ?u16 = null,
};

/// Parses argv once and returns values shared by all application modes.
pub fn parseCommandLine(init: std.process.Init) !CommandLineArgs {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var args = CommandLineArgs{};

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            args.help = true;
        } else if (std.mem.eql(u8, arg, "--replay")) {
            args.replay = true;
        } else if (std.mem.eql(u8, arg, "--loop")) {
            args.loop = true;
        } else if (std.mem.eql(u8, arg, "--bluetooth")) {
            args.bluetooth = true;
        } else if (std.mem.eql(u8, arg, "--save-packets")) {
            args.save_packets = true;
        } else if (std.mem.eql(u8, arg, "--record-only")) {
            args.record_only = true;
        } else if (std.mem.eql(u8, arg, "--lightbar")) {
            args.lightbar = true;
        } else if (std.mem.eql(u8, arg, "--leds")) {
            args.leds = true;
        } else if (std.mem.eql(u8, arg, "--motor-mode")) {
            args.motor_mode = takeValue(argv, &i) orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--audio-sink")) {
            args.audio_sink = takeValue(argv, &i) orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--audio-gain")) {
            args.audio_gain = takeValue(argv, &i) orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--speed")) {
            args.speed = takeValue(argv, &i) orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--ip-address")) {
            args.ip_address = takeValue(argv, &i) orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--audio-test")) {
            // Optional channel; without one, defaults to channel 0.
            args.audio_test = takeValue(argv, &i) orelse "";
        } else if (std.mem.eql(u8, arg, "--port")) {
            const value = takeValue(argv, &i) orelse return error.InvalidPort;
            const port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidPort;
            if (port == 0) return error.InvalidPort;
            args.port = port;
        } else if (std.mem.eql(u8, arg, "--capture-count")) {
            const value = takeValue(argv, &i) orelse return error.InvalidCaptureCount;
            const count = std.fmt.parseInt(u32, value, 10) catch return error.InvalidCaptureCount;
            if (count == 0) return error.InvalidCaptureCount;
            args.capture_count = count;
        } else if (!args.help) {
            std.debug.print("unknown option '{s}' (use --help for usage)\n", .{arg});
            return error.UnknownOption;
        }
    }
    return args;
}

/// Returns the next argument if it is a value, not another `--` option.
/// On success advances `i` past the value; otherwise `i` stays put.
pub fn takeValue(argv: []const [:0]const u8, i: *usize) ?[]const u8 {
    if (i.* + 1 >= argv.len) return null;
    const value = argv[i.* + 1];
    if (std.mem.startsWith(u8, value, "--")) return null;
    i.* += 1;
    return value;
}

/// Prints usage information for all command-line options.
pub fn printHelp() void {
    const usage =
        \\Usage: horizon-dualsense-haptics [options]
        \\
        \\Options:
        \\  --help                     Show this help and exit
        \\  --motor-mode simple|audio  Select the haptic backend
        \\  --bluetooth                 Force simple rumble mode and disable USB audio
        \\  --audio-sink <substring>    Select the matching SDL audio device
        \\  --audio-gain <0..1>         Set audio output gain
        \\  --ip-address <address>      IP address to receive telemetry (default 127.0.0.1)
        \\  --port <port>               UDP port to receive telemetry (default 8800)
        \\  --save-packets              Save received packets under fh5_packets/
        \\  --capture-count <n>         Save up to n packets (implies --save-packets)
        \\  --record-only               Record packets without initializing audio or HID
        \\  --replay                    Replay bundled fh5_packets/packet-*.fh5tel captures
        \\  --loop                      Repeat replay mode indefinitely
        \\  --speed <factor>            Scale replay speed; 1.0 is the captured rate
        \\  --audio-test [0..3]         Emit a test tone on one audio channel
        \\  --lightbar                  Enable the RPM-driven RGB lightbar
        \\  --leds                      Enable the gear-indicator player LEDs
        \\
    ;
    std.debug.print("{s}", .{usage});
}
