// SPDX-License-Identifier: AGPL-3.0-or-later

//! Portable time helpers.

const std = @import("std");

/// Monotonic elapsed time in milliseconds (never jumps).
pub inline fn nowMillis(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}
