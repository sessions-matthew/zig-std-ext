# stdx — Zig Standard Library Extensions

`stdx` is a modular, high-performance library extending the Zig standard library (`std`) while following its exact architectural patterns, conventions, and idioms.

---

## 1. Module Overview

| Module | Responsibility | Key Features |
| :--- | :--- | :--- |
| **`stdx.net`** | Network Servers & Multiplexing | Single-threaded non-blocking `AsyncServer` (poll/kqueue), decoupled request handlers, zero worker thread overhead. |
| **`stdx.concurrency`** | Main-Thread Friendly Workers | `AsyncTask(Context, Result)`: lock-free single-flight worker runner with $O(1)$ (< 5 ns) atomic polling for 60/120 FPS game/UI loops. |
| **`stdx.math2d`** | 2D Geometry & Transforms | Pure-Zig `Vec2`, `Rect`, `StageCamera` (contain/cover/stretch), touch target hit-expansion ($44\times 44\text{ pt}$ Apple HIG), and cubic/back easing. |
| **`stdx.diff`** | Unified Diffs & Split Pairing | Zero-allocation unified diff & patch parser (`parseUnifiedDiff`), hunk tracking, addition/deletion metrics, and side-by-side split view row builder. |
| **`stdx.trace`** | Latency Percentiles & Perfetto | Zero-allocation latency statistics (`compute`: P50, P90, P95, P99, mean, stddev), circular `RollingBuffer`, and standard Chrome / Perfetto Catapult JSON trace exporter. |
| **`stdx.ansi`** | ANSI / VT100 Terminal Parsing | Zero-allocation ANSI escape sequence parser (`Iterator`), sequence stripper (`strip`), terminal display column calculator (`visibleWidth`), and 16/256/24-bit TrueColor SGR formatter (`Style`). |
| **`stdx.crc`** | Hardware & Protocol Checksums | Fast bitwise and table-driven CRC engines: `crc16CcittFalse` (0x1021 / 0xFFFF), `crc16Xmodem`, `crc32` (IEEE 802.3), and `crc8`. |
| **`stdx.framing`** | Streaming Packet Wire Framing | Zero-allocation streaming frame parser (`StreamParser`) with repeated SOF preamble sync, line-noise recovery, and packet serialization (`serializePacket`). |
| **`stdx.rpc`** | Comptime Microcontroller / IPC RPC | Zero-allocation compile-time RPC generator. Reflects over API struct declarations via `@typeInfo`, synthesizing typed client stubs (`RpcClient`) and server dispatchers (`RpcDispatcher`). |
| **`stdx.apple`** | Apple OS & Metal Bridge | Zero-`@cImport` typed ARM64 `objc_msgSend` trampolines (`msgSend0/1/2`), `sel_registerName`, `objc_autoreleasePool`, `NSRect`/`NSPoint`, and Metal device creation. Accessible as `stdx.apple` or `stdx.objc`. |
| **`stdx.fs`** | Universal Portable File I/O | C-`stdio` fallback filesystem (`fopen`, `fread`, `fwrite`, `fseek`, `ftell`, `access`, `mkdir`) for iOS devices/simulators and freestanding targets. |
| **`stdx.process`** | Non-blocking Pipe Poller | `SubprocessPoller(capacity)`: executes child processes with non-blocking pipes and drains stdout incrementally into fixed buffers without stalling caller threads. |
| **`stdx.state`** | Type-Hashed State Store | `StateStore`: host-owned React-like `useState` with hierarchical scopes, comptime structural type-hashing (`computeTypeHash`), and `InlineString(capacity)`. |

---

## 2. Project Architecture

```text
zig-std-ext/
├── build.zig               # Exposes 'stdx' and sub-modules
├── build.zig.zon           # Package manifest with fingerprint
├── LICENSE                 # MIT License (2026 Matthew Sessions)
├── README.md
├── examples/
│   └── echo_server.zig     # Example single-threaded echo server
└── src/
    ├── root.zig            # Master root (re-exports std + stdx namespaces)
    ├── net/                # AsyncServer, Response
    ├── concurrency/        # AsyncTask(Context, Result)
    ├── math2d/             # Vec2, Rect, StageCamera, Easing
    ├── diff/               # Unified diff parser & split row builder
    ├── trace/              # P50/P95/P99 latency stats & Chrome trace exporter
    ├── ansi/               # ANSI VT100 parser, stripper, visible width, SGR styles
    ├── crc/                # CRC-16 CCITT/XMODEM, CRC-32, CRC-8
    ├── framing/            # Streaming packet framing, StreamParser, serializer
    ├── rpc/                # Zero-allocation comptime RPC generator (RpcClient, RpcDispatcher)
    ├── apple/              # Pure-Zig typed Objective-C & Metal trampolines
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
    .fingerprint = 0x5479474fa354b5eb,
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

### A. Zero-Allocation Compile-Time RPC (`stdx.rpc` & `stdx.framing`)

Define an API contract as a plain Zig struct with function declarations. Client and Server dispatchers are generated automatically at comptime with 0 heap allocations:

```zig
const stdx = @import("stdx");

// 1. Define API contract
const CalcApi = struct {
    add: fn (a: i32, b: i32) i32,
    divide: fn (a: i32, b: i32) anyerror!i32,
};

// 2. Implement Service
const CalcService = struct {
    pub fn add(self: *CalcService, a: i32, b: i32) i32 {
        _ = self;
        return a + b;
    }
    pub fn divide(self: *CalcService, a: i32, b: i32) !i32 {
        _ = self;
        if (b == 0) return error.DivisionByZero;
        return @divTrunc(a, b);
    }
};

// 3. Connect Client and Server over any transport (serial UART, pipe, DuplexFifo)
var service = CalcService{};
var dispatcher = stdx.rpc.RpcDispatcher(CalcApi, CalcService).init(&service);
var client = stdx.rpc.RpcClient(CalcApi).init(&transport);

const result = try client.call("add", .{ 10, 25 }); // -> 35
```

### B. Streaming Packet Wire Framing (`stdx.framing`)

```zig
const stdx = @import("stdx");

// Stream byte-by-byte with automatic noise recovery and CRC verification:
var parser = stdx.framing.StreamParser.init();

for (incoming_bytes) |byte| {
    if (parser.feed(byte)) |packet| {
        // Complete valid packet received
        const id = packet.msg_id;
        const payload = packet.getPayload();
        _ = id;
        _ = payload;
    }
}
```

### C. Non-blocking Background Computation (`stdx.concurrency`)

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

### D. Parsing Unified Diffs & Hunks (`stdx.diff`)

```zig
const std = @import("std");
const stdx = @import("stdx");

var parsed: stdx.diff.ParsedDiff = undefined;
stdx.diff.parseUnifiedDiff(diff_patch_str, &parsed);

std.debug.print("Hunks: {d}, +{d}/-{d}\n", .{
    parsed.stats.hunks,
    parsed.stats.additions,
    parsed.stats.deletions,
});

for (parsed.split_rows[0..parsed.split_row_count]) |row| {
    if (row.is_header) continue;
    // Render side-by-side left/right diff columns
}
```

### E. Latency Percentiles & Chrome Trace Export (`stdx.trace`)

```zig
const std = @import("std");
const stdx = @import("stdx");

// 1. Calculate P50, P90, P95, P99 latency percentiles
var latencies = [_]u64{ 1200, 1500, 3100, 950, 4200, 1100 };
const stats = stdx.trace.compute(&latencies);
std.debug.print("P50: {d} ns, P95: {d} ns, P99: {d} ns\n", .{ stats.p50, stats.p95, stats.p99 });

// 2. Export Chrome / Perfetto timeline events
var tracer = stdx.trace.TraceCollector.init(allocator);
defer tracer.deinit();

try tracer.record("frame_render", "gfx", start_ns, end_ns);
const json_bytes = try tracer.exportJsonAlloc(allocator);
defer allocator.free(json_bytes);
```

### F. ANSI Escape Stripping & Visible Terminal Width (`stdx.ansi`)

```zig
const stdx = @import("stdx");

const styled = "\x1b[1;32mSUCCESS:\x1b[0m 42 tests passed";
const width = stdx.ansi.visibleWidth(styled); // -> 23 columns

var clean_buf: [128]u8 = undefined;
const plain = stdx.ansi.strip(styled, &clean_buf); // -> "SUCCESS: 42 tests passed"
```

---

## 5. Development & Testing Commands

```bash
cd ~/Projects/zig-std-ext

# Run unit and integration test suite across all modules
zig build test --summary all

# Cross-compile for Linux x86_64 and aarch64
zig build -Dtarget=x86_64-linux
zig build -Dtarget=aarch64-linux

# Build and launch sample echo server
zig build run-example
```

---

## 6. Credits & Attribution

Designed and engineered in collaboration with **Google DeepMind Gemini**.
