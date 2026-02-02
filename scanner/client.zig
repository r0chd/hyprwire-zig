const std = @import("std");
const mem = std.mem;

const Scanner = @import("./root.zig");
const SCANNER_SIGNATURE = Scanner.SCANNER_SIGNATURE;
const Document = Scanner.Document;
const GenerateError = Scanner.GenerateError;
const writeMethodHandler = Scanner.writeMethodHandler;
const ir = @import("ir.zig");
const Protocol = ir.Protocol;
const Object = ir.Object;
const Method = ir.Method;
const ObjectSet = ir.ObjectSet;

pub fn generateClientCodeForGlobal(gpa: mem.Allocator, doc: *const Document, global_iface: []const u8, requested_version: u32) ![]const u8 {
    const protocol = try Protocol.fromDocument(doc, gpa);

    if (protocol.version < requested_version) {
        return GenerateError.ProtocolVersionTooLow;
    }

    if (mem.eql(u8, global_iface, protocol.name)) {
        return generateClientCode(gpa, protocol, null);
    }

    const selected = try protocol.computeReachableSet(gpa, global_iface, requested_version);
    return generateClientCode(gpa, protocol, selected);
}

fn generateClientCode(gpa: mem.Allocator, protocol: Protocol, selected: ?ObjectSet) ![]const u8 {
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
        try writeObjectCode(writer, obj, seen > 0);
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
            \\//
            \\// This protocol's author copyright notice is:
            \\
        , .{});

        var lines = mem.splitScalar(u8, copyright, '\n');
        while (lines.next()) |line| {
            const l = mem.trimStart(u8, line, " ");
            try writer.print("// {s}\n", .{l});
        }

        try writer.print(
            \\//
            \\
            \\
        , .{});
    }
}

fn writeHeader(writer: anytype, protocol: Protocol) !void {
    try writer.print(
        \\const std = @import("std");
        \\
        \\const hyprwire = @import("hyprwire");
        \\const types = hyprwire.types;
        \\const client = types.client;
        \\const spec = hyprwire.proto.{s}.spec;
        \\
    , .{protocol.name});
}

fn writeObjectCode(writer: anytype, obj: Object, use_short_init: bool) !void {
    for (obj.s2c_methods, 0..) |method, idx| {
        try writeMethodHandler(writer, obj, method, idx);
    }
    try writeObjectStruct(writer, obj, use_short_init);
}

fn writeObjectStruct(writer: anytype, obj: Object, use_short_init: bool) !void {
    // Define Event outside the struct to avoid dependency loop
    try writer.print("pub const {s}Event = union(enum) {{\n", .{obj.name_pascal});
    for (obj.s2c_methods) |method| {
        try writer.print("    @\"{s}\": struct {{\n", .{method.name});
        for (method.args) |arg| {
            try writer.print("        {s}: {s},\n", .{ arg.name, arg.zig_event_type });
        }
        try writer.print("    }},\n", .{});
    }
    try writer.print("}};\n\n", .{});

    // Define Listener outside the struct to avoid dependency loop
    // Use *anyopaque to avoid forward reference to the Object type
    try writer.print(
        \\pub const {s}Listener = hyprwire.reexports.Trait(.{{
        \\    .{s}Listener = fn (std.mem.Allocator, *anyopaque, {s}Event) void,
        \\}});
        \\
        \\
    , .{ obj.name_pascal, obj.name_camel, obj.name_pascal });

    try writer.print("pub const {s}Object = struct {{\n", .{obj.name_pascal});
    try writer.print("    pub const Event = {s}Event;\n", .{obj.name_pascal});
    try writer.print("    pub const Listener = {s}Listener;\n\n", .{obj.name_pascal});

    try writer.print(
        \\    object: types.Object,
        \\    listener: Listener,
        \\    arena: std.heap.ArenaAllocator,
        \\
        \\    const Self = @This();
        \\
        \\    pub fn init(gpa: std.mem.Allocator, listener: Listener, object: types.Object) !*Self {{
        \\        const self = try gpa.create(Self);
        \\        self.* = .{{
    , .{});

    if (use_short_init) {
        try writer.print(
            \\
            \\            .object = object,
            \\            .listener = listener,
            \\            .arena = std.heap.ArenaAllocator.init(gpa),
            \\        }};
            \\
            \\        self.object.vtable.setData(self.object.ptr, self);
            \\
        , .{});
    } else {
        try writer.print(
            \\
            \\            .listener = listener,
            \\            .object = object,
            \\            .arena = std.heap.ArenaAllocator.init(gpa),
            \\        }};
            \\
            \\        self.object.vtable.setData(self.object.ptr, self);
            \\
        , .{});
    }

    for (obj.s2c_methods, 0..) |_, idx| {
        try writer.print("        try self.object.vtable.listen(self.object.ptr, gpa, {}, @ptrCast(&{s}_method{}));\n", .{ idx, obj.name_camel, idx });
    }

    try writer.print(
        \\
        \\        return self;
        \\    }}
        \\
    , .{});

    // Collect all destructor args for deinit signature
    var destructor_args: std.ArrayList(struct { name: []const u8, zig_type: []const u8 }) = .empty;
    var destructor_methods: std.ArrayList(struct { name_pascal: []const u8, arg_names: []const []const u8 }) = .empty;
    var arg_name_counts = std.StringHashMap(u32).init(std.heap.page_allocator);

    for (obj.c2s_methods) |method| {
        if (method.is_destructor) {
            var method_arg_names: std.ArrayList([]const u8) = .empty;
            for (method.args) |arg| {
                const count = arg_name_counts.get(arg.name) orelse 0;
                const renamed = if (count == 0)
                    try std.fmt.allocPrint(std.heap.page_allocator, "{s}0", .{arg.name})
                else
                    try std.fmt.allocPrint(std.heap.page_allocator, "{s}{}", .{ arg.name, count });
                try arg_name_counts.put(arg.name, count + 1);
                try destructor_args.append(std.heap.page_allocator, .{ .name = renamed, .zig_type = arg.zig_send_type });
                try method_arg_names.append(std.heap.page_allocator, renamed);
            }
            try destructor_methods.append(std.heap.page_allocator, .{
                .name_pascal = method.name_pascal,
                .arg_names = try method_arg_names.toOwnedSlice(std.heap.page_allocator),
            });
        }
    }

    try writer.print("    pub fn deinit(self: *Self, io: std.Io, gpa: std.mem.Allocator", .{});
    for (destructor_args.items) |arg| {
        try writer.print(", @\"{s}\": {s}", .{ arg.name, arg.zig_type });
    }
    try writer.print(") void {{\n", .{});

    if (destructor_methods.items.len == 0) {
        try writer.print("        _ = io;\n", .{});
    } else {
        for (destructor_methods.items) |method| {
            try writer.print("        self.send{s}(io, gpa", .{method.name_pascal});
            for (method.arg_names) |arg_name| {
                try writer.print(", @\"{s}\"", .{arg_name});
            }
            try writer.print(");\n", .{});
        }
    }
    try writer.print(
        \\        gpa.destroy(self);
        \\    }}
        \\
    , .{});

    for (obj.c2s_methods) |method| {
        try writeSendMethod(writer, method);
    }

    try writer.print(
        \\
        \\    pub fn dispatch(
        \\        self: *Self,
        \\        opcode: u16,
        \\        args: anytype,
        \\    ) void {{
        \\        switch (opcode) {{
    , .{});

    for (obj.s2c_methods, 0..) |method, idx| {
        try writer.print(
            \\
            \\            {} => if (self.listener.@"{s}") |cb|
            \\                cb(self, args[0]),
        , .{ idx, method.name });
    }

    try writer.print(
        \\
        \\            else => {{}},
        \\        }}
        \\    }}
        \\}};
        \\
        \\
    , .{});
}

fn writeSendMethod(writer: anytype, method: Method) !void {
    if (method.returns_type.len > 0) {
        try writer.print(
            \\
            \\    pub fn send{s}(self: *Self, io: std.Io, gpa: std.mem.Allocator) !types.Object {{
            \\        const wire: types.WireObject = .{{ .ptr = self.object.ptr, .vtable = @ptrCast(@alignCast(self.object.vtable)) }};
            \\        const seq = try wire.callMethod(io, gpa, {}, .{{}});
            \\        if (self.object.vtable.clientSock(self.object.ptr)) |sock| {{
            \\            const obj = sock.objectForSeq(seq) orelse return error.NoObject;
            \\            return types.Object.from(obj);
            \\        }}
            \\
            \\        return error.NoClientSocket;
            \\    }}
            \\
        , .{ method.name_pascal, method.idx });
        return;
    }

    const visibility = if (method.is_destructor) "" else "pub ";
    const return_type = if (method.is_destructor) "void" else "!void";

    try writer.print("\n    {s}fn send{s}(self: *Self, io: std.Io, gpa: std.mem.Allocator", .{ visibility, method.name_pascal });

    for (method.args) |arg| {
        try writer.print(", @\"{s}\": {s}", .{ arg.name, arg.zig_send_type });
    }

    try writer.print(") {s} {{\n", .{return_type});
    try writer.print("        const wire: types.WireObject = .{{ .ptr = self.object.ptr, .vtable = @ptrCast(@alignCast(self.object.vtable)) }};\n", .{});

    if (method.args.len == 0) {
        if (method.is_destructor) {
            try writer.print(
                \\        _ = wire.callMethod(io, gpa, {}, .{{}}) catch {{}};
                \\    }}
                \\
            , .{method.idx});
        } else {
            try writer.print(
                \\        _ = try wire.callMethod(io, gpa, {}, .{{}});
                \\    }}
                \\
            , .{method.idx});
        }
    } else {
        // Build tuple directly
        try writer.print("        ", .{});
        if (method.is_destructor) {
            try writer.print("_ = wire.callMethod(io, gpa, {}, .{{\n", .{method.idx});
        } else {
            try writer.print("_ = try wire.callMethod(io, gpa, {}, .{{\n", .{method.idx});
        }
        for (method.args) |arg| {
            try writer.print("            @\"{s}\",\n", .{arg.name});
        }
        if (method.is_destructor) {
            try writer.print(
                \\        }}) catch {{}};
                \\    }}
                \\
            , .{});
        } else {
            try writer.print(
                \\        }});
                \\    }}
                \\
            , .{});
        }
    }
}

fn writeProtocolImpl(writer: anytype, protocol: Protocol, selected: ?ObjectSet, obj_count: usize) !void {
    try writer.print(
        \\pub const {s}Impl = struct {{
        \\    version: u32,
        \\    interface: types.client.ProtocolImplementation = .{{
        \\        .protocolFn = Self.protocolFn,
        \\        .implementationFn = Self.implementationFn,
        \\    }},
        \\
        \\    const Self = @This();
        \\
        \\
    , .{protocol.name_pascal});

    try writer.print(
        \\    pub fn init(version: u32) Self {{
        \\        return .{{ .version = version }};
        \\    }}
        \\
        \\    pub fn protocolFn(_: *const types.client.ProtocolImplementation) *const types.ProtocolSpec {{
        \\        return &(spec.TestProtocolV1ProtocolSpec{{}}).interface;
        \\    }}
        \\
        \\    pub fn implementationFn(
        \\        ptr: *const types.client.ProtocolImplementation,
        \\        gpa: std.mem.Allocator,
        \\    ) ![]*client.ObjectImplementation {{
        \\        const self: *const Self = @fieldParentPtr("interface", ptr);
        \\
        \\        const impls = try gpa.alloc(*client.ObjectImplementation, {});
        \\        errdefer gpa.free(impls);
        \\
        \\
    , .{obj_count});

    var idx: usize = 0;
    for (protocol.objects) |obj| {
        if (selected) |sel| {
            if (!sel.contains(obj.name)) continue;
        }
        try writer.print(
            \\        impls[{}] = try gpa.create(client.ObjectImplementation);
            \\        errdefer gpa.destroy(impls[{}]);
            \\        impls[{}].* = .{{
            \\            .object_name = "{s}",
            \\            .version = self.version,
            \\        }};
            \\
        , .{ idx, idx, idx, obj.name });
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
