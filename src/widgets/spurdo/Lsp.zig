const std = @import("std");
const zignet = @import("zignet");
const common = @import("common.zig");
const log = std.log.scoped(.lsp);

pub const ConsumerQueue = zignet.protocol.Queue(
    "lsp_consumer",
    union(enum) {
        lsp_initialized: void,
    },
    32,
);

const LspQueue = zignet.protocol.Queue(
    "lsp_queue",
    union(enum) {
        quit: void,
        spawn: common.Language,
    },
    32,
);

const LspPipe = zignet.protocol.Pipe(
    "lsp_pipe",
    4096,
    std.io.GenericWriter(*@This(), anyerror, threadLspPipe),
);

const LspProc = zignet.protocol.Process(
    "lsp_proc",
    std.io.GenericWriter(*@This(), anyerror, threadLspMsg),
    std.io.GenericWriter(*@This(), anyerror, threadLspInfo),
);

const ZigNet = zignet.ZigNet(&.{
    // Serializes general commands to the LSP thread
    LspQueue,
    // Serializes JSON-RPC input to the LSP process
    LspPipe,
    // LSP Process
    LspProc,
}, .{});

fn encodeToWriter(msg: anytype, writer: anytype) !void {
    var noop_writer = std.io.countingWriter(std.io.null_writer);
    try std.json.stringify(msg, .{}, noop_writer.writer());
    try writer.print("Content-Length: {}\r\n\r\n", .{noop_writer.bytes_written});
    var buffered = std.io.bufferedWriter(writer);
    try std.json.stringify(msg, .{}, buffered.writer());
    try buffered.flush();
}

thread: ?std.Thread = null,
queue: LspQueue = .{},
pipe: LspPipe = .{},
consumer: ConsumerQueue = .{},

// Access only on the thread
proc: LspProc = .{},
net: ZigNet = undefined,
last_lang: common.Language = .none,

pub fn start(self: *@This()) !void {
    if (self.thread != null) return;
    self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
}

pub fn deinit(self: *@This()) void {
    self.queue.write(.quit) catch @panic("unrecovable");
    if (self.thread) |thrd| thrd.join();
    self.* = undefined;
}

pub fn spawn(self: *@This(), lang: common.Language) !void {
    try self.queue.write(.{ .spawn = lang });
}

pub fn open(self: *@This(), lang: common.Language, uri: []const u8, contents: []const u8, version: i64) !void {
    try encodeToWriter(.{
        .jsonrpc = "2.0",
        .method = "textDocument/didOpen",
        .params = .{
            .textDocument = .{
                .uri = uri,
                .languageId = lang,
                .version = version,
                .text = contents,
            },
        },
    }, self.pipe.writer());
    try encodeToWriter(.{
        .jsonrpc = "2.0",
        .id = MsgId.semantic_full,
        .method = "textDocument/semanticTokens/full",
        .params = .{
            .textDocument = .{
                .uri = "file:///home/nix/dev/personal/spurdo/src/main.zig",
            },
        },
    }, self.pipe.writer());
}

fn threadLspInfo(_: *@This(), bytes: []const u8) error{}!usize {
    const static = struct {
        var buffer: std.BoundedArray(u8, 4096) = .{};
    };
    static.buffer.appendSlice(bytes) catch {};
    if (std.mem.lastIndexOfScalar(u8, static.buffer.constSlice(), '\n')) |pos| {
        log.info("{s}", .{static.buffer.constSlice()[0..pos]});
        const left = static.buffer.len - (pos + 1);
        std.mem.copyBackwards(u8, static.buffer.slice()[0..left], static.buffer.slice()[pos + 1 ..]);
        static.buffer.len = @intCast(left);
    }
    return bytes.len;
}

fn threadLspPipe(self: *@This(), bytes: []const u8) anyerror!usize {
    log.debug("=> {s}", .{bytes});
    try self.proc.writeAll(bytes);
    return bytes.len;
}

fn threadLspMsg(self: *@This(), bytes: []const u8) anyerror!usize {
    const off = std.mem.indexOfPos(u8, bytes, 0, "\r\n\r\n") orelse return error.InvalidLspMsg;
    log.debug("<= {s}", .{bytes[off + 4 ..]});

    var mem: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&mem);
    const Id = struct { id: MsgId, @"error": ?Error = null };
    const hdr = try std.json.parseFromSliceLeaky(Id, fba.allocator(), bytes[off + 4 ..], .{
        .ignore_unknown_fields = true,
    });

    if (hdr.@"error") |err| {
        log.err("<= {d}: {s}", .{ @intFromEnum(err.code), err.message });
        return error.LspError;
    }

    switch (hdr.id) {
        .init => {
            const res = try std.json.parseFromSliceLeaky(Response(Initialization), fba.allocator(), bytes[off + 4 ..], .{
                .ignore_unknown_fields = true,
            });
            _ = res; // autofix
            try encodeToWriter(.{
                .jsonrpc = "2.0",
                .method = "initialized",
                .params = struct {}{},
            }, self.pipe.writer());
            try self.consumer.write(.lsp_initialized);
        },
        .shutdown => log.debug("shutdown ack", .{}),
        .semantic_full => {},
    }

    return bytes.len;
}

fn threadSpawnLsp(self: *@This(), lang: common.Language) !void {
    if (self.proc.proc.id != 0) self.net.close(&self.proc);
    self.last_lang = lang;
    try self.net.open(&self.proc, .{
        .argv = &.{ "nix", "run", "nixpkgs#zls" },
        .stdout_writer = .{ .context = self },
        .stderr_writer = .{ .context = self },
        .stdin = .Pipe,
    });
    errdefer self.net.close(&self.proc);
    try encodeToWriter(.{
        .jsonrpc = "2.0",
        .id = MsgId.init,
        .method = "initialize",
        .params = .{
            .processId = std.os.linux.getpid(),
            .clientInfo = .{
                .name = "spurdo :D",
                .version = "0.0.0",
            },
            .locale = "en-US",
            .rootPath = "/home/nix/dev/personal/spurdo",
            .capabilities = struct {}{},
        },
    }, self.pipe.writer());
}

fn threadHandleOutput(self: *@This(), output: ZigNet.Output) !void {
    switch (output) {
        .lsp_proc => |ev| switch (ev.what) {
            .@"error" => |err| zignet.logError(log, @tagName(output), ev.proto, err),
            .close => if (ev.proto == &self.proc) {
                log.warn("lsp closed unexpectedly", .{});
                try self.threadSpawnLsp(self.last_lang);
            },
        },
        .lsp_queue => |ev| switch (ev.what) {
            .quit => {
                if (self.proc.proc.id != 0) {
                    encodeToWriter(.{
                        .jsonrpc = "2.0",
                        .id = MsgId.shutdown,
                        .method = "shutdown",
                    }, self.pipe.writer()) catch {};
                    encodeToWriter(.{
                        .jsonrpc = "2.0",
                        .method = "exit",
                    }, self.pipe.writer()) catch {};
                }
                return error.LspThreadExit;
            },
            .spawn => |lang| try self.threadSpawnLsp(lang),
        },
        .lsp_pipe => |ev| switch (ev.what) {
            .@"error" => |err| zignet.logError(log, @tagName(output), ev.proto, err),
        },
    }
}

fn threadMain(self: *@This()) !void {
    self.thread.?.setName("spurdo-lsp :D") catch {};

    var mem: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&mem);
    self.net = try ZigNet.init(fba.allocator());
    defer {
        self.net.deinit();
        self.net = undefined;
    }

    try self.net.open(&self.queue, .{});

    try self.net.open(&self.pipe, .{
        .writer = .{ .context = self },
    });

    while (true) {
        if (self.net.read(-1) catch |err| {
            log.err("fatal error: {}", .{err});
            break;
        }) |output| {
            self.threadHandleOutput(output) catch |err| switch (err) {
                error.LspThreadExit => break,
                else => log.warn("{}", .{err}),
            };
        }
        std.Thread.yield() catch {};
    }
}

pub const Error = struct {
    code: Code,
    message: []const u8,

    /// The error codes from and including -32768 to -32000 are reserved for pre-defined errors. Any code within this range, but not defined explicitly below is reserved for future use.
    /// The remainder of the space is available for application defined errors.
    pub const Code = enum(i64) {
        /// Invalid JSON was received by the server. An error occurred on the server while parsing the JSON text.
        parse_error = -32700,
        /// The JSON sent is not a valid Request object.
        invalid_request = -32600,
        /// The method does not exist / is not available.
        method_not_found = -32601,
        /// Invalid method parameter(s).
        invalid_params = -32602,
        /// Internal JSON-RPC error.
        internal_error = -32603,

        /// -32000 to -32099 are reserved for implementation-defined server-errors.
        _,

        pub fn jsonStringify(code: Code, stream: anytype) @TypeOf(stream.*).Error!void {
            try stream.write(@intFromEnum(code));
        }
    };
};

const MsgId = enum(u8) {
    init,
    shutdown,
    semantic_full,
};

fn Response(Result: type) type {
    return struct {
        jsonrpc: []const u8,
        id: MsgId,
        result: Result = .{},
        @"error": ?Error = null,
    };
}

const Initialization = struct {
    const TextDocumentSync = struct {
        openClose: bool = false,
        change: i64 = 0,
        willSave: bool = false,
        willSaveWaitUntil: bool = false,
        save: bool = false,
    };
    const CompletionProvider = struct {
        triggerCharacters: []const []const u8 = &.{},
        resolveProvider: bool = false,
        completionItem: struct {
            labelDetailsSupport: bool = false,
        } = .{},
    };
    const SignatureHelpProvider = struct {
        triggerCharacters: []const []const u8 = &.{},
        retriggerCharacters: []const []const u8 = &.{},
    };
    const SemanticTokensProvider = struct {
        legend: struct {
            tokenTypes: ?[]const []const u8 = &.{},
            tokenModifiers: ?[]const []const u8 = &.{},
        } = .{},
        range: bool = false,
        full: bool = false,
    };
    const WorkspaceFolders = struct {
        supported: bool = false,
        changeNotifications: bool = false,
    };
    capabilities: struct {
        positionEncoding: enum {
            unsupported,
            @"utf-8",
            @"utf-16",
            @"utf-32",
        } = .unsupported,
        textDocumentSync: TextDocumentSync = .{},
        completionProvider: CompletionProvider = .{},
        hoverProvider: bool = false,
        signatureHelpProvider: SignatureHelpProvider = .{},
        declarationProvider: bool = false,
        definitionProvider: bool = false,
        typeDefinitionProvider: bool = false,
        implementationProvider: bool = false,
        referencesProvider: bool = false,
        documentHighlightProvider: bool = false,
        documentSymbolProvider: bool = false,
        codeActionProvider: bool = false,
        colorProvider: bool = false,
        workspaceSymbolProvider: bool = false,
        documentFormattingProvider: bool = false,
        documentRangeFormattingProvider: bool = false,
        renameProvider: bool = false,
        foldingRangeProvider: bool = false,
        selectionRangeProvider: bool = false,
        semanticTokensProvider: SemanticTokensProvider = .{},
        inlayHintProvider: bool = false,
        workspace: struct {
            workspaceFolders: WorkspaceFolders = .{},
        } = .{},
    } = .{},
    serverInfo: struct {
        name: []const u8 = "unknown",
        version: []const u8 = "0.0.0",
    } = .{},
};
