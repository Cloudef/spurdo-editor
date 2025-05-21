const std = @import("std");
const log = std.log.scoped(.lsp);

// Generated message structs
pub const msg = @import("lsp-generated").types;
const JsonRPCMessage = @import("lsp-generated").JsonRPCMessage;

pub const BufferSize = 16384;

const PackedID = packed struct(u64) {
    const Parity = 0b00000_00000_10101_01010_10101;
    method: Method,
    sub_id: u32,
    parity: u25 = Parity,
};

const ID = union(enum) {
    number: i64,
    string: []const u8,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!ID {
        switch (try source.peekNextTokenType()) {
            .number => return .{ .number = try std.json.innerParse(i64, allocator, source, options) },
            .string => return .{ .string = try std.json.innerParse([]const u8, allocator, source, options) },
            else => return error.SyntaxError,
        }
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!ID {
        _ = allocator;
        _ = options;
        switch (source) {
            .integer => |number| return .{ .number = number },
            .string => |string| return .{ .string = string },
            else => return error.UnexpectedToken,
        }
    }

    pub fn jsonStringify(self: @This(), stream: anytype) @TypeOf(stream.*).Error!void {
        switch (self) {
            inline else => |value| try stream.write(value),
        }
    }

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .number => |number| try writer.print("{d}", .{number}),
            .string => |str| try writer.writeAll(str),
        }
    }
};

const MethodType = enum {
    request,
    notification,
};

pub const Method = blk: {
    var fields: []const std.builtin.Type.EnumField = &.{};
    for (msg.request_metadata, 0..) |meta, idx| {
        fields = fields ++ .{std.builtin.Type.EnumField{
            .name = meta.method ++ "",
            .value = idx,
        }};
    }
    for (msg.notification_metadata, 0..) |meta, idx| {
        fields = fields ++ .{std.builtin.Type.EnumField{
            .name = meta.method ++ "",
            .value = msg.request_metadata.len + idx,
        }};
    }
    break :blk @Type(.{
        .@"enum" = .{
            .tag_type = std.math.IntFittingRange(0, fields.len),
            .fields = fields,
            .decls = &.{},
            .is_exhaustive = true,
        },
    });
};

fn MethodParams(comptime method: Method) type {
    for (msg.request_metadata, 0..) |meta, idx| {
        if (idx == @intFromEnum(method)) {
            return meta.Params orelse struct {};
        }
    }
    for (msg.notification_metadata, 0..) |meta, idx| {
        if (msg.request_metadata.len + idx == @intFromEnum(method)) {
            return meta.Params orelse struct {};
        }
    }
    unreachable;
}

fn MethodResult(comptime method: Method) type {
    if (comptime methodType(method) == .notification) return MethodParams(method);
    for (msg.request_metadata, 0..) |meta, idx| {
        if (idx == @intFromEnum(method)) {
            if (meta.Result == void or meta.Result == ?void) return struct {};
            return meta.Result;
        }
    }
    unreachable;
}

fn MethodPartialResult(comptime method: Method) type {
    for (msg.request_metadata, 0..) |meta, idx| {
        if (idx == @intFromEnum(method)) {
            return meta.PartialResult;
        }
    }
    unreachable;
}

fn methodDirection(comptime method: Method) msg.MessageDirection {
    for (msg.request_metadata, 0..) |meta, idx| {
        if (idx == @intFromEnum(method)) {
            return meta.direction;
        }
    }
    for (msg.notification_metadata, 0..) |meta, idx| {
        if (msg.request_metadata.len + idx == @intFromEnum(method)) {
            return meta.direction;
        }
    }
    unreachable;
}

fn methodType(method: Method) MethodType {
    if (@intFromEnum(method) >= msg.request_metadata.len)
        return .notification;
    return .request;
}

// Use this instead of lsp.Message.Response, this does not use json.Value for the result field.
// Not using json.Value can save memory allocations when using std.json.parse functions.
fn RequestResponse(Result: type) type {
    return struct {
        result: Result,
    };
}

pub const Error = struct {
    code: JsonRPCMessage.Response.Error.Code,
    message: []const u8,
};

fn RequestResponseFull(Result: type) type {
    return struct {
        jsonrpc: []const u8 = "2.0",
        id: ID,
        result: Result,
        @"error": ?Error,
    };
}

fn NotificationResponse(Params: type) type {
    return struct {
        params: Params,
    };
}

fn Request(Params: type) type {
    return struct {
        jsonrpc: []const u8 = "2.0",
        id: ID,
        method: Method,
        params: Params,
    };
}

fn Notification(Params: type) type {
    return struct {
        jsonrpc: []const u8 = "2.0",
        method: Method,
        params: Params,
    };
}

pub const Parser = struct {
    const ContentType = enum {
        @"application/vscode-jsonrpc; charset=utf-8",
        @"application/vscode-jsonrpc; charset=utf8",
    };

    const Header = struct {
        off: usize = 0,
        content_length: usize = 0,
        content_type: ContentType = .@"application/vscode-jsonrpc; charset=utf-8",
    };

    const RpcHeader = struct {
        id: ?ID = null,
        method: ?Method = null,
        @"error": ?Error = null,
    };

    pub const Msg = struct {
        id: ID = .{ .number = 0 },
        type: union(enum) {
            response: Method,
            request: Method,
            notification: Method,
        },
    };

    bounded: std.BoundedArray(u8, BufferSize) = .{},
    header: ?Header = null,

    fn extractHeader(self: *@This()) !void {
        if (self.header != null) return;

        const off = blk: {
            if (self.header) |hdr| {
                break :blk hdr.off;
            } else if (std.mem.indexOfPos(u8, self.bounded.constSlice(), 0, "\r\n\r\n")) |pos| {
                break :blk pos + 4;
            } else return; // header not complete yet
        };

        self.header = blk: {
            var content_length: ?usize = null;
            var content_type: ContentType = .@"application/vscode-jsonrpc; charset=utf-8";
            var hdr_iter = std.mem.tokenizeSequence(u8, self.bounded.constSlice()[0 .. off - 4], "\r\n");
            while (hdr_iter.next()) |kv| {
                var kv_iter = std.mem.tokenizeSequence(u8, kv, ": ");
                const key = kv_iter.next() orelse return error.InvalidMsg1;
                const val = kv_iter.next() orelse return error.InvalidMsg2;
                if (std.ascii.eqlIgnoreCase(key, "content-length")) {
                    content_length = std.fmt.parseInt(usize, val, 10) catch return error.InvalidMsg3;
                } else if (std.ascii.eqlIgnoreCase(key, "content-type")) {
                    content_type = std.meta.stringToEnum(ContentType, val) orelse return error.UnsupportedContentType;
                }
            }
            break :blk .{
                .off = off,
                .content_length = content_length orelse return error.InvalidMsg4,
                .content_type = content_type,
            };
        };
    }

    pub fn push(self: *@This(), bytes: []const u8) !void {
        try self.bounded.appendSlice(bytes);
        try self.extractHeader();
    }

    pub fn peek(self: *@This()) !?Msg {
        const hdr = self.header orelse return null;

        if (self.bounded.len < hdr.off + hdr.content_length) {
            return null;
        }

        log.debug("<= {s}", .{self.bounded.constSlice()[hdr.off .. hdr.off + hdr.content_length]});

        var mem: [16]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&mem);
        @setEvalBranchQuota(5_000);
        var res = std.json.parseFromSliceLeaky(RpcHeader, fba.allocator(), self.bounded.constSlice()[hdr.off .. hdr.off + hdr.content_length], .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_if_needed,
        }) catch |err| {
            log.err("Failed to parse the RpcHeader", .{});
            return err;
        };

        if (res.@"error") |err| {
            log.err("<= {d}: {s}", .{ @intFromEnum(err.code), err.message });
            return error.LspError;
        }

        if (res.method) |method| {
            if (res.id) |id| return .{ .id = id, .type = .{ .request = method } };
            return .{ .type = .{ .notification = method } };
        } else if (res.id) |*id| {
            if (id.* != .number) return error.InvalidMsg;
            const pid: PackedID = @bitCast(id.number);
            if (pid.parity != PackedID.Parity) return error.InvalidMsg;
            return .{ .id = .{ .number = pid.sub_id }, .type = .{ .response = pid.method } };
        }

        return error.InvalidMsg;
    }

    pub fn parseRequest(self: *@This(), allocator: std.mem.Allocator, comptime method: Method) !MethodParams(method) {
        if (comptime methodDirection(method) == .client_to_server) @compileError("client method");
        if (comptime methodType(method) != .request) @compileError("not a request");
        const off: usize, const content_length: usize = .{ self.header.?.off, self.header.?.content_length };
        const res = std.json.parseFromSliceLeaky(NotificationResponse(MethodParams(method)), allocator, self.bounded.constSlice()[off .. off + content_length], .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.err("Failed to pop rpc request as `{s}`: {}", .{ @tagName(method), err });
            return error.InvalidMsg;
        };
        return res.params;
    }

    pub fn parseResponse(self: *@This(), allocator: std.mem.Allocator, comptime method: Method) !MethodResult(method) {
        if (comptime methodDirection(method) == .server_to_client) @compileError("server method");
        if (comptime methodType(method) != .request) @compileError("not a request");
        const off: usize, const content_length: usize = .{ self.header.?.off, self.header.?.content_length };
        const res = std.json.parseFromSliceLeaky(RequestResponse(MethodResult(method)), allocator, self.bounded.constSlice()[off .. off + content_length], .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.err("Failed to pop rpc response as `{s}`: {}", .{ @tagName(method), err });
            return error.InvalidMsg;
        };
        return res.result;
    }

    pub fn parseNotification(self: *@This(), allocator: std.mem.Allocator, comptime method: Method) !MethodResult(method) {
        if (comptime methodType(method) != .notification) @compileError("not a notification");
        const off: usize, const content_length: usize = .{ self.header.?.off, self.header.?.content_length };
        const res = std.json.parseFromSliceLeaky(NotificationResponse(MethodResult(method)), allocator, self.bounded.constSlice()[off .. off + content_length], .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.err("Failed to pop rpc notification as `{s}: {}`", .{ @tagName(method), err });
            return error.InvalidMsg;
        };
        return res.params;
    }

    pub fn pop(self: *@This()) void {
        const off: usize, const content_length: usize = .{ self.header.?.off, self.header.?.content_length };
        const end = content_length + off;
        std.mem.copyForwards(u8, self.bounded.slice()[0..], self.bounded.slice()[end..]);
        self.bounded.len -= @intCast(end);
        self.header = null;
        self.extractHeader() catch @panic("");
    }
};

fn serializeToWriterAny(strut: anytype, writer: anytype) !void {
    var noop_writer = std.io.countingWriter(std.io.null_writer);
    try std.json.stringify(strut, .{ .emit_null_optional_fields = false }, noop_writer.writer());
    var buffered = std.io.BufferedWriter(BufferSize, @TypeOf(writer)){ .unbuffered_writer = writer };
    try buffered.writer().print("Content-Length: {}\r\n\r\n", .{noop_writer.bytes_written});
    try std.json.stringify(strut, .{ .emit_null_optional_fields = false }, buffered.writer());
    try buffered.flush();
}

pub inline fn respond(id: ID, comptime method: Method, result: MethodResult(method), writer: anytype) !void {
    if (comptime methodDirection(method) == .client_to_server) @compileError("client method");
    if (comptime methodType(method) != .request) @compileError("not a request");
    try serializeToWriterAny(RequestResponseFull(MethodResult(method)){
        .id = id,
        .result = result,
        .@"error" = null,
    }, writer);
}

pub inline fn send(sub_id: u32, comptime method: Method, params: MethodParams(method), writer: anytype) !void {
    if (comptime methodDirection(method) == .server_to_client) @compileError("server method");
    if (comptime methodType(method) == .request) {
        try serializeToWriterAny(Request(MethodParams(method)){
            .id = .{ .number = @bitCast(PackedID{ .method = method, .sub_id = sub_id }) },
            .method = method,
            .params = params,
        }, writer);
    } else {
        try serializeToWriterAny(Notification(MethodParams(method)){
            .method = method,
            .params = params,
        }, writer);
    }
}
