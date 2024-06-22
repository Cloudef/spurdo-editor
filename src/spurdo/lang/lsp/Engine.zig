const std = @import("std");
const ztd = @import("ztd");
const rpc = @import("rpc.zig");
const MemoryDB = @import("memory_db.zig").MemoryDB;
const log = std.log.scoped(.lsp);

const Range = struct { begin: u32, end: u32 };

pub const Db = MemoryDB(struct {
    semantic_tokens: struct {
        doc: Document.Index,
        delta_line: u32,
        delta_start_char: u32,
        length: u16,
        type: SemanticTokenType,
        modifiers: ztd.enums.BitfieldSet(SemanticModifierType),
    },
    diagnostics: struct {
        uri: []const u8,
        version: ?i32,
        line: Range,
        char: Range,
        severity: enum(u8) {
            err = 1,
            warn = 2,
            info = 3,
            hint = 4,
        },
        code: union(enum) {
            int: i32,
            str: []const u8,
        },
        message: []const u8,

        pub fn clone(old: @This(), allocator: std.mem.Allocator) !@This() {
            var new: @This() = old;
            new.uri = try allocator.dupe(u8, old.uri);
            errdefer allocator.free(new.uri);
            new.code = switch (new.code) {
                .int => old.code,
                .str => .{ .str = try allocator.dupe(u8, old.code.str) },
            };
            errdefer if (new.code == .str) allocator.free(new.code.str);
            new.message = try allocator.dupe(u8, old.message);
            errdefer allocator.free(new.message);
            return new;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.uri);
            if (self.code == .str) allocator.free(self.code.str);
            allocator.free(self.message);
            self.* = undefined;
        }
    },
});

const ServerParams = struct {
    name: []const u8 = "",
    version: []const u8 = "",
    semanticTokens: ztd.enums.BoundedEnumArray(SemanticTokenType) = .{},
    semanticModifiers: ztd.enums.BoundedEnumArray(SemanticModifierType) = .{},

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        self.* = undefined;
    }
};

allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator.State = .{},
parser: rpc.Parser = .{},
server: ServerParams = .{},
db: Db,

pub fn init(allocator: std.mem.Allocator) @This() {
    return .{ .allocator = allocator, .db = Db.init(allocator) };
}

pub fn deinit(self: *@This()) void {
    self.server.deinit(self.allocator);
    self.db.deinit();
    self.* = undefined;
}

pub fn exit(_: *@This(), writer: anytype) !void {
    try rpc.send(0, .exit, .{}, writer);
}

pub fn shutdown(_: *@This(), writer: anytype) !void {
    try rpc.send(0, .shutdown, .{}, writer);
}

pub const OpenOptions = struct {
    idx: Document.Index,
    lang: []const u8,
    uri: []const u8,
    contents: []const u8,
    version: i32,
};

pub fn open(_: *@This(), opts: OpenOptions, writer: anytype) !void {
    const id = Document.init(opts.idx, opts.uri);
    try rpc.send(@bitCast(id), .@"textDocument/didOpen", .{
        .textDocument = .{
            .uri = opts.uri,
            .languageId = .{ .custom_value = opts.lang },
            .version = opts.version,
            .text = opts.contents,
        },
    }, writer);
    try rpc.send(@bitCast(id), .@"textDocument/semanticTokens/full", .{
        .textDocument = .{ .uri = opts.uri },
    }, writer);
    try rpc.send(0, .@"workspace/symbol", .{
        .query = "",
    }, writer);
}

pub const DidChangeOptions = struct {
    idx: Document.Index,
    uri: []const u8,
    version: i32,
    contents: []const u8,
};

pub fn didChange(_: *@This(), opts: DidChangeOptions, writer: anytype) !void {
    const id = Document.init(opts.idx, opts.uri);
    try rpc.send(@bitCast(id), .@"textDocument/didChange", .{
        .textDocument = .{
            .uri = opts.uri,
            .version = opts.version,
        },
        .contentChanges = &.{
            .text = opts.contents,
        },
    }, writer);
}

pub const WillSaveOptions = struct {
    idx: Document.Index,
    uri: []const u8,
    reason: enum(u8) {
        manual = 1,
        after_delay = 2,
        focus_out = 3,
    },
};

pub fn willSave(_: *@This(), opts: WillSaveOptions, writer: anytype) !void {
    const id = Document.init(opts.idx, opts.uri);
    try rpc.send(@bitCast(id), .@"textDocument/willSave", .{
        .textDocument = .{ .uri = opts.uri },
        .reason = opts.reason,
    }, writer);
}

pub const DidSaveOptions = struct {
    idx: Document.Index,
    uri: []const u8,
    contents: []const u8,
};

pub fn didSave(_: *@This(), opts: DidSaveOptions, writer: anytype) !void {
    const id = Document.init(opts.idx, opts.uri);
    try rpc.send(@bitCast(id), .@"textDocument/didSave", .{
        .textDocument = .{ .uri = opts.uri },
        .text = opts.contents,
    }, writer);
}

pub const DidCloseOptions = struct {
    idx: Document.Index,
    uri: []const u8,
};

pub fn didClose(_: *@This(), opts: DidCloseOptions, writer: anytype) !void {
    const id = Document.init(opts.idx, opts.uri);
    try rpc.send(@bitCast(id), .@"textDocument/didClose", .{
        .textDocument = .{ .uri = opts.uri },
    }, writer);
}

pub fn push(self: *@This(), bytes: []const u8) !void {
    try self.parser.push(bytes);
}

pub const Output = union(enum) {
    nop: void,
    initialized: void,
    semantic_tokens: Document.Index,
};

pub fn pop(self: *@This(), writer: anytype) !?Output {
    var arena = self.arena.promote(self.allocator);
    defer _ = arena.reset(.retain_capacity);
    if (try self.parser.peek()) |rpc_msg| {
        defer self.parser.pop();
        switch (rpc_msg.type) {
            .response => |method| switch (method) {
                .initialize => {
                    {
                        self.server.deinit(self.allocator);
                        self.server = .{};
                        const res = try self.parser.parseResponse(arena.allocator(), .initialize);
                        if (res.serverInfo) |info| {
                            log.info("server: {s} ({s})", .{ info.name, info.version orelse "unknown" });
                            self.server.name = try self.allocator.dupe(u8, info.name);
                            if (info.version) |ver| self.server.version = try self.allocator.dupe(u8, ver);
                        }
                        if (res.capabilities.semanticTokensProvider) |provider| switch (provider) {
                            .SemanticTokensOptions => |opts| {
                                for (opts.legend.tokenTypes) |str| if (std.meta.stringToEnum(SemanticTokenType, str)) |e| {
                                    self.server.semanticTokens.append(e) catch {};
                                } else {
                                    self.server.semanticTokens.append(.unknown) catch {};
                                };
                                for (opts.legend.tokenModifiers) |str| if (std.meta.stringToEnum(SemanticModifierType, str)) |e| {
                                    self.server.semanticModifiers.append(e) catch {};
                                } else {
                                    self.server.semanticModifiers.append(.unknown) catch {};
                                };
                            },
                            else => {},
                        };
                    }
                    try rpc.send(0, .initialized, .{}, writer);
                    return .initialized;
                },
                .shutdown => {
                    log.debug("shutdown ack", .{});
                    rpc.send(0, .exit, .{}, writer) catch {};
                    return error.Shutdown;
                },
                .@"textDocument/semanticTokens/full" => {
                    const doc: Document = @bitCast(@as(u32, @intCast(rpc_msg.id.number)));
                    {
                        const res = try self.parser.parseResponse(arena.allocator(), .@"textDocument/semanticTokens/full");
                        if (res) |r| {
                            var iter = std.mem.window(u32, r.data, 5, 5);
                            while (iter.next()) |tok| {
                                if (tok[3] >= self.server.semanticTokens.len) continue;

                                var mods: ztd.enums.BitfieldSet(SemanticModifierType) = .{};
                                const set: std.StaticBitSet(std.meta.fields(SemanticModifierType).len) = .{ .mask = @intCast(tok[4]) };
                                var set_iter = set.iterator(.{});
                                while (set_iter.next()) |idx| {
                                    if (idx >= self.server.semanticModifiers.len) continue;
                                    mods.set(self.server.semanticModifiers.get(idx), true);
                                }

                                try self.db.insert(.semantic_tokens, .{
                                    .doc = doc.idx,
                                    .delta_line = tok[0],
                                    .delta_start_char = tok[1],
                                    .length = @intCast(tok[2]),
                                    .type = self.server.semanticTokens.get(tok[3]),
                                    .modifiers = mods,
                                });
                            }
                        }
                    }
                    return .{ .semantic_tokens = doc.idx };
                },
                .@"workspace/symbol" => {},
                else => log.debug("unhandled response: {s}: {}", .{ @tagName(method), rpc_msg.id }),
            },
            .request => |method| switch (method) {
                .@"workspace/configuration" => {
                    const res = try self.parser.parseRequest(arena.allocator(), .@"workspace/configuration");
                    for (res.items) |cfg| {
                        log.warn("{s}", .{cfg.section orelse "nope"});
                    }
                    try rpc.respond(rpc_msg.id, .@"workspace/configuration", &.{}, writer);
                },
                .@"workspace/semanticTokens/refresh" => {
                    try rpc.respond(rpc_msg.id, .@"workspace/semanticTokens/refresh", .{}, writer);
                },
                else => log.debug("unhandled request: {s}: {}", .{ @tagName(method), rpc_msg.id }),
            },
            .notification => |method| switch (method) {
                .@"window/showMessage" => {
                    const msg = try self.parser.parseNotification(arena.allocator(), .@"window/showMessage");
                    switch (msg.type) {
                        .Error => log.err("{s}", .{msg.message}),
                        .Warning => log.warn("{s}", .{msg.message}),
                        .Info, .Log => log.info("{s}", .{msg.message}),
                        .Debug => log.debug("{s}", .{msg.message}),
                    }
                },
                .@"$/logTrace" => {
                    const trace = try self.parser.parseNotification(arena.allocator(), .@"$/logTrace");
                    log.debug("{s}", .{trace.message});
                },
                .@"textDocument/publishDiagnostics" => {
                    self.db.drop(.diagnostics);
                    const res = try self.parser.parseNotification(arena.allocator(), .@"textDocument/publishDiagnostics");
                    for (res.diagnostics) |diag| {
                        try self.db.insert(.diagnostics, .{
                            .uri = res.uri,
                            .version = res.version,
                            .line = .{ .begin = diag.range.start.line, .end = diag.range.end.line },
                            .char = .{ .begin = diag.range.start.character, .end = diag.range.end.character },
                            .severity = @enumFromInt(@intFromEnum(diag.severity orelse .Error)),
                            .code = if (diag.code) |code| switch (code) {
                                .integer => |int| .{ .int = int },
                                .string => |str| .{ .str = str },
                            } else .{ .int = 0 },
                            .message = diag.message,
                        });
                    }
                },
                else => log.debug("unhandled notification: {s}", .{@tagName(method)}),
            },
        }
        return .nop;
    }
    return null;
}

fn get_process_id() std.posix.pid_t {
    if (@hasDecl(std.posix.system, "getpid")) {
        return std.posix.system.getpid();
    } else {
        const c = struct {
            pub extern "c" fn getpid() std.posix.pid_t;
        };
        return c.getpid();
    }
}

pub fn initialize(_: @This(), writer: anytype) !void {
    // TODO: engine should keep track of all open documents etc, and restore the state here
    const supportedSymbolKinds = comptime blk: {
        var tokens: []const rpc.msg.SymbolKind = &.{};
        for (std.meta.fields(rpc.msg.SymbolKind)) |field| {
            tokens = tokens ++ .{@as(rpc.msg.SymbolKind, @enumFromInt(field.value))};
        }
        break :blk tokens;
    };
    const supportedTokenTypes = comptime blk: {
        var tokens: []const []const u8 = &.{};
        for (std.meta.fields(rpc.msg.SemanticTokenTypes)) |field| {
            tokens = tokens ++ .{field.name};
        }
        break :blk tokens;
    };
    const supportedTokenModifiers = comptime blk: {
        var tokens: []const []const u8 = &.{};
        for (std.meta.fields(rpc.msg.SemanticTokenModifiers)) |field| {
            tokens = tokens ++ .{field.name};
        }
        break :blk tokens;
    };
    try rpc.send(0, .initialize, .{
        .processId = get_process_id(),
        .clientInfo = .{
            .name = "spurdo :D",
            .version = "0.0.0",
        },
        .locale = "en-US",
        .trace = .messages,
        .rootPath = "/home/nix/dev/personal/spurdo",
        .rootUri = "file:///home/nix/dev/personal/spurdo",
        .workspaceFolders = &.{.{
            .uri = "file:///home/nix/dev/personal/spurdo",
            .name = "root",
        }},
        .capabilities = .{
            .general = .{
                .staleRequestSupport = .{
                    .cancel = true,
                    .retryOnContentModified = &.{},
                },
                .markdown = .{
                    .parser = "spurdo-md :D",
                    .version = "0.0.0",
                    .allowedTags = &.{},
                },
                .positionEncodings = &.{
                    .@"utf-8",
                },
            },
            .window = .{
                .workDoneProgress = true,
                .showMessage = .{
                    .messageActionItem = .{
                        .additionalPropertiesSupport = true,
                    },
                },
                .showDocument = .{
                    .support = true,
                },
            },
            .workspace = .{
                .applyEdit = true,
                .workspaceEdit = .{
                    .documentChanges = true,
                    .resourceOperations = &.{
                        .create,
                        .rename,
                        .delete,
                    },
                    .failureHandling = .textOnlyTransactional,
                    .normalizesLineEndings = false,
                    .changeAnnotationSupport = .{
                        .groupsOnLabel = true,
                    },
                },
                .didChangeConfiguration = .{
                    .dynamicRegistration = false,
                },
                .didChangeWatchedFiles = .{
                    .dynamicRegistration = false,
                    .relativePatternSupport = false,
                },
                .symbol = .{
                    .dynamicRegistration = false,
                    .symbolKind = .{ .valueSet = supportedSymbolKinds },
                    .tagSupport = .{ .valueSet = &.{.Deprecated} },
                    .resolveSupport = .{
                        .properties = &.{},
                    },
                },
                .executeCommand = .{
                    .dynamicRegistration = false,
                },
                .workspaceFolders = true,
                .configuration = true,
                .semanticTokens = .{ .refreshSupport = true },
                .codeLens = .{ .refreshSupport = true },
                .inlineValue = .{ .refreshSupport = true },
                .inlayHint = .{ .refreshSupport = true },
                .diagnostics = .{ .refreshSupport = true },
                .fileOperations = .{
                    .dynamicRegistration = false,
                    .didCreate = true,
                    .willCreate = true,
                    .didRename = true,
                    .willRename = true,
                    .didDelete = true,
                    .willDelete = true,
                },
            },
            .textDocument = .{
                .synchronization = .{
                    .dynamicRegistration = false,
                    .willSave = true,
                    .willSaveWaitUntil = true,
                    .didSave = true,
                },
                .completion = .{
                    .dynamicRegistration = false,
                    .completionItem = .{
                        .snippetSupport = true,
                        .commitCharactersSupport = true,
                        .documentationFormat = &.{ .plaintext, .markdown },
                        .deprecatedSupport = true,
                        .preselectSupport = true,
                        .insertReplaceSupport = true,
                        .labelDetailsSupport = true,
                    },
                    .contextSupport = true,
                    .insertTextMode = .adjustIndentation,
                },
                .hover = .{
                    .dynamicRegistration = false,
                    .contentFormat = &.{ .plaintext, .markdown },
                },
                .signatureHelp = .{
                    .dynamicRegistration = false,
                    .signatureInformation = .{
                        .documentationFormat = &.{ .plaintext, .markdown },
                        .activeParameterSupport = true,
                    },
                    .contextSupport = true,
                },
                .declaration = .{
                    .dynamicRegistration = false,
                    .linkSupport = true,
                },
                .definition = .{
                    .dynamicRegistration = false,
                    .linkSupport = true,
                },
                .typeDefinition = .{
                    .dynamicRegistration = false,
                    .linkSupport = true,
                },
                .implementation = .{
                    .dynamicRegistration = false,
                    .linkSupport = true,
                },
                .references = .{
                    .dynamicRegistration = false,
                },
                .documentHighlight = .{
                    .dynamicRegistration = false,
                },
                .documentSymbol = .{
                    .dynamicRegistration = false,
                    .hierarchicalDocumentSymbolSupport = true,
                    .labelSupport = true,
                },
                .codeAction = .{
                    .dynamicRegistration = false,
                    .isPreferredSupport = true,
                    .disabledSupport = true,
                    .dataSupport = true,
                    .honorsChangeAnnotations = true,
                },
                .codeLens = .{
                    .dynamicRegistration = false,
                },
                .documentLink = .{
                    .dynamicRegistration = false,
                    .tooltipSupport = true,
                },
                .colorProvider = .{
                    .dynamicRegistration = false,
                },
                .formatting = .{
                    .dynamicRegistration = false,
                },
                .rangeFormatting = .{
                    .dynamicRegistration = false,
                },
                .rename = .{
                    .dynamicRegistration = false,
                    .prepareSupport = true,
                    .prepareSupportDefaultBehavior = .Identifier,
                    .honorsChangeAnnotations = true,
                },
                .publishDiagnostics = .{
                    .relatedInformation = true,
                    .tagSupport = .{
                        .valueSet = &.{
                            .Unnecessary,
                            .Deprecated,
                        },
                    },
                    .versionSupport = true,
                    .codeDescriptionSupport = true,
                    .dataSupport = true,
                },
                .selectionRange = .{
                    .dynamicRegistration = false,
                },
                .callHierarchy = .{
                    .dynamicRegistration = false,
                },
                .semanticTokens = .{
                    .dynamicRegistration = false,
                    .requests = .{ .full = .{ .bool = true } },
                    .tokenTypes = supportedTokenTypes,
                    .tokenModifiers = supportedTokenModifiers,
                    .formats = &.{.relative},
                    .serverCancelSupport = true,
                    .augmentsSyntaxTokens = true,
                    .multilineTokenSupport = true,
                    .overlappingTokenSupport = true,
                },
                .moniker = .{
                    .dynamicRegistration = false,
                },
                .typeHierarchy = .{
                    .dynamicRegistration = false,
                },
                .inlineValue = .{
                    .dynamicRegistration = false,
                },
                .inlayHint = .{
                    .dynamicRegistration = false,
                },
                .diagnostic = .{
                    .dynamicRegistration = false,
                    .relatedDocumentSupport = true,
                },
            },
            .notebookDocument = null,
        },
    }, writer);
}

pub const Document = packed struct(u32) {
    pub const Limit = 15;
    pub const Index = std.math.IntFittingRange(0, Limit);

    idx: Index,
    uri_hash: u28,

    pub fn init(idx: Index, uri: []const u8) @This() {
        return .{ .idx = idx, .uri_hash = @truncate(std.hash.Murmur3_32.hash(uri)) };
    }
};

pub const SemanticTokenType = enum {
    namespace,
    type,
    class,
    @"enum",
    interface,
    @"struct",
    typeParameter,
    parameter,
    variable,
    property,
    enumMember,
    event,
    function,
    method,
    macro,
    keyword,
    modifier,
    comment,
    string,
    number,
    regexp,
    operator,
    decorator,
    errorTag,
    builtin,
    label,
    keywordLiteral,
    @"union",
    @"opaque",
    unknown,
};

pub const SemanticModifierType = enum {
    declaration,
    definition,
    readonly,
    static,
    deprecated,
    abstract,
    @"async",
    modification,
    documentation,
    defaultLibrary,
    generic,
    @"_",
    unknown,
};
