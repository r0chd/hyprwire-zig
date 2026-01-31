const std = @import("std");
const builtin = @import("builtin");

pub fn Trait(comptime methods: anytype) type {

    // Generate VTable type with function pointers
    const VTableType = generateVTableType(methods);

    // Create the validation namespace
    const ValidationNamespace = CreateValidationNamespace(methods);

    // Return the VTable-based trait type directly
    return struct {
        ptr: *anyopaque,
        vtable: *const VTableType,

        const Self = @This();

        pub const VTable = VTableType;
        pub const validation = ValidationNamespace;

        /// Creates an trait wrapper from an implementation pointer and vtable.
        pub fn init(impl: anytype, vtable_ptr: *const VTableType) Self {
            const ImplPtr = @TypeOf(impl);
            const impl_type_info = @typeInfo(ImplPtr);

            // Verify it's a pointer
            if (impl_type_info != .pointer) {
                @compileError("init() requires a pointer to an implementation, got: " ++ @typeName(ImplPtr));
            }

            const ImplType = impl_type_info.pointer.child;

            // Validate that the type satisfies the trait at compile time
            comptime validation.satisfiedBy(ImplType);

            return .{
                .ptr = impl,
                .vtable = vtable_ptr,
            };
        }

        /// Automatically generates VTable wrappers and creates an trait wrapper.
        pub fn from(impl: anytype) Self {
            const ImplPtr = @TypeOf(impl);
            const impl_type_info = @typeInfo(ImplPtr);

            // Verify it's a pointer
            if (impl_type_info != .pointer) {
                @compileError("from() requires a pointer to an implementation, got: " ++ @typeName(ImplPtr));
            }

            const ImplType = impl_type_info.pointer.child;

            // Validate that the type satisfies the trait at compile time
            comptime validation.satisfiedBy(ImplType);

            // Generate a unique wrapper struct with static VTable for this ImplType
            const gen = struct {
                fn generateWrapperForField(comptime T: type, comptime vtable_field: std.builtin.Type.StructField) *const anyopaque {
                    // Extract function signature from vtable field
                    const fn_ptr_info = @typeInfo(vtable_field.type);
                    const fn_info = @typeInfo(fn_ptr_info.pointer.child).@"fn";
                    const method_name = vtable_field.name;

                    // Check if the implementation method expects *T or T
                    const impl_method_info = @typeInfo(@TypeOf(@field(T, method_name)));
                    const impl_fn_info = impl_method_info.@"fn";
                    const first_param_info = @typeInfo(impl_fn_info.params[0].type.?);
                    const expects_pointer = first_param_info == .pointer;

                    // Generate wrapper matching the exact signature
                    const param_count = fn_info.params.len;
                    if (param_count < 1 or param_count > 5) {
                        @compileError("Method '" ++ method_name ++ "' has too many parameters. Only 1-5 parameters (including self pointer) are supported.");
                    }

                    // Create wrapper with exact parameter types from VTable signature
                    if (expects_pointer) {
                        return switch (param_count) {
                            1 => &struct {
                                fn wrapper(ptr: *anyopaque) callconv(fn_info.calling_convention) fn_info.return_type.? {
                                    const self: *T = @ptrCast(@alignCast(ptr));
                                    return @field(T, method_name)(self);
                                }
                            }.wrapper,
                            2 => &struct {
                                fn wrapper(ptr: *anyopaque, p1: fn_info.params[1].type.?) callconv(fn_info.calling_convention) fn_info.return_type.? {
                                    const self: *T = @ptrCast(@alignCast(ptr));
                                    return @field(T, method_name)(self, p1);
                                }
                            }.wrapper,
                            3 => &struct {
                                fn wrapper(ptr: *anyopaque, p1: fn_info.params[1].type.?, p2: fn_info.params[2].type.?) callconv(fn_info.calling_convention) fn_info.return_type.? {
                                    const self: *T = @ptrCast(@alignCast(ptr));
                                    return @field(T, method_name)(self, p1, p2);
                                }
                            }.wrapper,
                            4 => &struct {
                                fn wrapper(ptr: *anyopaque, p1: fn_info.params[1].type.?, p2: fn_info.params[2].type.?, p3: fn_info.params[3].type.?) callconv(fn_info.calling_convention) fn_info.return_type.? {
                                    const self: *T = @ptrCast(@alignCast(ptr));
                                    // Cast *anyopaque to the expected implementation type if needed
                                    const impl_p2_type = impl_fn_info.params[2].type.?;
                                    const actual_p2 = if (@typeInfo(fn_info.params[2].type.?).pointer.child == anyopaque and
                                        @typeInfo(impl_p2_type) == .pointer and @typeInfo(impl_p2_type).pointer.child != anyopaque)
                                        @as(impl_p2_type, @ptrCast(@alignCast(p2)))
                                    else
                                        p2;
                                    return @field(T, method_name)(self, p1, actual_p2, p3);
                                }
                            }.wrapper,
                            5 => &struct {
                                fn wrapper(ptr: *anyopaque, p1: fn_info.params[1].type.?, p2: fn_info.params[2].type.?, p3: fn_info.params[3].type.?, p4: fn_info.params[4].type.?) callconv(fn_info.calling_convention) fn_info.return_type.? {
                                    const self: *T = @ptrCast(@alignCast(ptr));
                                    return @field(T, method_name)(self, p1, p2, p3, p4);
                                }
                            }.wrapper,
                            else => unreachable,
                        };
                    } else {
                        return switch (param_count) {
                            1 => &struct {
                                fn wrapper(ptr: *anyopaque) callconv(fn_info.calling_convention) fn_info.return_type.? {
                                    const self: *T = @ptrCast(@alignCast(ptr));
                                    return @field(T, method_name)(self.*);
                                }
                            }.wrapper,
                            2 => &struct {
                                fn wrapper(ptr: *anyopaque, p1: fn_info.params[1].type.?) callconv(fn_info.calling_convention) fn_info.return_type.? {
                                    const self: *T = @ptrCast(@alignCast(ptr));
                                    return @field(T, method_name)(self.*, p1);
                                }
                            }.wrapper,
                            3 => &struct {
                                fn wrapper(ptr: *anyopaque, p1: fn_info.params[1].type.?, p2: fn_info.params[2].type.?) callconv(fn_info.calling_convention) fn_info.return_type.? {
                                    const self: *T = @ptrCast(@alignCast(ptr));
                                    return @field(T, method_name)(self.*, p1, p2);
                                }
                            }.wrapper,
                            4 => &struct {
                                fn wrapper(ptr: *anyopaque, p1: fn_info.params[1].type.?, p2: fn_info.params[2].type.?, p3: fn_info.params[3].type.?) callconv(fn_info.calling_convention) fn_info.return_type.? {
                                    const self: *T = @ptrCast(@alignCast(ptr));
                                    return @field(T, method_name)(self.*, p1, p2, p3);
                                }
                            }.wrapper,
                            5 => &struct {
                                fn wrapper(ptr: *anyopaque, p1: fn_info.params[1].type.?, p2: fn_info.params[2].type.?, p3: fn_info.params[3].type.?, p4: fn_info.params[4].type.?) callconv(fn_info.calling_convention) fn_info.return_type.? {
                                    const self: *T = @ptrCast(@alignCast(ptr));
                                    return @field(T, method_name)(self.*, p1, p2, p3, p4);
                                }
                            }.wrapper,
                            else => unreachable,
                        };
                    }
                }

                const vtable: VTableType = blk: {
                    var result: VTableType = undefined;
                    // Iterate over all VTable fields (includes embedded trait methods)
                    for (std.meta.fields(VTableType)) |vtable_field| {
                        const wrapper_ptr = generateWrapperForField(ImplType, vtable_field);
                        @field(result, vtable_field.name) = @ptrCast(@alignCast(wrapper_ptr));
                    }
                    break :blk result;
                };
            };

            return .{
                .ptr = @constCast(impl),
                .vtable = &gen.vtable,
            };
        }
    };
}

/// Compares two types structurally to determine if they're compatible
fn isTypeCompatible(comptime T1: type, comptime T2: type) bool {
    const info1 = @typeInfo(T1);
    const info2 = @typeInfo(T2);

    // If types are identical, they're compatible
    if (T1 == T2) return true;

    // If type categories don't match, they're not compatible
    if (@intFromEnum(info1) != @intFromEnum(info2)) return false;

    return switch (info1) {
        .@"struct" => |s1| blk: {
            const s2 = @typeInfo(T2).@"struct";
            if (s1.fields.len != s2.fields.len) break :blk false;
            if (s1.is_tuple != s2.is_tuple) break :blk false;

            for (s1.fields, s2.fields) |f1, f2| {
                if (!std.mem.eql(u8, f1.name, f2.name)) break :blk false;
                if (!isTypeCompatible(f1.type, f2.type)) break :blk false;
            }
            break :blk true;
        },
        .@"enum" => |e1| blk: {
            const e2 = @typeInfo(T2).@"enum";
            if (e1.fields.len != e2.fields.len) break :blk false;

            for (e1.fields, e2.fields) |f1, f2| {
                if (!std.mem.eql(u8, f1.name, f2.name)) break :blk false;
                if (f1.value != f2.value) break :blk false;
            }
            break :blk true;
        },
        .array => |a1| blk: {
            const a2 = @typeInfo(T2).array;
            if (a1.len != a2.len) break :blk false;
            break :blk isTypeCompatible(a1.child, a2.child);
        },
        .pointer => |p1| blk: {
            const p2 = @typeInfo(T2).pointer;
            if (p1.size != p2.size) break :blk false;
            // Allow *anyopaque in the expected type (T2) to match any pointer in implementation (T1)
            if (p2.child == anyopaque and p1.size == .one and p2.size == .one) break :blk true;
            if (p1.is_const != p2.is_const) break :blk false;
            if (p1.is_volatile != p2.is_volatile) break :blk false;
            break :blk isTypeCompatible(p1.child, p2.child);
        },
        .optional => |o1| blk: {
            const o2 = @typeInfo(T2).optional;
            break :blk isTypeCompatible(o1.child, o2.child);
        },
        else => T1 == T2,
    };
}

/// Generates helpful hints for type mismatches
fn generateTypeHint(comptime expected: type, comptime got: type) ?[]const u8 {
    const exp_info = @typeInfo(expected);
    const got_info = @typeInfo(got);

    // Check for common slice constness issues
    if (exp_info == .pointer and got_info == .pointer) {
        const exp_ptr = exp_info.pointer;
        const got_ptr = got_info.pointer;
        if (exp_ptr.is_const and !got_ptr.is_const) {
            return "Consider making the parameter type const (e.g., []const u8 instead of []u8)";
        }
    }

    // Check for optional vs non-optional mismatches
    if (exp_info == .optional and got_info != .optional) {
        return "The expected type is optional. Consider wrapping the parameter in '?'";
    }
    if (exp_info != .optional and got_info == .optional) {
        return "The expected type is non-optional. Remove the '?' from the parameter type";
    }

    // Check for enum type mismatches
    if (exp_info == .@"enum" and got_info == .@"enum") {
        return "Check that the enum values and field names match exactly";
    }

    // Check for struct field mismatches
    if (exp_info == .@"struct" and got_info == .@"struct") {
        const exp_s = exp_info.@"struct";
        const got_s = got_info.@"struct";
        if (exp_s.fields.len != got_s.fields.len) {
            return "The structs have different numbers of fields";
        }
        // Could add more specific field comparison hints here
        return "Check that all struct field names and types match exactly";
    }

    // Generic catch-all for pointer size mismatches
    if (exp_info == .pointer and got_info == .pointer) {
        const exp_ptr = exp_info.pointer;
        const got_ptr = got_info.pointer;
        if (exp_ptr.size != got_ptr.size) {
            return "Check pointer type (single item vs slice vs many-item)";
        }
    }

    return null;
}

/// Formats type mismatch errors with helpful hints
fn formatTypeMismatch(
    comptime expected: type,
    comptime got: type,
    indent: []const u8,
) []const u8 {
    var result = std.fmt.comptimePrint(
        "{s}Expected: {s}\n{s}Got: {s}",
        .{
            indent,
            @typeName(expected),
            indent,
            @typeName(got),
        },
    );

    // Add hint if available
    if (generateTypeHint(expected, got)) |hint| {
        result = result ++ std.fmt.comptimePrint("\n   {s}Hint: {s}", .{ indent, hint });
    }

    return result;
}

fn generateVTableType(comptime methods: anytype) type {
    comptime {
        // Build array of struct fields for the VTable
        var fields: []const std.builtin.Type.StructField = &.{};

        // Helper function to add a method to the VTable
        const addMethod = struct {
            fn add(method_field: std.builtin.Type.StructField, method_fn: anytype, field_list: []const std.builtin.Type.StructField) []const std.builtin.Type.StructField {
                const fn_info = @typeInfo(method_fn).@"fn";

                // Build parameter list: insert *anyopaque as first param (implicit self)
                var params: [fn_info.params.len + 1]std.builtin.Type.Fn.Param = undefined;
                params[0] = .{
                    .is_generic = false,
                    .is_noalias = false,
                    .type = *anyopaque,
                };

                // Copy all trait parameters after the implicit self
                for (fn_info.params, 1..) |param, i| {
                    params[i] = param;
                }

                // Create function pointer type
                const FnType = blk: {
                    const FnAttr = std.builtin.Type.Fn.Attributes;
                    const ParamAttr = std.builtin.Type.Fn.Param.Attributes;

                    // Zig 0.16 @Fn expects separate param types and param attributes.
                    var param_types: [params.len]type = undefined;
                    var param_attrs: [params.len]ParamAttr = undefined;

                    for (params, 0..) |p, i| {
                        param_types[i] = p.type.?;
                        param_attrs[i] = .{};
                        if (@hasField(ParamAttr, "is_noalias")) param_attrs[i].is_noalias = p.is_noalias;
                        if (@hasField(ParamAttr, "is_generic")) param_attrs[i].is_generic = p.is_generic;
                    }

                    var fn_attrs: FnAttr = .{};
                    if (@hasField(FnAttr, "calling_convention")) fn_attrs.calling_convention = fn_info.calling_convention;
                    if (@hasField(FnAttr, "is_var_args")) fn_attrs.is_var_args = false;
                    if (@hasField(FnAttr, "is_generic")) fn_attrs.is_generic = false;

                    break :blk @Fn(&param_types, &param_attrs, fn_info.return_type.?, fn_attrs);
                };

                const FnPtrType = *const FnType;

                // Add field to VTable
                return field_list ++ &[_]std.builtin.Type.StructField{.{
                    .name = method_field.name,
                    .type = FnPtrType,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(FnPtrType),
                }};
            }
        }.add;

        // Add methods from primary trait
        for (std.meta.fields(@TypeOf(methods))) |method_field| {
            const method_fn = @field(methods, method_field.name);
            // Only add if not already present from embedded traits
            fields = addMethod(method_field, method_fn, fields);
        }

        // Create the VTable struct type
        return blk: {
            const FieldAttr = std.builtin.Type.StructField.Attributes;

            var field_names: [fields.len][]const u8 = undefined;
            var field_types: [fields.len]type = undefined;
            var field_attrs: [fields.len]FieldAttr = undefined;

            for (fields, 0..) |f, i| {
                field_names[i] = f.name;
                field_types[i] = f.type;
                field_attrs[i] = .{};
                if (@hasField(FieldAttr, "alignment")) field_attrs[i].alignment = f.alignment;
                if (@hasField(FieldAttr, "is_comptime")) field_attrs[i].is_comptime = f.is_comptime;
                if (@hasField(FieldAttr, "default_value_ptr")) field_attrs[i].default_value_ptr = f.default_value_ptr;
            }

            break :blk @Struct(.auto, null, &field_names, &field_types, &field_attrs);
        };
    }
}

fn CreateValidationNamespace(comptime methods: anytype) type {
    return struct {
        const Methods = @TypeOf(methods);

        /// Represents all possible trait implementation problems
        pub const Incompatibility = union(enum) {
            missing_method: []const u8,
            wrong_param_count: struct {
                method: []const u8,
                expected: usize,
                got: usize,
            },
            param_type_mismatch: struct {
                method: []const u8,
                param_index: usize,
                expected: type,
                got: type,
            },
            return_type_mismatch: struct {
                method: []const u8,
                expected: type,
                got: type,
            },
            ambiguous_method: struct {
                method: []const u8,
                traits: []const []const u8,
            },
        };

        /// Collects all method names from this trait and its embedded traits
        fn collectMethodNames() []const []const u8 {
            comptime {
                var method_count: usize = 0;

                // Count methods from primary trait
                for (std.meta.fields(Methods)) |_| {
                    method_count += 1;
                }

                // Now create array of correct size
                var names: [method_count][]const u8 = undefined;
                var index: usize = 0;

                // Add primary trait methods
                for (std.meta.fields(Methods)) |field| {
                    names[index] = field.name;
                    index += 1;
                }

                return &names;
            }
        }

        /// Checks if a method exists in multiple traits and returns the list of traits if so
        fn findMethodConflicts(comptime method_name: []const u8) ?[]const []const u8 {
            comptime {
                var trait_count: usize = 0;

                // Count primary trait
                if (@hasDecl(Methods, method_name)) {
                    trait_count += 1;
                }

                if (trait_count <= 1) return null;

                var traits: [trait_count][]const u8 = undefined;
                var index: usize = 0;

                // Add primary trait
                if (@hasDecl(Methods, method_name)) {
                    index += 1;
                }

                return &traits;
            }
        }

        fn isCompatibleErrorSet(comptime Expected: type, comptime Actual: type) bool {
            const exp_info = @typeInfo(Expected);
            const act_info = @typeInfo(Actual);

            if (exp_info != .error_union or act_info != .error_union) {
                return Expected == Actual;
            }

            // Any error union in the trait accepts any error set in the implementation
            return exp_info.error_union.payload == act_info.error_union.payload;
        }

        pub fn incompatibilities(comptime ImplType: type) []const Incompatibility {
            comptime {
                var problems: []const Incompatibility = &.{};

                // First check for method ambiguity across all traits
                for (collectMethodNames()) |method_name| {
                    if (findMethodConflicts(method_name)) |conflicting_traits| {
                        problems = problems ++ &[_]Incompatibility{.{
                            .ambiguous_method = .{
                                .method = method_name,
                                .traits = conflicting_traits,
                            },
                        }};
                    }
                }

                // If we have ambiguous methods, return early
                if (problems.len > 0) return problems;

                // Check primary trait methods
                for (std.meta.fields(@TypeOf(methods))) |field| {
                    if (!@hasDecl(ImplType, field.name)) {
                        problems = problems ++ &[_]Incompatibility{.{
                            .missing_method = field.name,
                        }};
                        continue;
                    }

                    const impl_fn = @TypeOf(@field(ImplType, field.name));
                    const expected_fn = @field(methods, field.name);

                    const impl_info = @typeInfo(impl_fn).@"fn";
                    const expected_info = @typeInfo(expected_fn).@"fn";

                    // Implementation has self parameter, trait signature doesn't
                    const expected_param_count = expected_info.params.len + 1;

                    if (impl_info.params.len != expected_param_count) {
                        problems = problems ++ &[_]Incompatibility{.{
                            .wrong_param_count = .{
                                .method = field.name,
                                .expected = expected_param_count,
                                .got = impl_info.params.len,
                            },
                        }};
                    } else {
                        // Compare impl params[1..] (skip self) with trait params[0..]
                        for (impl_info.params[1..], expected_info.params, 0..) |impl_param, expected_param, i| {
                            if (!isTypeCompatible(impl_param.type.?, expected_param.type.?)) {
                                problems = problems ++ &[_]Incompatibility{.{
                                    .param_type_mismatch = .{
                                        .method = field.name,
                                        .param_index = i + 1,
                                        .expected = expected_param.type.?,
                                        .got = impl_param.type.?,
                                    },
                                }};
                            }
                        }
                    }

                    if (!isCompatibleErrorSet(expected_info.return_type.?, impl_info.return_type.?)) {
                        problems = problems ++ &[_]Incompatibility{.{
                            .return_type_mismatch = .{
                                .method = field.name,
                                .expected = expected_info.return_type.?,
                                .got = impl_info.return_type.?,
                            },
                        }};
                    }
                }

                return problems;
            }
        }

        fn formatIncompatibility(incompatibility: Incompatibility) []const u8 {
            const indent = if (builtin.os.tag == .windows) "   \\- " else "   └─ ";
            return switch (incompatibility) {
                .missing_method => |method| std.fmt.comptimePrint("Missing required method: {s}\n{s}Add the method with the correct signature to your implementation", .{ method, indent }),

                .wrong_param_count => |info| std.fmt.comptimePrint("Method '{s}' has incorrect number of parameters:\n" ++
                    "{s}Expected {d} parameters\n" ++
                    "{s}Got {d} parameters\n" ++
                    "   {s}Hint: Remember that the first parameter should be the self/receiver type", .{
                    info.method,
                    indent,
                    info.expected,
                    indent,
                    info.got,
                    indent,
                }),

                .param_type_mismatch => |info| std.fmt.comptimePrint("Method '{s}' parameter {d} has incorrect type:\n{s}", .{
                    info.method,
                    info.param_index,
                    formatTypeMismatch(info.expected, info.got, indent),
                }),

                .return_type_mismatch => |info| std.fmt.comptimePrint("Method '{s}' return type is incorrect:\n{s}", .{
                    info.method,
                    formatTypeMismatch(info.expected, info.got, indent),
                }),

                .ambiguous_method => |info| std.fmt.comptimePrint("Method '{s}' is ambiguous - it appears in multiple traits: {s}\n" ++
                    "   {s}Hint: This method needs to be uniquely implemented or the ambiguity resolved", .{
                    info.method,
                    info.traits,
                    indent,
                }),
            };
        }

        pub fn satisfiedBy(comptime ImplType: type) void {
            comptime {
                const problems = incompatibilities(ImplType);
                if (problems.len > 0) {
                    const title = "Type '{s}' does not implement the expected trait(s). To fix:\n";

                    // First compute the total size needed for our error message
                    var total_len: usize = std.fmt.count(title, .{@typeName(ImplType)});

                    // Add space for each problem's length
                    for (1.., problems) |i, problem| {
                        total_len += std.fmt.count("{d}. {s}\n", .{ i, formatIncompatibility(problem) });
                    }

                    // Now create a fixed-size array of the exact size we need
                    var errors: [total_len]u8 = undefined;
                    var written: usize = 0;

                    written += (std.fmt.bufPrint(errors[written..], title, .{@typeName(ImplType)}) catch unreachable).len;

                    // Write each problem
                    for (1.., problems) |i, problem| {
                        written += (std.fmt.bufPrint(errors[written..], "{d}. {s}\n", .{ i, formatIncompatibility(problem) }) catch unreachable).len;
                    }

                    @compileError(errors[0..written]);
                }
            }
        }
    };
}
