const std = @import("std");
const hw = @import("hyprwire");

const posix = std.posix;
const fmt = std.fmt;

pub fn spec() void {}

pub fn main() void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const alloc = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("TEST FAIL");
    }

    const xdg_runtime_dir = posix.getenv("XDG_RUNTIME_DIR").?;
    var socket = (try hw.ServerSocket.open(alloc, fmt.allocPrint(alloc, "{s}/test-hw.sock", .{xdg_runtime_dir}))).?;
    defer socket.deinit(alloc);
}
