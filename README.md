## hyprwire
A fast and consistent wire protocol for IPC

## What is hyprwire

Hyprwire is a fast and consistent wire protocol, and its implementation. This is essentially a
"method" for processes to talk to each other.

### How does hyprwire differ from other things?

Hyprwire is heavily inspired by Wayland, and heavily anti-inspired by D-Bus.

Hyprwire is:
- Strict: both sides need to be on the same page to communicate. No "random data" is allowed.
- Fast: initial handshakes are very simple and allow for quick information exchange (including one-shot operations)
- Simple to use: a strongly typed API with compile-time validation, preventing protocol misuse before code ever runs.
- Simple internally: the protocol itself is simple and straightforward to parse / write your own implementation

## Usage
A `Scanner` interface is provided which you may integrate with your `build.zig`:

```zig
const std = @import("std");
const Build = std.Build;

const Scanner = @import("hyprwire").Scanner;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const hyprwire = b.dependency("hyprwire", .{
        .target = target,
        .optimize = optimize,
    });

    const scanner = Scanner.create(b, hyprwire);
    scanner.addCustomProtocol(b.path("protocol/protocol-v1.xml"));

    // Pass the maximum version implemented by your hyprwire server or client.
    scanner.generate("test_protocol_v1", 1);

    const exe = b.addExecutable(.{
        .name = "foobar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("foobar.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("hyprwire", hyprwire.module("hyprwire"));

    b.installArtifact(exe);
}
```

Then, you may import the provided module in your project:

```zig
const hyprwire = @import("hyprwire");
const test_protocol = hyprwire.proto.test_protocol_v1.client;
```

See `examples` directory for more
