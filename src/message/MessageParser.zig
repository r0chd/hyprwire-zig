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
const log = std.log;
const meta = std.meta;
const protocol_version = build_options.protocol_version;
const isTrace = helpers.isTrace;

const steadyMillis = @import("../root.zig").steadyMillis;

pub const MessageParsingResult = enum(u8) {
    ok = 0,
    parse_error = 1,
    incomplete = 2,
    stray_fds = 3,
};

pub const MessageParser = struct {
    const Self = @This();
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{ .allocator = allocator };
    }

    pub fn handleMessage(self: *Self, gpa: mem.Allocator, data: *SocketRawParsedMessage, role: union(enum) { client: *ClientSocket, server: *ServerClient }) MessageParsingResult {
        return switch (role) {
            .client => |client| self.handleClientMessage(gpa, data, client),
            .server => |client| self.handleServerMessage(data, client),
        };
    }

    fn handleClientMessage(self: *Self, gpa: mem.Allocator, data: *SocketRawParsedMessage, client: *ClientSocket) MessageParsingResult {
        var needle: usize = 0;
        while (needle < data.data.items.len) {
            const ret = parseSingleMessageClient(self.allocator, data, needle, client) catch return .parse_error;
            if (ret == 0) return .parse_error;

            needle += ret;
        }

        if (client.shouldEndReading()) {
            if (isTrace()) {
                log.debug("[{} @ {}] -- handleMessage: End read early", .{ client.fd.raw, steadyMillis() });
                data.data.items = data.data.items[needle..data.data.items.len];
                client.pending_socket_data.append(gpa, data.*) catch return .parse_error;
                return .ok;
            }
        }

        if (data.fds.items.len != 0) {
            return .stray_fds;
        }

        if (isTrace()) {
            log.debug("[{} @ {}] -- handleMessage: Finished read", .{ client.fd.raw, steadyMillis() });
        }

        return .ok;
    }

    fn handleServerMessage(self: *Self, data: *SocketRawParsedMessage, client: *ServerClient) MessageParsingResult {
        var needle: usize = 0;
        while (needle < data.data.items.len and !client.@"error") {
            const ret = parseSingleMessageServer(self.allocator, data, needle, client) catch return .parse_error;
            if (ret == 0) {
                return .parse_error;
            }

            needle += ret;
        }

        if (data.fds.items.len > 0) {
            return .stray_fds;
        }

        if (isTrace()) {
            log.debug("[{} @ {}] -- handleMessage: Finished read", .{ client.fd.raw, steadyMillis() });
        }

        return .ok;
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
                    var msg = messages.HandshakeAck.fromBytes(raw.data.items, off) catch |err| {
                        log.debug("client at fd {} core protocol error: malformed message recvd (handshake_ack)", .{client.fd.raw});
                        return err;
                    };
                    client.version = msg.version;

                    if (isTrace()) {
                        const parsed = messages.parseData(Message.from(&msg), gpa) catch |err| {
                            log.debug("[{} @ {}] -> parse error: {s}", .{ client.fd.raw, steadyMillis(), @errorName(err) });
                            return error.ParseError;
                        };
                        defer gpa.free(parsed);
                        log.debug("[{} @ {}] <- {s}", .{ client.fd.raw, steadyMillis(), parsed });
                    }

                    var protocol_names: std.ArrayList([]const u8) = try .initCapacity(gpa, client.server.?.impls.items.len);
                    for (client.server.?.impls.items) |impl| {
                        var protocol = impl.vtable.protocol(impl.ptr);
                        protocol_names.appendAssumeCapacity(try fmt.allocPrint(gpa, "{s}@{}", .{ protocol.vtable.specName(protocol.ptr), protocol.vtable.specVer(protocol.ptr) }));
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

                    if (isTrace()) {
                        const parsed = messages.parseData(Message.from(&msg), gpa) catch |err| {
                            log.debug("[{} @ {}] -> parse error: {s}", .{ client.fd.raw, steadyMillis(), @errorName(err) });
                            return error.ParseError;
                        };
                        defer gpa.free(parsed);
                        log.debug("[{} @ {}] <- {s}", .{ client.fd.raw, steadyMillis(), parsed });
                    }
                },
                .roundtrip_request => {
                    var msg = messages.RoundtripRequest.fromBytes(raw.data.items, off) catch |err| {
                        log.debug("client at fd {} core protocol error: malformed message recvd (roundtrip_request)", .{client.fd.raw});
                        return err;
                    };

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
                        log.err("server at fd {} core protocol error: malformed message recvd (handshake_begin): {s}", .{ client.fd.raw, @errorName(err) });
                        client.@"error" = true;
                        return 0;
                    };
                    if (msg.getLen() == 0) {
                        log.err("server at fd {} core protocol error: malformed message recvd (handshake_begin)", .{client.fd.raw});
                        client.@"error" = true;
                        return 0;
                    }

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

                    const parsed = messages.parseData(Message.from(&msg), gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.fd.raw, steadyMillis(), @errorName(err) });
                        return msg.getLen();
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.fd.raw, steadyMillis(), parsed });

                    var ack_msg = messages.HandshakeAck.init(1);
                    try client.sendMessage(gpa, Message.from(&ack_msg));

                    return msg.getLen();
                },
                .handshake_ack => {
                    var msg = messages.HandshakeAck.fromBytes(raw.data.items, off) catch |err| {
                        log.err("server at fd {} core protocol error: malformed message recvd (handshake_ack): {s}", .{ client.fd.raw, @errorName(err) });
                        client.@"error" = true;
                        return 0;
                    };
                    if (msg.getLen() == 0) {
                        log.err("server at fd {} core protocol error: malformed message recvd (handshake_ack)", .{client.fd.raw});
                        client.@"error" = true;
                        return 0;
                    }

                    const parsed = messages.parseData(Message.from(&msg), gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.fd.raw, steadyMillis(), @errorName(err) });
                        return msg.getLen();
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.fd.raw, steadyMillis(), parsed });

                    client.handshake_done = true;

                    return msg.getLen();
                },
                .handshake_protocols => {
                    var msg = messages.HandshakeProtocols.fromBytes(gpa, raw.data.items, off) catch |err| {
                        log.err("server at fd {} core protocol error: malformed message recvd (handshake_protocols): {s}", .{ client.fd.raw, @errorName(err) });
                        client.@"error" = true;
                        return 0;
                    };
                    if (msg.getLen() == 0) {
                        log.err("server at fd {} core protocol error: malformed message recvd (handshake_protocols)", .{client.fd.raw});
                        client.@"error" = true;
                        return 0;
                    }

                    const parsed = messages.parseData(Message.from(&msg), gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.fd.raw, steadyMillis(), @errorName(err) });
                        return msg.getLen();
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.fd.raw, steadyMillis(), parsed });

                    client.handshake_done = true;

                    return msg.getLen();
                },
                .new_object => {
                    var msg = messages.NewObject.fromBytes(raw.data.items, off) catch |err| {
                        log.err("server at fd {} core protocol error: malformed message recvd (new_object): {s}", .{ client.fd.raw, @errorName(err) });
                        client.@"error" = true;
                        return 0;
                    };
                    if (msg.getLen() == 0) {
                        log.err("server at fd {} core protocol error: malformed message recvd (new_object)", .{client.fd.raw});
                        client.@"error" = true;
                        return 0;
                    }

                    const parsed = messages.parseData(Message.from(&msg), gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.fd.raw, steadyMillis(), @errorName(err) });
                        return msg.getLen();
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.fd.raw, steadyMillis(), parsed });

                    client.onSeq(msg.seq, msg.id);

                    return msg.getLen();
                },
                .generic_protocol_message => {
                    var msg = messages.GenericProtocolMessage.fromBytes(gpa, raw.data.items, &fds, off) catch |err| {
                        log.err("server at fd {} core protocol error: malformed message recvd (generic_protocol_message): {s}", .{ client.fd.raw, @errorName(err) });
                        client.@"error" = true;
                        return 0;
                    };
                    if (msg.getLen() == 0) {
                        log.err("server at fd {} core protocol error: malformed message recvd (generic_protocol_message)", .{client.fd.raw});
                        client.@"error" = true;
                        return 0;
                    }

                    const parsed = messages.parseData(Message.from(&msg), gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.fd.raw, steadyMillis(), @errorName(err) });
                        return msg.getLen();
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.fd.raw, steadyMillis(), parsed });

                    try client.onGeneric(gpa, msg);

                    return msg.getLen();
                },
                .fatal_protocol_error => {
                    var msg = messages.FatalProtocolError.fromBytes(gpa, raw.data.items, off) catch |err| {
                        log.err("server at fd {} core protocol error: malformed message recvd (fatal_protocol_error): {s}", .{ client.fd.raw, @errorName(err) });
                        client.@"error" = true;
                        return 0;
                    };

                    log.err("fatal protocol error: object {} error {}: {s}", .{ msg.object_id, msg.error_id, msg.error_msg });
                    client.@"error" = true;
                    return msg.getLen();
                },
                .roundtrip_done => {
                    var msg = messages.RoundtripDone.fromBytes(raw.data.items, off) catch |err| {
                        log.err("server at fd {} core protocol error: malformed message recvd (roundtrip_done): {s}", .{ client.fd.raw, @errorName(err) });
                        client.@"error" = true;
                        return 0;
                    };
                    if (msg.getLen() == 0) {
                        log.err("server at fd {} core protocol error: malformed message recvd (roundtrip_done)", .{client.fd.raw});
                        client.@"error" = true;
                        return 0;
                    }

                    const parsed = messages.parseData(Message.from(&msg), gpa) catch |err| {
                        log.debug("[{} @ {}] -> parse error: {s}", .{ client.fd.raw, steadyMillis(), @errorName(err) });
                        return msg.getLen();
                    };
                    defer gpa.free(parsed);
                    log.debug("[{} @ {}] <- {s}", .{ client.fd.raw, steadyMillis(), parsed });

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

    pub fn parseVarInt(self: *Self, data: []const u8, offset: usize) std.meta.Tuple(&.{ usize, usize }) {
        return self.parseVarIntSpan(data[offset..]);
    }

    fn parseVarIntSpan(self: *Self, data: []const u8) meta.Tuple(&.{ usize, usize }) {
        _ = self;
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

    pub fn encodeVarInt(self: *Self, num: usize) []const u8 {
        _ = self;
        var buffer: [4]u8 = undefined;
        var data: std.ArrayList(u8) = .initBuffer(&buffer);
        data.appendAssumeCapacity(@as(u8, @truncate(num >> 0)) | 0x80);
        data.appendAssumeCapacity(@as(u8, @truncate(num >> 7)) | 0x80);
        data.appendAssumeCapacity(@as(u8, @truncate(num >> 14)) | 0x80);
        data.appendAssumeCapacity(@as(u8, @truncate(num >> 21)) | 0x80);

        while (data.getLast() == 0x80 and data.items.len > 1) {
            _ = data.pop();
        }

        buffer[data.items.len - 1] &= ~@as(u8, 0x80);

        return data.items;
    }
};

pub var message_parser: MessageParser = undefined;

pub fn initGlobalParser(gpa: mem.Allocator) void {
    message_parser = MessageParser.init(gpa);
}
