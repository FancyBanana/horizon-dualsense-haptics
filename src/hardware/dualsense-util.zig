// SPDX-License-Identifier: AGPL-3.0-or-later

//! High-level DualSense API: composable output-report builder, adaptive
//! trigger effect constructors, and input decoding (`decodeInput` ->
//! `InputState`).
//!
//! Developers describe the *desired effect* ("rumble the left coil at 60%",
//! "rigid trigger that resists more as it is pulled"); this module picks the
//! flag bits, packet fields, and wire encodings.  The raw protocol reference
//! (report layouts, flag constants) lives in `dualsense.zig`
//! and is re-exported here so a single import covers both layers:
//!
//! ```zig
//! const ds = @import("hardware/dualsense-util.zig");
//!
//! var builder: ds.ReportBuilder = .{};
//! builder.setMotorsNorm(0.6, 0.2);                       // rumble emulation
//! builder.setLeftTriggerEffect(ds.TriggerEffect.rigidNorm(0.7));
//! builder.useVoiceCoilHaptics();                         // PCM haptics mode
//! builder.boostInternalSpeaker();                        // audible cues
//! builder.setLightbarColorNorm(1.0, 0.25, 0);
//! const report = try builder.toReport();
//! ```
//!
//! The grip voice coils have one hardware path and two drivers (rumble
//! emulation bytes vs RL/RR PCM from the USB audio interface); requesting
//! both on one builder fails at `toReport` time with
//! `error.ConflictingRumbleMode`.
//!

const std = @import("std");
pub const proto = @import("dualsense.zig");

// ---------------------------------------------------------------------------
// Re-exports from the raw protocol module (single-import convenience).
// ---------------------------------------------------------------------------

pub const Flag0 = proto.Flag0;
pub const Flag1 = proto.Flag1;
pub const Audio = proto.Audio;
pub const PowerSave = proto.PowerSave;
pub const FLAG2_LED_BRIGHTNESS_CONTROL_ENABLE = proto.FLAG2_LED_BRIGHTNESS_CONTROL_ENABLE;
pub const FLAG2_LIGHTBAR_SETUP_CONTROL_ENABLE = proto.FLAG2_LIGHTBAR_SETUP_CONTROL_ENABLE;
pub const FLAG2_RUMBLE_V2 = proto.FLAG2_RUMBLE_V2;
pub const LIGHTBAR_SETUP_LIGHT_ON = proto.LIGHTBAR_SETUP_LIGHT_ON;
pub const LIGHTBAR_SETUP_LIGHT_OUT = proto.LIGHTBAR_SETUP_LIGHT_OUT;
pub const PLAYER_LED_PATTERNS = proto.PLAYER_LED_PATTERNS;
pub const MuteLedMode = proto.MuteLedMode;
pub const EffectMode = proto.EffectMode;
pub const OutputReportCommon = proto.OutputReportCommon;
pub const InputReportCommon = proto.InputReportCommon;
pub const UsbInputReport = proto.UsbInputReport;
pub const BtInputReport = proto.BtInputReport;
pub const USB_INPUT_REPORT_SIZE = proto.USB_INPUT_REPORT_SIZE;
pub const UsbOutputReport = proto.UsbOutputReport;
pub const FullUsbOutputReport = proto.FullUsbOutputReport;
pub const BtOutputReport = proto.BtOutputReport;

// ---------------------------------------------------------------------------
// Value normalization helpers
// ---------------------------------------------------------------------------

/// Clamps to 0..1, mapping NaN/inf to 0 so telemetry glitches are inert.
fn clamp01(n: f32) f32 {
    const v = if (std.math.isFinite(n)) n else 0;
    return std.math.clamp(v, 0, 1);
}

/// Normalized force (0..1) -> raw force byte (0..255).
pub fn forceFromNorm(n: f32) u8 {
    return @intFromFloat(@round(clamp01(n) * 255.0));
}

/// Normalized pull-depth position (0..1) -> nearest trigger zone index 0..9.
pub fn zoneFromNorm(position_norm: f32) u8 {
    return @intFromFloat(@round(clamp01(position_norm) * 9.0));
}

/// Normalized level (0..1) -> zone strength byte (0..8, 0 = inactive zone).
pub fn levelFromNorm(n: f32) u8 {
    return @intFromFloat(@round(clamp01(n) * 8.0));
}

/// Raw amplitude byte (0..255) -> zone strength byte (1..8).
pub fn zoneAmp(a: u8) u8 {
    return @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(a)) / 255.0 * 8.0, 1, 8));
}

// ---------------------------------------------------------------------------
// Zone maps (10 zones along the trigger pull, 0 = rest .. 9 = fully pressed)
// ---------------------------------------------------------------------------

/// Uniform strength `level` (1..8) on zones `start`..9, rest off.  Classic
/// "resistance kicks in after this point" feel.
pub fn zoneBand(start: u8, level: u8) [10]u8 {
    var zones = [_]u8{0} ** 10;
    const lvl = std.math.clamp(level, 1, 8);
    const first = @min(@as(usize, start), zones.len);
    for (zones[first..]) |*z| z.* = lvl;
    return zones;
}

/// Uniform strength on zones `start`..`end` inclusive, rest off.
pub fn zoneRange(start: u8, end: u8, level: u8) [10]u8 {
    var zones = [_]u8{0} ** 10;
    const lvl = std.math.clamp(level, 1, 8);
    const first = @min(@as(usize, start), zones.len - 1);
    const last = @min(@as(usize, end), zones.len - 1);
    if (first > last) return zones; // empty range
    for (zones[first .. last + 1]) |*z| z.* = lvl;
    return zones;
}

/// Resistance rising linearly from the resting position up to `peak` (0..8)
/// at the fully pressed position: hydraulic pedal / progressive spring feel.
pub fn risingZones(peak: u8) [10]u8 {
    const m = std.math.clamp(peak, 0, 8);
    var zones: [10]u8 = undefined;
    for (0..10) |i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / 9.0;
        zones[i] = @intFromFloat(@round(t * @as(f32, @floatFromInt(m))));
    }
    return zones;
}

// ---------------------------------------------------------------------------
// Adaptive trigger effects
// ---------------------------------------------------------------------------

/// Wrapper around the raw 11-byte adaptive-trigger effect payload.
/// Byte 0 of `data` is the `EffectMode` tag; the rest are mode parameters.
/// Constructors describe the desired feel; `data` is what goes on the wire.
pub const TriggerEffect = struct {
    /// Raw device payload, ready to be copied into an output report.
    data: [11]u8 = [_]u8{0} ** 11,

    fn init(mode: EffectMode, params: []const u8) TriggerEffect {
        var e: TriggerEffect = .{};
        e.data[0] = @intFromEnum(mode);
        for (params, 1..) |p, i| e.data[i] = p;
        return e;
    }

    /// Release the trigger actuator and let it return to its resting state.
    /// The neutral/off effect: send this when no effect should be active
    /// (menu, paused, effect ended) so held resistance/vibration does not
    /// linger on the actuator.
    pub fn off() TriggerEffect {
        return init(.reset, &.{0});
    }

    /// Ranges: `force` 0..255.
    ///
    /// Constant spring: uniform resistance across the entire pull path.
    /// The trigger feels heavier everywhere but still travels fully; there
    /// is no break point or texture. `force` is 0..255 device units where 0
    /// is a light (not zero) resistance. Use for hydraulic pedals, stiff
    /// levers, or any "heavier spring" feel. For a wall that stops travel,
    /// see `weapon`; for weight that grows as you pull, see `rigidZones`
    /// with `risingZones`.
    pub fn rigid(force: u8) TriggerEffect {
        return init(.rigid, &.{ 0, force });
    }

    /// Constant spring, from a normalized force: same feel as `rigid`,
    /// with 0..1 instead of raw device units (0 = light resistance, 1 =
    /// maximum). Preferred over `rigid` for new code.
    pub fn rigidNorm(force_norm: f32) TriggerEffect {
        return rigid(forceFromNorm(force_norm));
    }

    /// Ranges: `freq` 0..255, `amp` 0..255.
    ///
    /// Buzz at one point near the resting position of the pull.
    /// Higher frequencies feel finer/grittier, lower ones chunkier. Classic uses: ABS lockup feedback, gear-shift kick,
    /// impact rumble while the trigger is only lightly held. For vibration
    /// spread over a section of the pull, see `vibrateZones`.
    pub fn vibrate(freq: u8, amp: u8) TriggerEffect {
        return init(.vibrate, &.{ freq, amp });
    }

    /// Point buzz near the resting position, from normalized values: same
    /// feel as `vibrate`, with frequency and amplitude on a 0..1 scale
    /// (1 = fastest/strongest the actuator offers).
    pub fn vibrateNorm(freq_norm: f32, amp_norm: f32) TriggerEffect {
        return vibrate(forceFromNorm(freq_norm), forceFromNorm(amp_norm));
    }

    /// Ranges: each of the 10 `zones` entries 0..8 (0 = free travel).
    ///
    /// Fully custom resistance profile along the pull. The trigger path is
    /// split into 10 zones (0 = resting, 9 = fully pressed); each zone gets
    /// strength 1..8, with 0 leaving that stretch of travel free. Build the
    /// map with `zoneBand` (wall from a point), `zoneRange` (resistance in
    /// one stretch), or `risingZones` (progressive draw weight, e.g. a
    /// brake pedal that firms up with depth).
    pub fn rigidZones(zones: [10]u8) TriggerEffect {
        var e = init(.rigid_zones, &.{});
        e.data[1..7].* = packZones(zones);
        return e;
    }

    /// Ranges: each of the 10 `zones` entries 0..8 (0 = inactive), `freq`
    /// 0..255.
    ///
    /// Buzzing confined to part of the pull: same 10-zone map as
    /// `rigidZones`, but active zones vibrate instead of resisting. This is
    /// the "automatic gun" mode -
    /// hold the trigger in the buzzing range for continuous fire feel.
    /// Also used for rev-limiters (buzz at the top of the pull) and wheelspin.
    pub fn vibrateZones(zones: [10]u8, freq: u8) TriggerEffect {
        var e = rigidZones(zones);
        e.data[0] = @intFromEnum(EffectMode.vibrate_zones);
        e.data[9] = freq;
        return e;
    }

    /// Ranges: `position` 0..9, `strength` 1..8 (0 = off).
    ///
    /// Two-stage trigger: free travel until zone `position`, then uniform
    /// strength-`strength` resistance from there to full press. Feels like
    /// a camera shutter or safety catch - slack first, then a wall. Unlike
    /// `weapon` the wall resists rather than hard-stops travel, and unlike
    /// `rigid` the first part of the pull stays loose.
    pub fn feedback(position: u8, strength: u8) TriggerEffect {
        if (strength == 0) return off();
        return rigidZones(zoneBand(position, strength));
    }

    /// Two-stage trigger (slack, then wall), from normalized values: same
    /// feel as `feedback`. `position_norm` is the pull depth (0..1) where
    /// resistance kicks in; `strength_norm` scales the wall (0 releases the
    /// actuator entirely, like `off`).
    pub fn feedbackNorm(position_norm: f32, strength_norm: f32) TriggerEffect {
        return feedback(zoneFromNorm(position_norm), levelFromNorm(strength_norm));
    }

    /// Ranges: `start`/`end` 0..9 (recommended: `start` 2..7, `end` up to
    /// 8), `strength` 1..8; 0 falls back to `off`.
    ///
    /// Semi-auto gun ("SemiAutomaticGun"): crisp break point like a real
    /// firearm trigger. Free travel to zone `start`, then travel stops dead
    /// in the `start`..`end` band at fixed `strength` (1..8) - one shot per
    /// pull. The stop is a hard limit, not progressive resistance (use
    /// `bow` when it should give gradually, `feedback` when it should just
    /// get heavy).
    pub fn weapon(start: u8, end: u8, strength: u8) TriggerEffect {
        if (strength == 0) return off();
        var e = init(.weapon, &.{});
        const mask = startStopZones(start, end);
        e.data[1] = @truncate(mask);
        e.data[2] = @truncate(mask >> 8);
        e.data[3] = @min(strength, 8) -| 1;
        return e;
    }

    /// Crisp semi-auto break point, from normalized values: same feel as
    /// `weapon`. Positions are pull depth 0..1; `strength_norm` is clamped
    /// to at least level 1 because a zero-strength break point is meaningless.
    pub fn weaponNorm(start_norm: f32, end_norm: f32, strength_norm: f32) TriggerEffect {
        return weapon(zoneFromNorm(start_norm), zoneFromNorm(end_norm), @max(levelFromNorm(strength_norm), 1));
    }

    /// Ranges: `start`/`end` 0..9 (recommended: `end` up to 8),
    /// `strength`/`snap_force` 1..8; either 0 falls back to `off`.
    ///
    /// Drawing a bowstring: free travel until zone `start`, then elastic
    /// resistance grows toward zone `end`. `strength` (1..8) sets the draw
    /// weight at full draw; `snap_force` (1..8) sets how violently the
    /// string snaps home on release. Distinct from `weapon`: the stop gives
    /// progressively instead of being absolute, and release has a kick.
    pub fn bow(start: u8, end: u8, strength: u8, snap_force: u8) TriggerEffect {
        if (strength == 0 or snap_force == 0) return off();
        var e = init(.bow, &.{});
        const mask = startStopZones(start, end);
        const pair = forcePair(strength -| 1, snap_force -| 1);
        e.data[1] = @truncate(mask);
        e.data[2] = @truncate(mask >> 8);
        e.data[3] = @truncate(pair);
        return e;
    }

    /// Bowstring draw with release snap, from normalized values: same feel
    /// as `bow`. Positions are pull depth 0..1; draw weight and snap force
    /// are 0..1, each clamped to at least level 1.
    pub fn bowNorm(start_norm: f32, end_norm: f32, strength_norm: f32, snap_force_norm: f32) TriggerEffect {
        return bow(
            zoneFromNorm(start_norm),
            zoneFromNorm(end_norm),
            @max(levelFromNorm(strength_norm), 1),
            @max(levelFromNorm(snap_force_norm), 1),
        );
    }

    /// Ranges: `start`/`end` 0..9 (zone indices, `start` < `end`),
    /// `first_foot` 0..6, `second_foot` `first_foot`+1..7, `frequency`
    /// 0..7 (3-bit; see below).
    ///
    /// Sony's "galloping" effect (0x23): a time-clocked two-foot gait
    /// oscillator inside the `start`..`end` band. The two "feet" are PHASE
    /// POSITIONS within the oscillation cycle (not strengths): the actuator
    /// steps first_foot -> second_foot -> first_foot at `frequency` hertz,
    /// producing a coarse ratchet-like scrape under the finger - horse
    /// hooves on uneven ground in PS5 titles. Per Nielk1's reference:
    /// only low frequency values are discernible, and the effect is not
    /// guaranteed on future firmware. Unlike `machine`, which alternates
    /// two STRENGTHS with an explicit period, galloping alternates two
    /// CYCLE POSITIONS at a fixed rate.
    pub fn galloping(start: u8, end: u8, first_foot: u8, second_foot: u8, frequency: u8) TriggerEffect {
        if (frequency == 0) return off();
        var e = init(.galloping, &.{});
        const mask = startStopZones(start, end);
        const pair = forcePair(second_foot, first_foot);
        e.data[1] = @truncate(mask);
        e.data[2] = @truncate(mask >> 8);
        e.data[3] = @truncate(pair);
        e.data[4] = frequency;
        return e;
    }

    /// Galloping gait oscillator, from normalized values: same feel as
    /// `galloping`. Positions are pull depth 0..1; the feet scale to their
    /// valid 3-bit phase ranges (first 0..6, second kept above first);
    /// frequency scales to the discernible 0..7 range.
    pub fn gallopingNorm(start_norm: f32, end_norm: f32, first_foot_norm: f32, second_foot_norm: f32, frequency_norm: f32) TriggerEffect {
        const scale6 = struct {
            fn f(n: f32) u8 {
                return @intFromFloat(@round(clamp01(n) * 6.0));
            }
        }.f;
        const scale7 = struct {
            fn f(n: f32) u8 {
                return @intFromFloat(@round(clamp01(n) * 7.0));
            }
        }.f;
        const first = scale6(first_foot_norm);
        const second = @max(scale7(second_foot_norm), first + 1);
        return galloping(
            zoneFromNorm(start_norm),
            zoneFromNorm(end_norm),
            first,
            second,
            scale7(frequency_norm),
        );
    }

    /// Ranges: `start`/`end` 0..9, `strength_a`/`strength_b` 0..7 (0
    /// disables one side of the cycle), `frequency`/`period` 0..255.
    ///
    /// Mechanical chugging: alternates between two resistance levels inside
    /// the `start`..`end` band. Unlike `vibrateZones`' continuous buzz this
    /// is a discrete pulse train - jackhammer, machine-gun bolt cycling,
    /// ratchet clicks. Unlike `galloping` the pulses run on a CLOCK
    /// (frequency x period), independent of how fast you pull.
    pub fn machine(start: u8, end: u8, strength_a: u8, strength_b: u8, frequency: u8, period: u8) TriggerEffect {
        if (frequency == 0) return off();
        var e = init(.machine, &.{});
        const mask = startStopZones(start, end);
        const pair = forcePair(strength_a, strength_b);
        e.data[1] = @truncate(mask);
        e.data[2] = @truncate(mask >> 8);
        e.data[3] = @truncate(pair);
        e.data[4] = frequency;
        e.data[5] = period;
        return e;
    }

    /// Mechanical pulse train, from normalized values: same feel as
    /// `machine`. Positions are pull depth 0..1; strengths scale to the
    /// mode's 0..7 levels (0 disables one side of the cycle), rate and
    /// period are 0..1.
    pub fn machineNorm(start_norm: f32, end_norm: f32, strength_a_norm: f32, strength_b_norm: f32, frequency_norm: f32, period_norm: f32) TriggerEffect {
        const scale7 = struct {
            fn f(n: f32) u8 {
                return @intFromFloat(@round(clamp01(n) * 7.0));
            }
        }.f;
        return machine(
            zoneFromNorm(start_norm),
            zoneFromNorm(end_norm),
            scale7(strength_a_norm),
            scale7(strength_b_norm),
            forceFromNorm(frequency_norm),
            forceFromNorm(period_norm),
        );
    }

    /// Simplified section resistance (community `Simple_Weapon`, mode
    /// 0x02): uniform `strength` between two positions given as RAW bytes,
    /// not 0..9 zone indices - the odd one out among the effects (e.g.
    /// reWASD's "full press" preset uses 144..160). Escape hatch for
    /// compatibility with tools/presets that speak raw bytes; prefer
    /// `feedback` or `weapon` for new code.
    pub fn section(start_position: u8, end_position: u8, strength: u8) TriggerEffect {
        return init(.section, &.{ start_position, end_position, strength });
    }
};

fn startStopZones(start: u8, end: u8) u16 {
    const s = @min(start, 9);
    const e = @min(end, 9);
    return (@as(u16, 1) << @intCast(s)) | (@as(u16, 1) << @intCast(e));
}

fn forcePair(a: u8, b: u8) u8 {
    return (a & 0x07) | ((b & 0x07) << 3);
}

/// Packs 10 zone levels into the 6-byte active-mask + 3-bits-per-zone
/// payload (kernel/SDL encoding).
fn packZones(zones: [10]u8) [6]u8 {
    var active: u16 = 0;
    var packed_bits: u32 = 0;
    for (zones, 0..) |z, i| {
        const level = @min(z, 8);
        if (level > 0) {
            active |= @as(u16, 1) << @intCast(i);
            packed_bits |= @as(u32, level - 1) << @intCast(3 * i);
        }
    }
    return .{
        @truncate(active),
        @truncate(active >> 8),
        @truncate(packed_bits),
        @truncate(packed_bits >> 8),
        @truncate(packed_bits >> 16),
        @truncate(packed_bits >> 24),
    };
}

// ---------------------------------------------------------------------------
// Output-report builder
// ---------------------------------------------------------------------------

/// Speaker/headphone output path (bits 4-5 of `audio_enable_bits`).
///
/// This routing only selects the audible sinks (headphone jacks, internal
/// speaker); the haptic actuators are not a sink here — over USB they are
/// driven by the rear channels of the 4-channel audio interface regardless
/// of this setting.
pub const SpeakerRouting = enum {
    /// Path select 0 (power-on default): left channel -> headphone left,
    /// right channel -> headphone right, internal speaker muted.
    headphone_stereo,
    /// Path select 3 (`PATH_SEL_INTERNAL_SPEAKER`): headphone sinks muted,
    /// right channel routed to the internal mono speaker. Pair with max
    /// speaker volume so effect audio is audible on the controller itself.
    internal_speaker,
};

/// Errors returned by `ReportBuilder.toReport`.
pub const ReportBuildError = error{
    /// Incompatible features were requested on one builder.
    ConflictingOptions,
    /// Classic rumble and audio-haptics routing were both requested; they are
    /// mutually exclusive ways to drive the haptic actuators.
    ConflictingRumbleMode,
};

/// Composable constructor for DualSense output reports.
///
/// Every setter is infallible and composes per-feature via OR semantics:
/// each setter touches only the flag bits that gate its own feature, so
/// independent features never stomp each other's state.  Conflict detection
/// is deferred entirely to `toReport()`, which fails when mutually exclusive
/// feature sets were ever requested on the same builder.
///
/// Setters come in two flavors:
///  - normalized (`*Norm`, float 0..1): preferred; no magic numbers.
///  - raw (`u8` bytes / masks): escape hatch for exact device units.
pub const ReportBuilder = struct {
    common: OutputReportCommon = .{ .valid_flag0 = 0, .valid_flag2 = 0 },
    wants_rumble: bool = false,
    wants_audio_haptics: bool = false,
    released_leds: bool = false,

    // ---- rumble -----------------------------------------------------------

    /// Sets the classic-rumble motor strengths (0..255 each).  Enables only
    /// the Flag0.RUMBLE bits plus FLAG2_RUMBLE_V2 (improved rumble emulation).
    pub fn setMotors(self: *ReportBuilder, motor_left: u8, motor_right: u8) void {
        self.wants_rumble = true;
        self.common.valid_flag0 |= Flag0.RUMBLE;
        self.common.valid_flag2 |= FLAG2_RUMBLE_V2;
        self.common.motor_left = motor_left;
        self.common.motor_right = motor_right;
    }

    /// Normalized classic-rumble strengths (0..1 per side).
    pub fn setMotorsNorm(self: *ReportBuilder, left_norm: f32, right_norm: f32) void {
        self.setMotors(forceFromNorm(left_norm), forceFromNorm(right_norm));
    }

    // ---- adaptive triggers -------------------------------------------------

    /// Stores the wrapped effect payload into the report's trigger field.
    pub fn setLeftTriggerEffect(self: *ReportBuilder, effect: TriggerEffect) void {
        self.common.left_trigger_effect = effect.data;
        self.common.valid_flag0 |= Flag0.LEFT_TRIGGER;
    }

    pub fn setRightTriggerEffect(self: *ReportBuilder, effect: TriggerEffect) void {
        self.common.right_trigger_effect = effect.data;
        self.common.valid_flag0 |= Flag0.RIGHT_TRIGGER;
    }

    /// Sets both trigger effects in one call.
    pub fn setTriggerEffects(self: *ReportBuilder, left: TriggerEffect, right: TriggerEffect) void {
        self.setLeftTriggerEffect(left);
        self.setRightTriggerEffect(right);
    }

    /// Releases both trigger actuators so no held effect lingers.
    pub fn releaseTriggers(self: *ReportBuilder) void {
        self.setTriggerEffects(TriggerEffect.off(), TriggerEffect.off());
    }

    // ---- actuator mode / audio sinks ---------------------------------------

    /// Declares that the grip voice coils are driven by RL/RR PCM rendered
    /// through the USB audio interface (`src/audio.zig`). The HID report
    /// carries no haptic state — this only marks the mode so `toReport`
    /// can reject builders that also request rumble emulation, whose
    /// firmware waveform would take over the same coils.
    pub fn useVoiceCoilHaptics(self: *ReportBuilder) void {
        self.wants_audio_haptics = true;
    }

    /// Makes effect audio audible on the controller itself: routes playback
    /// to the internal mono speaker at max hardware volume with +6 dB
    /// preamp (the kernel's speaker-on preset). Purely about the audible
    /// speaker sink; the haptic actuators follow the RL/RR channels
    /// regardless of routing.
    pub fn boostInternalSpeaker(self: *ReportBuilder) void {
        self.setSpeakerRouting(.internal_speaker);
        self.setSpeakerVolume(Audio.SPEAKER_VOLUME_MAX);
        self.setAudioControl2(Audio.SP_PREAMP_GAIN_6DB);
    }

    /// Selects which sinks receive the L/R audio-channel sources.
    pub fn setSpeakerRouting(self: *ReportBuilder, route: SpeakerRouting) void {
        self.setAudioRouting(switch (route) {
            .headphone_stereo => @as(u8, 0),
            .internal_speaker => Audio.PATH_SEL_INTERNAL_SPEAKER,
        });
    }

    /// Raw audio routing byte (see `Audio.PATH_SEL_*`; bits 0-3 carry mic
    /// input flags).  Escape hatch; prefer `setSpeakerRouting`.
    pub fn setAudioRouting(self: *ReportBuilder, enable_bits: u8) void {
        self.common.valid_flag0 |= Flag0.APPLY_AUDIO_CONTROL;
        self.common.audio_enable_bits = enable_bits;
    }

    /// Mute bits for speaker/headphones/microphone/haptics (byte 10, upper
    /// nibble; see `PowerSave.*_MUTE`). Gated by POWER_SAVE_CONTROL_ENABLE
    /// like the kernel driver's mute handling.
    pub fn setAudioMuteBits(self: *ReportBuilder, bits: u8) void {
        self.common.valid_flag1 |= Flag1.POWER_SAVE_CONTROL_ENABLE;
        self.common.power_save_mute_control |= bits;
    }

    pub fn setHeadphoneVolume(self: *ReportBuilder, volume: u8) void {
        self.common.valid_flag0 |= Flag0.HEADPHONE_VOLUME;
        self.common.headphone_volume = volume;
    }

    /// Normalized headphone volume (0..1 of the device maximum).
    pub fn setHeadphoneVolumeNorm(self: *ReportBuilder, volume_norm: f32) void {
        self.setHeadphoneVolume(scaleToMax(volume_norm, Audio.HEADPHONE_VOLUME_MAX));
    }

    pub fn setSpeakerVolume(self: *ReportBuilder, volume: u8) void {
        self.common.valid_flag0 |= Flag0.SPEAKER_VOLUME;
        self.common.speaker_volume = volume;
    }

    /// Normalized speaker volume (0..1 of the device maximum).
    pub fn setSpeakerVolumeNorm(self: *ReportBuilder, volume_norm: f32) void {
        self.setSpeakerVolume(scaleToMax(volume_norm, Audio.SPEAKER_VOLUME_MAX));
    }

    pub fn setMicrophoneVolume(self: *ReportBuilder, volume: u8) void {
        self.common.valid_flag0 |= Flag0.MIC_VOLUME;
        self.common.microphone_volume = volume;
    }

    /// Normalized microphone volume (0..1 of the device maximum).
    pub fn setMicrophoneVolumeNorm(self: *ReportBuilder, volume_norm: f32) void {
        self.setMicrophoneVolume(scaleToMax(volume_norm, Audio.MIC_VOLUME_MAX));
    }

    /// Speaker preamp/attenuation control byte (see `Audio.SP_PREAMP_*`).
    pub fn setAudioControl2(self: *ReportBuilder, value: u8) void {
        self.common.valid_flag1 |= Flag1.AUDIO_CONTROL2_ENABLE;
        self.common.audio_control2 = value;
    }

    // ---- lightbar and player LEDs ------------------------------------------

    pub fn setLightbarColor(self: *ReportBuilder, red: u8, green: u8, blue: u8) void {
        self.common.valid_flag1 |= Flag1.LIGHTBAR_CONTROL_ENABLE;
        self.common.led_red = red;
        self.common.led_green = green;
        self.common.led_blue = blue;
    }

    /// Normalized lightbar color; each channel 0..1.
    pub fn setLightbarColorNorm(self: *ReportBuilder, red_norm: f32, green_norm: f32, blue_norm: f32) void {
        self.setLightbarColor(forceFromNorm(red_norm), forceFromNorm(green_norm), forceFromNorm(blue_norm));
    }

    /// Turns the lightbar LED on or off via the setup byte.
    pub fn setLightbarSetup(self: *ReportBuilder, light_on: bool) void {
        self.common.valid_flag1 |= Flag1.LIGHTBAR_CONTROL_ENABLE;
        self.common.valid_flag2 |= FLAG2_LIGHTBAR_SETUP_CONTROL_ENABLE;
        self.common.lightbar_setup = if (light_on) LIGHTBAR_SETUP_LIGHT_ON else LIGHTBAR_SETUP_LIGHT_OUT;
    }

    /// Raw player-indicator bitmask (bit 0/bit 4 outer LEDs, bit 2 center).
    pub fn setPlayerLeds(self: *ReportBuilder, mask: u8) void {
        self.common.valid_flag1 |= Flag1.PLAYER_INDICATOR_CONTROL_ENABLE;
        self.common.player_leds = mask;
    }

    /// Player-indicator pattern for player number 0..5 (clamped); 0 is off.
    pub fn setPlayerLedsPattern(self: *ReportBuilder, player_number: usize) void {
        self.setPlayerLeds(PLAYER_LED_PATTERNS[@min(player_number, PLAYER_LED_PATTERNS.len - 1)]);
    }

    /// Brightness of the player-indicator LEDs. Firmware scale is 0..2:
    /// 0 = high (brightest), 1 = medium, 2 = low (dimmest); dualsensectl
    /// rejects values above 2. Level only - has no effect unless a player
    /// LED pattern is also set (`setPlayerLeds`/`setPlayerLedsPattern`),
    /// and does not affect the RGB lightbar.
    pub fn setLedBrightness(self: *ReportBuilder, brightness: u8) void {
        self.common.valid_flag1 |= Flag1.PLAYER_INDICATOR_CONTROL_ENABLE;
        self.common.valid_flag2 |= FLAG2_LED_BRIGHTNESS_CONTROL_ENABLE;
        self.common.led_brightness = brightness;
    }

    /// Releases LED control back to the console.  Conflicts with any
    /// explicit lightbar/player-LED control at `toReport` time.
    pub fn releaseLeds(self: *ReportBuilder) void {
        self.released_leds = true;
        self.common.valid_flag1 |= Flag1.RELEASE_LEDS;
    }

    // ---- mute LED, power save, haptics extras ------------------------------

    /// Mute-button LED mode; `.off` is the explicit reset value.
    pub fn setMicLight(self: *ReportBuilder, mode: MuteLedMode) void {
        self.common.valid_flag1 |= Flag1.MIC_MUTE_LED_CONTROL_ENABLE;
        self.common.mic_light_mode = @intFromEnum(mode);
    }

    /// Adds power-save control bits (see `PowerSave`) to the power-save/mute
    /// control byte (byte 10); gates them with POWER_SAVE_CONTROL_ENABLE.
    pub fn setPowerSaveFlags(self: *ReportBuilder, bits: u8) void {
        self.common.valid_flag1 |= Flag1.POWER_SAVE_CONTROL_ENABLE;
        self.common.power_save_mute_control |= bits;
    }

    /// Explicit power-save reset: clears every PowerSave bit while keeping
    /// the control-enable flag so the cleared byte is applied.
    pub fn clearPowerSaveFlags(self: *ReportBuilder) void {
        self.common.valid_flag1 |= Flag1.POWER_SAVE_CONTROL_ENABLE;
        self.common.power_save_mute_control = 0;
    }

    /// Scales down classic-rumble strength (bits 0-2) and trigger vibration
    /// strength (bits 4-6) via the motor power level byte, each level 0..7;
    /// gated by VIBRATION_ATTENUATION_ENABLE.
    pub fn setVibrationAttenuation(self: *ReportBuilder, rumble_attenuation: u8, trigger_attenuation: u8) void {
        self.common.valid_flag1 |= Flag1.VIBRATION_ATTENUATION_ENABLE;
        self.common.motor_power_level = (rumble_attenuation & 0x07) | ((trigger_attenuation & 0x07) << 4);
    }

    /// Enables or disables the controller-side haptic low-pass filter:
    /// sets/clears both the valid_flag1 gate bit and the filter value byte.
    pub fn setHapticLowPassFilter(self: *ReportBuilder, enabled: bool) void {
        const gate = Flag1.HAPTIC_LOW_PASS_FILTER_ENABLE;
        const value: u8 = 0x01; // haptics_flags bit 0 = low-pass enabled
        if (enabled) {
            self.common.valid_flag1 |= gate;
            self.common.haptics_flags |= value;
        } else {
            self.common.valid_flag1 &= ~gate;
            self.common.haptics_flags &= ~value;
        }
    }

    /// Extra haptics configuration bits applied verbatim to haptics_flags.
    pub fn setHapticsFlags(self: *ReportBuilder, bits: u8) void {
        self.common.haptics_flags |= bits;
    }

    pub fn clearHapticsFlags(self: *ReportBuilder) void {
        self.common.haptics_flags = 0;
    }

    /// Gates vibration attenuation (strength is carried by audio_control2).
    pub fn setVibrationAttenuationEnabled(self: *ReportBuilder, enabled: bool) void {
        if (enabled) {
            self.common.valid_flag1 |= Flag1.VIBRATION_ATTENUATION_ENABLE;
        } else {
            self.common.valid_flag1 &= ~Flag1.VIBRATION_ATTENUATION_ENABLE;
        }
    }

    pub fn setHostTimestamp(self: *ReportBuilder, timestamp_ms: u32) void {
        std.mem.writeInt(u32, &self.common.host_timestamp, timestamp_ms, .little);
    }

    // ---- output ------------------------------------------------------------

    /// Builds the final USB report, validating that no mutually exclusive
    /// feature sets were ever requested.
    pub fn toReport(self: *const ReportBuilder) ReportBuildError!UsbOutputReport {
        if (self.wants_rumble and self.wants_audio_haptics) return error.ConflictingRumbleMode;
        const led_control = Flag1.LIGHTBAR_CONTROL_ENABLE | Flag1.PLAYER_INDICATOR_CONTROL_ENABLE;
        if (self.released_leds and (self.common.valid_flag1 & led_control) != 0) {
            return error.ConflictingOptions;
        }
        return .{ .common = self.common };
    }

    /// Safe fallback report: everything idle except a trigger-effect reset on
    /// both actuators (so held effects are released even without other flags).
    pub fn offReport() UsbOutputReport {
        var b: ReportBuilder = .{};
        b.releaseTriggers();
        return b.toReport() catch unreachable;
    }
};

/// Normalized volume (0..1) scaled to a device-specific maximum byte.
fn scaleToMax(norm: f32, max: u8) u8 {
    return @intFromFloat(@round(clamp01(norm) * @as(f32, max)));
}

// ---------------------------------------------------------------------------
// Input decoding
// ---------------------------------------------------------------------------

pub const InputState = struct {
    left_stick: struct { x: u8, y: u8 },
    right_stick: struct { x: u8, y: u8 },
    left_trigger: u8,
    right_trigger: u8,
    square: bool,
    cross: bool,
    circle: bool,
    triangle: bool,
    l1: bool,
    r1: bool,
    l2: bool,
    r2: bool,
    create: bool,
    options: bool,
    l3: bool,
    r3: bool,
    ps: bool,
    touchpad: bool,
    mic_mute: bool,
    fn1: bool,
    fn2: bool,
    left_paddle: bool,
    right_paddle: bool,
    hat: proto.Hat,
    gyro: [3]f32, // degrees per second
    accel: [3]f32, // g
    sensor_timestamp: u32,
    touch: [2]struct { active: bool, id: u8, x: u12, y: u12 },
    battery_capacity: u8, // 0..100
    battery_status: proto.BatteryStatus,
    headphone: bool,
    microphone: bool,
    mic_mute_led: bool,
};

/// Decode the common 63-byte input payload into a high-level state.
pub fn decodeInput(report: *const proto.InputReportCommon) InputState {
    const b0 = report.buttons0;
    const b1 = report.buttons1;
    const b2 = report.buttons2;
    const hat = b0 & proto.Buttons0.HAT_SWITCH;
    const cap = report.status0 & proto.Status0.BATTERY_CAPACITY;
    const charging = (report.status0 & proto.Status0.CHARGING) >> proto.Status0.CHARGING_SHIFT;
    const touch0: proto.TouchPoint = .{
        .contact = report.touch0_contact,
        .x_lo = report.touch0_x_lo,
        .nibble = report.touch0_nibble,
        .y_hi = report.touch0_y_hi,
    };
    const touch1: proto.TouchPoint = .{
        .contact = report.touch1_contact,
        .x_lo = report.touch1_x_lo,
        .nibble = report.touch1_nibble,
        .y_hi = report.touch1_y_hi,
    };
    const gyro_x = std.mem.readInt(i16, &.{ report.gyro_x_lo, report.gyro_x_hi }, .little);
    const gyro_y = std.mem.readInt(i16, &.{ report.gyro_y_lo, report.gyro_y_hi }, .little);
    const gyro_z = std.mem.readInt(i16, &.{ report.gyro_z_lo, report.gyro_z_hi }, .little);
    const accel_x = std.mem.readInt(i16, &.{ report.accel_x_lo, report.accel_x_hi }, .little);
    const accel_y = std.mem.readInt(i16, &.{ report.accel_y_lo, report.accel_y_hi }, .little);
    const accel_z = std.mem.readInt(i16, &.{ report.accel_z_lo, report.accel_z_hi }, .little);
    const sensor_timestamp = std.mem.readInt(u32, &.{
        report.sensor_timestamp_0,
        report.sensor_timestamp_1,
        report.sensor_timestamp_2,
        report.sensor_timestamp_3,
    }, .little);
    return .{
        .left_stick = .{ .x = report.left_stick_x, .y = report.left_stick_y },
        .right_stick = .{ .x = report.right_stick_x, .y = report.right_stick_y },
        .left_trigger = report.left_trigger,
        .right_trigger = report.right_trigger,
        .square = b0 & proto.Buttons0.SQUARE != 0,
        .cross = b0 & proto.Buttons0.CROSS != 0,
        .circle = b0 & proto.Buttons0.CIRCLE != 0,
        .triangle = b0 & proto.Buttons0.TRIANGLE != 0,
        .l1 = b1 & proto.Buttons1.L1 != 0,
        .r1 = b1 & proto.Buttons1.R1 != 0,
        .l2 = b1 & proto.Buttons1.L2 != 0,
        .r2 = b1 & proto.Buttons1.R2 != 0,
        .create = b1 & proto.Buttons1.CREATE != 0,
        .options = b1 & proto.Buttons1.OPTIONS != 0,
        .l3 = b1 & proto.Buttons1.L3 != 0,
        .r3 = b1 & proto.Buttons1.R3 != 0,
        .ps = b2 & proto.Buttons2.PS_HOME != 0,
        .touchpad = b2 & proto.Buttons2.TOUCHPAD != 0,
        .mic_mute = b2 & proto.Buttons2.MIC_MUTE != 0,
        .fn1 = b2 & proto.EdgeButtons.FN1 != 0,
        .fn2 = b2 & proto.EdgeButtons.FN2 != 0,
        .left_paddle = b2 & proto.EdgeButtons.LEFT_PADDLE != 0,
        .right_paddle = b2 & proto.EdgeButtons.RIGHT_PADDLE != 0,
        .hat = proto.hat_switch[hat],
        .gyro = .{
            @as(f32, @floatFromInt(gyro_x)) / @as(f32, proto.GYRO_RES_PER_DEG_S),
            @as(f32, @floatFromInt(gyro_y)) / @as(f32, proto.GYRO_RES_PER_DEG_S),
            @as(f32, @floatFromInt(gyro_z)) / @as(f32, proto.GYRO_RES_PER_DEG_S),
        },
        .accel = .{
            @as(f32, @floatFromInt(accel_x)) / @as(f32, proto.ACC_RES_PER_G),
            @as(f32, @floatFromInt(accel_y)) / @as(f32, proto.ACC_RES_PER_G),
            @as(f32, @floatFromInt(accel_z)) / @as(f32, proto.ACC_RES_PER_G),
        },
        .sensor_timestamp = sensor_timestamp,
        .touch = .{
            .{
                .active = touch0.active(),
                .id = touch0.id(),
                .x = touch0.x(),
                .y = touch0.y(),
            },
            .{
                .active = touch1.active(),
                .id = touch1.id(),
                .x = touch1.x(),
                .y = touch1.y(),
            },
        },
        .battery_capacity = switch (charging) {
            // Kernel mapping: 0 discharging / 1 charging -> data*10+5 %;
            // 0x2 full -> 100%; anything else (not-charging, failure) -> 0%.
            0x0, 0x1 => @min(cap * 10 + 5, 100),
            0x2 => 100,
            else => 0,
        },
        .battery_status = @enumFromInt(charging),
        .headphone = report.status1 & proto.Status1.HP_DETECT != 0,
        .microphone = report.status1 & proto.Status1.MIC_DETECT != 0,
        .mic_mute_led = report.status1 & proto.Status1.MIC_MUTE != 0,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "normalized helpers" {
    try std.testing.expectEqual(@as(u8, 0), forceFromNorm(-1));
    try std.testing.expectEqual(@as(u8, 0), forceFromNorm(std.math.nan(f32)));
    try std.testing.expectEqual(@as(u8, 255), forceFromNorm(1.0));
    try std.testing.expectEqual(@as(u8, 128), forceFromNorm(0.5));

    try std.testing.expectEqual(@as(u8, 0), levelFromNorm(0));
    try std.testing.expectEqual(@as(u8, 4), levelFromNorm(0.5));
    try std.testing.expectEqual(@as(u8, 8), levelFromNorm(2));

    try std.testing.expectEqual(@as(u8, 100), scaleToMax(1.0, Audio.SPEAKER_VOLUME_MAX));
}

test "zone map helpers" {
    const r = risingZones(8);
    try std.testing.expectEqual(@as(u8, 0), r[0]);
    try std.testing.expectEqual(@as(u8, 8), r[9]);
    for (r, 0..) |v, i| {
        if (i > 0) try std.testing.expect(v >= r[i - 1]);
    }
    const off = risingZones(0);
    for (off) |v| try std.testing.expectEqual(@as(u8, 0), v);

    const band = zoneBand(5, 6);
    try std.testing.expectEqual(@as(u8, 0), band[4]);
    try std.testing.expectEqual(@as(u8, 6), band[5]);
    try std.testing.expectEqual(@as(u8, 6), band[9]);

    const empty = zoneBand(255, 6);
    for (empty) |v| try std.testing.expectEqual(@as(u8, 0), v);

    const range = zoneRange(2, 4, 7);
    try std.testing.expectEqual(@as(u8, 0), range[1]);
    try std.testing.expectEqual(@as(u8, 7), range[2]);
    try std.testing.expectEqual(@as(u8, 7), range[4]);
    try std.testing.expectEqual(@as(u8, 0), range[5]);

    try std.testing.expectEqual(@as(u8, 8), zoneAmp(255));
    try std.testing.expectEqual(@as(u8, 1), zoneAmp(1));

    try std.testing.expectEqual(@as(u8, 0), zoneFromNorm(0));
    try std.testing.expectEqual(@as(u8, 9), zoneFromNorm(1));
    try std.testing.expectEqual(@as(u8, 5), zoneFromNorm(0.55));
    try std.testing.expectEqual(@as(u8, 0), zoneFromNorm(-3));
}

test "trigger effect encodings" {
    const off = TriggerEffect.off();
    try std.testing.expectEqual(@intFromEnum(EffectMode.reset), off.data[0]);

    const rigid = TriggerEffect.rigid(180);
    try std.testing.expectEqual(@intFromEnum(EffectMode.rigid), rigid.data[0]);
    try std.testing.expectEqual(0, rigid.data[1]);
    try std.testing.expectEqual(180, rigid.data[2]);

    const rigid_norm = TriggerEffect.rigidNorm(0.5);
    try std.testing.expectEqual(@intFromEnum(EffectMode.rigid), rigid_norm.data[0]);
    try std.testing.expectEqual(@as(u8, 128), rigid_norm.data[2]);

    const vibrate = TriggerEffect.vibrate(20, 130);
    try std.testing.expectEqual(@intFromEnum(EffectMode.vibrate), vibrate.data[0]);
    try std.testing.expectEqual(20, vibrate.data[1]);
    try std.testing.expectEqual(130, vibrate.data[2]);

    // top 2 zones maxed -> active = 0x0300
    const zones = TriggerEffect.rigidZones(.{ 0, 0, 0, 0, 0, 0, 0, 0, 8, 8 });
    try std.testing.expectEqual(@intFromEnum(EffectMode.rigid_zones), zones.data[0]);
    try std.testing.expectEqual(0x00, zones.data[1]); // active mask low byte
    try std.testing.expectEqual(0x03, zones.data[2]); // active mask high byte
    try std.testing.expectEqual(0x00, zones.data[3]); // packed bits 0-7 (zones 0-2)
    try std.testing.expectEqual(0x00, zones.data[4]); // packed bits 8-15 (zones 3-5)
    try std.testing.expectEqual(0x00, zones.data[5]); // packed bits 16-23 (zones 6-7)
    try std.testing.expectEqual(0x3F, zones.data[6]); // packed bits 24-29 (zones 8-9)

    // all zones maxed -> 30-bit packed field all ones, freq at byte 9
    const all = TriggerEffect.vibrateZones(.{ 8, 8, 8, 8, 8, 8, 8, 8, 8, 8 }, 20);
    try std.testing.expectEqual(@intFromEnum(EffectMode.vibrate_zones), all.data[0]);
    try std.testing.expectEqual(0xFF, all.data[1]);
    try std.testing.expectEqual(0x03, all.data[2]);
    try std.testing.expectEqual(0xFF, all.data[3]);
    try std.testing.expectEqual(0xFF, all.data[4]);
    try std.testing.expectEqual(0xFF, all.data[5]);
    try std.testing.expectEqual(0x3F, all.data[6]);
    try std.testing.expectEqual(20, all.data[9]);

    const clamped = TriggerEffect.rigidZones(.{ 9, 9, 9, 9, 9, 9, 9, 9, 9, 9 });
    try std.testing.expectEqual(0x3F, clamped.data[6]);

    const section = TriggerEffect.section(0x90, 0xA0, 200);
    try std.testing.expectEqual(@intFromEnum(EffectMode.section), section.data[0]);
    try std.testing.expectEqual(@as(u8, 0x90), section.data[1]);
    try std.testing.expectEqual(@as(u8, 0xA0), section.data[2]);
    try std.testing.expectEqual(@as(u8, 200), section.data[3]);

    const weapon = TriggerEffect.weapon(2, 8, 8);
    try std.testing.expectEqual(@intFromEnum(EffectMode.weapon), weapon.data[0]);
    try std.testing.expectEqual(0x04, weapon.data[1]); // bit 2
    try std.testing.expectEqual(0x01, weapon.data[2]); // bit 8
    try std.testing.expectEqual(7, weapon.data[3]); // strength - 1

    const bow = TriggerEffect.bow(1, 8, 8, 1);
    try std.testing.expectEqual(@intFromEnum(EffectMode.bow), bow.data[0]);

    const gallop = TriggerEffect.galloping(0, 9, 0, 7, 3);
    try std.testing.expectEqual(@intFromEnum(EffectMode.galloping), gallop.data[0]);
    try std.testing.expectEqual(3, gallop.data[4]);

    const machine = TriggerEffect.machine(1, 9, 7, 7, 5, 10);
    try std.testing.expectEqual(@intFromEnum(EffectMode.machine), machine.data[0]);
    try std.testing.expectEqual(5, machine.data[4]);
    try std.testing.expectEqual(10, machine.data[5]);
}

test "normalized trigger effect constructors match raw encodings" {
    const vib_n = TriggerEffect.vibrateNorm(0.5, 1.0);
    try std.testing.expectEqual((TriggerEffect.vibrate(128, 255)).data, vib_n.data);

    // feedback at full pull depth and strength == rigidZones over all zones at 8
    const fb = TriggerEffect.feedbackNorm(1.0, 1.0);
    try std.testing.expectEqual((TriggerEffect.rigidZones(zoneBand(9, 8))).data, fb.data);

    // zero strength feedback releases the actuator
    try std.testing.expectEqual((TriggerEffect.off()).data, (TriggerEffect.feedbackNorm(0.5, 0)).data);

    const wp = TriggerEffect.weaponNorm(0.2, 0.8, 1.0);
    try std.testing.expectEqual((TriggerEffect.weapon(2, 7, 8)).data, wp.data);

    const bw = TriggerEffect.bowNorm(0.0, 1.0, 0.5, 0.25);
    try std.testing.expectEqual((TriggerEffect.bow(0, 9, 4, 2)).data, bw.data);

    const gl = TriggerEffect.gallopingNorm(0.0, 1.0, 0.5, 1.0, 0.5);
    try std.testing.expectEqual((TriggerEffect.galloping(0, 9, 3, 7, 4)).data, gl.data);

    const ma = TriggerEffect.machineNorm(0.0, 1.0, 1.0, 0.0, 0.5, 0.5);
    try std.testing.expectEqual((TriggerEffect.machine(0, 9, 7, 0, 128, 128)).data, ma.data);
}

test "report builder composes per-feature flags" {
    var b: ReportBuilder = .{};
    b.setLightbarColor(255, 0, 64);
    b.setPlayerLedsPattern(3);
    b.setLedBrightness(200);
    b.setMicLight(.pulse);
    b.setPowerSaveFlags(PowerSave.MOTION | PowerSave.HAPTICS);
    b.setHapticLowPassFilter(true);
    b.setHapticsFlags(0x01);
    b.setLeftTriggerEffect(TriggerEffect.rigid(120));
    b.setRightTriggerEffect(TriggerEffect.off());

    try std.testing.expect(!b.wants_rumble and !b.wants_audio_haptics);
    const report = try b.toReport();
    const c = &report.common;

    try std.testing.expectEqual(Flag0.RIGHT_TRIGGER | Flag0.LEFT_TRIGGER, c.valid_flag0);
    try std.testing.expectEqual(
        Flag1.MIC_MUTE_LED_CONTROL_ENABLE | Flag1.POWER_SAVE_CONTROL_ENABLE |
            Flag1.LIGHTBAR_CONTROL_ENABLE | Flag1.PLAYER_INDICATOR_CONTROL_ENABLE |
            Flag1.HAPTIC_LOW_PASS_FILTER_ENABLE,
        c.valid_flag1,
    );
    try std.testing.expectEqual(
        FLAG2_LED_BRIGHTNESS_CONTROL_ENABLE,
        c.valid_flag2,
    );
    try std.testing.expectEqual(@as(u8, 255), c.led_red);
    try std.testing.expectEqual(@as(u8, 64), c.led_blue);
    try std.testing.expectEqual(PLAYER_LED_PATTERNS[3], c.player_leds);
    try std.testing.expectEqual(@as(u8, 200), c.led_brightness);
    try std.testing.expectEqual(@intFromEnum(MuteLedMode.pulse), c.mic_light_mode);
    try std.testing.expectEqual(PowerSave.MOTION | PowerSave.HAPTICS, c.power_save_mute_control);
    try std.testing.expectEqual(@as(u8, 0x01), c.haptics_flags);
    try std.testing.expectEqual(@intFromEnum(EffectMode.rigid), c.left_trigger_effect[0]);
    try std.testing.expectEqual(@intFromEnum(EffectMode.reset), c.right_trigger_effect[0]);
}

test "report builder normalized setters" {
    var b: ReportBuilder = .{};
    b.setMotorsNorm(0.5, 1.0);
    b.setLightbarColorNorm(1.0, 0.0, 0.5);
    b.setSpeakerVolumeNorm(1.0);
    b.setMicrophoneVolumeNorm(0.0);
    b.setHeadphoneVolumeNorm(1.0);

    const report = try b.toReport();
    try std.testing.expectEqual(@as(u8, 128), report.common.motor_left);
    try std.testing.expectEqual(@as(u8, 255), report.common.motor_right);
    try std.testing.expectEqual(Flag0.RUMBLE | Flag0.HEADPHONE_VOLUME | Flag0.SPEAKER_VOLUME | Flag0.MIC_VOLUME, report.common.valid_flag0);
    try std.testing.expectEqual(@as(u8, 255), report.common.led_red);
    try std.testing.expectEqual(@as(u8, 128), report.common.led_blue);
    try std.testing.expectEqual(Audio.SPEAKER_VOLUME_MAX, report.common.speaker_volume);
    try std.testing.expectEqual(@as(u8, 0), report.common.microphone_volume);
    try std.testing.expectEqual(Audio.HEADPHONE_VOLUME_MAX, report.common.headphone_volume);
}

test "voice coil preset matches manual audio wiring" {
    var preset: ReportBuilder = .{};
    preset.useVoiceCoilHaptics();
    preset.boostInternalSpeaker();

    var manual: ReportBuilder = .{};
    manual.useVoiceCoilHaptics();
    manual.setAudioRouting(Audio.PATH_SEL_INTERNAL_SPEAKER);
    manual.setSpeakerVolume(Audio.SPEAKER_VOLUME_MAX);
    manual.setAudioControl2(Audio.SP_PREAMP_GAIN_6DB);

    const a = try preset.toReport();
    const m = try manual.toReport();
    try std.testing.expectEqual(m.common.valid_flag0, a.common.valid_flag0);
    try std.testing.expectEqual(m.common.valid_flag1, a.common.valid_flag1);
    try std.testing.expectEqual(m.common.valid_flag2, a.common.valid_flag2);
    try std.testing.expectEqual(m.common.audio_enable_bits, a.common.audio_enable_bits);
    try std.testing.expectEqual(m.common.speaker_volume, a.common.speaker_volume);
    try std.testing.expectEqual(m.common.audio_control2, a.common.audio_control2);
    // Only the sink-apply bits the preset actually configured; no trigger
    // or volume apply bits get blasted in "for haptics".
    try std.testing.expectEqual(Flag0.APPLY_AUDIO_CONTROL | Flag0.SPEAKER_VOLUME, a.common.valid_flag0);

    // Voice-coil mode still conflicts with rumble emulation at build time.
    preset.setMotors(10, 20);
    try std.testing.expectError(error.ConflictingRumbleMode, preset.toReport());
}

test "report builder audio path and rumble conflict" {
    var b: ReportBuilder = .{};
    b.useVoiceCoilHaptics();
    b.boostInternalSpeaker();
    b.setHeadphoneVolume(10);
    b.setMicrophoneVolume(20);
    b.setAudioMuteBits(0);

    const report = try b.toReport();
    try std.testing.expectEqual(
        Flag0.APPLY_AUDIO_CONTROL | Flag0.SPEAKER_VOLUME |
            Flag0.HEADPHONE_VOLUME | Flag0.MIC_VOLUME,
        report.common.valid_flag0,
    );
    try std.testing.expectEqual(
        Flag1.AUDIO_CONTROL2_ENABLE | Flag1.POWER_SAVE_CONTROL_ENABLE,
        report.common.valid_flag1,
    );
    try std.testing.expectEqual(@as(u8, 0), report.common.valid_flag2); // no rumble-v2

    // Rumbling on top of the PCM-haptics mode is rejected at build time.
    b.setMotors(10, 20);
    try std.testing.expectError(error.ConflictingRumbleMode, b.toReport());

    // ...and vice versa from a fresh builder.
    var rb: ReportBuilder = .{};
    rb.setMotors(1, 2);
    rb.useVoiceCoilHaptics();
    try std.testing.expectError(error.ConflictingRumbleMode, rb.toReport());
}

test "report builder rumble sets only rumble bits" {
    var b: ReportBuilder = .{};
    b.setMotors(100, 50);
    const report = try b.toReport();
    try std.testing.expectEqual(Flag0.RUMBLE, report.common.valid_flag0);
    try std.testing.expectEqual(FLAG2_RUMBLE_V2, report.common.valid_flag2);
    try std.testing.expectEqual(@as(u8, 0), report.common.valid_flag1);
    try std.testing.expectEqual(@as(u8, 100), report.common.motor_left);
    try std.testing.expectEqual(@as(u8, 50), report.common.motor_right);
}

test "report builder release-leds conflicts with explicit led control" {
    var b: ReportBuilder = .{};
    b.releaseLeds();
    _ = try b.toReport();
    b.setLightbarColor(1, 2, 3);
    try std.testing.expectError(error.ConflictingOptions, b.toReport());

    var pb: ReportBuilder = .{};
    pb.setPlayerLeds(0x04);
    pb.releaseLeds();
    try std.testing.expectError(error.ConflictingOptions, pb.toReport());
}

test "report builder explicit off/reset methods" {
    var b: ReportBuilder = .{};
    b.setPowerSaveFlags(PowerSave.TOUCH | PowerSave.AUDIO);
    b.clearPowerSaveFlags();
    b.setHapticLowPassFilter(true);
    b.setHapticLowPassFilter(false);
    b.setVibrationAttenuationEnabled(false);
    b.setHostTimestamp(0x12345678);
    b.setMicLight(.off);

    b.releaseTriggers();
    const report = try b.toReport();
    try std.testing.expectEqual(@as(u8, 0), report.common.power_save_mute_control);
    try std.testing.expectEqual(
        Flag1.POWER_SAVE_CONTROL_ENABLE | Flag1.MIC_MUTE_LED_CONTROL_ENABLE,
        report.common.valid_flag1,
    );
    try std.testing.expectEqual(@as(u32, 0x12345678), std.mem.readInt(u32, &report.common.host_timestamp, .little));
    try std.testing.expectEqual(@intFromEnum(MuteLedMode.off), report.common.mic_light_mode);
    try std.testing.expectEqual(@intFromEnum(EffectMode.reset), report.common.left_trigger_effect[0]);
    try std.testing.expectEqual(@intFromEnum(EffectMode.reset), report.common.right_trigger_effect[0]);
}

test "input state decoding" {
    var common: proto.InputReportCommon = std.mem.zeroes(proto.InputReportCommon);
    common.left_stick_x = 128;
    common.left_trigger = 64;
    common.buttons0 = proto.Buttons0.CIRCLE | 2; // hat = 2 (east)
    common.buttons1 = proto.Buttons1.L1 | proto.Buttons1.OPTIONS;
    common.buttons2 = proto.Buttons2.PS_HOME | proto.EdgeButtons.LEFT_PADDLE;
    common.gyro_x_lo = 0x00;
    common.gyro_x_hi = 0x04; // 1024 little-endian
    common.accel_x_lo = 0x00;
    common.accel_x_hi = 0x20; // 8192 little-endian
    common.sensor_timestamp_0 = 0x78;
    common.sensor_timestamp_1 = 0x56;
    common.sensor_timestamp_2 = 0x34;
    common.sensor_timestamp_3 = 0x12;
    common.status0 = 5 | (@as(u8, 1) << 4); // 50% + charging
    common.status1 = proto.Status1.HP_DETECT | proto.Status1.MIC_MUTE;

    const state = decodeInput(&common);
    try std.testing.expectEqual(@as(u8, 128), state.left_stick.x);
    try std.testing.expectEqual(@as(u8, 64), state.left_trigger);
    try std.testing.expect(state.circle);
    try std.testing.expect(state.l1);
    try std.testing.expect(state.options);
    try std.testing.expect(state.ps);
    try std.testing.expect(state.left_paddle);
    try std.testing.expectEqual(@as(i2, 1), state.hat.x);
    try std.testing.expectEqual(@as(i2, 0), state.hat.y);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), state.gyro[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), state.accel[0], 0.001);
    try std.testing.expectEqual(@as(u32, 0x12345678), state.sensor_timestamp);
    try std.testing.expectEqual(@as(u8, 55), state.battery_capacity); // 5*10+5
    try std.testing.expectEqual(proto.BatteryStatus.charging, state.battery_status);
    try std.testing.expect(state.headphone);
    try std.testing.expect(state.mic_mute_led);
}
