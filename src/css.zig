//! The CSS of a `<style>` element, read into the CSS nodes @tsrx/core reads it into.

const std = @import("std");
const yuku = @import("parser");
const tsrx = @import("tsrx.zig");

const ast = yuku.ast;
const dialect = yuku.dialect;

const Error = std.mem.Allocator.Error;
const Failure = Error || error{InvalidCss};
const Node = tsrx.Node;
const NodeIndex = ast.NodeIndex;
const Parser = dialect.Parser;
const Span = ast.Span;

pub fn shape(node: Node) dialect.Shape {
    return switch (node) {
        .style_sheet => .{ .type = "StyleSheet", .fields = &.{ "source", "children[]" } },
        .rule => .{ .type = "Rule", .fields = &.{ "prelude", "block" } },
        .atrule => .{ .type = "Atrule", .fields = &.{ "name", "prelude", "block" } },
        .block => .{ .type = "Block", .fields = &.{"children[]"} },
        .declaration => .{ .type = "Declaration", .fields = &.{ "property", "value" } },
        .selector_list => .{ .type = "SelectorList", .fields = &.{"children[]"} },
        .complex_selector => .{ .type = "ComplexSelector", .fields = &.{"children[]"} },
        .relative_selector => .{
            .type = "RelativeSelector",
            .fields = &.{ "combinator", "selectors[]" },
        },
        .combinator => .{ .type = "Combinator", .fields = &.{"name"} },
        .descendant_combinator => .{ .type = "Combinator", .properties = "{\"name\":\" \"}" },
        .type_selector => .{ .type = "TypeSelector", .fields = &.{"name"} },
        .id_selector => .{ .type = "IdSelector", .fields = &.{"name"} },
        .class_selector => .{ .type = "ClassSelector", .fields = &.{"name"} },
        .pseudo_class_selector => .{
            .type = "PseudoClassSelector",
            .fields = &.{ "name", "args" },
        },
        .pseudo_element_selector => .{
            .type = "PseudoElementSelector",
            .fields = &.{ "name", "args" },
        },
        .attribute_selector => .{
            .type = "AttributeSelector",
            .fields = &.{ "name", "matcher", "value", "flags" },
        },
        .nesting_selector => .{ .type = "NestingSelector", .properties = "{\"name\":\"&\"}" },
        .nth => .{ .type = "Nth", .fields = &.{"value"} },
        .percentage => .{ .type = "Percentage", .fields = &.{"value"} },
        .text => .{ .type = "Text", .text = true },
        else => unreachable,
    };
}

/// The style sheet of the CSS in `span`, null after a diagnostic.
pub fn parse(p: *Parser, span: Span) Error!?NodeIndex {
    var css: Css = .{ .p = p, .source = p.tree().source[0..span.end], .index = span.start };
    return css.parseSheet(span) catch |err| switch (err) {
        error.InvalidCss => null,
        error.OutOfMemory => |oom| oom,
    };
}

const Css = struct {
    p: *Parser,
    /// The source up to the end of the CSS.
    source: []const u8,
    index: u32,

    fn parseSheet(css: *Css, span: Span) Failure!NodeIndex {
        var items = css.p.list();
        defer items.reset();
        try items.append(try css.text(span));
        while (true) {
            try css.skipTrivia();
            if (css.index == css.source.len) break;
            try items.append(try if (css.at('@')) css.parseAtrule() else css.parseRule());
        }
        return css.p.addNode(.style_sheet, items.items(), span);
    }

    fn parseAtrule(css: *Css) Failure!NodeIndex {
        const start = css.index;
        css.index += 1;
        const name = try css.text(try css.identifier());
        const stop = try css.valueEnd(css.index);
        const prelude = try css.text(css.trim(css.index, stop));
        css.index = stop;
        const block: NodeIndex = if (css.at('{')) try css.parseBlock() else block: {
            try css.expect(';');
            break :block .null;
        };
        return css.node(.atrule, &.{ name, prelude, block }, start);
    }

    fn parseRule(css: *Css) Failure!NodeIndex {
        const start = css.index;
        const prelude = try css.parseSelectorList(false);
        const block = try css.parseBlock();
        return css.node(.rule, &.{ prelude, block }, start);
    }

    fn parseBlock(css: *Css) Failure!NodeIndex {
        const start = css.index;
        try css.expect('{');
        var items = css.p.list();
        defer items.reset();
        while (css.index < css.source.len) {
            try css.skipTrivia();
            if (css.at('}')) break;
            try items.append(try css.parseBlockItem());
        }
        try css.expect('}');
        return css.node(.block, items.items(), start);
    }

    // a declaration, unless a `{` ends what follows, as it does a nested rule
    fn parseBlockItem(css: *Css) Failure!NodeIndex {
        if (css.at('@')) return css.parseAtrule();
        const stop = try css.valueEnd(css.index);
        if (css.source[stop] == '{') return css.parseRule();

        const start = css.index;
        while (css.index < stop and !isSpace(css.source[css.index]) and
            css.source[css.index] != ':') css.index += 1;
        const property = try css.text(.{ .start = start, .end = css.index });
        css.skipWhitespace();
        _ = css.eat(':');
        const value = css.trim(css.index, stop);
        if (value.start == value.end and !std.mem.startsWith(u8, css.source[start..], "--")) {
            return css.fail("CSS Declaration cannot be empty");
        }
        css.index = stop;
        const value_text = try css.text(value);
        const span: Span = .{ .start = start, .end = stop };
        const declaration = try css.p.addNode(.declaration, &.{ property, value_text }, span);
        if (!css.at('}')) try css.expect(';');
        return declaration;
    }

    // `nested` in a pseudo-class, which a `)` ends
    fn parseSelectorList(css: *Css, nested: bool) Failure!NodeIndex {
        try css.skipTrivia();
        const start = css.index;
        var items = css.p.list();
        defer items.reset();
        while (css.index < css.source.len) {
            try items.append(try css.parseSelector(nested));
            const end = css.index;
            try css.skipTrivia();
            if (css.atClose(nested)) {
                return css.add(.selector_list, items.items(), start, end);
            }
            try css.expect(',');
            try css.skipTrivia();
        }
        return css.fail("Unexpected end of input");
    }

    // relative selectors, each a combinator and the selectors after it
    fn parseSelector(css: *Css, nested: bool) Failure!NodeIndex {
        const start = css.index;
        var relatives = css.p.list();
        defer relatives.reset();
        var relative_start = start;
        var selectors = css.p.list();
        defer selectors.reset();
        try selectors.append(.null);
        while (css.index < css.source.len) {
            if (try css.parseSimpleSelector(nested)) |selector| try selectors.append(selector);
            const end = css.index;
            try css.skipTrivia();
            const closed = css.at(',') or css.atClose(nested);
            css.index = end;
            const combinator: NodeIndex = if (closed) .null else try css.parseCombinator();
            if (!closed and combinator == .null) continue;

            // like @tsrx/core, a combinator drops the empty selector before it
            const relative: NodeIndex = if (closed or selectors.items().len > 1)
                try css.add(.relative_selector, selectors.items(), relative_start, end)
            else
                .null;
            selectors.reset();
            if (relative != .null) try relatives.append(relative);
            if (closed) {
                return css.add(.complex_selector, relatives.items(), start, end);
            }
            relative_start = css.p.tree().span(combinator).start;
            css.skipWhitespace();
            if (css.at(',') or css.atClose(nested)) return css.fail("Invalid selector");
            selectors = css.p.list();
            try selectors.append(combinator);
        }
        return css.fail("Unexpected end of input");
    }

    // null at a combinator
    fn parseSimpleSelector(css: *Css, nested: bool) Failure!?NodeIndex {
        const start = css.index;
        switch (css.source[start]) {
            '&' => {
                css.index += 1;
                return try css.node(.nesting_selector, &.{}, start);
            },
            '*' => {
                css.index += 1;
                const star: Span = .{ .start = start, .end = css.index };
                const name = if (css.eat('|')) try css.identifier() else star;
                return try css.node(.type_selector, &.{try css.text(name)}, start);
            },
            '#', '.' => |char| {
                css.index += 1;
                const kind: Node = if (char == '#') .id_selector else .class_selector;
                return try css.node(kind, &.{try css.text(try css.identifier())}, start);
            },
            ':' => {
                css.index += 1;
                const kind: Node = if (css.eat(':'))
                    .pseudo_element_selector
                else
                    .pseudo_class_selector;
                const name = try css.text(try css.identifier());
                var args: NodeIndex = .null;
                if (css.eat('(')) {
                    args = try css.parseSelectorList(true);
                    try css.expect(')');
                }
                return try css.node(kind, &.{ name, args }, start);
            },
            '[' => return try css.parseAttributeSelector(),
            else => {},
        }
        if (nested) {
            if (css.nthEnd()) |end| return try css.valueSelector(.nth, end);
        }
        if (css.percentageEnd()) |end| return try css.valueSelector(.percentage, end);
        if (css.combinatorLength() != null) return null;
        var name = try css.identifier();
        if (css.eat('|')) name = try css.identifier();
        return try css.node(.type_selector, &.{try css.text(name)}, start);
    }

    fn valueSelector(css: *Css, kind: Node, end: u32) Failure!NodeIndex {
        const start = css.index;
        css.index = end;
        return css.node(kind, &.{try css.text(.{ .start = start, .end = end })}, start);
    }

    fn parseAttributeSelector(css: *Css) Failure!NodeIndex {
        const start = css.index;
        css.index += 1;
        css.skipWhitespace();
        const name = try css.text(try css.identifier());
        css.skipWhitespace();
        var matcher: NodeIndex = .null;
        var value: NodeIndex = .null;
        if (css.matcherLength()) |length| {
            matcher = try css.text(.{ .start = css.index, .end = css.index + length });
            css.index += length;
            css.skipWhitespace();
            value = try css.text(try css.attributeValue());
        }
        css.skipWhitespace();
        const flags_start = css.index;
        css.index = runEnd(css.source, css.index, std.ascii.isAlphabetic);
        const flags: NodeIndex = if (css.index == flags_start) .null else try css.text(.{
            .start = flags_start,
            .end = css.index,
        });
        css.skipWhitespace();
        try css.expect(']');
        return css.node(.attribute_selector, &.{ name, matcher, value, flags }, start);
    }

    // unquoted up to whitespace or `]`, or between quotes
    fn attributeValue(css: *Css) Failure!Span {
        const quote: u8 = if (css.at('"') or css.at('\'')) css.source[css.index] else 0;
        if (quote != 0) css.index += 1;
        const start = css.index;
        while (css.index < css.source.len) {
            const char = css.source[css.index];
            if (char == '\\') {
                css.escape();
            } else if (if (quote != 0) char == quote else isSpace(char) or char == ']') {
                const value: Span = .{ .start = start, .end = css.index };
                if (quote != 0) css.index += 1;
                return value;
            } else {
                css.index += 1;
            }
        }
        return css.fail("Unexpected end of input");
    }

    // `.null` without one
    fn parseCombinator(css: *Css) Failure!NodeIndex {
        const start = css.index;
        css.skipWhitespace();
        if (css.combinatorLength()) |length| {
            const name: Span = .{ .start = css.index, .end = css.index + length };
            css.index += length;
            const combinator = try css.node(.combinator, &.{try css.text(name)}, name.start);
            css.skipWhitespace();
            return combinator;
        }
        if (css.index == start) return .null;
        return css.node(.descendant_combinator, &.{}, start);
    }

    fn combinatorLength(css: *const Css) ?u32 {
        if (css.index == css.source.len) return null;
        return switch (css.source[css.index]) {
            '+', '~', '>' => 1,
            '|' => if (std.mem.startsWith(u8, css.source[css.index..], "||")) 2 else null,
            else => null,
        };
    }

    fn matcherLength(css: *const Css) ?u32 {
        const rest = css.source[css.index..];
        if (std.mem.startsWith(u8, rest, "=")) return 1;
        const operator = rest.len >= 2 and rest[1] == '=' and
            std.mem.findScalar(u8, "~^$*|", rest[0]) != null;
        return if (operator) 2 else null;
    }

    // `even`, `odd`, `2n+1`, `-n+3`, or `5`, before a `,` or a `)`, or with an `of` after it
    fn nthEnd(css: *const Css) ?u32 {
        const source = css.source;
        var index = css.index;
        if (std.mem.startsWith(u8, source[index..], "even")) {
            index += 4;
        } else if (std.mem.startsWith(u8, source[index..], "odd")) {
            index += 3;
        } else {
            const negative = source[index] == '-';
            if (negative or source[index] == '+') index += 1;
            const digits = index;
            index = digitsEnd(source, index);
            if (index < source.len and source[index] == 'n') {
                index += 1;
                const sign = spaceEnd(source, index);
                const signed = sign < source.len and
                    (source[sign] == '+' or source[sign] == '-' and !negative);
                const offset = if (signed) digitsEnd(source, spaceEnd(source, sign + 1)) else sign;
                if (signed and offset > spaceEnd(source, sign + 1)) {
                    index = offset;
                } else if (negative) {
                    return null;
                }
            } else if (negative or index == digits) {
                return null;
            }
        }
        const after = spaceEnd(source, index);
        if (after < source.len and (source[after] == ',' or source[after] == ')')) return index;
        const of = after > index and std.mem.startsWith(u8, source[after..], "of") and
            after + 2 < source.len and isSpace(source[after + 2]);
        return if (of) spaceEnd(source, after + 2) else null;
    }

    // `\d+(\.\d+)?%`
    fn percentageEnd(css: *const Css) ?u32 {
        const source = css.source;
        var index = digitsEnd(source, css.index);
        if (index == css.index) return null;
        const fraction = digitsEnd(source, index + 1);
        if (std.mem.startsWith(u8, source[index..], ".") and fraction > index + 1) index = fraction;
        return if (index < source.len and source[index] == '%') index + 1 else null;
    }

    fn identifier(css: *Css) Failure!Span {
        const start = css.index;
        const digit = start + @intFromBool(css.at('-'));
        if (digit < css.source.len and std.ascii.isDigit(css.source[digit])) {
            return css.fail("Unexpected CSS identifier");
        }
        while (css.index < css.source.len) {
            const char = css.source[css.index];
            if (char == '\\') {
                css.escape();
            } else if (isIdentifierChar(char)) {
                css.index += 1;
            } else {
                break;
            }
        }
        if (css.index == start) return css.fail("Expected identifier");
        return .{ .start = start, .end = css.index };
    }

    // a `\` and up to six hex digits with one whitespace after them, or any one character
    fn escape(css: *Css) void {
        css.index += 1;
        const hex = css.index;
        css.index = @min(runEnd(css.source, hex, std.ascii.isHex), hex + 6);
        const rest = css.source[css.index..];
        if (css.index == hex) {
            css.index += @intFromBool(rest.len > 0);
        } else if (std.mem.startsWith(u8, rest, "\r\n")) {
            css.index += 2;
        } else if (rest.len > 0 and isSpace(rest[0])) {
            css.index += 1;
        }
    }

    // where a value ends, at a `;`, `{`, or `}` outside quotes and `url(...)`
    fn valueEnd(css: *Css, from: u32) Failure!u32 {
        const source = css.source;
        var quote: u8 = 0;
        var url = false;
        var index = from;
        while (tsrx.findAny(source, index, "\\\"'();{}")) |found| : (index += 1) {
            index = @intCast(found);
            switch (source[index]) {
                '\\' => index += 1,
                '"', '\'' => |char| {
                    if (quote == 0) quote = char else if (quote == char) quote = 0;
                },
                '(' => url = url or std.mem.endsWith(u8, source[from..index], "url"),
                ')' => url = false,
                else => if (quote == 0 and !url) return index,
            }
        }
        css.index = @intCast(source.len);
        return css.fail("Unexpected end of input");
    }

    fn skipTrivia(css: *Css) Failure!void {
        while (true) {
            css.skipWhitespace();
            if (css.eatText("/*")) {
                try css.skipPast("*/");
            } else if (css.eatText("<!--")) {
                try css.skipPast("-->");
            } else {
                return;
            }
        }
    }

    fn skipPast(css: *Css, comptime close: []const u8) Failure!void {
        if (css.index == css.source.len) return css.fail("Unexpected end of input");
        const found = std.mem.findPos(u8, css.source, css.index, close) orelse {
            css.index = @intCast(css.source.len);
            return css.fail("Expected " ++ close);
        };
        css.index = @intCast(found + close.len);
    }

    fn skipWhitespace(css: *Css) void {
        css.index = spaceEnd(css.source, css.index);
    }

    fn atClose(css: *const Css, nested: bool) bool {
        return css.at(if (nested) ')' else '{');
    }

    fn at(css: *const Css, char: u8) bool {
        return css.index < css.source.len and css.source[css.index] == char;
    }

    fn eat(css: *Css, char: u8) bool {
        if (!css.at(char)) return false;
        css.index += 1;
        return true;
    }

    fn eatText(css: *Css, comptime prefix: []const u8) bool {
        if (!std.mem.startsWith(u8, css.source[css.index..], prefix)) return false;
        css.index += prefix.len;
        return true;
    }

    fn expect(css: *Css, comptime char: u8) Failure!void {
        if (!css.eat(char)) return css.fail("Expected " ++ .{char});
    }

    fn trim(css: *const Css, start: u32, end: u32) Span {
        var span: Span = .{ .start = spaceEnd(css.source[0..end], start), .end = end };
        while (span.end > span.start and isSpace(css.source[span.end - 1])) span.end -= 1;
        return span;
    }

    fn text(css: *Css, span: Span) Error!NodeIndex {
        return css.p.addNode(.text, &.{}, span);
    }

    // ending at the current index
    fn node(css: *Css, kind: Node, children: []const NodeIndex, start: u32) Error!NodeIndex {
        return css.add(kind, children, start, css.index);
    }

    fn add(
        css: *Css,
        kind: Node,
        children: []const NodeIndex,
        start: u32,
        end: u32,
    ) Error!NodeIndex {
        return css.p.addNode(kind, children, .{ .start = start, .end = end });
    }

    fn fail(css: *Css, comptime message: []const u8) Failure {
        const end = @min(css.index + 1, css.source.len);
        try css.p.report(.{ .start = css.index, .end = @intCast(end) }, "TSRX3013: " ++ message);
        return error.InvalidCss;
    }
};

fn isIdentifierChar(char: u8) bool {
    return char >= 0x80 or std.ascii.isAlphanumeric(char) or char == '_' or char == '-';
}

// https://www.w3.org/TR/css-syntax-3/#whitespace
fn isSpace(char: u8) bool {
    return switch (char) {
        ' ', '\t', '\n', '\r', 0x0c => true,
        else => false,
    };
}

fn spaceEnd(source: []const u8, start: u32) u32 {
    return runEnd(source, start, isSpace);
}

fn digitsEnd(source: []const u8, start: u32) u32 {
    return runEnd(source, start, std.ascii.isDigit);
}

fn runEnd(source: []const u8, start: u32, comptime class: fn (u8) bool) u32 {
    var index = start;
    while (index < source.len and class(source[index])) index += 1;
    return index;
}
