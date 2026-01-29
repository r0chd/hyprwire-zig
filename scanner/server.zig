const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const xml = @import("xml");
const Scanner = @import("./root.zig");
const SCANNER_SIGNATURE = Scanner.SCANNER_SIGNATURE;
const Document = Scanner.Document;
const MessageMagic = Scanner.MessageMagic;
const GenerateError = Scanner.GenerateError;
const writeMethodHandler = Scanner.writeMethodHandler;

const ir = @import("ir.zig");
const Protocol = ir.Protocol;
const Object = ir.Object;
const Method = ir.Method;
const ObjectSet = ir.ObjectSet;

pub fn generateServerCodeForGlobal(gpa: mem.Allocator, doc: *const Document, global_iface: []const u8, requested_version: u32) ![]const u8 {
    const protocol = try Protocol.fromDocument(doc, gpa);

    if (protocol.version < requested_version) {
        return GenerateError.ProtocolVersionTooLow;
    }

    if (mem.eql(u8, global_iface, protocol.name)) {
        return generateServerCode(gpa, protocol, null);
    }

    const selected = try protocol.computeReachableSet(gpa, global_iface, requested_version);
    return generateServerCode(gpa, protocol, selected);
}

fn generateServerCode(gpa: mem.Allocator, protocol: Protocol, selected: ?ObjectSet) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    const writer = &output.writer;

    try writeCopyrightHeader(writer, protocol);
    try writeHeader(writer, protocol);

    var obj_count: usize = 0;
    for (protocol.objects) |obj| {
        if (selected) |sel| {
            if (!sel.contains(obj.name)) continue;
        }
        obj_count += 1;
    }

    var seen: usize = 0;
    for (protocol.objects) |obj| {
        if (selected) |sel| {
            if (!sel.contains(obj.name)) continue;
        }
        const is_last = seen == obj_count - 1;
        try writeObjectCode(writer, obj, is_last);
        seen += 1;
    }

    try writeProtocolImpl(writer, protocol, selected, obj_count);

    return output.toOwnedSlice();
}

fn writeCopyrightHeader(writer: anytype, protocol: Protocol) !void {
    try writer.print("// {s}\n", .{SCANNER_SIGNATURE});
    try writer.print("// {s}\n\n", .{protocol.name});

    if (protocol.copyright) |copyright| {
        try writer.print(
            \\// This protocol's author copyright notice is:
            \\//
            \\// {s}
            \\
            \\
        , .{copyright});
    }
}

fn writeHeader(writer: anytype, protocol: Protocol) !void {
    try writer.print(
        \\const std = @import("std");
        \\
        \\const hyprwire = @import("hyprwire");
        \\const types = hyprwire.types;
        \\const server = types.server;
        \\const spec = hyprwire.proto.{s}.spec;
        \\
    , .{protocol.name});
}

fn writeObjectCode(writer: anytype, obj: Object, is_last: bool) !void {
    for (obj.c2s_methods, 0..) |method, idx| {
        try writeMethodHandler(writer, obj, method, idx);
    }
    try writeObjectStruct(writer, obj, is_last);
}

fn writeObjectStruct(writer: anytype, obj: Object, is_last: bool) !void {
    const is_first_object = mem.eql(u8, obj.name, "my_manager_v1");

    try writer.print("\npub const {s}Object = struct {{\n", .{obj.name_pascal});

    try writer.print("    pub const Event = union(enum) {{\n", .{});
    for (obj.c2s_methods) |method| {
        if (method.args.len == 0 and method.returns_type.len == 0) {
            try writer.print("        @\"{s}\": struct {{}},\n", .{method.name});
        } else {
            try writer.print("        @\"{s}\": struct {{\n", .{method.name});
            if (method.returns_type.len > 0) {
                try writer.print("            seq: u32,\n", .{});
            } else {
                for (method.args) |arg| {
                    try writer.print("            @\"{s}\": {s},\n", .{ arg.name, arg.zig_server_struct_type });
                }
            }
            try writer.print("        }},\n", .{});
        }
    }
    try writer.print("    }};\n", .{});

    try writer.print(
        \\
        \\    pub const Listener = hyprwire.Trait(.{{
        \\        .{s}Listener = fn (std.mem.Allocator, Event) void,
        \\    }}, null);
        \\
        \\    object: *types.Object,
        \\    listener: Listener,
        \\    arena: std.heap.ArenaAllocator,
        \\
        \\    const Self = @This();
        \\
        \\    pub fn init(gpa: std.mem.Allocator, listener: Listener, object: *types.Object) !*Self {{
        \\        const self = try gpa.create(Self);
        \\        self.* = .{{
    , .{obj.name_camel});

    if (is_first_object) {
        try writer.print(
            \\
            \\            .listener = listener,
            \\            .object = object,
            \\            .arena = std.heap.ArenaAllocator.init(gpa),
            \\        }};
            \\
            \\        object.vtable.setData(object.ptr, self);
            \\
        , .{});
    } else {
        try writer.print(
            \\
            \\            .object = object,
            \\            .listener = listener,
            \\            .arena = std.heap.ArenaAllocator.init(gpa),
            \\        }};
            \\
            \\        object.vtable.setData(object.ptr, self);
            \\
        , .{});
    }

    try writer.print("\n", .{});
    for (obj.c2s_methods, 0..) |_, idx| {
        try writer.print("        try object.vtable.listen(object.ptr, gpa, {}, @ptrCast(&{s}_method{}));\n", .{ idx, obj.name_camel, idx });
    }

    if (is_first_object) {
        try writer.print(
            \\
            \\        return self;
            \\    }}
            \\    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {{
            \\        self.arena.deinit();
            \\        gpa.destroy(self);
            \\    }}
            \\
            \\    pub fn getObject(self: *Self) *types.Object {{
            \\        return self.object;
            \\    }}
            \\
            \\    pub fn @"error"(self: *Self, code: u32, message: []const u8) void {{
            \\        self.object.vtable.@"error"(self.object.ptr, code, message);
            \\    }}
            \\
            \\    pub fn setOnDeinit(self: *Self, @"fn": *const fn () void) void {{
            \\        self.object.vtable.setOnDeinit(self.object.ptr, @"fn");
            \\    }}
            \\
        , .{});
    } else {
        try writer.print(
            \\        return self;
            \\    }}
            \\
            \\    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {{
            \\        self.arena.deinit();
            \\        gpa.destroy(self);
            \\    }}
            \\
            \\    pub fn setOnDeinit(self: *Self, @"fn": *const fn (*Self) void) void {{
            \\        self.object.vtable.setOnDeinit(self.object.ptr, @"fn");
            \\    }}
            \\
            \\    pub fn @"error"(self: *Self, io: std.Io, gpa: std.mem.Allocator, code: u32, message: [:0]const u8) void {{
            \\        self.object.vtable.@"error"(self.object.ptr, io, gpa, code, message);
            \\    }}
            \\
        , .{});
    }

    for (obj.s2c_methods) |method| {
        try writeSendMethod(writer, method);
    }

    if (is_last) {
        try writer.print("}};\n\n", .{});
    } else {
        try writer.print("}};\n", .{});
    }
}

fn writeSendMethod(writer: anytype, method: Method) !void {
    if (method.args.len == 0) {
        try writer.print(
            \\
            \\    pub fn send{s}(self: *Self, io: std.Io, gpa: std.mem.Allocator) !void {{
            \\        var buffer: [0]types.Arg = undefined;
            \\        var args = types.Args.init(&buffer, .{{}});
            \\        _ = try self.object.vtable.call(self.object.ptr, io, gpa, {}, &args);
            \\    }}
        , .{ method.name_pascal, method.idx });
    } else {
        try writer.print("\n    pub fn send{s}(self: *Self, io: std.Io, gpa: std.mem.Allocator", .{method.name_pascal});

        for (method.args) |arg| {
            try writer.print(", {s}: {s}", .{ arg.name, arg.zig_send_type });
        }

        try writer.print(
            \\) !void {{
            \\        var buffer: [{d}]types.Arg = undefined;
            \\        var args = types.Args.init(&buffer, .{{
            \\
        , .{method.args.len});

        for (method.args) |arg| {
            try writer.print("            @\"{s}\",\n", .{arg.name});
        }

        try writer.print(
            \\        }});
            \\        _ = try self.object.vtable.call(self.object.ptr, io, gpa, {}, &args);
            \\    }}
            \\
        , .{method.idx});
    }
}

fn writeProtocolImpl(writer: anytype, protocol: Protocol, selected: ?ObjectSet, obj_count: usize) !void {
    try writer.print(
        \\pub const {s}Listener = hyprwire.Trait(.{{
        \\    .bind = fn (*types.Object) void,
        \\}}, null);
        \\
        \\pub const {s}Impl = struct {{
        \\    version: u32,
        \\    listener: {s}Listener,
        \\
        \\    const Self = @This();
        \\
    , .{ protocol.name_pascal, protocol.name_pascal, protocol.name_pascal });

    try writer.print(
        \\    pub fn init(
        \\        version: u32,
        \\        listener: {s}Listener,
        \\    ) Self {{
        \\        return .{{
        \\            .version = version,
        \\            .listener = listener,
        \\        }};
        \\    }}
        \\
        \\    pub fn protocol(_: *Self) types.ProtocolSpec {{
        \\        return types.ProtocolSpec.from(&spec.{s}ProtocolSpec{{}});
        \\    }}
        \\
        \\    pub fn implementation(
        \\        self: *Self,
        \\        gpa: std.mem.Allocator,
        \\    ) ![]*server.ObjectImplementation {{
        \\        const impls = try gpa.alloc(*server.ObjectImplementation, {});
        \\        errdefer gpa.free(impls);
        \\
        \\
    , .{ protocol.name_pascal, protocol.name_pascal, obj_count });

    var idx: usize = 0;
    for (protocol.objects) |obj| {
        if (selected) |sel| {
            if (!sel.contains(obj.name)) continue;
        }
        const is_first = idx == 0;
        try writer.print(
            \\        impls[{}] = try gpa.create(server.ObjectImplementation);
            \\        errdefer gpa.destroy(impls[{}]);
            \\        impls[{}].* = .{{
            \\            .context = self.listener.ptr,
            \\            .object_name = "{s}",
            \\            .version = self.version,
        , .{ idx, idx, idx, obj.name });

        if (is_first) {
            try writer.print(
                \\
                \\            .onBind = self.listener.vtable.bind,
                \\        }};
                \\
            , .{});
        } else {
            try writer.print(
                \\
                \\        }};
                \\
            , .{});
        }

        idx += 1;
        if (idx < obj_count) {
            try writer.print("\n", .{});
        }
    }

    try writer.print(
        \\
        \\        return impls;
        \\    }}
        \\}};
        \\
    , .{});
}

test {
    std.testing.refAllDecls(@This());
}
