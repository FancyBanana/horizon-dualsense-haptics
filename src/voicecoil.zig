// SPDX-License-Identifier: AGPL-3.0-or-later

//! Voice-coil audio haptics: telemetry -> per-channel intensity/frequency
//! for the DualSense USB audio stream, plus HID report flags that route
//! haptics through the audio path.

const std = @import("std");
const parser = @import("fh5_packet_parser.zig");
const ds = @import("hardware/dualsense.zig");
const audio = @import("audio.zig");
const config = @import("config.zig");

/// Per-side audio intensity and frequency.
pub const AudioCue = struct {
    amp: f32 = 0,
    freq: f32 = 90,
};

/// Sets the flags that route haptics through USB audio.
pub fn configureAudioReport(motor_mode: config.MotorMode, report: *ds.OutputReport) void {
    if (motor_mode != .audio) return;

    // Same flags the kernel driver uses for speaker + voice-coil routing.
    report.valid_flag0 = ds.Flag0.AUDIO_HAPTICS;
    report.valid_flag1 = ds.Flag1.AUDIO_CONTROL2_ENABLE;
    report.audio_enable_bits = ds.Audio.PATH_SEL_INTERNAL_SPEAKER;
    report.speaker_volume = ds.Audio.SPEAKER_VOLUME_MAX;
    report.audio_control2 = ds.Audio.SP_PREAMP_GAIN_6DB;
}

/// Publishes per-side audio cues; called even while HID is disconnected.
pub fn updateAudio(
    motor_mode: config.MotorMode,
    audio_backend: ?*audio.AudioHaptics,
    frame: *const parser.HorizonFrame,
) void {
    if (motor_mode != .audio) return;
    const backend = audio_backend orelse return;
    const racing = frame.IsRaceOn != 0;

    const left = if (racing) sideAudioCue(
        max2(frame.SurfaceRumbleFl, frame.SurfaceRumbleRl),
        max2(@abs(frame.WheelRotationSpeedFl), @abs(frame.WheelRotationSpeedRl)),
        max2(@abs(frame.TireCombinedSlipFl), @abs(frame.TireCombinedSlipRl)),
        frame.WheelOnRumbleStripFl != 0 or frame.WheelOnRumbleStripRl != 0,
        max2(frame.WheelInPuddleDepthFl, frame.WheelInPuddleDepthRl),
    ) else AudioCue{};
    const right = if (racing) sideAudioCue(
        max2(frame.SurfaceRumbleFr, frame.SurfaceRumbleRr),
        max2(@abs(frame.WheelRotationSpeedFr), @abs(frame.WheelRotationSpeedRr)),
        max2(@abs(frame.TireCombinedSlipFr), @abs(frame.TireCombinedSlipRr)),
        frame.WheelOnRumbleStripFr != 0 or frame.WheelOnRumbleStripRr != 0,
        max2(frame.WheelInPuddleDepthFr, frame.WheelInPuddleDepthRr),
    ) else AudioCue{};

    backend.setIntensity(left.amp, right.amp);
    backend.setFrequency(left.freq, right.freq);
    backend.setActive(racing);
}

/// Combines one side's surface, slip, strip, puddle, and wheel-speed inputs.
pub fn sideAudioCue(surface: f32, wheel_rotation: f32, combined_slip: f32, on_strip: bool, puddle: f32) AudioCue {
    const safe_surface = finiteOrZero(surface);
    const safe_rotation = finiteOrZero(wheel_rotation);
    const safe_slip = finiteOrZero(combined_slip);
    const safe_puddle = finiteOrZero(puddle);
    const slip = std.math.clamp(safe_slip, 0, 3);
    const strip_amp: f32 = if (on_strip) 0.22 else 0;
    const puddle_amp = std.math.clamp(safe_puddle, 0, 1) * 0.08;
    const amp = std.math.clamp(std.math.clamp(safe_surface, 0, 1) + slip * 0.10 + strip_amp + puddle_amp, 0, 1);

    const strip_freq: f32 = if (on_strip) 30 else 0;
    const puddle_freq = std.math.clamp(safe_puddle, 0, 1) * 10;
    const freq = std.math.clamp(
        45 + std.math.clamp(safe_rotation, 0, 120) * 1.1 + slip * 18 + strip_freq - puddle_freq,
        45,
        220,
    );
    return .{ .amp = amp, .freq = freq };
}

fn max2(a: f32, b: f32) f32 {
    const left = finiteOrZero(a);
    const right = finiteOrZero(b);
    return if (left > right) left else right;
}

fn finiteOrZero(value: f32) f32 {
    return if (std.math.isFinite(value)) value else 0;
}

test "audio cues vary with wheel state" {
    const calm = sideAudioCue(0.2, 10, 0, false, 0);
    const loaded = sideAudioCue(0.2, 80, 1.5, true, 0);

    try std.testing.expect(loaded.amp > calm.amp);
    try std.testing.expect(loaded.freq > calm.freq);
    try std.testing.expect(loaded.amp <= 1.0);
    try std.testing.expect(loaded.freq <= 220.0);
}
