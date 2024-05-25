const std = @import("std");
const common = @import("../common.zig");
const log = std.log.scoped(.spurdo_lang_zig);

const CommentState = packed struct(u16) {
    const Phase = enum(u8) {
        searching,
        maybe,
        found,
    };

    byte: u8 = 0,
    phase: Phase = .searching,

    pub fn init(byte: u8, phase: Phase) @This() {
        return .{ .byte = byte, .phase = phase };
    }

    pub fn asInt(byte: u8, phase: Phase) u16 {
        return @This().init(byte, phase).int();
    }

    pub fn int(self: @This()) u16 {
        return @bitCast(self);
    }
};

pub fn parse(allocator: std.mem.Allocator, contents: []const u8, meta: *common.MetaList, meta_map: *common.MetaMap) !void {
    var comment_parser: CommentState = .{};
    var comment_begin: usize = 0;
    for (contents, 0..) |b, index| {
        if (comment_parser.phase == .found) {
            if (b == '\n') {
                comment_parser.phase = .searching;
                try meta.append(allocator, .{
                    .style = .{ .dim = true },
                });
                for (comment_begin..index) |span| {
                    try meta_map.put(allocator, span, meta.len - 1);
                }
            }
        } else {
            comment_parser.byte = b;
            switch (comment_parser.int()) {
                CommentState.asInt('/', .searching) => {
                    comment_parser.phase = .maybe;
                    comment_begin = index;
                },
                CommentState.asInt('/', .maybe) => comment_parser.phase = .found,
                else => comment_parser.phase = .searching,
            }
        }
    }

    var ast = try std.zig.Ast.parse(allocator, @ptrCast(contents[0 .. contents.len - 1]), .zig);
    defer ast.deinit(allocator);

    for (ast.tokens.items(.tag), 0..) |tag, index| {
        if (tag.lexeme()) |name| {
            if (std.zig.Token.keywords.has(name)) {
                try meta.append(allocator, .{
                    .style = .{ .fg = .{ .index = 5 } },
                });
                const range = ast.tokenToSpan(@intCast(index));
                for (range.start..range.end) |span| {
                    try meta_map.put(allocator, span, meta.len - 1);
                }
                continue;
            }
        }
        switch (tag) {
            .doc_comment, .container_doc_comment => {
                try meta.append(allocator, .{
                    .style = .{ .dim = true, .bold = true },
                });
                const range = ast.tokenToSpan(@intCast(index));
                for (range.start..range.end) |span| {
                    try meta_map.put(allocator, span, meta.len - 1);
                }
            },
            .comma, .colon, .semicolon => {
                try meta.append(allocator, .{
                    .style = .{ .fg = .{ .index = 6 } },
                });
                const range = ast.tokenToSpan(@intCast(index));
                for (range.start..range.end) |span| {
                    try meta_map.put(allocator, span, meta.len - 1);
                }
            },
            .period,
            .period_asterisk,
            .question_mark,
            .bang,
            .ampersand,
            .ampersand_equal,
            .tilde,
            .slash,
            .slash_equal,
            .equal,
            .equal_equal,
            .plus,
            .plus_plus,
            .plus_equal,
            .plus_percent,
            .plus_percent_equal,
            .plus_pipe,
            .plus_pipe_equal,
            .minus,
            .minus_equal,
            .minus_percent,
            .minus_percent_equal,
            .minus_pipe,
            .minus_pipe_equal,
            .asterisk,
            .asterisk_equal,
            .asterisk_asterisk,
            .asterisk_percent,
            .asterisk_percent_equal,
            .asterisk_pipe,
            .asterisk_pipe_equal,
            .percent,
            .percent_equal,
            .pipe,
            .pipe_pipe,
            .pipe_equal,
            .equal_angle_bracket_right,
            .bang_equal,
            .caret,
            .caret_equal,
            .angle_bracket_left,
            .angle_bracket_left_equal,
            .angle_bracket_angle_bracket_left,
            .angle_bracket_angle_bracket_left_equal,
            .angle_bracket_angle_bracket_left_pipe,
            .angle_bracket_angle_bracket_left_pipe_equal,
            .angle_bracket_right,
            .angle_bracket_right_equal,
            .angle_bracket_angle_bracket_right,
            .angle_bracket_angle_bracket_right_equal,
            .l_brace,
            .r_brace,
            .l_bracket,
            .r_bracket,
            .l_paren,
            .r_paren,
            => {
                try meta.append(allocator, .{
                    .style = .{ .fg = .{ .index = 10 } },
                });
                const range = ast.tokenToSpan(@intCast(index));
                for (range.start..range.end) |span| {
                    try meta_map.put(allocator, span, meta.len - 1);
                }
            },
            else => {},
        }
    }

    for (ast.nodes.items(.tag), ast.nodes.items(.main_token), 0..) |tag, main_token, index| {
        switch (tag) {
            .field_access => {
                try meta.append(allocator, .{
                    .style = .{ .fg = .{ .index = 6 } },
                });
                const main_span = ast.tokenToSpan(main_token);
                for (main_span.start..main_span.end) |span| {
                    try meta_map.put(allocator, span, meta.len - 1);
                }
            },
            .builtin_call, .builtin_call_two, .builtin_call_two_comma, .builtin_call_comma, .@"asm" => {
                try meta.append(allocator, .{
                    .style = .{ .fg = .{ .index = 3 } },
                });
                const main_span = ast.tokenToSpan(main_token);
                for (main_span.start..main_span.end) |span| {
                    try meta_map.put(allocator, span, meta.len - 1);
                }
            },
            .struct_init_dot, .struct_init_dot_two, .struct_init_dot_two_comma => {
                var buf: [2]std.zig.Ast.Node.Index = undefined;
                if (ast.fullStructInit(&buf, @intCast(index))) |init| {
                    for (init.ast.fields) |field| {
                        try meta.append(allocator, .{
                            .style = .{ .fg = .{ .index = 11 } },
                        });
                        const main_span = ast.tokenToSpan(ast.firstToken(field) - 2);
                        for (main_span.start..main_span.end) |span| {
                            try meta_map.put(allocator, span, meta.len - 1);
                        }
                    }
                }
            },
            .container_field_init, .container_field => {
                try meta.append(allocator, .{
                    .style = .{ .fg = .{ .index = 11 } },
                });
                const main_span = ast.tokenToSpan(main_token);
                for (main_span.start..main_span.end) |span| {
                    try meta_map.put(allocator, span, meta.len - 1);
                }
            },
            .identifier => {
                try meta.append(allocator, .{
                    .style = .{ .fg = .{ .index = 12 } },
                });
                const main_span = ast.tokenToSpan(main_token);
                for (main_span.start..main_span.end) |span| {
                    try meta_map.put(allocator, span, meta.len - 1);
                }
            },
            .string_literal, .multiline_string_literal, .enum_literal, .number_literal, .char_literal => {
                try meta.append(allocator, .{
                    .style = .{ .fg = .{ .index = 2 } },
                });
                const main_span = ast.tokenToSpan(main_token);
                for (main_span.start..main_span.end) |span| {
                    try meta_map.put(allocator, span, meta.len - 1);
                }
            },
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                try meta.append(allocator, .{
                    .style = .{ .fg = .{ .index = 4 } },
                });
                const main_span = ast.tokenToSpan(main_token);
                for (main_span.start..main_span.end) |span| {
                    try meta_map.put(allocator, span, meta.len - 1);
                }
            },
            .@"try", .@"catch", .unreachable_literal => {
                try meta.append(allocator, .{
                    .style = .{ .fg = .{ .index = 1 } },
                });
                const main_span = ast.tokenToSpan(main_token);
                for (main_span.start..main_span.end) |span| {
                    try meta_map.put(allocator, span, meta.len - 1);
                }
            },
            .@"defer", .@"errdefer" => {
                try meta.append(allocator, .{
                    .style = .{ .fg = .{ .index = 15 } },
                });
                const main_span = ast.tokenToSpan(main_token);
                for (main_span.start..main_span.end) |span| {
                    try meta_map.put(allocator, span, meta.len - 1);
                }
            },
            else => {},
        }
    }
}
