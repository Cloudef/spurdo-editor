const std = @import("std");
const Interface = @import("../protocol.zig").Interface;

pub fn Queue(comptime name: []const u8, comptime Msg: type, comptime max_messsages: usize) type {
    return struct {
        pub const Name = name;
        pub const Output = Msg;
        pub const WatchTag = enum { source };
        pub const OpenError = Interface.Error;

        ev: ?*Interface.NativeLoop = null,
        handle: Interface.NativeHandle = undefined,
        msgs: std.BoundedArray(Msg, max_messsages) = .{},
        mutex: std.Thread.Mutex = .{},

        pub fn open(self: *@This(), _: anytype, interface: Interface) OpenError!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.ev = interface.native();
            self.handle = try interface.createEventSource();
            errdefer interface.removeEventSource(self.handle);
            for (0..self.msgs.len) |_| _ = self.ev.?.notify(.write, self.handle);
            try interface.watch(self.handle, WatchTag.source);
        }

        pub fn close(self: *@This(), interface: Interface) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            interface.unwatch(self.handle);
            interface.removeEventSource(self.handle);
            self.ev = null;
            self.handle = undefined;
        }

        pub fn read(self: *@This(), _: Interface, _: WatchTag) ?Output {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.ev) |ev| _ = ev.notify(.read, self.handle);
            if (self.msgs.len == 0) return null;
            return self.msgs.pop();
        }

        pub fn write(self: *@This(), msg: Msg) !void {
            if (self.ev) |ev| {
                while (true) {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    self.msgs.insert(0, msg) catch continue;
                    _ = ev.notify(.write, self.handle);
                    break;
                }
            } else {
                self.mutex.lock();
                defer self.mutex.unlock();
                try self.msgs.insert(0, msg);
            }
        }
    };
}

pub fn Pipe(comptime name: []const u8, comptime buffer_size: usize, comptime ChildWriter: type) type {
    return struct {
        pub const Name = name;
        pub const WatchTag = enum { source };
        pub const OpenError = Interface.Error;

        pub const OpenOptions = struct {
            writer: ChildWriter,
        };

        ev: ?*Interface.NativeLoop = null,
        handle: Interface.NativeHandle = undefined,
        buffer: std.BoundedArray(u8, buffer_size) = .{},
        mutex: std.Thread.Mutex = .{},
        child_writer: ChildWriter = undefined,

        pub fn open(self: *@This(), opts: OpenOptions, interface: Interface) OpenError!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.child_writer = opts.writer;
            self.ev = interface.native();
            self.handle = try interface.createEventSource();
            errdefer interface.removeEventSource(self.handle);
            if (self.buffer.len > 0) _ = self.ev.?.notify(.write, self.handle);
            try interface.watch(self.handle, WatchTag.source);
        }

        pub fn close(self: *@This(), interface: Interface) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            interface.unwatch(self.handle);
            interface.removeEventSource(self.handle);
            self.ev = null;
            self.handle = undefined;
            self.child_writer = undefined;
        }

        pub fn read(self: *@This(), _: Interface, _: WatchTag) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.ev) |ev| _ = ev.notify(.read, self.handle);
            if (self.buffer.len > 0) {
                try self.child_writer.writeAll(self.buffer.constSlice());
                self.buffer.len = 0;
            }
        }

        pub fn write(self: *@This(), bytes: []const u8) !usize {
            if (self.ev) |ev| {
                while (true) {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    self.buffer.appendSlice(bytes) catch continue;
                    if (bytes.len > 0) _ = ev.notify(.write, self.handle);
                    break;
                }
            } else {
                self.mutex.lock();
                defer self.mutex.unlock();
                try self.buffer.appendSlice(bytes);
            }
            return bytes.len;
        }

        pub const Writer = std.io.GenericWriter(*@This(), error{Overflow}, write);

        pub fn writer(self: *@This()) Writer {
            return .{ .context = self };
        }
    };
}
