const std = @import("std");

const SocketRawParsedMessage = @import("../socket/socket_helpers.zig").SocketRawParsedMessage;

const mem = std.mem;

const ServerClient = opaque {};
const ClientSocket = opaque {};

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

    pub fn handleMessageServer(self: *Self, data: SocketRawParsedMessage, client: *ServerClient) MessageParsingResult {
        _ = self;
        _ = data;
        _ = client;
        return .ok;
    }

    pub fn handleMessageClient(self: *Self, data: SocketRawParsedMessage, client: *ClientSocket) MessageParsingResult {
        _ = self;
        _ = data;
        _ = client;
        return .ok;
    }

    pub fn parseVarInt(self: *Self, data: []const u8, offset: usize) struct { usize, usize } {
        _ = self;
        _ = data;
        _ = offset;
        return .{ 0, 0 };
    }

    pub fn parseVarIntSpan(self: *Self, data: []const u8) struct { usize, usize } {
        _ = self;
        _ = data;
        return .{ 0, 0 };
    }

    pub fn encodeVarInt(self: *Self, num: usize) ![]u8 {
        _ = num;
        return try self.allocator.alloc(u8, 1);
    }

    fn parseSingleMessageServer(self: *Self, data: SocketRawParsedMessage, off: usize, client: *ServerClient) usize {
        _ = self;
        _ = data;
        _ = off;
        _ = client;
        return 0;
    }

    fn parseSingleMessageClient(self: *Self, data: SocketRawParsedMessage, off: usize, client: *ClientSocket) usize {
        _ = self;
        _ = data;
        _ = off;
        _ = client;
        return 0;
    }
};

pub var message_parser: MessageParser = undefined;

pub fn initGlobalParser(gpa: mem.Allocator) void {
    message_parser = MessageParser.init(gpa);
}
