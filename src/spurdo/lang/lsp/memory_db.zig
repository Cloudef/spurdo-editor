const std = @import("std");
const ztd = @import("ztd");

const ChunkAllocator = @import("chunk_allocator.zig").ChunkAllocator;

pub fn MemoryDB(comptime Tables: type) type {
    ztd.meta.comptimeAssertType(Tables, "ztd", "Tables", &.{.Struct});

    const TablesStruct = blk: {
        var fields: []const std.builtin.Type.StructField = &.{};
        for (std.meta.fields(Tables)) |field| {
            const Table = struct {
                pub const Row = field.type;
                pub const Field = std.meta.FieldEnum(field.type);
                lock: std.Thread.RwLock = .{},
                rows: std.MultiArrayList(field.type) = .{},

                // used for small data if cols has to be cloned
                comptime has_pool: bool = @hasDecl(Row, "clone"),
                pool: if (@hasDecl(Row, "clone")) ChunkAllocator(.{}) else void,

                pub fn init(allocator: std.mem.Allocator) @This() {
                    return .{
                        .pool = if (@hasDecl(Row, "clone")) ChunkAllocator(.{}).init(allocator) else {},
                    };
                }

                pub fn reset(self: *@This(), allocator: std.mem.Allocator) void {
                    self.lock.lock();
                    defer self.lock.unlock();
                    if (self.has_pool) _ = self.pool.reset(.free_all);
                    self.rows.deinit(allocator);
                    self.rows = .{};
                }

                pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                    {
                        self.lock.lock();
                        defer self.lock.unlock();
                        if (self.has_pool) self.pool.deinit();
                        self.rows.deinit(allocator);
                    }
                    self.* = undefined;
                }
            };

            fields = fields ++ .{.{
                .name = field.name,
                .type = Table,
                .default_value = null,
                .is_comptime = false,
                .alignment = 0,
            }};
        }
        break :blk @Type(.{
            .Struct = .{
                .layout = .auto,
                .fields = fields,
                .decls = &.{},
                .is_tuple = false,
            },
        });
    };

    return struct {
        pub const Table = std.meta.FieldEnum(TablesStruct);
        table: TablesStruct,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) @This() {
            var self: @This() = undefined;
            self.allocator = allocator;
            inline for (std.meta.fields(Table)) |field| {
                const tbl = &@field(self.table, field.name);
                tbl.* = @TypeOf(tbl.*).init(allocator);
            }
            return self;
        }

        pub fn deinit(self: *@This()) void {
            inline for (std.meta.fields(Table)) |field| {
                var tbl = &@field(self.table, field.name);
                tbl.deinit(self.allocator);
            }
            self.* = undefined;
        }

        pub fn drop(self: *@This(), comptime table: Table) void {
            var tbl = &@field(self.table, @tagName(table));
            tbl.reset(self.allocator);
        }

        pub fn delete(self: *@This(), comptime table: Table, filter: anytype) void {
            var tbl = &@field(self.table, @tagName(table));
            tbl.lock.lock();
            defer tbl.lock.unlock();
            var begin = 0;
            loop: while (true) {
                for (begin..tbl.rows.len) |idx| {
                    var matches: usize = 0;
                    inline for (std.meta.fields(@TypeOf(filter))) |field| {
                        const fld = comptime std.meta.stringToEnum(@TypeOf(tbl).Field, field.name) orelse unreachable;
                        matches += @intFromBool(std.meta.eql(tbl.rows.items(fld)[idx], filter));
                    }
                    if (matches != std.meta.fields(@TypeOf(filter)).len) continue;
                    if (comptime @hasDecl(@TypeOf(tbl).Row, "deinit")) {
                        tbl.rows.get(idx).deinit(tbl.pool.allocator());
                    }
                    tbl.rows.swapRemove(idx);
                    begin = idx;
                    continue :loop;
                }
                break;
            }
        }

        pub fn insert(self: *@This(), comptime table: Table, row: std.meta.FieldType(TablesStruct, table).Row) !void {
            var tbl = &@field(self.table, @tagName(table));
            tbl.lock.lock();
            defer tbl.lock.unlock();
            if (comptime tbl.has_pool) {
                try tbl.rows.append(self.allocator, try row.clone(tbl.pool.allocator()));
            } else {
                try tbl.rows.append(self.allocator, row);
            }
        }

        pub fn Fetch(comptime table: Table) type {
            return struct {
                pub const Field = std.meta.FieldType(TablesStruct, table).Field;
                pub const Row = std.meta.FieldType(TablesStruct, table).Row;
                rows: std.MultiArrayList(Row).Slice,
                lock: *std.Thread.RwLock,

                pub fn deinit(self: *@This()) void {
                    self.lock.unlockShared();
                    self.* = undefined;
                }
            };
        }

        pub fn fetch(self: *@This(), comptime table: Table) Fetch(table) {
            var tbl = &@field(self.table, @tagName(table));
            tbl.lock.lockShared();
            return .{ .rows = tbl.rows.slice(), .lock = &tbl.lock };
        }

        pub fn Iterator(comptime table: Table, comptime Filter: type) type {
            return struct {
                pub const Field = Fetch(table).Field;
                pub const Row = Fetch(table).Row;
                idx: usize = 0,
                filter: Filter,
                fetch: Fetch(table),

                pub fn next(self: *@This()) ?Row {
                    while (self.idx < self.fetch.rows.len) {
                        var matches: usize = 0;
                        inline for (std.meta.fields(Filter)) |field| {
                            const fld = comptime std.meta.stringToEnum(Field, field.name) orelse unreachable;
                            matches += @intFromBool(std.meta.eql(self.fetch.rows.items(fld)[self.idx], @field(self.filter, field.name)));
                        }
                        if (matches != std.meta.fields(Filter).len) {
                            self.idx += 1;
                            continue;
                        }
                        break;
                    }
                    if (self.idx >= self.fetch.rows.len) return null;
                    defer self.idx += 1;
                    return self.fetch.rows.get(self.idx);
                }

                pub fn deinit(self: *@This()) void {
                    self.fetch.deinit();
                }
            };
        }

        pub fn iterator(self: *@This(), comptime table: Table, filter: anytype) Iterator(table, @TypeOf(filter)) {
            return .{ .filter = filter, .fetch = self.fetch(table) };
        }
    };
}
