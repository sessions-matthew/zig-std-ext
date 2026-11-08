const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Primary exported module: 'stdx'
    const stdx_mod = b.addModule("stdx", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Sub-module aliases so callers can import specific domains directly:
    const submodules = [_][]const u8{
        "net",
        "concurrency",
        "math2d",
        "apple",
        "fs",
        "process",
        "state",
        "diff",
        "trace",
        "ansi",
    };

    inline for (submodules) |mod_name| {
        _ = b.addModule(mod_name, .{
            .root_source_file = b.path("src/" ++ mod_name ++ "/root.zig"),
            .target = target,
            .optimize = optimize,
        });
    }

    // 2. Unit tests (`zig build test`)
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (target.result.os.tag.isDarwin()) {
        tests.root_module.linkSystemLibrary("objc", .{});
    }
    const run_test = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all stdx unit tests");
    test_step.dependOn(&run_test.step);

    // 3. Example server (`zig build run-example`)
    const example_exe = b.addExecutable(.{
        .name = "echo-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/echo_server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    example_exe.root_module.addImport("stdx", stdx_mod);

    const run_example = b.addRunArtifact(example_exe);
    const run_example_step = b.step("run-example", "Run sample single-threaded echo server");
    run_example_step.dependOn(&run_example.step);
}
