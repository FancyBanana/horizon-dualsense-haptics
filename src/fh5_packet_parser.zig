// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const builtin = @import("builtin");

/// Byte-accurate layout of a Forza Horizon 5 telemetry frame.
pub const HorizonFrame = struct {
    // sled
    IsRaceOn: i32 = 0,
    TimestampMS: u32 = 0,
    EngineMaxRpm: f32 = 0,
    EngineIdleRpm: f32 = 0,
    CurrentEngineRpm: f32 = 0,
    AccelerationX: f32 = 0,
    AccelerationY: f32 = 0,
    AccelerationZ: f32 = 0,
    VelocityX: f32 = 0,
    VelocityY: f32 = 0,
    VelocityZ: f32 = 0,
    AngularVelocityX: f32 = 0,
    AngularVelocityY: f32 = 0,
    AngularVelocityZ: f32 = 0,
    Yaw: f32 = 0,
    Pitch: f32 = 0,
    Roll: f32 = 0,
    NormalizedSuspensionTravelFl: f32 = 0,
    NormalizedSuspensionTravelFr: f32 = 0,
    NormalizedSuspensionTravelRl: f32 = 0,
    NormalizedSuspensionTravelRr: f32 = 0,
    TireSlipRatioFl: f32 = 0,
    TireSlipRatioFr: f32 = 0,
    TireSlipRatioRl: f32 = 0,
    TireSlipRatioRr: f32 = 0,
    WheelRotationSpeedFl: f32 = 0,
    WheelRotationSpeedFr: f32 = 0,
    WheelRotationSpeedRl: f32 = 0,
    WheelRotationSpeedRr: f32 = 0,
    WheelOnRumbleStripFl: i32 = 0,
    WheelOnRumbleStripFr: i32 = 0,
    WheelOnRumbleStripRl: i32 = 0,
    WheelOnRumbleStripRr: i32 = 0,
    WheelInPuddleDepthFl: f32 = 0,
    WheelInPuddleDepthFr: f32 = 0,
    WheelInPuddleDepthRl: f32 = 0,
    WheelInPuddleDepthRr: f32 = 0,
    SurfaceRumbleFl: f32 = 0,
    SurfaceRumbleFr: f32 = 0,
    SurfaceRumbleRl: f32 = 0,
    SurfaceRumbleRr: f32 = 0,
    TireSlipAngleFl: f32 = 0,
    TireSlipAngleFr: f32 = 0,
    TireSlipAngleRl: f32 = 0,
    TireSlipAngleRr: f32 = 0,
    TireCombinedSlipFl: f32 = 0,
    TireCombinedSlipFr: f32 = 0,
    TireCombinedSlipRl: f32 = 0,
    TireCombinedSlipRr: f32 = 0,
    SuspensionTravelMetersFl: f32 = 0,
    SuspensionTravelMetersFr: f32 = 0,
    SuspensionTravelMetersRl: f32 = 0,
    SuspensionTravelMetersRr: f32 = 0,
    CarOrdinal: i32 = 0,
    CarClass: i32 = 0,
    CarPerformanceIndex: i32 = 0,
    DrivetrainType: i32 = 0,
    NumCylinders: i32 = 0,
    // Horizon extra fields between the sled and dash sections
    CarCategory: i32 = 0,
    HorizonUnknown1: u32 = 0,
    HorizonUnknown2: u32 = 0,
    // dash
    PositionX: f32 = 0,
    PositionY: f32 = 0,
    PositionZ: f32 = 0,
    Speed: f32 = 0,
    Power: f32 = 0,
    Torque: f32 = 0,
    TireTempFl: f32 = 0,
    TireTempFr: f32 = 0,
    TireTempRl: f32 = 0,
    TireTempRr: f32 = 0,
    Boost: f32 = 0,
    Fuel: f32 = 0,
    DistanceTraveled: f32 = 0,
    BestLap: f32 = 0,
    LastLap: f32 = 0,
    CurrentLap: f32 = 0,
    CurrentRaceTime: f32 = 0,
    LapNumber: u16 = 0,
    RacePosition: u8 = 0,
    Accel: u8 = 0,
    Brake: u8 = 0,
    Clutch: u8 = 0,
    HandBrake: u8 = 0,
    Gear: u8 = 0,
    Steer: i8 = 0,
    NormalizedDrivingLine: i8 = 0,
    NormalizedAIBrakeDifference: i8 = 0,
    HorizonTrailingUnknown: u8 = 0,
};

/// Byte length of a Forza Horizon telemetry packet.
pub const PACKET_SIZE = 324;

comptime {
    if (@sizeOf(HorizonFrame) != PACKET_SIZE) {
        @compileError("HorizonFrame must be exactly 324 bytes");
    }
}

/// Parses a fixed-size little-endian Horizon packet. The packed struct
/// (checked above) is a plain byte image of the packet.
pub fn parseHorizonPacket(data: [324]u8) HorizonFrame {
    var frame: HorizonFrame = undefined;
    @memcpy(std.mem.asBytes(&frame), &data);

    if (builtin.cpu.arch.endian() == .big) {
        inline for (@typeInfo(HorizonFrame).@"struct".fields) |field| {
            @field(frame, field.name) = std.mem.littleToNative(field.type, @field(frame, field.name));
        }
    }

    return frame;
}

test "parses little-endian telemetry fields" {
    var bytes = [_]u8{0} ** PACKET_SIZE;
    bytes[0..4].* = .{ 1, 0, 0, 0 };
    bytes[4..8].* = .{ 0x78, 0x56, 0x34, 0x12 };

    const frame = parseHorizonPacket(bytes);
    try std.testing.expectEqual(@as(i32, 1), frame.IsRaceOn);
    try std.testing.expectEqual(@as(u32, 0x12345678), frame.TimestampMS);
}
