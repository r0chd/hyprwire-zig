const std = @import("std");
const xml = @import("xml");
const scanner = @import("scanner");
const Document = scanner.Document;
const generateClientCode = scanner.generateClientCode;
const generateServerCode = scanner.generateServerCode;

const testing = std.testing;
const mem = std.mem;
const fs = std.fs;
const heap = std.heap;

const SNAPSHOT_DIR = "scanner/tests/snapshots";
const PROTOCOL_DIR = "scanner/tests";

const PROTOCOLS = [_][]const u8{
    "protocol-v1.xml",
};

fn readSnapshot(allocator: mem.Allocator, snapshot_path: []const u8) ![]const u8 {
    const file = fs.cwd().openFile(snapshot_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("\n=== SNAPSHOT NOT FOUND ===\n", .{});
            std.debug.print("Expected snapshot at: {s}\n", .{snapshot_path});
            return error.SnapshotNotFound;
        },
        else => return err,
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    return contents;
}

fn compareSnapshots(allocator: mem.Allocator, actual: []const u8, expected_path: []const u8) !void {
    const expected_raw = try readSnapshot(allocator, expected_path);
    defer allocator.free(expected_raw);
    const expected = trimTrailingNewlines(expected_raw);
    const actual_trimmed = trimTrailingNewlines(actual);

    if (!mem.eql(u8, actual_trimmed, expected)) {
        std.debug.print("\n=== SNAPSHOT MISMATCH ===\n", .{});
        std.debug.print("Expected snapshot: {s}\n\n", .{expected_path});
        std.debug.print("=== EXPECTED ===\n{s}\n", .{expected});
        std.debug.print("=== ACTUAL ===\n{s}\n", .{actual_trimmed});
        return error.SnapshotMismatch;
    }
}

fn extractProtocolName(allocator: mem.Allocator, document: *const Document) ![]const u8 {
    for (document.root_nodes) |node| {
        switch (node) {
            .element => |e| {
                if (mem.eql(u8, e.name, "protocol")) {
                    if (e.attributes.get("name")) |name| {
                        return try allocator.dupe(u8, name);
                    }
                }
            },
            else => {},
        }
    }
    return error.ProtocolNameNotFound;
}

fn trimTrailingNewlines(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and (s[end - 1] == '\n' or s[end - 1] == '\r')) {
        end -= 1;
    }
    return s[0..end];
}

fn testSnapshot(allocator: mem.Allocator, document: *const Document, role: enum { client, server }, protocol_name: []const u8, arena: mem.Allocator) !void {
    // Generate code
    const generated = switch (role) {
        .client => generateClientCode(document),
        .server => try generateServerCode(arena, document),
    };

    const snapshot_name = try std.fmt.allocPrint(allocator, "{s}-{s}.zig", .{ protocol_name, if (role == .client) "client" else "server" });
    defer allocator.free(snapshot_name);

    const snapshot_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ SNAPSHOT_DIR, snapshot_name });
    defer allocator.free(snapshot_path);

    try compareSnapshots(allocator, generated, snapshot_path);
}

fn testProtocol(allocator: mem.Allocator, proto_filename: []const u8) !void {
    var arena_state = heap.ArenaAllocator.init(heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const proto_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ PROTOCOL_DIR, proto_filename });
    defer allocator.free(proto_path);

    // Read and parse the protocol file
    var input_file = try fs.cwd().openFile(proto_path, .{});
    defer input_file.close();

    var input_buf: [4096]u8 = undefined;
    var input_reader = input_file.reader(&input_buf);
    var streaming_reader = xml.Reader.Streaming.init(arena, &input_reader.interface, .{});
    defer streaming_reader.deinit();
    const reader = &streaming_reader.interface;

    const document = try Document.parse(arena, reader);
    const protocol_name = try extractProtocolName(allocator, &document);
    defer allocator.free(protocol_name);

    // Test both client and server generation
    try testSnapshot(allocator, &document, .client, protocol_name, arena);
    try testSnapshot(allocator, &document, .server, protocol_name, arena);
}

test "scanner snapshot: all protocols" {
    for (PROTOCOLS) |proto_filename| {
        try testProtocol(testing.allocator, proto_filename);
    }
}
