const std = @import("std");
const hw = @import("hyprwire");
const protocol_server = @import("test_protocol_v1-server.zig");
const protocol_spec = @import("test_protocol_v1-spec.zig");

const mem = std.mem;
const posix = std.posix;
const fmt = std.fmt;

var socket: *hw.ServerSocket = undefined;
var manager: *protocol_server.MyManagerV1Object = undefined;
var object: *protocol_server.MyObjectV1Object = undefined;

fn bindFn(obj: *hw.types.Object, gpa: mem.Allocator) void {
    std.debug.print("Object bound XD\n", .{});

    manager = protocol_server.MyManagerV1Object.init(gpa, obj) catch return;

    manager.sendSendMessage(gpa, "Hello object") catch {};
    manager.setSendMessage(sendMessage);
    manager.setSendMessageFd(sendMessageFd);
    manager.setSendMessageArray(sendMessageArray);
    manager.setSendMessageArrayUint(sendMessageArrayUint);
    manager.setMakeObject(sendMakeObject);
    manager.setOnDeinit(onDeinit);
}

fn sendMessage(msg: [*:0]const u8) void {
    std.debug.print("Recvd message: {s}\n", .{msg});
}

fn sendMessageFd(fd: i32) void {
    var buf: [5]u8 = undefined;
    _ = posix.read(fd, &buf) catch {};
    std.debug.print("Recvd fd {} with data: {s}\n", .{ fd, buf });
}

fn sendMessageArray(data: [*:null]?[*:0]const u8) void {
    _ = data;
    // var str: std.ArrayList(u8) = .empty;
    // defer str.deinit(std.heap.c_allocator);

    // var i: usize = 0;
    // while (data[i]) |d| : (i += 1) {
    //     str.print(std.heap.c_allocator, "{s}, ", .{d}) catch unreachable;
    // }
    // if (str.items.len > 1) {
    //     _ = str.pop();
    //     _ = str.pop();
    // }
    // std.debug.print("Got array message: {s}\n", .{str.items});
}

fn sendMessageArrayUint(data: [*:0]u32) void {
    _ = data;
    // var str: std.ArrayList(u8) = .empty;
    // defer str.deinit(std.heap.c_allocator);

    // var i: usize = 0;
    // while (data[i] != 0) : (i += 1) {
    //     str.print(std.heap.c_allocator, "{}, ", .{data[i]}) catch unreachable;
    // }
    // if (str.items.len > 1) {
    //     _ = str.pop();
    //     _ = str.pop();
    // }
    // std.debug.print("Got uint array message: {s}\n", .{str.items});
}

fn onDeinit() void {}

fn sendMakeObject(seq: u32) void {
    const alloc = std.heap.c_allocator;
    const server_object = socket.createObject(
        alloc,
        manager.getObject().vtable.getClient(manager.getObject().ptr),
        @ptrCast(@alignCast(manager.getObject().ptr)),
        "my_object_v1",
        seq,
    ).?;
    const obj = alloc.create(hw.types.Object) catch return;
    obj.* = hw.types.Object.from(server_object);
    object = protocol_server.MyObjectV1Object.init(alloc, obj) catch return;
    object.sendSendMessage(alloc, "Hello object") catch return;
    object.setSendMessage(objectSendMessage);
    object.setSendEnum(struct {
        fn cb(e: protocol_spec.TestProtocolV1MyEnum) void {
            std.debug.print("Object sent enum: {}\n", .{e});

            std.debug.print("Erroring out the client!\n", .{});

            object.err(alloc, @intFromEnum(e), "Important error occurred!") catch return;
        }
    }.cb);
}

fn objectSendMessage(message: [*:0]const u8) void {
    std.debug.print("Object says hello: {s}\n", .{message});
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const alloc = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("LEAK DETECTED");
    }

    const xdg_runtime_dir = posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntimeDir;
    const socket_path_buf = try fmt.allocPrintSentinel(alloc, "{s}/test-hw.sock", .{xdg_runtime_dir}, 0);
    defer alloc.free(socket_path_buf);

    socket = try hw.ServerSocket.open(alloc, socket_path_buf);
    defer socket.deinit(alloc);

    const spec = protocol_server.TestProtocolV1Impl.init(1, bindFn);
    const pro = hw.types.server_impl.ProtocolServerImplementation.from(&spec);
    try socket.addImplementation(alloc, pro);

    while (socket.dispatchEvents(alloc, true) catch false) {}
}
