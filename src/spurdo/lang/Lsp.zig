const std = @import("std");
const ztd = @import("ztd");
const aio = @import("aio");
const coro = @import("coro");
const rpc = @import("lsp/rpc.zig");
const Engine = @import("lsp/Engine.zig");
const log = std.log.scoped(.lsp);

allocator: std.mem.Allocator,
lang: []const u8,
engine: Engine,
child: ?std.process.Child = null,
pipe: std.ArrayListUnmanaged(u8) = .{},
watchdog_task: ?coro.Task.Generic2(watchdog) = null,
stdout_write_task: ?coro.Task.Generic2(stdoutWrite) = null,
stdout_read_task: ?coro.Task.Generic2(stdoutRead) = null,
stderr_task: ?coro.Task.Generic2(stderr) = null,
exit: bool = false,

const Yield = enum {
    no_state,
    init,
    pipe,
};

pub fn init(allocator: std.mem.Allocator, lang: []const u8) @This() {
    return .{
        .allocator = allocator,
        .engine = Engine.init(allocator),
        .lang = lang,
    };
}

pub fn deinit(self: *@This()) void {
    self.exit = true;
    if (self.watchdog_task) |task| task.cancel();
    if (self.stdout_write_task) |task| task.cancel();
    if (self.stdout_read_task) |task| task.cancel();
    if (self.stderr_task) |task| task.cancel();
    if (self.child) |*child| cleanChild(child);
    self.engine.deinit();
    self.pipe.deinit(self.allocator);
    self.* = undefined;
}

fn stdoutRead(self: *@This()) !void {
    defer log.debug("stdoutRead: {s}: bye", .{self.lang});
    while (!self.exit) {
        while (self.child == null) {
            try coro.io.single(.timeout, .{ .ns = std.time.ns_per_s });
        }
        var buf: [rpc.BufferSize]u8 = undefined;
        var len: usize = 0;
        child: while (self.child) |*child| {
            self.engine.push(buf[0..len]) catch |err| {
                log.err("stdoutRead: {s}: {}", .{ self.lang, err });
                break :child;
            };
            while (self.engine.pop(child.stdin.?.writer()) catch |err| {
                // error occured, synchronize with writer and restart communication
                log.err("stdoutRead: {s}: {}", .{ self.lang, err });
                self.stdout_write_task.?.wakeupIf(Yield.init);
                break :child;
            }) |out| switch (out) {
                .initialized => self.stdout_write_task.?.wakeupIf(Yield.init),
                .semantic_tokens => {},
                .nop => {},
            };
            coro.io.single(.read, .{ .file = child.stdout.?, .buffer = &buf, .out_read = &len }) catch |err| {
                log.err("stdoutRead: {s}: {}", .{ self.lang, err });
                break :child;
            };
        }
        log.warn("stdoutRead: {s}: communication with child lost", .{self.lang});
    }
}

fn stdoutWrite(self: *@This()) !void {
    defer log.debug("stdoutWrite: {s}: bye", .{self.lang});
    while (!self.exit) {
        while (self.child == null) {
            try coro.io.single(.timeout, .{ .ns = std.time.ns_per_s });
        }
        if (self.child) |*child| {
            self.engine.initialize(child.stdin.?.writer()) catch continue;
        } else continue;
        // wait until lsp is initialized
        try coro.yield(Yield.init);
        while (self.child) |*child| {
            defer self.pipe.clearRetainingCapacity();
            child.stdin.?.writeAll(self.pipe.items) catch |err| {
                log.err("stdoutWrite: {s}: {}", .{ self.lang, err });
                break;
            };
            try coro.yield(Yield.pipe);
        }
        log.warn("stdoutWrite: {s}: communication with child lost", .{self.lang});
    }
}

fn stderr(self: *@This()) !void {
    defer log.debug("stderr: {s}: bye", .{self.lang});
    while (!self.exit) {
        while (self.child == null) {
            try coro.io.single(.timeout, .{ .ns = std.time.ns_per_s });
        }
        var logger = ztd.io.newlineLogger(4096, log.info);
        var buf: [4096]u8 = undefined;
        var len: usize = undefined;
        while (self.child) |*child| {
            coro.io.single(.read, .{ .file = child.stderr.?, .buffer = &buf, .out_read = &len }) catch |err| {
                log.err("stderr: {s}: {}", .{ self.lang, err });
                break;
            };
            _ = logger.write(buf[0..len]) catch continue;
        }
        log.warn("stderr: {s}: communication with child lost", .{self.lang});
    }
}

fn cleanChild(child: *std.process.Child) void {
    // annoying that we need this function, but std.process.Child only has wait and kill
    // we can't use neither because aio.ChildExit already does the waitid, and std considers
    // ECHILD as race condition leading to a unreachable
    // child.cleanup() or something would be nice in std
    if (child.stdin) |s| s.close();
    if (child.stdout) |s| s.close();
    if (child.stderr) |s| s.close();
}

fn watchdog(self: *@This()) !void {
    defer self.watchdog_task = null;
    defer log.debug("watchdog: {s}: bye", .{self.lang});
    while (!self.exit) {
        while (self.child) |*child| {
            coro.io.single(.child_exit, .{ .child = child.id }) catch {};
            break;
        }
        if (self.exit) break;
        if (self.child) |*child| {
            log.warn("watchdog: {s}: unexpected lsp process exit, restarting ...", .{self.lang});
            cleanChild(child);
        }
        self.child = null;
        // make tasks aware that the child is dead
        if (self.stdout_read_task) |task| task.signal();
        if (self.stdout_write_task) |task| task.signal();
        if (self.stderr_task) |task| task.signal();
        var child = std.process.Child.init(&.{ "nix", "run", "github:zigtools/zls" }, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        self.child = child;
    }
}

pub fn spawn(self: *@This(), scheduler: *coro.Scheduler) !void {
    if (self.exit) return;
    if (self.watchdog_task) |task| task.cancel();
    if (self.stdout_write_task) |task| task.cancel();
    if (self.stdout_read_task) |task| task.cancel();
    if (self.stderr_task) |task| task.cancel();
    self.watchdog_task = try scheduler.spawn(watchdog, .{self}, .{});
    self.stdout_write_task = try scheduler.spawn(stdoutWrite, .{self}, .{});
    self.stdout_read_task = try scheduler.spawn(stdoutRead, .{self}, .{});
    self.stderr_task = try scheduler.spawn(stderr, .{self}, .{});
}

pub fn db(self: *@This()) *Engine.Db {
    return &self.engine.db;
}

fn notifyPipe(self: *@This()) void {
    if (self.stdout_write_task) |task| task.wakeupIf(Yield.pipe);
}

pub fn open(self: *@This(), opts: Engine.OpenOptions) !void {
    try self.engine.open(opts, self.pipe.writer(self.allocator));
    self.notifyPipe();
}

pub fn didChange(self: *@This(), opts: Engine.DidChangeOptions) !void {
    try self.engine.didChange(opts, self.pipe.writer(self.allocator));
    self.notifyPipe();
}
