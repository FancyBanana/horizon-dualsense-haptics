// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

/// Defines the executable, test targets, SDL dependency, and run step.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // SDL3 is fetched as a package (castholm/SDL) and statically compiled by
    // it, so the build needs no system SDL dev package and the binary needs no
    // libSDL3.so at runtime. The build script exposes its `include/` directory
    // to the modules that @cImport the SDL3 headers and links the SDL3 static
    // library into the executables.
    const sdl = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "horizon-dualsense-haptics",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        // This is a temporary fix for the .sframe relocation bug
        .use_llvm = true,
        .use_lld = true,
    });
    wireSdl(exe.root_module, sdl);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Each source file with tests gets its own root so Zig executes those tests.
    const haptics_test_mod = b.createModule(.{
        .root_source_file = b.path("src/haptics.zig"),
        .target = target,
        .optimize = optimize,
    });
    wireSdl(haptics_test_mod, sdl);
    const run_haptics_tests = b.addRunArtifact(b.addTest(.{
        .root_module = haptics_test_mod,
    }));

    const run_dualsense_tests = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dualsense.zig"),
            .target = target,
            .optimize = optimize,
        }),
    }));

    const run_parser_tests = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/packet_parser.zig"),
            .target = target,
            .optimize = optimize,
        }),
    }));

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_haptics_tests.step);
    test_step.dependOn(&run_dualsense_tests.step);
    test_step.dependOn(&run_parser_tests.step);

    const device_test_mod = b.createModule(.{
        .root_source_file = b.path("src/device_sdl.zig"),
        .target = target,
        .optimize = optimize,
    });
    wireSdl(device_test_mod, sdl);
    const run_device_tests = b.addRunArtifact(b.addTest(.{
        .root_module = device_test_mod,
    }));
    test_step.dependOn(&run_device_tests.step);
}

/// Gives a module the SDL3 headers, libc linkage, and static SDL3 library.
fn wireSdl(m: *std.Build.Module, sdl: *std.Build.Dependency) void {
    m.link_libc = true;
    m.addIncludePath(sdl.path("include"));
    m.linkLibrary(sdl.artifact("SDL3"));
}
