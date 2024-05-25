const std = @import("std");
const zignet = @import("zignet");
const vaxis = @import("vaxis");
const Lsp = @import("spurdo/Lsp.zig");
const log = std.log.scoped(.spurdo);

const CodeView = @import("spurdo/CodeView.zig");

pub const NativeHandle = zignet.protocol.Interface.NativeHandle;

const ZigNet = zignet.ZigNet(&.{
    Lsp.ConsumerQueue,
}, .{});

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

pub const Content = CodeView.Content;

allocator: std.mem.Allocator,
net: ZigNet,
lsp: Lsp = .{},
code: CodeView = .{},

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .allocator = allocator,
        .net = try ZigNet.init(allocator),
    };
}

pub fn deinit(self: *@This()) void {
    self.net.deinit();
    self.lsp.deinit();
    self.* = undefined;
}

pub fn run(self: *@This()) !void {
    try self.net.open(&self.lsp.consumer, .{});
    try self.lsp.start();
}

pub fn input(self: *@This(), key: vaxis.Key) !void {
    try self.code.input(key);
}

pub fn update(self: *@This()) !void {
    if (try self.net.read(0)) |output| switch (output) {
        .lsp_consumer => |ev| switch (ev.what) {
            .lsp_initialized => {
                try self.lsp.open(.zig, "file:///home/nix/dev/personal/spurdo/src/main.zig", self.code.contents.items, 1);
            },
        },
    };
}

pub fn draw(self: *@This(), win: vaxis.Window) void {
    self.code.draw(win);
}

pub fn updateContents(self: *@This(), content: Content) !void {
    try self.code.updateContents(self.allocator, content);
    try self.lsp.spawn(content.lang);
}
