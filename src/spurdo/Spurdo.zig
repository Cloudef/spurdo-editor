const std = @import("std");
const aio = @import("aio");
const coro = @import("coro");
const vaxis = @import("vaxis");
const Editor = @import("Editor.zig");
const zig = @import("lang/zig.zig");
const Lsp = @import("lang/Lsp.zig");
const log = std.log.scoped(.spurdo);

pub const Buffer = Editor.Buffer;
pub const Content = Editor.Buffer.Content;

allocator: std.mem.Allocator,
scheduler: coro.Scheduler,
lsp: Lsp,
buffer: Buffer = .{},
editor: Editor = .{},

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .allocator = allocator,
        .scheduler = try coro.Scheduler.init(allocator, .{}),
        .lsp = Lsp.init(allocator, "zig"),
    };
}

pub fn deinit(self: *@This()) void {
    self.lsp.deinit(&self.scheduler);
    self.scheduler.deinit();
    self.* = undefined;
}

pub fn input(self: *@This(), key: vaxis.Key) !void {
    self.editor.input(key);
}

pub fn update(self: *@This()) !void {
    try self.scheduler.tick(.nonblocking);
}

fn drawTopBar(_: *@This(), win: vaxis.Window) void {
    _ = win.print(&.{.{
        .text = " src ›  main.zig › 󰡱 main",
    }}, .{}) catch {};
}

fn drawBottomBar(_: *@This(), win: vaxis.Window) void {
    _ = win.print(&.{.{
        .text = "Normal",
    }}, .{}) catch {};
}

pub fn draw(self: *@This(), win: vaxis.Window) void {
    self.drawTopBar(win.child(.{
        .height = .{ .limit = 1 },
    }));

    self.editor.draw(win.child(.{
        .y_off = 1,
        .height = .{ .limit = win.height -| 2 },
    }), self.buffer, .{
        .indentation = 4,
        .highlighted_line = 92,
    });

    self.drawBottomBar(win.child(.{
        .y_off = win.height - 1,
        .height = .{ .limit = 1 },
    }));
}

fn styler(self: *@This(), style: zig.Style, begin: usize, end: usize) !void {
    try self.buffer.updateStyle(self.allocator, .{
        .begin = begin,
        .end = end,
        .style = .{
            .fg = switch (style.fg) {
                .ansi => |idx| .{ .index = idx },
                .rgb => |rgb| vaxis.Color.rgbFromUint(@intFromEnum(rgb)),
                .default => .default,
            },
            .bg = switch (style.fg) {
                .ansi => |idx| .{ .index = idx },
                .rgb => |rgb| vaxis.Color.rgbFromUint(@intFromEnum(rgb)),
                .default => .default,
            },
            .ul = switch (style.fg) {
                .ansi => |idx| .{ .index = idx },
                .rgb => |rgb| vaxis.Color.rgbFromUint(@intFromEnum(rgb)),
                .default => .default,
            },
            .ul_style = @enumFromInt(@intFromEnum(style.ul_style)),
            .bold = style.bold,
            .dim = style.dim,
            .italic = style.italic,
            .strikethrough = style.strikethrough,
        },
    });
}

pub fn updateContents(self: *@This(), content: Content) !void {
    try self.buffer.update(self.allocator, content);
    try self.buffer.content.append(self.allocator, 0);
    defer _ = self.buffer.content.pop();
    try zig.style(self.allocator, .zig, .{}, @ptrCast(self.buffer.content.items[0..content.bytes.len]), self, styler);
    try self.lsp.spawn(&self.scheduler);
    try self.lsp.open(.{
        .idx = 0,
        .uri = "file:///home/nix/dev/personal/spurdo/src/main.zig",
        .lang = "zig",
        .contents = self.buffer.content.items,
        .version = 1,
    });
}
