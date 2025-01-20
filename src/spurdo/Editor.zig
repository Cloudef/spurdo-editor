const std = @import("std");
const vaxis = @import("vaxis");
const grapheme = @import("grapheme");
const DisplayWidth = @import("DisplayWidth");
const ScrollView = vaxis.widgets.ScrollView;
const LineNumbers = vaxis.widgets.LineNumbers;

pub const DrawOptions = struct {
    highlighted_line: usize = 0,
    draw_line_numbers: bool = true,
    indentation: usize = 0,
};

pub const BufferWriter = struct {
    pub const Error = error{OutOfMemory};
    pub const Writer = std.io.GenericWriter(@This(), Error, write);

    allocator: std.mem.Allocator,
    buffer: *Buffer,
    gd: *const grapheme.GraphemeData,
    wd: *const DisplayWidth.DisplayWidthData,

    pub fn write(self: @This(), bytes: []const u8) Error!usize {
        try self.buffer.append(self.allocator, .{
            .bytes = bytes,
            .gd = self.gd,
            .wd = self.wd,
        });
        return bytes.len;
    }

    pub fn writer(self: @This()) Writer {
        return .{ .context = self };
    }
};

pub const Buffer = struct {
    const StyleList = std.ArrayListUnmanaged(vaxis.Style);
    const StyleMap = std.HashMapUnmanaged(usize, usize, std.hash_map.AutoContext(usize), std.hash_map.default_max_load_percentage);

    pub const Content = struct {
        bytes: []const u8,
        gd: *const grapheme.GraphemeData,
        wd: *const DisplayWidth.DisplayWidthData,
    };

    pub const Style = struct {
        begin: usize,
        end: usize,
        style: vaxis.Style,
    };

    pub const Error = error{OutOfMemory};

    grapheme: std.MultiArrayList(grapheme.Grapheme) = .{},
    content: std.ArrayListUnmanaged(u8) = .{},
    style_list: StyleList = .{},
    style_map: StyleMap = .{},
    rows: usize = 0,
    cols: usize = 0,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.style_map.deinit(allocator);
        self.style_list.deinit(allocator);
        self.grapheme.deinit(allocator);
        self.content.deinit(allocator);
        self.* = undefined;
    }

    /// Clears all buffer data.
    pub fn clear(self: *@This(), allocator: std.mem.Allocator) void {
        self.deinit(allocator);
        self.* = .{};
    }

    /// Replaces contents of the buffer, all previous buffer data is lost.
    pub fn update(self: *@This(), allocator: std.mem.Allocator, content: Content) Error!void {
        self.clear(allocator);
        errdefer self.clear(allocator);
        var cols: usize = 0;
        var iter = grapheme.Iterator.init(content.bytes, content.gd);
        const dw: DisplayWidth = .{ .data = content.wd };
        while (iter.next()) |g| {
            try self.grapheme.append(allocator, .{
                .len = g.len,
                .offset = @as(u32, @intCast(self.content.items.len)) + g.offset,
            });
            const cluster = g.bytes(content.bytes);
            if (std.mem.eql(u8, cluster, "\n")) {
                self.cols = @max(self.cols, cols);
                cols = 0;
                continue;
            }
            cols +|= dw.strWidth(cluster);
        }
        try self.content.appendSlice(allocator, content.bytes);
        self.cols = @max(self.cols, cols);
        self.rows = std.mem.count(u8, content.bytes, "\n");
    }

    /// Clears all styling data.
    pub fn clearStyle(self: *@This(), allocator: std.mem.Allocator) void {
        self.style_list.deinit(allocator);
        self.style_map.deinit(allocator);
    }

    /// Update style for range of the buffer contents.
    pub fn updateStyle(self: *@This(), allocator: std.mem.Allocator, style: Style) Error!void {
        const style_index = blk: {
            for (self.style_list.items, 0..) |s, i| {
                if (std.meta.eql(s, style.style)) {
                    break :blk i;
                }
            }
            try self.style_list.append(allocator, style.style);
            break :blk self.style_list.items.len - 1;
        };
        for (style.begin..style.end) |i| {
            try self.style_map.put(allocator, i, style_index);
        }
    }

    pub fn writer(
        self: *@This(),
        allocator: std.mem.Allocator,
        gd: *const grapheme.GraphemeData,
        wd: *const DisplayWidth.DisplayWidthData,
    ) BufferWriter.Writer {
        return .{
            .context = .{
                .allocator = allocator,
                .buffer = self,
                .gd = gd,
                .wd = wd,
            },
        };
    }
};

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

scroll_view: ScrollView = .{ .vertical_scrollbar = null },
highlighted_style: vaxis.Style = .{ .bg = .{ .index = 0 } },
indentation_cell: vaxis.Cell = .{
    .char = .{
        .grapheme = "┆",
        .width = 1,
    },
    .style = .{ .dim = true },
},

pub fn input(self: *@This(), key: vaxis.Key) void {
    self.scroll_view.input(key);
}

pub fn draw(self: *@This(), win: vaxis.Window, buffer: Buffer, opts: DrawOptions) void {
    const pad_left: usize = if (opts.draw_line_numbers) LineNumbers.numDigits(buffer.rows) +| 1 else 0;
    self.scroll_view.draw(win, .{
        .cols = buffer.cols + pad_left,
        .rows = buffer.rows,
    });
    if (opts.draw_line_numbers) {
        var nl: LineNumbers = .{
            .highlighted_line = opts.highlighted_line,
            .num_lines = buffer.rows +| 1,
        };
        nl.draw(win.child(.{
            .x_off = 0,
            .y_off = 0,
            .width = @intCast(pad_left),
            .height = win.height,
        }), self.scroll_view.scroll.y);
    }
    self.drawCode(win.child(.{ .x_off = @intCast(pad_left) }), buffer, opts);
}

fn drawCode(self: *@This(), win: vaxis.Window, buffer: Buffer, opts: DrawOptions) void {
    const Pos = struct { x: usize = 0, y: usize = 0 };
    var pos: Pos = .{};
    var byte_index: usize = 0;
    var is_indentation = true;
    const bounds = self.scroll_view.bounds(win);
    for (buffer.grapheme.items(.len), buffer.grapheme.items(.offset), 0..) |g_len, g_offset, index| {
        if (bounds.above(pos.y)) {
            break;
        }

        const cluster = buffer.content.items[g_offset..][0..g_len];
        defer byte_index += cluster.len;

        if (std.mem.eql(u8, cluster, "\n")) {
            if (index == buffer.grapheme.len - 1) {
                break;
            }
            pos.y += 1;
            pos.x = 0;
            is_indentation = true;
            continue;
        } else if (bounds.below(pos.y)) {
            continue;
        }

        const highlighted_line = pos.y +| 1 == opts.highlighted_line;
        var style: vaxis.Style = if (highlighted_line) self.highlighted_style else .{};

        if (buffer.style_map.get(byte_index)) |meta| {
            const tmp = style.bg;
            style = buffer.style_list.items[meta];
            style.bg = tmp;
        }

        const width = win.gwidth(cluster);
        defer pos.x +|= width;

        if (!bounds.colInside(pos.x)) {
            continue;
        }

        if (opts.indentation > 0 and !std.mem.eql(u8, cluster, " ")) {
            is_indentation = false;
        }

        if (is_indentation and opts.indentation > 0 and pos.x % opts.indentation == 0) {
            var cell = self.indentation_cell;
            cell.style.bg = style.bg;
            self.scroll_view.writeCell(win, pos.x, pos.y, cell);
        } else {
            self.scroll_view.writeCell(win, pos.x, pos.y, .{
                .char = .{ .grapheme = cluster, .width = @intCast(width) },
                .style = style,
            });
        }

        if (highlighted_line) {
            for (pos.x +| width..bounds.x2) |x| {
                self.scroll_view.writeCell(win, x, pos.y, .{ .style = style });
            }
        }
    }
}
