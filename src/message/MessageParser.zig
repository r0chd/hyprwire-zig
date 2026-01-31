const std = @import("std");
const enums = std.enums;
const fmt = std.fmt;
const mem = std.mem;
const meta = std.meta;
const Io = std.Io;
const build_options = @import("build_options");
const protocol_version = build_options.protocol_version;

const helpers = @import("helpers");
const isTrace = helpers.isTrace;
const steadyMillis = @import("hyprwire").steadyMillis;

const ClientSocket = @import("../client/ClientSocket.zig");
const wire_object = @import("../implementation/wire_object.zig");
const ServerClient = @import("../server/ServerClient.zig");
const SocketRawParsedMessage = @import("../socket/SocketRawParsedMessage.zig");
const Message = @import("./messages/Message.zig");
const MessageType = @import("MessageType.zig").MessageType;

const log = std.log.scoped(.hw);

pub const Error = error{
    StrayFds,
    InvalidMessage,
    MalformedMessage,
    VersionNegotiationFailed,
};

pub fn handleMessage(
    io: Io,
    gpa: mem.Allocator,
    data: *SocketRawParsedMessage,
    role: union(enum) { client: *ClientSocket, server: *ServerClient },
) (wire_object.Error || Error || Message.Error || mem.Allocator.Error || Io.Writer.Error)!void {
    return switch (role) {
        .client => |client| handleClientMessage(io, gpa, data, client),
        .server => |client| handleServerMessage(io, gpa, data, client),
    };
}

fn handleClientMessage(
    io: Io,
    gpa: mem.Allocator,
    data: *SocketRawParsedMessage,
    client: *ClientSocket,
) (wire_object.Error || Error || Message.Error || mem.Allocator.Error || Io.Writer.Error)!void {
    var needle: usize = 0;
    while (needle < data.data.items.len) {
        const ret = try parseSingleMessageClient(io, gpa, data, needle, client);

        needle += ret;

        if (client.shouldEndReading()) {
            if (isTrace()) log.debug("[{} @ {}] -- handleMessage: End read early", .{ client.stream.socket.handle, steadyMillis() });
            data.data.items = data.data.items[needle..data.data.items.len];
            try client.pending_socket_data.append(gpa, data.*);
            // Move ownership to pending_socket_data
            data.* = SocketRawParsedMessage{};
            return;
        }
    }

    if (data.fds.items.len != 0) {
        return Error.StrayFds;
    }

    if (isTrace()) {
        log.debug("[{} @ {}] -- handleMessage: Finished read", .{ client.stream.socket.handle, steadyMillis() });
    }

    return;
}

fn handleServerMessage(
    io: Io,
    gpa: mem.Allocator,
    data: *SocketRawParsedMessage,
    client: *ServerClient,
) (wire_object.Error || Error || Message.Error || mem.Allocator.Error || Io.Writer.Error)!void {
    var needle: usize = 0;
    while (needle < data.data.items.len and !client.@"error") {
        const ret = try parseSingleMessageServer(io, gpa, data, needle, client);

        needle += ret;
    }

    if (data.fds.items.len > 0) {
        return Error.StrayFds;
    }

    if (isTrace()) {
        log.debug("[{} @ {}] -- handleMessage: Finished read", .{ client.stream.socket.handle, steadyMillis() });
    }

    return;
}

fn parseSingleMessageServer(
    io: Io,
    gpa: mem.Allocator,
    raw: *SocketRawParsedMessage,
    off: usize,
    client: *ServerClient,
) (wire_object.Error || Error || Message.Error || mem.Allocator.Error || Io.Writer.Error)!usize {
    if (enums.fromInt(MessageType, raw.data.items[off])) |message_type| {
        switch (message_type) {
            .sup => {
                var hello_msg = Message.Hello.fromBytes(raw.data.items, off) catch |err| {
                    log.debug("client at fd {} core protocol error: malformed message recvd (sup)", .{client.stream.socket.handle});
                    return err;
                };

                if (isTrace()) {
                    const parsed = hello_msg.interface.parseData(gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.stream.socket.handle, steadyMillis(), @errorName(err) });
                        return err;
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.stream.socket.handle, steadyMillis(), parsed });
                }

                client.dispatchFirstPoll();
                const versions = [_]u32{1};
                var msg = try Message.HandshakeBegin.init(gpa, &versions);
                defer msg.deinit(gpa);
                client.sendMessage(io, gpa, &msg.interface);
                return hello_msg.interface.len;
            },
            .handshake_ack => {
                var msg = Message.HandshakeAck.fromBytes(gpa, raw.data.items, off) catch |err| {
                    log.debug("client at fd {} core protocol error: malformed message recvd (handshake_ack)", .{client.stream.socket.handle});
                    return err;
                };
                defer msg.deinit(gpa);
                client.version = msg.version;

                if (isTrace()) {
                    const parsed = msg.interface.parseData(gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.stream.socket.handle, steadyMillis(), @errorName(err) });
                        return err;
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.stream.socket.handle, steadyMillis(), parsed });
                }

                var protocol_names: std.ArrayList([:0]const u8) = try .initCapacity(gpa, client.server.?.impls.items.len);
                defer {
                    for (protocol_names.items) |name| {
                        gpa.free(name);
                    }
                    protocol_names.deinit(gpa);
                }
                for (client.server.?.impls.items) |impl| {
                    var protocol = impl.protocol();
                    protocol_names.appendAssumeCapacity(try fmt.allocPrintSentinel(gpa, "{s}@{}", .{ protocol.specName(), protocol.specVer() }, 0));
                }
                var message = try Message.HandshakeProtocols.init(gpa, protocol_names.items);
                defer message.deinit(gpa);
                client.sendMessage(io, gpa, &message.interface);

                return msg.interface.len;
            },
            .bind_protocol => {
                var msg = Message.BindProtocol.fromBytes(gpa, raw.data.items, off) catch |err| {
                    log.debug("client at fd {} core protocol error: malformed message recvd (bind_protocol)", .{client.stream.socket.handle});
                    return err;
                };
                defer msg.deinit(gpa);

                if (isTrace()) {
                    const parsed = msg.interface.parseData(gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.stream.socket.handle, steadyMillis(), @errorName(err) });
                        return err;
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.stream.socket.handle, steadyMillis(), parsed });
                }

                _ = client.createObject(io, gpa, msg.protocol, "", msg.version, msg.seq);

                return msg.interface.len;
            },
            .generic_protocol_message => {
                var msg = Message.GenericProtocolMessage.fromBytes(gpa, raw.data.items, &raw.fds, off) catch |err| {
                    log.debug("client at fd {} core protocol error: malformed message recvd (generic_protocol_message)", .{client.stream.socket.handle});
                    return err;
                };
                defer msg.deinit(gpa);

                if (isTrace()) {
                    const parsed = msg.interface.parseData(gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.stream.socket.handle, steadyMillis(), @errorName(err) });
                        return err;
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.stream.socket.handle, steadyMillis(), parsed });
                }

                try client.onGeneric(io, gpa, msg);
                return msg.interface.len;
            },
            .roundtrip_request => {
                var msg = Message.RoundtripRequest.fromBytes(gpa, raw.data.items, off) catch |err| {
                    log.debug("client at fd {} core protocol error: malformed message recvd (roundtrip_request)", .{client.stream.socket.handle});
                    return err;
                };
                defer msg.deinit(gpa);

                if (isTrace()) {
                    const parsed = msg.interface.parseData(gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.stream.socket.handle, steadyMillis(), @errorName(err) });
                        return err;
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.stream.socket.handle, steadyMillis(), parsed });
                }

                client.scheduled_roundtrip_seq = msg.seq;

                return msg.interface.len;
            },
            .roundtrip_done,
            .fatal_protocol_error,
            .new_object,
            .handshake_begin,
            .handshake_protocols,
            => |tag| {
                client.@"error" = true;
                log.debug("client at fd {} core protocol error: invalid message recvd {s}", .{ client.stream.socket.handle, @tagName(tag) });
                return Error.InvalidMessage;
            },
            .invalid => {},
        }
    }

    log.debug("client at fd {} core protocol error: malformed message recvd (invalid type code)", .{client.stream.socket.handle});
    client.@"error" = true;

    return Error.MalformedMessage;
}

fn parseSingleMessageClient(
    io: Io,
    gpa: mem.Allocator,
    raw: *SocketRawParsedMessage,
    off: usize,
    client: *ClientSocket,
) (wire_object.Error || Error || Message.Error || mem.Allocator.Error || Io.Writer.Error)!usize {
    if (enums.fromInt(MessageType, raw.data.items[off])) |message_type| {
        switch (message_type) {
            .handshake_begin => {
                var msg = Message.HandshakeBegin.fromBytes(gpa, raw.data.items, off) catch |err| {
                    log.err("server at fd {} core protocol error: malformed message recvd (handshake_begin)", .{client.stream.socket.handle});
                    return err;
                };
                defer msg.deinit(gpa);

                var version_supported = false;
                for (msg.versions) |version| {
                    if (version == protocol_version) {
                        version_supported = true;
                        break;
                    }
                }

                if (!version_supported) {
                    log.err("server at fd {} core protocol error: version negotiation failed", .{client.stream.socket.handle});
                    client.@"error" = true;
                    return Error.VersionNegotiationFailed;
                }

                if (isTrace()) {
                    const parsed = msg.interface.parseData(gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.stream.socket.handle, steadyMillis(), @errorName(err) });
                        return err;
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.stream.socket.handle, steadyMillis(), parsed });
                }

                var ack_msg = try Message.HandshakeAck.init(gpa, protocol_version);
                defer ack_msg.deinit(gpa);
                try client.sendMessage(io, gpa, &ack_msg.interface);

                return msg.interface.len;
            },
            .handshake_ack => {
                var msg = Message.HandshakeAck.fromBytes(gpa, raw.data.items, off) catch |err| {
                    log.err("server at fd {} core protocol error: malformed message recvd (handshake_ack)", .{client.stream.socket.handle});
                    return err;
                };
                defer msg.deinit(gpa);

                if (isTrace()) {
                    const parsed = msg.interface.parseData(gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.stream.socket.handle, steadyMillis(), @errorName(err) });
                        return err;
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.stream.socket.handle, steadyMillis(), parsed });
                }

                client.handshake_done = true;

                return msg.interface.len;
            },
            .handshake_protocols => {
                var msg = Message.HandshakeProtocols.fromBytes(gpa, raw.data.items, off) catch |err| {
                    log.err("server at fd {} core protocol error: malformed message recvd (handshake_protocols)", .{client.stream.socket.handle});
                    return err;
                };
                defer msg.deinit(gpa);

                if (isTrace()) {
                    const parsed = msg.interface.parseData(gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.stream.socket.handle, steadyMillis(), @errorName(err) });
                        return err;
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.stream.socket.handle, steadyMillis(), parsed });
                }

                client.serverSpecs(io, gpa, msg.protocols);

                return msg.interface.len;
            },
            .new_object => {
                var msg = Message.NewObject.fromBytes(gpa, raw.data.items, off) catch |err| {
                    log.err("server at fd {} core protocol error: malformed message recvd (new_object)", .{client.stream.socket.handle});
                    return err;
                };
                defer msg.deinit(gpa);

                if (isTrace()) {
                    const parsed = msg.interface.parseData(gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.stream.socket.handle, steadyMillis(), @errorName(err) });
                        return err;
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.stream.socket.handle, steadyMillis(), parsed });
                }

                client.onSeq(msg.seq, msg.id);

                return msg.interface.len;
            },
            .generic_protocol_message => {
                var msg = Message.GenericProtocolMessage.fromBytes(gpa, raw.data.items, &raw.fds, off) catch |err| {
                    log.err("server at fd {} core protocol error: malformed message recvd (generic_protocol_message)", .{client.stream.socket.handle});
                    return err;
                };
                defer msg.deinit(gpa);

                if (isTrace()) {
                    const parsed = msg.interface.parseData(gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.stream.socket.handle, steadyMillis(), @errorName(err) });
                        return err;
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.stream.socket.handle, steadyMillis(), parsed });
                }

                try client.onGeneric(io, gpa, msg);

                return msg.interface.len;
            },
            .fatal_protocol_error => {
                var msg = Message.FatalProtocolError.fromBytes(gpa, raw.data.items, off) catch |err| {
                    log.err("server at fd {} core protocol error: malformed message recvd (fatal_protocol_error)", .{client.stream.socket.handle});
                    return err;
                };
                defer msg.deinit(gpa);

                log.err("fatal protocol error: object {} error {}: {s}", .{ msg.object_id, msg.error_id, msg.error_msg });
                client.@"error" = true;
                return msg.interface.len;
            },
            .roundtrip_done => {
                var msg = Message.RoundtripDone.fromBytes(gpa, raw.data.items, off) catch |err| {
                    log.err("server at fd {} core protocol error: malformed message recvd (roundtrip_done)", .{client.stream.socket.handle});
                    return err;
                };
                defer msg.deinit(gpa);

                if (isTrace()) {
                    const parsed = msg.interface.parseData(gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.stream.socket.handle, steadyMillis(), @errorName(err) });
                        return err;
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.stream.socket.handle, steadyMillis(), parsed });
                }

                client.last_ackd_roundtrip_seq = msg.seq;

                return msg.interface.len;
            },
            .sup,
            .bind_protocol,
            .roundtrip_request,
            => |tag| {
                client.@"error" = true;
                log.err("server at fd {} core protocol error: invalid message recvd ({s})", .{ client.stream.socket.handle, @tagName(tag) });
                return Error.InvalidMessage;
            },
            .invalid => {},
        }
    }

    log.err("server at fd {} core protocol error: invalid message recvd (invalid type code)", .{client.stream.socket.handle});
    client.@"error" = true;

    return Error.InvalidMessage;
}

pub fn parseVarInt(data: []const u8, offset: usize) std.meta.Tuple(&.{ usize, usize }) {
    return parseVarIntSpan(data[offset..]);
}

fn parseVarIntSpan(data: []const u8) meta.Tuple(&.{ usize, usize }) {
    if (data.len == 0) return .{ 0, 0 };

    var rolling: usize = 0;
    var i: usize = 0;
    const len = data.len;

    while (true) {
        const chunk = data[i] & 0x7F;
        rolling |= (@as(usize, chunk)) << @as(u6, @intCast(i * 7));
        i += 1;

        if (i >= len or (data[i - 1] & 0x80) == 0) break;
    }

    return .{ rolling, i };
}

pub fn encodeVarInt(num: usize, buffer: []u8) []const u8 {
    var n = num;
    var i: usize = 0;

    while (true) {
        const chunk: u8 = @truncate(n & 0x7F);
        n >>= 7;
        buffer[i] = if (n == 0) chunk else (chunk | 0x80);
        i += 1;
        if (n == 0) break;
    }

    return buffer[0..i];
}

test "parseVarInt/encodeVarInt - basic functionality" {
    const testing = std.testing;

    var initial: usize = 1;
    while (initial < std.math.maxInt(usize) / 2) : (initial *= 2) {
        var buffer: [10]u8 = undefined;
        const encoded = encodeVarInt(initial, &buffer);

        const parsed, const encoded_len = parseVarInt(encoded, 0);
        try testing.expectEqual(parsed, initial);
        try testing.expectEqual(encoded.len, encoded_len);
    }
}

test "parseVarInt/encodeVarInt - edge cases" {
    const testing = std.testing;

    {
        var buffer: [10]u8 = undefined;
        const encoded = encodeVarInt(0, &buffer);
        try testing.expectEqual(encoded.len, 1);
        try testing.expectEqual(encoded[0], 0x00);

        const parsed, const len = parseVarInt(encoded, 0);
        try testing.expectEqual(parsed, 0);
        try testing.expectEqual(len, 1);
    }

    {
        var buffer: [10]u8 = undefined;
        const encoded = encodeVarInt(127, &buffer);
        try testing.expectEqual(encoded.len, 1);
        try testing.expectEqual(encoded[0], 0x7F);

        const parsed, const len = parseVarInt(encoded, 0);
        try testing.expectEqual(parsed, 127);
        try testing.expectEqual(len, 1);
    }

    {
        var buffer: [10]u8 = undefined;
        const encoded = encodeVarInt(128, &buffer);
        try testing.expectEqual(encoded.len, 2);
        try testing.expectEqual(encoded[0], 0x80);
        try testing.expectEqual(encoded[1], 0x01);

        const parsed, const len = parseVarInt(encoded, 0);
        try testing.expectEqual(parsed, 128);
        try testing.expectEqual(len, 2);
    }

    const test_values = [_]usize{
        0,     1,       42,      127,                  128,                      255,
        256,   16383,   16384,   32767,                32768,                    65535,
        65536, 2097151, 2097152, std.math.maxInt(u24), std.math.maxInt(u32) - 1, std.math.maxInt(u32),
    };

    for (test_values) |value| {
        var buffer: [10]u8 = undefined;
        const encoded = encodeVarInt(value, &buffer);
        const parsed, const len = parseVarInt(encoded, 0);

        try testing.expectEqual(parsed, value);
        try testing.expectEqual(len, encoded.len);
    }
}

test "parseVarInt/encodeVarInt - maximum values" {
    const testing = std.testing;

    const max_value = std.math.maxInt(usize);
    var buffer: [10]u8 = undefined;
    const encoded = encodeVarInt(max_value, &buffer);

    const parsed, const len = parseVarInt(encoded, 0);
    try testing.expectEqual(parsed, max_value);
    try testing.expectEqual(len, encoded.len);
}

test "parseVarInt - malformed input" {
    const testing = std.testing;

    {
        const data: []const u8 = &[_]u8{};
        const result = parseVarInt(data, 0);
        try testing.expectEqual(result.@"0", 0);
        try testing.expectEqual(result.@"1", 0);
    }

    {
        const data = [_]u8{0x80};
        const result = parseVarInt(&data, 0);
        try testing.expectEqual(result.@"0", 0);
        try testing.expectEqual(result.@"1", 1);
    }

    {
        var buffer: [10]u8 = undefined;
        const prefix = [_]u8{ 0xFF, 0xFF };
        const value: usize = 42;
        const encoded = encodeVarInt(value, &buffer);

        var combined: [12]u8 = undefined;
        combined[0] = prefix[0];
        combined[1] = prefix[1];
        for (encoded, 0..) |byte, i| {
            combined[2 + i] = byte;
        }

        const parsed, const len = parseVarInt(&combined, 2);
        try testing.expectEqual(parsed, value);
        try testing.expectEqual(len, encoded.len);
    }
}

test "parseVarInt/encodeVarInt - roundtrip consistency" {
    const testing = std.testing;

    const test_values = [_]usize{
        0,         1,         42,        127,       128,       255,        256,        511,        512,        1023,       1024,
        2047,      2048,      4095,      4096,      8191,      8192,       16383,      16384,      32767,      32768,      65535,
        65536,     131071,    131072,    262143,    262144,    524287,     524288,     1048575,    1048576,    2097151,    2097152,
        4194303,   4194304,   8388607,   8388608,   16777215,  16777216,   33554431,   33554432,   67108863,   67108864,   134217727,
        134217728, 268435455, 268435456, 536870911, 536870912, 1073741823, 1073741824, 2147483647, 2147483648, 4294967295,
    };

    for (test_values) |value| {
        var buffer: [10]u8 = undefined;
        const encoded = encodeVarInt(value, &buffer);
        const parsed, const len = parseVarInt(encoded, 0);

        try testing.expectEqual(parsed, value);
        try testing.expectEqual(len, encoded.len);
    }
}

test {
    std.testing.refAllDecls(@This());
}
