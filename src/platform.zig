// SPDX-License-Identifier: AGPL-3.0-or-later

//! Portable time helpers. Replaces the previous `linux.clock_gettime(.MONOTONIC)`
//! calls so the rest of the app compiles unchanged on Windows.

const std = @import("std");

/// Monotonic clock in milliseconds. `io` is the std.Io the caller already
/// carries around (`init.io`, or `std.testing.io` in tests). The `awake` clock
/// maps to CLOCK_MONOTONIC on Linux; the freshness envelope and reconnect
/// throttling only need a clock that never jumps, so wall-clock changes can't
/// leave a motor stuck on.
/// Returns monotonic elapsed time in milliseconds.
pub fn nowMillis(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}
