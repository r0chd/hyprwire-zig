const std = @import("std");
const build_options = @import("build_options");
const messages = @import("./messages/root.zig");
const helpers = @import("helpers");

const SocketRawParsedMessage = @import("../socket/socket_helpers.zig").SocketRawParsedMessage;
const ServerClient = @import("../server/ServerClient.zig");
const ClientSocket = @import("../client/ClientSocket.zig");
const MessageType = @import("MessageType.zig").MessageType;
const Message = messages.Message;

const fmt = std.fmt;
const mem = std.mem;
const log = std.log.scoped(.hw);
const meta = std.meta;
const protocol_version = build_options.protocol_version;
const isTrace = helpers.isTrace;

const steadyMillis = @import("../root.zig").steadyMillis;

pub const MessageParsingResult = error{
    ParseError,
    Incomplete,
    StrayFds,
};

pub fn handleMessage(gpa: mem.Allocator, data: *SocketRawParsedMessage, role: union(enum) { client: *ClientSocket, server: *ServerClient }) MessageParsingResult!void {
    return switch (role) {
        .client => |client| handleClientMessage(gpa, data, client),
        .server => |client| handleServerMessage(gpa, data, client),
    };
}

fn handleClientMessage(gpa: mem.Allocator, data: *SocketRawParsedMessage, client: *ClientSocket) MessageParsingResult!void {
    var needle: usize = 0;
    while (needle < data.data.items.len) {
        const ret = parseSingleMessageClient(gpa, data, needle, client) catch return error.ParseError;
        if (ret == 0) return error.ParseError;

        needle += ret;

        if (client.shouldEndReading()) {
            if (isTrace()) log.debug("[{} @ {}] -- handleMessage: End read early", .{ client.fd.raw, steadyMillis() });
            data.data.items = data.data.items[needle..data.data.items.len];
            client.pending_socket_data.append(gpa, data.*) catch return error.ParseError;
            // Ownership transferred to pending_socket_data; clear local to avoid double
            // deinit by the caller.
            data.* = SocketRawParsedMessage{};
            return;
        }
    }

    if (data.fds.items.len != 0) {
        return error.StrayFds;
    }

    if (isTrace()) {
        log.debug("[{} @ {}] -- handleMessage: Finished read", .{ client.fd.raw, steadyMillis() });
    }

    return;
}

fn handleServerMessage(gpa: mem.Allocator, data: *SocketRawParsedMessage, client: *ServerClient) MessageParsingResult!void {
    var needle: usize = 0;
    while (needle < data.data.items.len and !client.@"error") {
        const ret = parseSingleMessageServer(gpa, data, needle, client) catch return error.ParseError;
        if (ret == 0) return error.ParseError;

        needle += ret;
    }

    if (data.fds.items.len > 0) {
        return error.StrayFds;
    }

    if (isTrace()) {
        log.debug("[{} @ {}] -- handleMessage: Finished read", .{ client.fd.raw, steadyMillis() });
    }

    return;
}

pub fn parseSingleMessageServer(gpa: mem.Allocator, raw: *SocketRawParsedMessage, off: usize, client: *ServerClient) !usize {
    var fds = raw.fds;

    if (meta.intToEnum(MessageType, raw.data.items[off])) |message_type| {
        switch (message_type) {
            .sup => {
                var hello_msg = messages.Hello.fromBytes(raw.data.items, off) catch |err| {
                    log.debug("client at fd {} core protocol error: malformed message recvd (sup)", .{client.fd.raw});
                    return err;
                };

                if (isTrace()) {
                    const parsed = messages.parseData(Message.from(&hello_msg), gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.fd.raw, steadyMillis(), @errorName(err) });
                        return hello_msg.getLen();
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.fd.raw, steadyMillis(), parsed });
                }

                client.dispatchFirstPoll();
                const versions = [_]u32{1};
                var msg = try messages.HandshakeBegin.init(gpa, &versions);
                client.sendMessage(gpa, Message.from(&msg));
                return hello_msg.getLen();
            },
            .handshake_ack => {
                var msg = messages.HandshakeAck.fromBytes(gpa, raw.data.items, off) catch |err| {
                    log.debug("client at fd {} core protocol error: malformed message recvd (handshake_ack)", .{client.fd.raw});
                    return err;
                };
                defer msg.deinit(gpa);
                client.version = msg.version;

                if (isTrace()) {
                    const parsed = messages.parseData(Message.from(&msg), gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.fd.raw, steadyMillis(), @errorName(err) });
                        return error.ParseError;
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.fd.raw, steadyMillis(), parsed });
                }

                var protocol_names: std.ArrayList([:0]const u8) = try .initCapacity(gpa, client.server.?.impls.items.len);
                for (client.server.?.impls.items) |impl| {
                    var protocol = impl.vtable.protocol(impl.ptr);
                    protocol_names.appendAssumeCapacity(try fmt.allocPrintSentinel(gpa, "{s}@{}", .{ protocol.vtable.specName(protocol.ptr), protocol.vtable.specVer(protocol.ptr) }, 0));
                }
                var message = try messages.HandshakeProtocols.init(gpa, protocol_names.items);
                defer message.deinit(gpa);
                client.sendMessage(gpa, Message.from(&message));

                return msg.getLen();
            },
            .bind_protocol => {
                var msg = messages.BindProtocol.fromBytes(gpa, raw.data.items, off) catch |err| {
                    log.debug("client at fd {} core protocol error: malformed message recvd (bind_protocol)", .{client.fd.raw});
                    return err;
                };

                if (isTrace()) {
                    const parsed = messages.parseData(Message.from(&msg), gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.fd.raw, steadyMillis(), @errorName(err) });
                        return error.ParseError;
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.fd.raw, steadyMillis(), parsed });
                }

                _ = try client.createObject(gpa, msg.protocol, "", msg.version, msg.seq);

                return msg.getLen();
            },
            .generic_protocol_message => {
                var msg = messages.GenericProtocolMessage.fromBytes(gpa, raw.data.items, &fds, off) catch |err| {
                    log.debug("client at fd {} core protocol error: malformed message recvd (generic_protocol_message)", .{client.fd.raw});
                    return err;
                };
                defer msg.deinit(gpa);

                if (isTrace()) {
                    const parsed = messages.parseData(Message.from(&msg), gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.fd.raw, steadyMillis(), @errorName(err) });
                        return error.ParseError;
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.fd.raw, steadyMillis(), parsed });
                }

                try client.onGeneric(gpa, msg);
                return msg.getLen();
            },
            .roundtrip_request => {
                var msg = messages.RoundtripRequest.fromBytes(gpa, raw.data.items, off) catch |err| {
                    log.debug("client at fd {} core protocol error: malformed message recvd (roundtrip_request)", .{client.fd.raw});
                    return err;
                };
                defer msg.deinit(gpa);

                if (isTrace()) {
                    const parsed = messages.parseData(Message.from(&msg), gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.fd.raw, steadyMillis(), @errorName(err) });
                        return error.ParseError;
                    };
                    defer gpa.free(parsed);
                }

                client.scheduled_roundtrip_seq = msg.seq;

                return msg.getLen();
            },
            .roundtrip_done,
            .fatal_protocol_error,
            .new_object,
            .handshake_begin,
            .handshake_protocols,
            => |tag| {
                client.@"error" = true;
                log.debug("client at fd {} core protocol error: invalid message recvd {s}", .{ client.fd.raw, @tagName(tag) });
                return 0;
            },
            .invalid => {},
        }
    } else |_| {}

    log.debug("client at fd {} core protocol error: malformed message recvd (invalid type code)", .{client.fd.raw});
    client.@"error" = true;

    return 0;
}

pub fn parseSingleMessageClient(gpa: mem.Allocator, raw: *SocketRawParsedMessage, off: usize, client: *ClientSocket) !usize {
    var fds = raw.fds;

    if (meta.intToEnum(MessageType, raw.data.items[off])) |message_type| {
        switch (message_type) {
            .handshake_begin => {
                var msg = messages.HandshakeBegin.fromBytes(gpa, raw.data.items, off) catch |err| {
                    log.err("server at fd {} core protocol error: malformed message recvd (handshake_begin)", .{client.fd.raw});
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
                    log.err("server at fd {} core protocol error: version negotiation failed", .{client.fd.raw});
                    client.@"error" = true;
                    return 0;
                }

                if (isTrace()) {
                    const parsed = messages.parseData(Message.from(&msg), gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.fd.raw, steadyMillis(), @errorName(err) });
                        return msg.getLen();
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.fd.raw, steadyMillis(), parsed });
                }

                var ack_msg = try messages.HandshakeAck.init(gpa, protocol_version);
                defer ack_msg.deinit(gpa);
                try client.sendMessage(gpa, Message.from(&ack_msg));

                return msg.getLen();
            },
            .handshake_ack => {
                var msg = messages.HandshakeAck.fromBytes(gpa, raw.data.items, off) catch |err| {
                    log.err("server at fd {} core protocol error: malformed message recvd (handshake_ack)", .{client.fd.raw});
                    return err;
                };
                defer msg.deinit(gpa);

                if (isTrace()) {
                    const parsed = messages.parseData(Message.from(&msg), gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.fd.raw, steadyMillis(), @errorName(err) });
                        return msg.getLen();
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.fd.raw, steadyMillis(), parsed });
                }

                client.handshake_done = true;

                return msg.getLen();
            },
            .handshake_protocols => {
                var msg = messages.HandshakeProtocols.fromBytes(gpa, raw.data.items, off) catch |err| {
                    log.err("server at fd {} core protocol error: malformed message recvd (handshake_protocols)", .{client.fd.raw});
                    return err;
                };
                defer msg.deinit(gpa);

                if (isTrace()) {
                    const parsed = messages.parseData(Message.from(&msg), gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.fd.raw, steadyMillis(), @errorName(err) });
                        return msg.getLen();
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.fd.raw, steadyMillis(), parsed });
                }

                client.serverSpecs(gpa, msg.protocols);

                return msg.getLen();
            },
            .new_object => {
                var msg = messages.NewObject.fromBytes(gpa, raw.data.items, off) catch |err| {
                    log.err("server at fd {} core protocol error: malformed message recvd (new_object)", .{client.fd.raw});
                    return err;
                };
                defer msg.deinit(gpa);

                if (isTrace()) {
                    const parsed = messages.parseData(Message.from(&msg), gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.fd.raw, steadyMillis(), @errorName(err) });
                        return msg.getLen();
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.fd.raw, steadyMillis(), parsed });
                }

                client.onSeq(msg.seq, msg.id);

                return msg.getLen();
            },
            .generic_protocol_message => {
                var msg = messages.GenericProtocolMessage.fromBytes(gpa, raw.data.items, &fds, off) catch |err| {
                    log.err("server at fd {} core protocol error: malformed message recvd (generic_protocol_message)", .{client.fd.raw});
                    return err;
                };
                defer msg.deinit(gpa);

                if (isTrace()) {
                    const parsed = messages.parseData(Message.from(&msg), gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.fd.raw, steadyMillis(), @errorName(err) });
                        return msg.getLen();
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.fd.raw, steadyMillis(), parsed });
                }

                try client.onGeneric(gpa, msg);

                return msg.getLen();
            },
            .fatal_protocol_error => {
                var msg = messages.FatalProtocolError.fromBytes(gpa, raw.data.items, off) catch |err| {
                    log.err("server at fd {} core protocol error: malformed message recvd (fatal_protocol_error)", .{client.fd.raw});
                    return err;
                };
                defer msg.deinit(gpa);

                log.err("fatal protocol error: object {} error {}: {s}", .{ msg.object_id, msg.error_id, msg.error_msg });
                client.@"error" = true;
                return msg.getLen();
            },
            .roundtrip_done => {
                var msg = messages.RoundtripDone.fromBytes(gpa, raw.data.items, off) catch |err| {
                    log.err("server at fd {} core protocol error: malformed message recvd (roundtrip_done)", .{client.fd.raw});
                    return err;
                };
                defer msg.deinit(gpa);

                if (isTrace()) {
                    const parsed = messages.parseData(Message.from(&msg), gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.fd.raw, steadyMillis(), @errorName(err) });
                        return msg.getLen();
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.fd.raw, steadyMillis(), parsed });
                }

                client.last_ackd_roundtrip_seq = msg.seq;

                return msg.getLen();
            },
            .sup,
            .bind_protocol,
            .roundtrip_request,
            => |tag| {
                client.@"error" = true;
                log.err("server at fd {} core protocol error: invalid message recvd ({s})", .{ client.fd.raw, @tagName(tag) });
                return 0;
            },
            .invalid => {},
        }
    } else |_| {}

    log.err("server at fd {} core protocol error: invalid message recvd (invalid type code)", .{client.fd.raw});
    client.@"error" = true;

    return 0;
}

pub fn parseVarInt(data: []const u8, offset: usize) std.meta.Tuple(&.{ usize, usize }) {
    return parseVarIntSpan(data[offset..]);
}

fn parseVarIntSpan(data: []const u8) meta.Tuple(&.{ usize, usize }) {
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

test "parseVarInt/encodeVarInt" {
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
