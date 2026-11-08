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

    // Sub-module alias 'net' so callers can do either:
    // `exe.root_module.addImport("stdx", dep.module("stdx"))` OR
    // `exe.root_module.addImport("net", dep.module("net"))`
    _ = b.addModule("net", .{
        .root_source_file = b.path("src/net/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 2. Unit tests (`zig build test`)
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_test = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run stdx unit tests");
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
