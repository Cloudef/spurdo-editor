const std = @import("std");

pub const Rgb = enum(u24) {
    _,
    pub fn init(r: u8, g: u8, b: u8) @This() {
        const v: u24 = @bitCast(packed struct(u24) {
            r: u8,
            g: u8,
            b: u8,
        }{ .r = r, .g = g, .b = b });
        return @enumFromInt(v);
    }

    pub fn initHex(hex: []const u8) !@This() {
        return @enumFromInt(try std.fmt.parseInt(u24, hex, 16));
    }

    pub fn asHex(self: @This()) [6]u8 {
        var buf: [6]u8 = undefined;
        const v: u24 = @intFromEnum(self);
        _ = std.fmt.formatIntBuf(&buf, v, 16, .lower, .{});
        return buf;
    }
};

pub const AnsiTheme = struct {
    black: Rgb = Rgb.initHex("1c1c1c") catch unreachable,
    red: Rgb = Rgb.initHex("d81860") catch unreachable,
    green: Rgb = Rgb.initHex("b7ce42") catch unreachable,
    yellow: Rgb = Rgb.initHex("fea63c") catch unreachable,
    blue: Rgb = Rgb.initHex("66aabb") catch unreachable,
    magneta: Rgb = Rgb.initHex("b7416e") catch unreachable,
    cyan: Rgb = Rgb.initHex("537175") catch unreachable,
    white: Rgb = Rgb.initHex("ddeedd") catch unreachable,
    black2: Rgb = Rgb.initHex("4d4d4d") catch unreachable,
    red2: Rgb = Rgb.initHex("f00060") catch unreachable,
    green2: Rgb = Rgb.initHex("bde077") catch unreachable,
    yellow2: Rgb = Rgb.initHex("ffe863") catch unreachable,
    blue2: Rgb = Rgb.initHex("aaccbb") catch unreachable,
    magneta2: Rgb = Rgb.initHex("bb4466") catch unreachable,
    cyan2: Rgb = Rgb.initHex("a3babf") catch unreachable,
    white2: Rgb = Rgb.initHex("6c887a") catch unreachable,
    foreground: Rgb = Rgb.initHex("cacaca") catch unreachable,
    background: Rgb = Rgb.initHex("121212") catch unreachable,
};

pub const Color = union(enum) {
    rgb: Rgb,
    ansi: std.math.IntFittingRange(0, std.meta.fields(AnsiTheme).len - 2),
    default: void,
};

pub const Style = struct {
    pub const Underline = enum {
        off,
        single,
        double,
        curly,
        dotted,
        dashed,
    };
    fg: Color = .default,
    bg: Color = .default,
    ul: Color = .default,
    ul_style: Underline = .off,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    strikethrough: bool = false,
};

pub const Theme = struct {
    keyword: Style = .{ .fg = .{ .ansi = 5 } },
    comment: Style = .{ .dim = true },
    doc_comment: Style = .{ .dim = true, .bold = true },
    literal: Style = .{ .fg = .{ .ansi = 2 } },
    builtin: Style = .{ .fg = .{ .ansi = 3 } },
    separator: Style = .{ .fg = .{ .ansi = 6 } },
    operator: Style = .{ .fg = .{ .ansi = 10 } },
    field: Style = .{ .fg = .{ .ansi = 11 } },
    identifier: Style = .{ .fg = .{ .ansi = 12 } },
    decl: Style = .{ .fg = .{ .ansi = 4 } },
    @"defer": Style = .{ .fg = .{ .ansi = 15 } },
    // try, catch, unreachable
    important: Style = .{ .fg = .{ .ansi = 1 } },

    pub fn toRgbScheme(self: @This(), ansi: AnsiTheme) @This() {
        var new = self;
        inline for (std.meta.fields(@This())) |field| {
            inline for (.{ "fg", "bg", "ul" }) |color| {
                @field(@field(new, field.name), color) = switch (@field(@field(self, field.name), color)) {
                    .ansi => |idx| blk: {
                        inline for (std.meta.fields(AnsiTheme), 0..) |afield, i| {
                            if (idx == i) break :blk .{ .rgb = @field(ansi, afield.name) };
                        }
                        unreachable;
                    },
                    .rgb => |rgb| .{ .rgb = rgb },
                    .default => .default,
                };
            }
        }
        return new;
    }
};

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

pub fn style(
    allocator: std.mem.Allocator,
    mode: std.zig.Ast.Mode,
    theme: Theme,
    buffer: [:0]const u8,
    context: anytype,
    styler: anytype,
) !void {
    var comment_parser: CommentState = .{};
    var comment_begin: usize = 0;
    for (buffer, 0..) |b, index| {
        if (comment_parser.phase == .found) {
            if (b == '\n') {
                comment_parser.phase = .searching;
                try styler(context, theme.comment, comment_begin, index);
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

    var ast = try std.zig.Ast.parse(allocator, buffer, mode);
    defer ast.deinit(allocator);

    for (ast.tokens.items(.tag), 0..) |tag, index| {
        switch (tag) {
            .multiline_string_literal_line => {
                const range = ast.tokenToSpan(@intCast(index));
                try styler(context, theme.literal, range.start, range.end);
            },
            .doc_comment, .container_doc_comment => {
                const range = ast.tokenToSpan(@intCast(index));
                try styler(context, theme.doc_comment, range.start, range.end);
            },
            .comma, .colon, .semicolon => {
                const range = ast.tokenToSpan(@intCast(index));
                try styler(context, theme.separator, range.start, range.end);
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
                const range = ast.tokenToSpan(@intCast(index));
                try styler(context, theme.operator, range.start, range.end);
            },
            .keyword_const => {},
            .keyword_var => {},
            else => {
                if (tag.lexeme()) |name| {
                    if (std.zig.Token.keywords.has(name)) {
                        const range = ast.tokenToSpan(@intCast(index));
                        try styler(context, theme.keyword, range.start, range.end);
                    }
                }
            },
        }
    }

    for (ast.nodes.items(.tag), ast.nodes.items(.main_token), 0..) |tag, main_token, index| {
        switch (tag) {
            .field_access => {
                const range = ast.tokenToSpan(main_token);
                try styler(context, theme.separator, range.start, range.end);
            },
            .builtin_call, .builtin_call_two, .builtin_call_two_comma, .builtin_call_comma, .@"asm" => {
                const range = ast.tokenToSpan(main_token);
                try styler(context, theme.builtin, range.start, range.end);
            },
            .struct_init_dot, .struct_init_dot_two, .struct_init_dot_two_comma => {
                var buf: [2]std.zig.Ast.Node.Index = undefined;
                if (ast.fullStructInit(&buf, @intCast(index))) |init| {
                    for (init.ast.fields) |field| {
                        const range = ast.tokenToSpan(ast.firstToken(field) - 2);
                        try styler(context, theme.field, range.start, range.end);
                    }
                }
            },
            .container_field_init, .container_field => {
                const range = ast.tokenToSpan(main_token);
                try styler(context, theme.field, range.start, range.end);
            },
            .identifier => {
                const range = ast.tokenToSpan(main_token);
                try styler(context, theme.identifier, range.start, range.end);
            },
            .string_literal, .enum_literal, .number_literal, .char_literal => {
                const range = ast.tokenToSpan(main_token);
                try styler(context, theme.literal, range.start, range.end);
            },
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                const range = ast.tokenToSpan(main_token);
                try styler(context, theme.decl, range.start, range.end);
            },
            .@"try", .@"catch", .unreachable_literal => {
                const range = ast.tokenToSpan(main_token);
                try styler(context, theme.important, range.start, range.end);
            },
            .@"defer", .@"errdefer" => {
                const range = ast.tokenToSpan(main_token);
                try styler(context, theme.@"defer", range.start, range.end);
            },
            else => {},
        }
    }
}

pub const Range = packed struct(u128) { begin: usize, end: usize };

pub const RangeStyle = struct {
    range: Range,
    style: Style,

    pub fn sort(_: void, a: @This(), b: @This()) bool {
        return a.range.begin < b.range.begin;
    }
};

pub fn styleIntoList(allocator: std.mem.Allocator, mode: std.zig.Ast.Mode, theme: Theme, buffer: [:0]const u8) ![]const RangeStyle {
    const Mapper = struct {
        list: std.ArrayList(RangeStyle),

        pub fn init(ally: std.mem.Allocator) @This() {
            return .{ .list = std.ArrayList(RangeStyle).init(ally) };
        }

        pub fn styler(self: *@This(), style_: Style, begin: usize, end: usize) !void {
            for (self.list.items) |*item| {
                if (std.meta.eql(item.range, Range{ .begin = begin, .end = end })) {
                    item.style = style_;
                    return;
                }
            }
            try self.list.append(.{ .range = .{ .begin = begin, .end = end }, .style = style_ });
        }
    };
    var mapper = Mapper.init(allocator);
    errdefer mapper.list.deinit();
    try style(allocator, mode, theme, buffer, &mapper, Mapper.styler);
    std.sort.pdq(RangeStyle, mapper.list.items, {}, RangeStyle.sort);
    return mapper.list.toOwnedSlice();
}

pub const HtmlMode = enum {
    full,
    css,
    code,
    css_code,
};

pub fn styleIntoHtml(allocator: std.mem.Allocator, html_mode: HtmlMode, mode: std.zig.Ast.Mode, ansi_theme: Theme, ansi: AnsiTheme, buffer: [:0]const u8) ![]const u8 {
    const theme = ansi_theme.toRgbScheme(ansi);
    const list = try styleIntoList(allocator, mode, theme, buffer);
    defer allocator.free(list);

    var html = std.ArrayList(u8).init(allocator);
    errdefer html.deinit();

    if (html_mode == .full) {
        try html.appendSlice("<!DOCTYPE html><html lang='en'><head><meta charset='utf-8'><style>*{margin:0;padding:0;}</style>");
    }

    switch (html_mode) {
        .full, .css, .css_code => {
            try html.writer().print(
                \\<style>
                \\pre.zig{{
                \\font-family: monospace;
                \\font-size: 13px;
                \\line-height: 16px;
                \\color: #{s};
                \\background-color: #{s};
                \\}}
            , .{ ansi.foreground.asHex(), ansi.background.asHex() });
            inline for (std.meta.fields(Theme)) |field| {
                try html.writer().print("span.{s}{{", .{field.name});
                const f: *const Style = &@field(theme, field.name);
                switch (f.fg) {
                    .default => {},
                    .rgb => |rgb| try html.writer().print("color: #{s};", .{rgb.asHex()}),
                    .ansi => unreachable,
                }
                switch (f.bg) {
                    .default => {},
                    .rgb => |rgb| try html.writer().print("background-color: #{s};", .{rgb.asHex()}),
                    .ansi => unreachable,
                }
                switch (f.ul) {
                    .default => {},
                    .rgb => |rgb| try html.writer().print("text-decoration-color: #{s};", .{rgb.asHex()}),
                    .ansi => unreachable,
                }
                switch (f.ul_style) {
                    .off => {},
                    .curly => try html.appendSlice("text-decoration-style: wavy;"),
                    .single => try html.appendSlice("text-decoration-style: solid;"),
                    .double => try html.appendSlice("text-decoration-style: double;"),
                    .dotted => try html.appendSlice("text-decoration-style: dotted;"),
                    .dashed => try html.appendSlice("text-decoration-style: dashed;"),
                }
                if (f.strikethrough or f.ul_style != .off) {
                    try html.appendSlice("text-decoration: ");
                    if (f.strikethrough) try html.appendSlice("line-through");
                    if (f.ul_style != .off) {
                        if (f.strikethrough) try html.append(' ');
                        try html.appendSlice("underline");
                    }
                    try html.append(';');
                }
                if (f.bold) try html.appendSlice("font-weight: bold;");
                if (f.italic) try html.appendSlice("font-style: italic;");
                if (f.dim) try html.appendSlice("filter: brightness(50%);");
                try html.append('}');
            }
            try html.appendSlice("</style>");
        },
        .code => {},
    }

    if (html_mode == .full) {
        try html.appendSlice("</head><body>");
    }

    switch (html_mode) {
        .full, .code, .css_code => {
            try html.appendSlice("<pre class='zig'><code>");

            var off: usize = 0;
            for (list) |kv| {
                if (off < kv.range.begin) try html.appendSlice(buffer[off..kv.range.begin]);
                inline for (std.meta.fields(Theme)) |field| {
                    if (std.meta.eql(@field(theme, field.name), kv.style)) {
                        try html.writer().print("<span class='{s}'>{s}</span>", .{ field.name, buffer[kv.range.begin..kv.range.end] });
                        break;
                    }
                }
                off = kv.range.end;
            }
            try html.appendSlice(buffer[off..]);
            try html.appendSlice("<code></pre>");
        },
        .css => {},
    }

    if (html_mode == .full) {
        try html.appendSlice("</body></html>");
    }

    return html.toOwnedSlice();
}
