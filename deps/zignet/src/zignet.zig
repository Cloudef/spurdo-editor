const std = @import("std");

/// Standard protocols.
pub const protocol = @import("protocol.zig");

/// Instance options.
pub const Options = struct {
    /// How many events are processed per read, increasing this may increase throughput.
    event_window: comptime_int = 64,
};

fn Resolve(proto: type, what: enum {
    type,
    open_options,
    open_rt,
    close_rt,
    read_rt,
}) type {
    if (@typeInfo(proto) != .Pointer) @compileError("zignet: `proto` must be a reference");
    const base = std.meta.Child(proto);
    if (@typeInfo(base) == .Pointer) @compileError("zignet: `proto` must be a reference to a value");
    return switch (what) {
        .type => base,
        .open_options => if (@hasDecl(base, "OpenOptions")) base.OpenOptions else struct {},
        .open_rt => @typeInfo(@TypeOf(base.open)).Fn.return_type.?,
        .close_rt => @typeInfo(@TypeOf(base.close)).Fn.return_type.?,
        .read_rt => @typeInfo(@TypeOf(base.read)).Fn.return_type.?,
    };
}

fn resolveName(comptime T: type) [:0]const u8 {
    const full = if (@hasDecl(T, "Name")) T.Name else @typeName(T);
    var iter = std.mem.splitBackwards(u8, full, ".");
    return iter.first() ++ "";
}

pub fn logError(log: anytype, tag: []const u8, proto: anytype, err: anyerror) void {
    log.err("{s}: ({x}): {}", .{ tag, @intFromPtr(proto), err });
}

pub fn ZigNet(comptime Protocols: []const type, comptime zignet_options: Options) type {
    const NativeLoop = protocol.Interface.NativeLoop;
    const NativeHandle = protocol.Interface.NativeHandle;
    const NotifyOp = protocol.Interface.NotifyOp;

    const ProtocolKind = blk: {
        comptime var enum_fields: [Protocols.len]std.builtin.Type.EnumField = undefined;
        inline for (Protocols, &enum_fields, 0..) |Proto, *field, index| {
            field.name = resolveName(Proto);
            field.value = index;
        }
        break :blk @Type(.{
            .Enum = .{
                .tag_type = std.math.IntFittingRange(0, Protocols.len),
                .fields = &enum_fields,
                .decls = &.{},
                .is_exhaustive = true,
            },
        });
    };

    const Source = packed struct {
        proto: *anyopaque,
        kind: ProtocolKind,
        watch: u8,
    };

    const NativeHandleToSource = std.AutoHashMap(NativeHandle, Source);

    const CombinedOutput = blk: {
        comptime var num_out = 0;
        inline for (Protocols) |Proto| {
            if (@hasDecl(Proto, "Output") or @typeInfo(Resolve(*Proto, .read_rt)) == .ErrorUnion) {
                num_out += 1;
            }
        }
        comptime var i = 0;
        comptime var enum_fields: [num_out]std.builtin.Type.EnumField = undefined;
        inline for (Protocols) |Proto| {
            if (@hasDecl(Proto, "Output") or @typeInfo(Resolve(*Proto, .read_rt)) == .ErrorUnion) {
                var field = &enum_fields[i];
                field.name = resolveName(Proto);
                field.value = i;
                i += 1;
            }
        }
        const OutputKind = @Type(.{
            .Enum = .{
                .tag_type = std.math.IntFittingRange(0, num_out),
                .fields = &enum_fields,
                .decls = &.{},
                .is_exhaustive = true,
            },
        });
        i = 0;
        comptime var union_fields: [num_out]std.builtin.Type.UnionField = undefined;
        inline for (Protocols) |Proto| {
            comptime var Output = if (@hasDecl(Proto, "Output")) Proto.Output else union(enum) {};
            if (@typeInfo(Resolve(*Proto, .read_rt)) == .ErrorUnion) {
                Output = @Type(.{
                    .Union = .{
                        .layout = .auto,
                        .tag_type = @Type(.{
                            .Enum = .{
                                .tag_type = std.math.IntFittingRange(0, std.meta.fields(Output).len + 1),
                                .fields = std.meta.fields(@typeInfo(Output).Union.tag_type.?) ++ .{
                                    .{
                                        .name = "error",
                                        .value = std.meta.fields(Output).len,
                                    },
                                },
                                .decls = &.{},
                                .is_exhaustive = true,
                            },
                        }),
                        .fields = std.meta.fields(Output) ++ .{.{
                            .name = "error",
                            .type = anyerror,
                            .alignment = 0,
                        }},
                        .decls = &.{},
                    },
                });
            }
            var field = &union_fields[i];
            field.name = resolveName(Proto);
            field.type = struct {
                proto: *Proto,
                what: Output,
            };
            field.alignment = 0;
            i += 1;
        }
        break :blk @Type(.{
            .Union = .{
                .layout = .auto,
                .tag_type = OutputKind,
                .fields = &union_fields,
                .decls = &.{},
            },
        });
    };

    const Impl = struct {
        proto: *anyopaque,
        kind: ProtocolKind,
        ev: *NativeLoop,
        ev_map: *NativeHandleToSource,

        fn init(net: anytype, proto: *anyopaque, kind: ProtocolKind) @This() {
            return .{
                .proto = proto,
                .kind = kind,
                .ev = &net.ev,
                .ev_map = &net.ev_map,
            };
        }

        fn createEventSource(ctx: *anyopaque) protocol.Interface.Error!NativeHandle {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.ev.createEventSource() catch |err| switch (err) {
                error.ProcessFdQuotaExceeded => error.SystemResources,
                error.SystemFdQuotaExceeded => error.SystemResources,
                error.SystemResources => error.SystemResources,
                error.Unexpected => error.Unexpected,
            };
        }

        fn removeEventSource(ctx: *anyopaque, handle: NativeHandle) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ev.removeEventSource(handle);
        }

        fn notify(ctx: *anyopaque, op: NotifyOp, handle: NativeHandle) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.ev.notify(op, handle);
        }

        fn watch(ctx: *anyopaque, handle: NativeHandle, tag: u8) protocol.Interface.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ev_map.putNoClobber(handle, .{ .proto = self.proto, .kind = self.kind, .watch = tag }) catch return error.SystemResources;
            errdefer _ = self.ev_map.remove(handle);
            return self.ev.watch(handle) catch |err| switch (err) {
                error.SystemResources => error.SystemResources,
                error.UserResourceLimitReached => error.SystemResources,
                error.FileDescriptorAlreadyPresentInSet => unreachable,
                error.OperationCausesCircularLoop => unreachable,
                error.FileDescriptorIncompatibleWithEpoll => unreachable,
                error.FileDescriptorNotRegistered => unreachable,
                error.Unexpected => error.Unexpected,
            };
        }

        fn unwatch(ctx: *anyopaque, handle: NativeHandle) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.ev_map.remove(handle);
            self.ev.unwatch(handle);
        }

        fn native(ctx: *anyopaque) *NativeLoop {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.ev;
        }

        inline fn vtable(self: *@This()) protocol.Interface {
            return .{
                .ctx = @ptrCast(self),
                .vtable = .{
                    .createEventSource = createEventSource,
                    .removeEventSource = removeEventSource,
                    .notify = notify,
                    .watch = watch,
                    .unwatch = unwatch,
                    .native = native,
                },
            };
        }
    };

    return struct {
        pub const Output = CombinedOutput;
        pub const Kind = ProtocolKind;
        pub const ReadError = NativeLoop.WaitError;

        ev: NativeLoop,
        ev_map: NativeHandleToSource,
        ev_window: std.BoundedArray(Source, zignet_options.event_window - 1) = .{},

        inline fn assertProto(proto: anytype) void {
            comptime var found = false;
            inline for (Protocols) |Protocol| {
                if (Resolve(@TypeOf(proto), .type) == Protocol) found = true;
            }
            if (!found) @compileError("zignet: type of `proto` is not listed in `Protocols`");
        }

        /// Intializes ZigNet instance.
        /// `allocator` is required to map native handles to protocol instances.
        pub fn init(allocator: std.mem.Allocator) !@This() {
            return .{
                .ev = try NativeLoop.init(),
                .ev_map = NativeHandleToSource.init(allocator),
            };
        }

        /// Deinitialize ZigNet instance.
        pub fn deinit(self: *@This()) void {
            outer: while (self.ev_map.count() > 0) {
                var iter = self.ev_map.iterator();
                while (iter.next()) |kv| {
                    inline for (Protocols, 0..) |Proto, index| {
                        if (@intFromEnum(kv.value_ptr.kind) == index) {
                            var interface = Impl.init(self, kv.value_ptr.proto, kv.value_ptr.kind);
                            const proto: *Proto = @ptrCast(@alignCast(kv.value_ptr.proto));
                            proto.close(interface.vtable());
                            continue :outer;
                        }
                    }
                }
            }
            self.ev.deinit();
            self.* = undefined;
        }

        fn kindFromProto(proto: anytype) Kind {
            inline for (Protocols, 0..) |Proto, index| {
                if (Resolve(@TypeOf(proto), .type) == Proto) {
                    return @enumFromInt(index);
                }
            }
            unreachable;
        }

        /// Open a connection to an host or start listening for connections.
        /// Blocks trying to open the connection immediately, returns error on failure.
        pub fn open(self: *@This(), proto: anytype, options: Resolve(@TypeOf(proto), .open_options)) Resolve(@TypeOf(proto), .open_rt) {
            assertProto(proto);
            var interface = Impl.init(self, proto, kindFromProto(proto));
            return proto.open(options, interface.vtable());
        }

        /// Close connection.
        pub fn close(self: *@This(), proto: anytype) Resolve(@TypeOf(proto), .close_rt) {
            assertProto(proto);
            var interface = Impl.init(self, proto, kindFromProto(proto));
            return proto.close(interface.vtable());
        }

        fn readFromSource(self: *@This(), source: Source) ?Output {
            inline for (Protocols, 0..) |Proto, index| {
                if (@intFromEnum(source.kind) == index) {
                    const proto: *Proto = @ptrCast(@alignCast(source.proto));
                    const msg = blk: {
                        var interface = Impl.init(self, source.proto, source.kind);
                        if (@typeInfo(Resolve(*Proto, .read_rt)) == .ErrorUnion) {
                            if (@typeInfo(@typeInfo(Resolve(*Proto, .read_rt)).ErrorUnion.payload) == .Optional) {
                                const opt = Proto.read(proto, interface.vtable(), @enumFromInt(source.watch)) catch |err| {
                                    const out = .{ .proto = proto, .what = .{ .@"error" = err } };
                                    return @unionInit(Output, resolveName(Proto), out);
                                };
                                break :blk opt orelse return null;
                            } else if (@typeInfo(Resolve(*Proto, .read_rt)).ErrorUnion.payload == void) {
                                Proto.read(proto, interface.vtable(), @enumFromInt(source.watch)) catch |err| {
                                    const out = .{ .proto = proto, .what = .{ .@"error" = err } };
                                    return @unionInit(Output, resolveName(Proto), out);
                                };
                                return null;
                            } else {
                                break :blk Proto.read(proto, interface.vtable(), @enumFromInt(source.watch)) catch |err| {
                                    const out = .{ .proto = proto, .what = .{ .@"error" = err } };
                                    return @unionInit(Output, resolveName(Proto), out);
                                };
                            }
                        } else {
                            if (@typeInfo(Resolve(*Proto, .read_rt)) == .Optional) {
                                const opt = Proto.read(proto, interface.vtable(), @enumFromInt(source.watch));
                                break :blk opt orelse return null;
                            } else if (Resolve(*Proto, .read_rt) == void) {
                                Proto.read(proto, interface.vtable(), @enumFromInt(source.watch)) catch |err| {
                                    const out = .{ .proto = proto, .what = .{ .@"error" = err } };
                                    return @unionInit(Output, resolveName(Proto), out);
                                };
                                return null;
                            } else {
                                break :blk Proto.read(proto, interface.vtable(), @enumFromInt(source.watch));
                            }
                        }
                    };
                    const tmp: Output = undefined;
                    const What = @TypeOf(@field(@field(tmp, resolveName(Proto)), "what"));
                    inline for (std.meta.fields(What), 0..) |field, i| {
                        if (i == @intFromEnum(std.meta.activeTag(msg))) {
                            const what = @unionInit(What, field.name, @field(msg, field.name));
                            return @unionInit(Output, resolveName(Proto), .{ .proto = proto, .what = what });
                        }
                    }
                }
            }
            unreachable;
        }

        /// Reads from every connection.
        /// `timeout` is in seconds, -1 blocks until there is output.
        /// If `timeout` is positive value and there is no output, then `null` is returned.
        pub fn read(self: *@This(), timeout: i32) ReadError!?Output {
            while (true) {
                while (self.ev_window.len > 0) {
                    if (self.readFromSource(self.ev_window.pop())) |ev| {
                        return ev;
                    }
                }
                var handles: [zignet_options.event_window]NativeHandle = undefined;
                const nevents = try self.ev.wait(timeout, handles.len, handles[0..]);
                var sources: [zignet_options.event_window - 1]Source = undefined;
                switch (nevents) {
                    0 => return null,
                    1 => {},
                    else => {
                        for (1..nevents) |i| sources[((nevents - 1) - i)] = self.ev_map.get(handles[i]).?;
                        self.ev_window.insertSlice(0, sources[0 .. nevents - 1]) catch unreachable;
                    },
                }
                if (self.readFromSource(self.ev_map.get(handles[0]).?)) |ev| {
                    return ev;
                }
            }
            unreachable;
        }
    };
}
