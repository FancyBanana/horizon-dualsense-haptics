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

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    wireSdl(root_mod, sdl);

    const exe = b.addExecutable(.{
        .name = "horizon-dualsense-haptics",
        .root_module = root_mod,
    });
    applySframeWorkaround(exe); // .sframe relocation bug
    b.installArtifact(exe);

    // Compiled but never installed or run: zls invokes this via the `check`
    // step for compile-on-save diagnostics without building the full binary.
    const exe_check = b.addExecutable(.{
        .name = "horizon-dualsense-haptics",
        .root_module = root_mod,
    });
    applySframeWorkaround(exe_check);
    const check_step = b.step("check", "Check the exe compiles");
    check_step.dependOn(&exe_check.step);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Tests are grouped by whether they need SDL, so the SDL3 static library
    // is only linked into the roots that @cImport its headers. haptics.zig
    // transitively imports device.zig -> device_sdl.zig, so a single root
    // exercises both their test blocks.
    const test_step = b.step("test", "Run tests");

    const sdl_test_mod = b.createModule(.{
        .root_source_file = b.path("src/haptics.zig"),
        .target = target,
        .optimize = optimize,
    });
    wireSdl(sdl_test_mod, sdl);
    const sdl_test = b.addTest(.{
        .root_module = sdl_test_mod,
    });
    applySframeWorkaround(sdl_test); // .sframe relocation bug
    const run_sdl_tests = b.addRunArtifact(sdl_test);
    test_step.dependOn(&run_sdl_tests.step);

    const dualsense_test_mod = b.createModule(.{
        .root_source_file = b.path("src/hardware/dualsense.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_dualsense_tests = b.addRunArtifact(b.addTest(.{
        .root_module = dualsense_test_mod,
    }));
    test_step.dependOn(&run_dualsense_tests.step);

    const parser_test_mod = b.createModule(.{
        .root_source_file = b.path("src/fh5_packet_parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_parser_tests = b.addRunArtifact(b.addTest(.{
        .root_module = parser_test_mod,
    }));
    test_step.dependOn(&run_parser_tests.step);
}

/// Gives a module the SDL3 headers, libc linkage, and static SDL3 library.
fn wireSdl(m: *std.Build.Module, sdl: *std.Build.Dependency) void {
    m.link_libc = true;
    m.addIncludePath(sdl.path("include"));
    m.linkLibrary(sdl.artifact("SDL3"));
}

/// Temporary fix for the .sframe relocation bug: force the LLVM + LLD
/// backends, which handle the R_X86_64_PC64 relocations in the system crt1.o
/// that the self-hosted linker rejects.
fn applySframeWorkaround(c: *std.Build.Step.Compile) void {
    c.use_llvm = true;
    c.use_lld = true;
}
