const std = @import("std");
const vaxis = @import("vaxis");

pub const Meta = struct {
    style: vaxis.Style,
};

pub const Language = enum {
    none,
    zig,
};

pub const MetaList = std.MultiArrayList(Meta);
pub const MetaMap = std.HashMapUnmanaged(usize, usize, std.hash_map.AutoContext(usize), std.hash_map.default_max_load_percentage);
