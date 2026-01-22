const std = @import("std");

const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

fixed: Allocator,
fallback: Allocator,
fba: *FixedBufferAllocator,

const Self = @This();

pub fn allocator(self: *Self) Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .free = free,
            .remap = remap,
        },
    };
}

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(ctx));
    return self.fixed.rawAlloc(len, alignment, ra) orelse self.fallback.rawAlloc(len, alignment, ra);
}

fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
    const self: *Self = @ptrCast(@alignCast(ctx));
    if (self.fba.ownsPtr(buf.ptr)) {
        if (self.fixed.rawResize(buf, alignment, new_len, ra)) {
            return true;
        }
    }
    return self.fallback.rawResize(buf, alignment, new_len, ra);
}

fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
    _ = ctx;
    _ = buf;
    _ = alignment;
    _ = ra;
    // hack.
    // Always noop since, in our specific usage, we know fallback is an arena.
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    if (resize(ctx, memory, alignment, new_len, ret_addr)) {
        return memory.ptr;
    }
    return null;
}
