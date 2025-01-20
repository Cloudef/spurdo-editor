const std = @import("std");
const ztd = @import("ztd");
const aio = @import("aio");
const coro = @import("coro");
const vaxis = @import("vaxis");
const LoopWithModules = @import("vaxis-aio.zig").LoopWithModules;
const datetime = @import("datetime");
const Spurdo = @import("spurdo/Spurdo.zig");
const TextView = vaxis.widgets.TextView;
const log = std.log.scoped(.main);

pub const coro_options: coro.Options = .{
    // .debug = true,
};

pub const aio_options: aio.Options = .{
    // .debug = true,
    // .fallback = .force,
};

const VaxisLogWriter = struct {
    pub const Writer = std.io.GenericWriter(*@This(), TextView.Buffer.Error, write);
    allocator: std.mem.Allocator,
    vaxis: *vaxis.Vaxis,
    loop: *LoopWithModules(Event, aio, coro),
    buffer: TextView.Buffer = .{},
    last_time: ?std.time.Instant = null,

    pub fn write(self: *@This(), bytes: []const u8) !usize {
        try self.buffer.append(self.allocator, .{
            .bytes = bytes,
            .gd = &self.vaxis.unicode.width_data.g_data,
            .wd = &self.vaxis.unicode.width_data,
        });
        const now = std.time.Instant.now() catch unreachable;
        if (self.last_time == null or now.since(self.last_time.?) / std.time.ns_per_s > 0) {
            self.loop.postEvent(.log) catch {};
            self.last_time = now;
        }
        return bytes.len;
    }

    pub fn deinit(self: *@This()) void {
        self.buffer.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn writer(self: *@This()) Writer {
        return .{ .context = self };
    }
};

const GlobalLog = struct {
    var mutex: std.Thread.Mutex = .{};
    var writer: ?std.io.AnyWriter = null;
    var last_date: ?datetime.DateTime = null;

    pub fn log(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
        ztd.meta.comptimeError(@tagName(scope).len > 15, "increase max scope length: {s}", .{@tagName(scope)});
        mutex.lock();
        defer mutex.unlock();
        var w = writer orelse std.io.getStdErr().writer().any();
        // TODO: get local timezone from the system
        const now = datetime.DateTime.now().add(.{ .hours = 9 });
        if (last_date == null or !std.meta.eql(last_date.?.date, now.date)) {
            last_date = now;
            w.print("--- {rfc3339} ---\n", .{now.date}) catch {};
        }
        const sign = switch (level) {
            .debug => "D",
            .info => "I",
            .warn => "W",
            .err => "E",
        };
        w.print("{s} {d:0>2}:{d:0>2}> {s:15}: " ++ format ++ "\n", .{
            sign,
            now.time.hour,
            now.time.minute,
            @tagName(scope),
        } ++ args) catch {};
    }

    pub fn updateWriter(maybe_writer: ?std.io.AnyWriter) void {
        mutex.lock();
        defer mutex.unlock();
        writer = maybe_writer;
    }
};

pub const std_options: std.Options = .{
    .logFn = GlobalLog.log,
};

pub const panic = vaxis.panic_handler;

const Event = union(enum) {
    log: void,
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

    var scheduler = try coro.Scheduler.init(allocator, .{});
    defer scheduler.deinit();

    var loop = try LoopWithModules(Event, aio, coro).init();
    try loop.spawn(&scheduler, &vx, &tty, null, .{});
    defer loop.deinit(&vx, &tty);

    var log_writer: VaxisLogWriter = .{
        .allocator = allocator,
        .vaxis = &vx,
        .loop = &loop,
    };
    defer log_writer.deinit();

    _ = try log_writer.write(
        \\███████╗██████╗ ██╗   ██╗██████╗ ██████╗  ██████╗     ██╗      ██████╗  ██████╗
        \\██╔════╝██╔══██╗██║   ██║██╔══██╗██╔══██╗██╔═══██╗    ██║     ██╔═══██╗██╔════╝
        \\███████╗██████╔╝██║   ██║██████╔╝██║  ██║██║   ██║    ██║     ██║   ██║██║  ███╗
        \\╚════██║██╔═══╝ ██║   ██║██╔══██╗██║  ██║██║   ██║    ██║     ██║   ██║██║   ██║
        \\███████║██║     ╚██████╔╝██║  ██║██████╔╝╚██████╔╝    ███████╗╚██████╔╝╚██████╔╝
        \\╚══════╝╚═╝      ╚═════╝ ╚═╝  ╚═╝╚═════╝  ╚═════╝     ╚══════╝ ╚═════╝  ╚═════╝
        \\
    );

    GlobalLog.updateWriter(log_writer.writer().any());
    defer GlobalLog.updateWriter(null);

    try vx.enterAltScreen(tty.anyWriter());
    try vx.queryTerminalSend(tty.anyWriter());

    var editor = try Spurdo.init(allocator, &scheduler);
    defer editor.deinit();

    var log_viewer: TextView = .{};

    try editor.updateContents(.{
        .bytes = "lol\n" ++ @embedFile("main.zig"),
        .gd = &vx.unicode.width_data.g_data,
        .wd = &vx.unicode.width_data,
    });

    var log_view = false;
    var buffered_tty_writer = tty.bufferedWriter();
    main: while (true) {
        _ = try scheduler.tick(.blocking);

        while (try loop.popEvent()) |event| switch (event) {
            .log => {},
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    break :main;
                } else if (key.matches('l', .{ .ctrl = true })) {
                    vx.queueRefresh();
                } else if (key.matches(vaxis.Key.f12, .{})) {
                    log_view = !log_view;
                } else {
                    if (!log_view) {
                        try editor.input(key);
                    } else {
                        log_viewer.input(key);
                    }
                }
            },
            .winsize => |ws| try vx.resize(allocator, buffered_tty_writer.writer().any(), ws),
        };

        const root = vx.window();
        root.clear();

        editor.draw(root);

        if (log_view) {
            GlobalLog.mutex.lock();
            defer GlobalLog.mutex.unlock();
            const child = root.child(.{
                .x_off = 1,
                .y_off = 1,
                .width = root.width - 2,
                .height = root.height - 2,
                .border = .{ .where = .all, .style = .{ .fg = .{ .index = 1 } } },
            });
            child.clear();
            child.hideCursor();
            log_viewer.draw(child, log_writer.buffer);
        }

        try vx.render(buffered_tty_writer.writer().any());
        try buffered_tty_writer.flush();
    }
}
