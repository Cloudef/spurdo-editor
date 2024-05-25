const std = @import("std");
const Interface = @import("../protocol.zig").Interface;

pub fn Process(comptime name: []const u8, comptime StdoutWriter: type, comptime StderrWriter: type) type {
    return struct {
        pub const Name = name;

        pub const OpenOptions = struct {
            argv: []const []const u8,
            stdout_writer: StdoutWriter,
            stderr_writer: StderrWriter,
            stdin: std.process.Child.StdIo = .Ignore,
        };

        pub const Output = union(enum) {
            close: void,
        };

        pub const WatchTag = enum {
            stdout,
            stderr,
        };

        pub const OpenError = Interface.Error || std.process.Child.SpawnError;
        pub const WriteError = std.fs.File.WriteError;
        pub const Writer = std.io.GenericWriter(*@This(), WriteError, write);

        proc: std.process.Child = undefined,
        status: u32 = 0,
        stdout: StdoutWriter = undefined,
        stderr: StderrWriter = undefined,

        pub fn open(self: *@This(), opts: OpenOptions, interface: Interface) OpenError!void {
            self.proc = std.process.Child.init(opts.argv, std.heap.page_allocator);
            self.stdout = opts.stdout_writer;
            self.stderr = opts.stderr_writer;
            self.proc.stdout_behavior = if (StdoutWriter != void) .Pipe else .Ignore;
            self.proc.stderr_behavior = if (StderrWriter != void) .Pipe else .Ignore;
            self.proc.stdin_behavior = opts.stdin;
            try self.proc.spawn();
            errdefer {
                _ = self.proc.kill() catch {};
                self.proc.id = 0;
            }
            if (self.proc.stdout) |stream| try interface.watch(.{ .fd = stream.handle }, WatchTag.stdout);
            errdefer if (self.proc.stdout) |stream| interface.unwatch(.{ .fd = stream.handle });
            if (self.proc.stderr) |stream| try interface.watch(.{ .fd = stream.handle }, WatchTag.stderr);
            errdefer if (self.proc.stderr) |stream| interface.unwatch(.{ .fd = stream.handle });
        }

        pub fn close(self: *@This(), interface: Interface) void {
            if (self.proc.stdout) |stream| interface.unwatch(.{ .fd = stream.handle });
            if (self.proc.stderr) |stream| interface.unwatch(.{ .fd = stream.handle });
            if (self.proc.id != 0) _ = self.proc.kill() catch {};
            self.proc.id = 0;
        }

        pub fn exitCode(self: @This()) void {
            std.debug.assert(self.proc.id == 0);
            return std.posix.W.EXITSTATUS(self.status);
        }

        fn poll(stream: std.fs.File) !bool {
            var pfd = [_]std.posix.pollfd{.{ .fd = stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const r = std.posix.poll(&pfd, 0) catch |err| return switch (err) {
                error.NetworkSubsystemFailed => unreachable,
                error.SystemResources => error.SystemResources,
                error.Unexpected => error.Unexpected,
            };
            return r == 1;
        }

        fn readNonblocking(stream: std.fs.File, buffer: []u8) !usize {
            return if (try poll(stream)) try stream.read(buffer) else 0;
        }

        pub fn read(self: *@This(), interface: Interface, tag: WatchTag) !?Output {
            const pid = try waitpid(self.proc.id, &self.status);
            if (pid == self.proc.id) {
                self.proc.id = 0;
                self.close(interface);
                return .close;
            }

            var res: usize = 0;
            var window: [4096]u8 = undefined;
            while (true) {
                res = switch (tag) {
                    .stdout => if (self.proc.stdout) |stream| try readNonblocking(stream, window[0..]) else 0,
                    .stderr => if (self.proc.stderr) |stream| try readNonblocking(stream, window[0..]) else 0,
                };
                if (res == 0) break;
                switch (tag) {
                    .stdout => if (StdoutWriter != void) try self.stdout.writeAll(window[0..res]),
                    .stderr => if (StderrWriter != void) try self.stderr.writeAll(window[0..res]),
                }
            }
            return null;
        }

        pub fn writeAll(self: *@This(), bytes: []const u8) WriteError!void {
            return self.proc.stdin.?.writeAll(bytes);
        }

        pub fn write(self: *@This(), bytes: []const u8) WriteError!usize {
            return self.proc.stdin.?.write(bytes);
        }

        fn waitpid(pid: std.process.Child.Id, status: *u32) !std.process.Child.Id {
            const ret = @as(std.process.Child.Id, @truncate(@as(isize, @bitCast(std.os.linux.waitpid(pid, status, std.os.linux.W.NOHANG)))));
            if (ret == -1) return error.WaitPidFailed;
            return ret;
        }

        pub fn writer(self: *@This()) Writer {
            return .{ .context = self };
        }
    };
}
