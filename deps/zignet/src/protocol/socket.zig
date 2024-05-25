const std = @import("std");
const Interface = @import("../protocol.zig").Interface;
const native = @import("socket/native.zig");

pub const Endpoint = native.EndPoint;
pub const Role = enum { server, client };

pub fn Writer(
    comptime Context: type,
    comptime WriteError: type,
    comptime writeFn: fn (context: Context, endpoint: ?Endpoint, bytes: []const u8) WriteError!usize,
) type {
    return struct {
        context: Context,
        pub const Error = WriteError;

        pub inline fn writeSocketData(self: @This(), endpoint: ?Endpoint, bytes: []const u8) Error!usize {
            return writeFn(self.context, endpoint, bytes);
        }

        pub inline fn write(self: @This(), bytes: []const u8) Error!usize {
            return writeFn(self.context, null, bytes);
        }
    };
}

pub fn Socket(comptime name: []const u8, comptime protocol: native.Protocol, comptime OutputWriter: type) type {
    return struct {
        pub const Name = name;
        pub const WatchTag = enum { socket };
        pub const WriteError = native.Socket.SendError;
        pub const Writer = std.io.GenericWriter(*@This(), WriteError, write);

        // On TCP this is just read window size, TCP stack fragments.
        // On UDP this is more important
        // http://ithare.com/64-network-dos-and-donts-for-game-engines-part-v-udp/
        pub const SafePayloadSize = if (protocol == .udp) 508 else 8192;

        pub const OpenOptions = struct {
            role: Role,
            host: []const u8,
            port: u16,
            output: OutputWriter,
        };

        socket: native.Socket = undefined,
        output: OutputWriter = undefined,

        pub fn watch(self: *@This(), interface: Interface) !void {
            try interface.watch(.{ .fd = self.socket.internal }, WatchTag.socket);
        }

        pub fn unwatch(self: *@This(), interface: Interface) void {
            interface.unwatch(.{ .fd = self.socket.internal });
        }

        pub fn open(self: *@This(), opts: OpenOptions, interface: Interface) !void {
            self.socket = switch (opts.role) {
                .server => blk: {
                    // TODO: determine address family based on options.host
                    var socket = try native.Socket.create(.ipv4, protocol);
                    errdefer socket.close();
                    try socket.bindToPort(opts.port);
                    break :blk socket;
                },
                .client => try native.connectToHost(std.heap.page_allocator, opts.host, opts.port, protocol),
            };
            errdefer self.socket.close();
            try self.watch(interface);
        }

        pub fn close(self: *@This(), interface: Interface) void {
            self.unwatch(interface);
            self.socket.close();
            self.socket = undefined;
        }

        pub fn read(self: *@This(), _: Interface, _: WatchTag) !void {
            // The sender could in theory change in between so we need to peek as well before every read.
            // Since this is generic read function we don't know the length of the data.
            // For real application it's better to write another protocol that does not use this read function,
            // see protocol/znet.zig for example.
            var res: native.Socket.ReceiveFrom = .{ .numberOfBytes = 0, .sender = undefined };
            var window: [SafePayloadSize]u8 = undefined;
            while (true) {
                if (res.numberOfBytes > 0) {
                    var pbuf: [1]u8 = undefined;
                    const nres: native.Socket.ReceiveFrom = self.socket.peekFrom(&pbuf) catch |err| return switch (err) {
                        error.WouldBlock => {},
                        else => err,
                    };
                    // no more data or this is now data from different sender, if so read it later
                    if (nres.numberOfBytes == 0 or !std.meta.eql(nres.sender, res.sender)) break;
                }
                res = self.socket.receiveFrom(window[0..]) catch |err| return switch (err) {
                    error.WouldBlock => {},
                    else => err,
                };
                if (res.numberOfBytes == 0) break;
                if (@hasDecl(OutputWriter, "writeSocketData")) {
                    _ = try self.output.writeSocketData(res.sender, window[0..res.numberOfBytes]);
                } else {
                    _ = try self.output.writeAll(window[0..res.numberOfBytes]);
                }
            }
        }

        pub inline fn writeSocketData(self: *@This(), endpoint: ?Endpoint, data: []const u8) !usize {
            if (endpoint) |ep| {
                return try self.socket.sendTo(ep, data);
            } else {
                return try self.socket.send(data);
            }
        }

        pub inline fn write(self: *@This(), data: []const u8) !usize {
            try self.writeSocketData(null, data);
            return data.len;
        }

        pub fn writeAllSocketData(self: *@This(), endpoint: ?Endpoint, data: []const u8) !void {
            var written: usize, var n: usize = .{ 0, 0 };
            while (written < data.len) {
                const to_write = @min((data.len - written), written + SafePayloadSize);
                n = try self.writeSocketData(endpoint, data[written..to_write]);
                written += n;
            }
        }

        pub inline fn writeAll(self: *@This(), data: []const u8) !void {
            try self.writeAllSocketData(null, data);
        }

        pub fn writer(self: *@This()) @This().Writer {
            return .{ .context = self };
        }
    };
}
