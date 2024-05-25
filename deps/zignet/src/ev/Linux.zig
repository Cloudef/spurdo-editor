const std = @import("std");
const ev = @import("../ev.zig");

pub const WaitError = error{};

pub const Handle = packed struct {
    fd: i32,
    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("!fd|{}", .{self.fd});
    }
};

epoll: std.os.linux.fd_t,

fn ectl(epoll: std.os.linux.fd_t, add: bool, fd: std.os.linux.fd_t) !void {
    var event: std.os.linux.epoll_event = .{ .events = std.os.linux.EPOLL.IN, .data = .{ .fd = fd } };
    try std.posix.epoll_ctl(epoll, if (add) std.os.linux.EPOLL.CTL_ADD else std.os.linux.EPOLL.CTL_DEL, fd, &event);
}

pub fn init() !@This() {
    const epoll = try std.posix.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
    return .{ .epoll = epoll };
}

pub fn deinit(self: *@This()) void {
    std.posix.close(self.epoll);
    self.* = undefined;
}

pub fn nativeHandle(self: *const @This()) Handle {
    return .{ .fd = self.epoll };
}

pub fn watch(self: *@This(), handle: Handle) !void {
    try ectl(self.epoll, true, handle.fd);
}

pub fn unwatch(self: *@This(), handle: Handle) void {
    ectl(self.epoll, false, handle.fd) catch unreachable;
}

pub fn wait(self: *@This(), timeout: i32, comptime window: u32, handles: *[window]Handle) WaitError!usize {
    var events: [window]std.os.linux.epoll_event = undefined;
    const nevents = std.os.linux.epoll_pwait(self.epoll, events[0..].ptr, window, timeout, null);
    for (events[0..nevents], 0..) |event, i| handles[i].fd = event.data.fd;
    return nevents;
}

pub fn createEventSource(_: *@This()) !Handle {
    const fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.SEMAPHORE);
    return .{ .fd = fd };
}

pub fn removeEventSource(_: *@This(), handle: Handle) void {
    std.posix.close(handle.fd);
}

pub fn notify(_: *@This(), op: ev.NotifyOp, handle: Handle) bool {
    var one: u64 = 1;
    _ = switch (op) {
        .write => std.posix.write(handle.fd, std.mem.asBytes(&one)),
        .read => std.posix.read(handle.fd, std.mem.asBytes(&one)),
    } catch |err| {
        return switch (err) {
            error.WouldBlock, error.NotOpenForWriting, error.NotOpenForReading => false,
            else => unreachable,
        };
    };
    return true;
}
