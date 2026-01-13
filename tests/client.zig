const std = @import("std");
const hw = @import("hyprwire");

const posix = std.posix;
const fmt = std.fmt;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const alloc = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("TEST FAIL");
    }

    const xdg_runtime_dir = posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntimeDir;
    const socket_path = try fmt.allocPrintSentinel(alloc, "{s}/test-hw.sock", .{xdg_runtime_dir}, 0);
    defer alloc.free(socket_path);

    const sock = try hw.ClientSocket.open(alloc, .{ .path = socket_path });
    defer sock.deinit(alloc);
}
