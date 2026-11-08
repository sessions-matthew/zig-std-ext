# stdx — Zig Standard Library Extensions

`stdx` is an independent, modular library designed to extend the Zig standard library (`std`) while following its exact architectural patterns, conventions, and idioms.

---

## 1. Project Architecture

The repository is structured to mirror the layout of Zig's official standard library:

```text
~/Projects/zig-std-ext/
├── build.zig               # Exposes 'stdx' and sub-modules ('net')
├── build.zig.zon           # Package manifest with fingerprint
├── README.md
├── examples/
│   └── echo_server.zig     # Example single-threaded echo server
└── src/
    ├── root.zig            # Top-level stdx namespace (re-exports std + extensions)
    └── net/                # Networking extension module
        ├── root.zig        # stdx.net namespace
        └── Server.zig      # Single-threaded multiplexed AsyncServer (poll/kqueue)
```

---

## 2. Using `stdx` in Your Projects

### A. Add Dependency in `build.zig.zon`

For local development across your workstation:

```zig
.{
    .name = .my_app,
    .version = "0.1.0",
    .fingerprint = 0x...,
    .dependencies = .{
        .stdx = .{
            .path = "../zig-std-ext", // or "~/Projects/zig-std-ext"
        },
    },
    .paths = .{""},
}
```

Or from a Git repository:

```bash
zig fetch --save git+https://github.com/your-org/zig-std-ext.git#main
```

### B. Import in `build.zig`

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Resolve stdx dependency
    const stdx_dep = b.dependency("stdx", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // 2. Add as a first-class module import
    exe.root_module.addImport("stdx", stdx_dep.module("stdx"));

    b.installArtifact(exe);
}
```

---

## 3. Usage Example

In your application code (`src/main.zig`):

```zig
const std = @import("std");
const stdx = @import("stdx");

fn handleClient(res: stdx.net.Response, msg: []const u8) void {
    std.debug.print("Received: {s}\n", .{msg});
    res.print("echo: {s}", .{msg}) catch return;
}

pub fn main() !void {
    // 100% single-threaded runtime (0 worker threads spawned)
    var single = std.Io.Threaded.init_single_threaded;
    const io = single.io();

    var server = try stdx.net.AsyncServer.init(io, .{
        .port = 8080,
        .address = "127.0.0.1",
    });
    defer server.deinit();

    std.debug.print("Server listening on 127.0.0.1:8080\n", .{});
    try server.run(handleClient);
}
```

---

## 4. Development & Testing Commands

```bash
cd ~/Projects/zig-std-ext

# Run unit and integration test suite
zig build test --summary all

# Build and launch sample echo server
zig build run-example
```
