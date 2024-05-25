pub const Queue = @import("protocol/sync.zig").Queue;
pub const Pipe = @import("protocol/sync.zig").Pipe;
pub const Process = @import("protocol/process.zig").Process;
pub const socket = @import("protocol/socket.zig");
pub const Socket = @import("protocol/socket.zig").Socket;

pub const Interface = struct {
    pub const NativeLoop = @import("ev.zig").NativeLoop;
    pub const NativeHandle = @import("ev.zig").NativeHandle;
    pub const NotifyOp = @import("ev.zig").NotifyOp;

    pub const Error = error{
        SystemResources,
        Unexpected,
    };

    ctx: *anyopaque,
    vtable: struct {
        createEventSource: *const fn (ctx: *anyopaque) Error!NativeHandle,
        removeEventSource: *const fn (ctx: *anyopaque, handle: NativeHandle) void,
        notify: *const fn (ctx: *anyopaque, op: NotifyOp, handle: NativeHandle) void,
        watch: *const fn (ctx: *anyopaque, handle: NativeHandle, tag: u8) Error!void,
        unwatch: *const fn (ctx: *anyopaque, handle: NativeHandle) void,
        native: *const fn (ctx: *anyopaque) *NativeLoop,
    },

    pub inline fn createEventSource(self: @This()) Error!NativeHandle {
        return self.vtable.createEventSource(self.ctx);
    }

    pub inline fn removeEventSource(self: @This(), handle: NativeHandle) void {
        self.vtable.removeEventSource(self.ctx, handle);
    }

    pub inline fn notify(self: @This(), op: NotifyOp, handle: NativeHandle) void {
        try self.vtable.notify(self.ctx, op, handle);
    }

    pub inline fn watch(self: @This(), handle: NativeHandle, tag: anytype) Error!void {
        try self.vtable.watch(self.ctx, handle, @intFromEnum(tag));
    }

    pub inline fn unwatch(self: @This(), handle: NativeHandle) void {
        self.vtable.unwatch(self.ctx, handle);
    }

    pub inline fn native(self: @This()) *NativeLoop {
        return self.vtable.native(self.ctx);
    }
};
