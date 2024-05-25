const std = @import("std");

pub const NotifyOp = enum { read, write };

pub const NativeLoop = switch (@import("builtin").target.os.tag) {
    .linux => @import("ev/Linux.zig"),
    else => @compileError("unsupported os"),
};

pub const NativeHandle = NativeLoop.Handle;
