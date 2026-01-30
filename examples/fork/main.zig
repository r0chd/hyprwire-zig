// TODO

const std = @import("std");
const posix = std.posix;
const Io = std.Io;
const mem = std.mem;

const hw = @import("hyprwire");
const test_protocol = hw.proto.test_protocol_v1;
const types = hw.types;

fn client(io: Io, gpa: mem.Allocator, fd: i32) !void {
    const sock = try hw.ClientSocket.open(io, gpa, .{ .fd = fd });

    sock.waitForHandshake(io, gpa) catch {
        std.debug.print("err: handshake failed\n", .{});
        return;
    };

    var impl = test_protocol.client.TestProtocolV1Impl.init(1);
    try sock.addImplementation(gpa, types.client.ProtocolImplementation.from(&impl));

    std.debug.print("OK!\n", .{});

    var protocol = impl.protocol();
    const SPEC = sock.getSpec(protocol.vtable.specName(protocol.ptr)) orelse {
        std.debug.print("err: test protocol unsupported\n", .{});
        return;
    };

    std.debug.print("test protocol supported at version {}. Binding.\n", .{SPEC.vtable.specVer(SPEC.ptr)});

    var obj = try sock.bindProtocol(io, gpa, protocol, 1);
    defer obj.deinit(gpa);
    // var manager = try test_protocol.client.MyManagerV1Object.init(
    //     gpa,
    //     test_protocol.client.MyManagerV1Object.Listener.from(&client),
    //     &types.Object.from(obj),
    // );

    // std.debug.print("Bound!\n", .{});

    // const pips = try Io.Threaded.pipe2(.{});
    // var out: Io.File = .{ .handle = pips[1] };
    // var buffer: [5]u8 = undefined;
    // var writer = out.writer(io, &buffer);
    // var iowriter = &writer.interface;
    // try iowriter.writeAll("pipe!");
    // try iowriter.flush();

    // std.debug.print("Will send fd {}\n", .{pips[0]});

    // try manager.sendSendMessage(io, gpa, "Hello!");
    // try manager.sendSendMessageFd(io, gpa, pips[0]);
    // try manager.sendSendMessageArray(io, gpa, &.{ "Hello", "via", "array!" });
    // try manager.sendSendMessageArray(io, gpa, &.{});
    // try manager.sendSendMessageArrayUint(io, gpa, &.{ 69, 420, 2137 });
}

fn server(fd: i32) !void {
    _ = fd;
}

pub fn main(init: std.process.Init) !void {
    var sock_fds: [2]i32 = undefined;
    if (posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &sock_fds) != 0) return error.Idk;

    const s = 0;
    const c = 1;
    const child = posix.system.fork();
    if (child < 0) {
        _ = posix.system.close(sock_fds[s]);
        _ = posix.system.close(sock_fds[c]);
        std.debug.print("Failed to fork\n", .{});
    } else if (child == 0) {
        _ = posix.system.close(sock_fds[s]);
        try client(init.io, init.gpa, sock_fds[c]);
    } else {
        _ = posix.system.close(sock_fds[c]);
        try server(sock_fds[s]);
    }
}
