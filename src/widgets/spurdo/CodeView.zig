const std = @import("std");
const vaxis = @import("vaxis");
const grapheme = @import("grapheme");
const common = @import("common.zig");
const log = std.log.scoped(.code_view);

const Cursor = struct {
    x: usize = 0,
    y: usize = 0,

    pub fn restrictTo(self: *@This(), w: usize, h: usize) void {
        self.x = @min(self.x, w);
        self.y = @min(self.y, h);
    }

    pub fn distance(self: *@This(), other: Cursor, cols: usize) usize {
        const x = if (self.x > other.x) self.x - other.x else other.x - self.x;
        const y = if (self.y > other.y) self.y - other.y else other.y - self.y;
        return x + y * cols;
    }
};

pub const Content = struct {
    lang: common.Language = .none,
    bytes: []const u8,
    gd: *const grapheme.GraphemeData,
};

graphemes: std.MultiArrayList(grapheme.Grapheme) = .{},
contents: std.ArrayListUnmanaged(u8) = .{},
meta: common.MetaList = .{},
meta_map: common.MetaMap = .{},
cursor: Cursor = .{},
selected: usize = 0,
line_numbers: bool = true,
top_bar: bool = true,
bottom_bar: bool = true,

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.meta.deinit(allocator);
    self.meta_map.deinit(allocator);
    self.graphemes.deinit(allocator);
    self.contents.deinit(allocator);
    self.* = undefined;
}

pub fn input(self: *@This(), key: vaxis.Key) !void {
    if (key.matches(vaxis.Key.right, .{})) {
        self.cursor.x += 1;
    } else if (key.matches(vaxis.Key.left, .{})) {
        if (self.cursor.x > 0) self.cursor.x -= 1;
    } else if (key.matches(vaxis.Key.up, .{})) {
        if (self.cursor.y > 0) self.cursor.y -= 1;
    } else if (key.matches(vaxis.Key.down, .{})) {
        self.cursor.y += 1;
    } else if (key.matches(vaxis.Key.end, .{})) {
        self.cursor.x = std.math.maxInt(usize);
    } else if (key.matches(vaxis.Key.home, .{})) {
        self.cursor.x = 0;
    }
}

fn extractDigit(v: usize, n: usize) usize {
    return (v / (std.math.powi(usize, 10, n) catch unreachable)) % 10;
}

fn numDigits(v: usize) usize {
    return switch (v) {
        0...9 => 1,
        10...99 => 2,
        100...999 => 3,
        1000...9999 => 4,
        10000...99999 => 5,
        100000...999999 => 6,
        1000000...9999999 => 7,
        10000000...99999999 => 8,
        else => 0,
    };
}

pub fn draw(self: *@This(), win: vaxis.Window) void {
    self.cursor.restrictTo(win.width, win.height);

    var pad: struct {
        top: usize = 0,
        left: usize = 0,
        right: usize = 0,
        bottom: usize = 0,
    } = .{};

    if (self.top_bar) {
        _ = win.print(&.{.{
            .text = " src ›  main.zig › 󰡱 main",
        }}, .{
            .row_offset = 0,
        }) catch {};
        pad.top += 1;
    }

    if (self.bottom_bar) {
        _ = win.print(&.{.{
            .text = "Normal",
        }}, .{
            .row_offset = win.height - 1,
        }) catch {};
        pad.bottom += 1;
    }

    if (self.line_numbers) {
        const num_lines = std.mem.count(u8, self.contents.items, "\n") + 1;
        const num_lines_digits = numDigits(num_lines);
        for (1..num_lines) |line| {
            if (pad.top + line - 1 >= win.height - pad.bottom) {
                break;
            }
            const selected_line = line - 1 == self.cursor.y;
            const digits = "0123456789";
            for (0..numDigits(line)) |i| {
                const digit = extractDigit(line, i);
                win.writeCell(pad.left + num_lines_digits - (i + 1), pad.top + line - 1, .{
                    .char = .{
                        .width = 1,
                        .grapheme = digits[digit .. digit + 1],
                    },
                    .style = .{
                        .dim = true,
                        .bg = if (selected_line) .{ .index = 0 } else .default,
                    },
                });
            }
        }
        pad.left += num_lines_digits + 1;
    }

    self.cursor.restrictTo(win.width, win.height - pad.bottom - pad.top - 1);

    var closestCell: Cursor = .{};
    var minDistance: usize = std.math.maxInt(usize);
    var cell: Cursor = .{};
    var byte_index: usize = 0;
    var is_indentation = true;
    for (self.graphemes.items(.len), self.graphemes.items(.offset), 0..) |g_len, g_offset, index| {
        if (pad.top + cell.y >= win.height - pad.bottom) {
            break;
        }

        var width: usize = 0;
        const cluster = self.contents.items[g_offset..][0..g_len];

        if (std.mem.eql(u8, cluster, "\n")) {
            if (index == self.graphemes.len - 1) {
                break;
            }
            cell.y += 1;
            cell.x = 0;
            is_indentation = true;
        }

        const selected_line = cell.y == self.cursor.y;
        var style: vaxis.Style = .{
            .bg = if (selected_line) .{ .index = 0 } else .default,
        };

        if (self.meta_map.get(byte_index)) |meta| {
            const tmp = style.bg;
            style = self.meta.items(.style)[meta];
            style.bg = tmp;
        }

        byte_index += cluster.len;

        if (!std.mem.eql(u8, cluster, "\n")) {
            if (!std.mem.eql(u8, cluster, " ")) {
                is_indentation = false;
            }
            width = win.gwidth(cluster);
            if (cell.x + width >= win.width) {
                continue;
            }
            const indentation = 4;
            if (is_indentation and cell.x % indentation == 0) {
                win.writeCell(pad.left + cell.x, pad.top + cell.y, .{
                    .char = .{
                        .grapheme = "┆",
                        .width = 1,
                    },
                    .style = .{
                        .dim = true,
                        .bg = style.bg,
                    },
                });
            } else {
                win.writeCell(pad.left + cell.x, pad.top + cell.y, .{
                    .char = .{
                        .grapheme = cluster,
                        .width = width,
                    },
                    .style = style,
                });
            }
        }

        const distance = self.cursor.distance(cell, win.width);
        if (distance < minDistance) {
            closestCell = cell;
            minDistance = distance;
            self.selected = index;
        }

        cell.x += width;

        if (selected_line) {
            for (cell.x..win.width) |x| {
                win.writeCell(pad.left + x, pad.top + cell.y, .{
                    .style = style,
                });
            }
            if (pad.left > 0) {
                win.writeCell(pad.left - 1, pad.top + cell.y, .{
                    .style = style,
                });
            }
        }
    }

    self.cursor = closestCell;
    win.showCursor(pad.left + self.cursor.x, pad.top + self.cursor.y);
}

pub fn updateContents(self: *@This(), allocator: std.mem.Allocator, content: Content) !void {
    self.contents.clearAndFree(allocator);
    try self.contents.appendSlice(allocator, content.bytes);
    try self.contents.append(allocator, 0);
    try self.graphemes.resize(allocator, 0);
    var iter = grapheme.Iterator.init(content.bytes, content.gd);
    while (iter.next()) |g| try self.graphemes.append(allocator, g);
    try self.meta.resize(allocator, 0);
    self.meta_map.clearAndFree(allocator);
    switch (content.lang) {
        .none => {},
        .zig => @import("lang/zig.zig").parse(allocator, self.contents.items, &self.meta, &self.meta_map) catch {},
    }
}
