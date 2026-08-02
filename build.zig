// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
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

    const mod = b.addModule("zig_forza_haptics", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    wireSdl(mod, sdl);

    const exe = b.addExecutable(.{
        .name = "zig_forza_haptics",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_forza_haptics", .module = mod },
            },
        }),
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

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Zig only executes `test` blocks declared in the tested root file, so the
    // unit tests that live in the other src/*.zig files need their own test
    // steps or they would be compiled but never run.
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
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_haptics_tests.step);
    test_step.dependOn(&run_dualsense_tests.step);
    test_step.dependOn(&run_parser_tests.step);
}

/// Gives a module what it needs to `@cImport` and link the statically built
/// SDL3: libc, the SDL3 headers, and the SDL3 library itself.
fn wireSdl(m: *std.Build.Module, sdl: *std.Build.Dependency) void {
    m.link_libc = true;
    m.addIncludePath(sdl.path("include"));
    m.linkLibrary(sdl.artifact("SDL3"));
}
