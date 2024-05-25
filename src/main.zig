const std = @import("std");
const vaxis = @import("vaxis");
const Spurdo = @import("widgets/Spurdo.zig");
const log = std.log.scoped(.main);

pub const std_options: std.Options = .{
    .logFn = log_cb,
};

var global_mutex: std.Thread.Mutex = .{};
var global_log: std.ArrayList(u8) = std.ArrayList(u8).init(std.heap.page_allocator);

fn log_cb(comptime _: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    global_mutex.lock();
    defer global_mutex.unlock();
    global_log.writer().print(@tagName(scope) ++ ": " ++ format ++ "\n", args) catch {};
}

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tty = try vaxis.Tty.init();
    defer tty.deinit();

    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, tty.anyWriter());
    try vx.queryTerminal(tty.anyWriter(), 1 * std.time.ns_per_s);

    var loop: vaxis.Loop(Event) = .{ .tty = &tty, .vaxis = &vx };
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.anyWriter());
    defer vx.exitAltScreen(tty.anyWriter()) catch {};

    var editor = try Spurdo.init(allocator);
    defer editor.deinit();
    try editor.run();

    try editor.updateContents(.{
        .lang = .zig,
        .bytes = @embedFile("main.zig"),
        .gd = &vx.unicode.grapheme_data,
    });

    var log_view = false;
    while (true) {
        const event = loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    break;
                } else if (key.matches('l', .{ .ctrl = true })) {
                    vx.queueRefresh();
                } else if (key.matches(vaxis.Key.f12, .{})) {
                    log_view = !log_view;
                } else {
                    if (!log_view) {
                        try editor.input(key);
                    } else {}
                }
            },
            .winsize => |ws| try vx.resize(allocator, tty.anyWriter(), ws),
        }

        const root = vx.window();
        root.clear();

        try editor.update();
        editor.draw(root);

        if (log_view) {
            const child = root.child(.{
                .x_off = 1,
                .y_off = 1,
                .width = .{ .limit = root.width - 2 },
                .height = .{ .limit = root.height - 2 },
                .border = .{ .where = .all, .style = .{ .fg = .{ .index = 1 } } },
            });
            child.clear();
            child.hideCursor();
            _ = child.print(&.{.{ .text = global_log.items }}, .{ .wrap = .grapheme }) catch {};
        }

        try vx.render(tty.anyWriter());
    }
}
