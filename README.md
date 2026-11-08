# stdx — Zig Standard Library Extensions

`stdx` is a modular, high-performance library extending the Zig standard library (`std`) while following its exact architectural patterns, conventions, and idioms.

---

## 1. Module Overview

| Module | Responsibility | Key Features |
| :--- | :--- | :--- |
| **`stdx.net`** | Network Servers & Multiplexing | Single-threaded non-blocking `AsyncServer` (poll/kqueue), decoupled request handlers, zero worker thread overhead. |
| **`stdx.concurrency`** | Main-Thread Friendly Workers | `AsyncTask(Context, Result)`: lock-free single-flight worker runner with $O(1)$ (< 5 ns) atomic polling for 60/120 FPS game/UI loops. |
| **`stdx.math2d`** | 2D Geometry & Transforms | Pure-Zig `Vec2`, `Rect`, `StageCamera` (contain/cover/stretch), touch target hit-expansion ($44\times 44\text{ pt}$ Apple HIG), and cubic/back easing. |
| **`stdx.objc`** | Apple Objective-C & Metal Bridge | Zero-`@cImport` typed ARM64 `objc_msgSend` trampolines, `sel_registerName`, `objc_autoreleasePool`, `NSRect`/`NSPoint`, and Metal device creation. |
| **`stdx.fs`** | Universal Portable File I/O | C-`stdio` fallback filesystem (`fopen`, `fread`, `fwrite`, `fseek`, `ftell`, `access`, `mkdir`) for iOS devices/simulators and freestanding targets. |
| **`stdx.process`** | Non-blocking Pipe Poller | `SubprocessPoller(capacity)`: executes child processes with non-blocking pipes and drains stdout incrementally into fixed buffers without stalling caller threads. |
| **`stdx.state`** | Type-Hashed State Store | `StateStore`: host-owned React-like `useState` with hierarchical scopes, comptime structural type-hashing (`computeTypeHash`), and `InlineString(capacity)`. |

---

## 2. Project Architecture

```text
zig-std-ext/
├── build.zig               # Exposes 'stdx' and sub-modules
├── build.zig.zon           # Package manifest with fingerprint
├── README.md
├── examples/
│   └── echo_server.zig     # Example single-threaded echo server
└── src/
    ├── root.zig            # Master root (re-exports std + stdx namespaces)
    ├── net/                # AsyncServer, Response
    ├── concurrency/        # AsyncTask(Context, Result)
    ├── math2d/             # Vec2, Rect, StageCamera, Easing
    ├── objc/               # Pure-Zig typed Objective-C & Metal trampolines
    ├── fs/                 # C-stdio portable filesystem helpers
    ├── process/            # SubprocessPoller non-blocking pipe reader
    └── state/              # StateStore, useState, InlineString, computeTypeHash
```

---

## 3. Using `stdx` in Your Projects

### A. Add Dependency in `build.zig.zon`

For local development across your workstation:

```zig
.{
    .name = .my_app,
    .version = "0.1.0",
    .fingerprint = 0x...,
    .dependencies = .{
        .stdx = .{
            .path = "../zig-std-ext",
        },
    },
    .paths = .{""},
}
```

Or from Git:

```bash
zig fetch --save git+https://github.com/sessions-matthew/zig-std-ext.git#main
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

## 4. Usage Examples

### A. Non-blocking Background Computation (`stdx.concurrency`)

```zig
const stdx = @import("stdx");

const Worker = struct {
    fn compute(x: u64) u64 {
        return x * x;
    }
};

var task = stdx.concurrency.AsyncTask(u64, u64).init();
defer task.deinit();

_ = task.spawn(42, Worker.compute);

// In your 60/120 FPS game/UI tick loop:
if (task.poll()) |result| {
    // Result available with 0 main-thread stall
    _ = result;
}
```

### B. Single-Threaded Network Server (`stdx.net`)

```zig
const std = @import("std");
const stdx = @import("stdx");

fn handleClient(res: stdx.net.Response, msg: []const u8) void {
    res.print("echo: {s}", .{msg}) catch return;
}

pub fn main() !void {
    var single = std.Io.Threaded.init_single_threaded;
    const io = single.io();

    var server = try stdx.net.AsyncServer.init(io, .{ .port = 8080 });
    defer server.deinit();

    try server.run(handleClient);
}
```

### C. Pure-Zig Apple Objective-C Calls (`stdx.objc`)

```zig
const stdx = @import("stdx");
const objc = stdx.objc;

pub fn getSystemDefaultMetalDevice() objc.id {
    return objc.c.MTLCreateSystemDefaultDevice();
}
```

---

## 5. Development & Testing Commands

```bash
cd ~/Projects/zig-std-ext

# Run unit and integration test suite across all modules
zig build test --summary all

# Build and launch sample echo server
zig build run-example
```

---

## 6. Credits & Attribution

Designed and engineered in collaboration with **Google DeepMind Gemini**.
