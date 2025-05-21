const std = @import("std");
const ztd = @import("ztd");
const log = std.log.scoped(.chunk_allocator);

pub const Options = struct {
    chunks: []const usize = &.{ 32, 64, 128, 256 },
};

/// This allocator allocates in fixed chunks
/// It's meant to be used for long living small allocations
pub fn ChunkAllocator(opts: Options) type {
    const Pools = blk: {
        var fields: []const std.builtin.Type.StructField = &.{};
        for (opts.chunks) |sz| {
            const Pool = FreeList(struct { mem: [sz]u8 });
            fields = fields ++ .{std.builtin.Type.StructField{
                .name = std.fmt.comptimePrint("p{}", .{sz}),
                .type = Pool,
                .default_value_ptr = &Pool{},
                .is_comptime = false,
                .alignment = 0,
            }};
        }
        break :blk @Type(.{
            .@"struct" = .{
                .layout = .auto,
                .fields = fields,
                .decls = &.{},
                .is_tuple = false,
            },
        });
    };

    return struct {
        pool: Pools = .{},
        arena: std.heap.ArenaAllocator,

        pub fn init(child_allocator: std.mem.Allocator) @This() {
            return .{ .arena = std.heap.ArenaAllocator.init(child_allocator) };
        }

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }

        pub const ResetMode = std.heap.ArenaAllocator.ResetMode;

        pub fn reset(self: *@This(), mode: ResetMode) bool {
            inline for (std.meta.fields(Pools)) |field| {
                const pool = &@field(self.pool, field.name);
                pool.reset();
            }
            return self.arena.reset(mode);
        }

        pub fn allocator(self: *@This()) std.mem.Allocator {
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

        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const n = len + (@as(usize, 1) << @as(std.mem.Allocator.Log2Align, @intFromEnum(alignment)));
            inline for (std.meta.fields(Pools), opts.chunks) |field, sz| {
                if (n <= sz) {
                    log.debug("{s}: requested {} bytes, allocated {} bytes", .{ field.name, len, n });
                    const pool = &@field(self.pool, field.name);
                    var node = pool.create(self.arena.allocator()) catch return null;
                    return node.mem[0..len].ptr;
                }
            }
            return null;
        }

        fn resize(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) bool {
            const cur_n = buf.len + (@as(usize, 1) << @as(std.mem.Allocator.Log2Align, @intFromEnum(alignment)));
            const new_n = new_len + (@as(usize, 1) << @as(std.mem.Allocator.Log2Align, @intFromEnum(alignment)));
            inline for (opts.chunks) |sz| {
                if (cur_n <= sz) return (new_n <= sz);
            }
            unreachable;
        }

        fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
            return null;
        }

        fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, _: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const n = buf.len + (@as(usize, 1) << @as(std.mem.Allocator.Log2Align, @intFromEnum(alignment)));
            inline for (std.meta.fields(Pools), opts.chunks) |field, sz| {
                if (n <= sz) {
                    const pool = &@field(self.pool, field.name);
                    return pool.destroy(@ptrCast(@alignCast(buf.ptr)));
                }
            }
            unreachable;
        }
    };
}

fn FreeList(comptime Item: type) type {
    return struct {
        pub const item_size = @max(@sizeOf(Node), @sizeOf(Item));
        const node_alignment = @alignOf(*anyopaque);
        pub const item_alignment = @max(node_alignment, @alignOf(Item));

        const Node = struct { next: ?*align(item_alignment) @This() };
        const NodePtr = *align(item_alignment) Node;
        const ItemPtr = *align(item_alignment) Item;

        free_list: ?NodePtr = null,

        pub fn reset(pool: *@This()) void {
            pool.free_list = null;
        }

        pub fn create(pool: *@This(), allocator: std.mem.Allocator) !ItemPtr {
            const node: NodePtr = blk: {
                if (pool.free_list) |item| {
                    pool.free_list = item.next;
                    break :blk item;
                } else {
                    break :blk @ptrCast(try allocator.alignedAlloc(u8, item_alignment, item_size));
                }
            };
            const ptr = @as(ItemPtr, @ptrCast(node));
            ptr.* = undefined;
            return ptr;
        }

        pub fn destroy(pool: *@This(), ptr: ItemPtr) void {
            ptr.* = undefined;
            const node = @as(NodePtr, @ptrCast(ptr));
            node.* = Node{ .next = pool.free_list };
            pool.free_list = node;
        }
    };
}
