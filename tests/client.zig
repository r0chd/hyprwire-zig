const std = @import("std");

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
    const socket_path = try fmt.allocPrint(alloc, "{s}/test-hw.sock", .{xdg_runtime_dir});
    defer alloc.free(socket_path);

    std.debug.print("Client would connect to: {s}\n", .{socket_path});
}
