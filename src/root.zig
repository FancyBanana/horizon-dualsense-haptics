// SPDX-License-Identifier: AGPL-3.0-or-later

//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

/// Audio-based DualSense haptics backend (SDL3).
pub const audio = @import("audio.zig");
/// Runtime configuration loaded from a key=value file plus CLI overrides.
pub const config = @import("config.zig");
