//! TSRX as a Yuku dialect (https://github.com/yuku-toolchain/yuku/blob/main/src/parser/dialect/README.md), following the [TSRX specification](https://tsrx.dev/specification).

const std = @import("std");
const yuku = @import("parser");
const css = @import("css.zig");

const ast = yuku.ast;
const dialect = yuku.dialect;

const Claim = dialect.Claim;
const Error = std.mem.Allocator.Error;
const NodeIndex = ast.NodeIndex;
const Parser = dialect.Parser;
const Token = ast.Token;

pub const files: []const dialect.File = &.{.{ .extension = ".tsrx", .lang = .tsx }};

pub const Node = enum {
    code_block,
    template,
    @"if",
    else_if,
    @"for",
    for_await,
    @"switch",
    case,
    @"try",
    @"catch",
    style,
    shorthand,
    style_sheet,
    rule,
    atrule,
    block,
    declaration,
    selector_list,
    complex_selector,
    relative_selector,
    combinator,
    descendant_combinator,
    type_selector,
    id_selector,
    class_selector,
    pseudo_class_selector,
    pseudo_element_selector,
    attribute_selector,
    nesting_selector,
    nth,
    percentage,
    text,

    pub fn shape(node: Node) dialect.Shape {
        return switch (node) {
            .code_block => .{
                .type = "JSXCodeBlock",
                .fields = &.{ "body[]", "render" },
                .block_scope = true,
            },
            .template => .{ .type = "BlockStatement", .fields = &.{"body[]"}, .block_scope = true },
            .@"if" => .{
                .type = "JSXIfExpression",
                .fields = &.{ "test", "consequent", "alternate" },
                .properties = "{\"statementType\":\"IfStatement\"}",
            },
            .else_if => .{
                .type = "IfStatement",
                .fields = &.{ "test", "consequent", "alternate" },
            },
            .@"for", .for_await => .{
                .type = "JSXForExpression",
                .fields = &.{ "left", "right", "index", "key", "body", "empty" },
                .properties = if (node == .for_await)
                    "{\"await\":true,\"statementType\":\"ForOfStatement\"}"
                else
                    "{\"await\":false,\"statementType\":\"ForOfStatement\"}",
                .block_scope = true,
                .lexical_bindings = true,
                .iteration = true,
            },
            .@"switch" => .{
                .type = "JSXSwitchExpression",
                .fields = &.{ "discriminant", "cases[]" },
                .properties = "{\"statementType\":\"SwitchStatement\"}",
                .@"switch" = true,
            },
            .case => .{ .type = "SwitchCase", .fields = &.{ "test", "consequent[]" } },
            .@"try" => .{
                .type = "JSXTryExpression",
                .fields = &.{ "block", "pending", "handler" },
                .properties = "{\"finalizer\":null,\"statementType\":\"TryStatement\"}",
            },
            .@"catch" => .{
                .type = "CatchClause",
                .fields = &.{ "param", "resetParam", "body" },
                .block_scope = true,
                .catch_bindings = true,
            },
            .style => .{
                .type = "JSXStyleElement",
                .fields = &.{ "openingElement", "children[]", "closingElement" },
            },
            .shorthand => .{
                .type = "JSXAttribute",
                .fields = &.{ "name", "value" },
                .properties = "{\"shorthand\":true}",
            },
            else => css.shape(node),
        };
    }
};

/// A construct, or an element that needs no `;`, as a statement.
pub fn statement(p: *Parser) Error!Claim {
    const token = p.token();
    if (token.tag != .less_than and constructAt(p, token) == null) return .decline;

    const value = try p.parseExpression(ast.Precedence.Lowest) orelse return .failed;
    const value_end = p.tree().span(value).end;
    const end = if (isElement(p.tree(), value) and p.token().tag != .semicolon)
        value_end
    else
        try p.semicolon(value_end) orelse return .failed;
    return claimed(try p.tree().addNode(
        .{ .expression_statement = .{ .expression = value } },
        .{ .start = token.span.start, .end = end },
    ));
}

/// A construct or a `<style>` element as a value.
pub fn expression(p: *Parser) Error!Claim {
    const token = p.token();
    const value = switch (token.tag) {
        .at => try parseConstruct(p, constructAt(p, token) orelse return .decline),
        .less_than => if (opensStyle(p, token.span.end)) try parseElement(p) else return .decline,
        .spread => {
            const brace = attributeBrace(p.tree().source, token.span.start) orelse return .decline;
            try p.report(.{ .start = brace, .end = brace + 1 }, "TSRX1006: Attribute values " ++
                "cannot be spread. Use a spread attribute (`{...props}`) instead.");
            return .failed;
        },
        else => return .decline,
    } orelse return .failed;
    if (!try p.advance()) return .failed;
    return claimed(value);
}

/// A tag or a subscript after output, or a tag starting a line, ends the expression.
pub fn operator(p: *Parser, left: NodeIndex, _: u8) Error!Claim {
    const token = p.token();
    const output = isOutput(p.tree(), left);
    if (output and token.tag.precedence() == ast.Precedence.Call) return .end;
    const tag = token.tag == .less_than and opensTag(p.tree().source, token.span.end);
    const ends = tag and (output or token.hasLineTerminatorBefore());
    return if (ends) .end else .decline;
}

/// A code block as a function body.
pub fn function_body(p: *Parser) Error!Claim {
    const start = p.token().span.start;
    if (constructAt(p, p.token()) != .code_block) return .decline;

    if (!try p.advance()) return .failed;
    const body = try parseCodeBlock(p, start, .any) orelse return .failed;
    if (!try p.advance()) return .failed;
    return claimed(body);
}

/// Template text, comments, constructs, containers, raw bodies, and closing tags.
pub fn jsx_child(p: *Parser, offset: u32, parent: NodeIndex) Error!Claim {
    const source = p.tree().source;
    if (offset == p.tree().span(parent).end) {
        if (try parseRawBody(p, parent, offset)) |claim| return claim;
    }
    if (offset == source.len) return unclosed(p, parent);

    switch (source[offset]) {
        '@' => if (constructAt(p, p.tokenAt(offset))) |construct| {
            if (!try p.seek(offset)) return .failed;
            return claimed(try parseConstruct(p, construct) orelse return .failed);
        },
        '<' => if (std.mem.startsWith(u8, source[offset + 1 ..], "/")) {
            return closingTag(p, parent, offset);
        } else if (opensStyle(p, offset + 1)) {
            if (!try p.seek(offset)) return .failed;
            return claimed(try parseElement(p) orelse return .failed);
        },
        '{' => if (p.tokenAt(offset + 1).tag != .spread) {
            if (!try p.seek(offset)) return .failed;
            return claimed(try parseContainer(p) orelse return .failed);
        },
        '}' => return unclosed(p, parent),
        '/' => if (commentAt(source, offset, offset)) |comment| {
            try p.recordComment(comment.type, comment.span);
            const empty = try p.tree().addNode(.{ .jsx_empty_expression = .{} }, comment.span);
            return claimed(try p.tree().addNode(
                .{ .jsx_expression_container = .{ .expression = empty } },
                comment.span,
            ));
        },
        else => {},
    }

    const end = textEnd(p, offset);
    if (end == offset) return .decline;
    return claimed(try p.addJsxText(.{ .start = offset, .end = end }));
}

/// `{name}` as an attribute, short for `name={name}`.
pub fn jsx_attribute(p: *Parser) Error!Claim {
    if (p.tokenAt(p.token().span.end).tag == .spread) return .decline;

    const container = try p.parseJsxExpressionContainer() orelse return .failed;
    const value = p.tree().data(container).jsx_expression_container.expression;
    if (p.tree().data(value) != .identifier_reference) {
        try p.report(p.tree().span(container), "A shorthand attribute names one identifier");
        return .failed;
    }
    const name = try p.tree().addNode(.{ .jsx_identifier = .{
        .name = p.tree().data(value).identifier_reference.name,
    } }, p.tree().span(value));
    return claimed(try p.addNode(.shorthand, &.{ name, container }, p.tree().span(container)));
}

/// `<{expression}>`, and no namespaced tags.
pub fn jsx_element_name(p: *Parser) Error!Claim {
    const token = p.token();
    if (token.tag == .jsx_identifier) {
        const colon = p.tokenAt(token.span.end);
        if (colon.tag != .colon) return .decline;
        const end = p.tokenAt(colon.span.end).span.end;
        const span: ast.Span = .{ .start = token.span.start, .end = end };
        try reportFormat(p, span, "TSRX1005: Namespaced elements are not supported in TSRX " ++
            "templates: <{s}>.", .{spanText(p, span)});
        return .failed;
    }
    if (token.tag != .left_brace) return .decline;

    if (p.tokenAt(token.span.end).tag == .spread) {
        try p.report(token.span, dynamic_tag_error);
        return .failed;
    }
    const container = try p.parseJsxExpressionContainer() orelse return .failed;
    const tree = p.tree();
    const before = std.mem.trimEnd(u8, tree.source[0..token.span.start], &std.ascii.whitespace);
    if (!std.mem.endsWith(u8, before, "/")) {
        const tag = tree.data(container).jsx_expression_container.expression;
        if (invalidTagPart(tree, tag)) |part| try p.report(tree.span(part), dynamic_tag_error);
    }
    return claimed(container);
}

/// A submodule named by an identifier, as in `import { load } from server`.
pub fn module_specifier(p: *Parser) Error!Claim {
    if (!p.token().tag.isIdentifierLike()) return .decline;

    const name = try p.parseExpression(ast.Precedence.Grouping) orelse return .failed;
    if (p.tree().data(name) != .identifier_reference) {
        try p.report(p.tree().span(name), "Expected a module specifier, a string or a submodule");
        return .failed;
    }
    return claimed(name);
}

const dynamic_tag_error = "TSRX2014: A dynamic tag expression must be an identifier, a " ++
    "member access such as `props.as` or `registry[name]`, or a string literal. Compute " ++
    "anything else before the element: `const Tag = c ? Child : Fallback;`, then `<{Tag} />`.";

const Construct = enum { code_block, @"if", @"for", @"switch", @"try" };

fn constructAt(p: *const Parser, at: Token) ?Construct {
    if (at.tag != .at) return null;
    const word = p.tokenAt(at.span.end);
    if (word.span.start != at.span.end or word.isEscaped()) return null;
    const next = p.tokenAt(word.span.end);
    return switch (word.tag) {
        .left_brace => .code_block,
        .@"try" => if (next.tag == .left_brace) .@"try" else null,
        .@"if" => if (next.tag == .left_paren) .@"if" else null,
        .@"switch" => if (next.tag == .left_paren) .@"switch" else null,
        .@"for" => switch (next.tag) {
            .left_paren => .@"for",
            .await => if (p.tokenAt(next.span.end).tag == .left_paren) .@"for" else null,
            else => null,
        },
        else => null,
    };
}

fn parseConstruct(p: *Parser, construct: Construct) Error!?NodeIndex {
    p.endDirectivePrologue();
    const start = p.token().span.start;
    if (!try p.advance()) return null;
    return switch (construct) {
        .code_block => parseCodeBlock(p, start, .code_block),
        .@"if" => parseIf(p, .@"if", start),
        .@"for" => parseFor(p, start),
        .@"switch" => parseSwitch(p, start),
        .@"try" => parseTry(p, start),
    };
}

fn parseCodeBlock(p: *Parser, start: u32, rule: Rule) Error!?NodeIndex {
    var items = p.list();
    defer items.reset();
    if (!(try parseItems(p, &items, rule) orelse return null)) try items.append(.null);
    return try addNodeTo(p, .code_block, items.items(), start);
}

fn parseTemplate(p: *Parser, rule: Rule) Error!?NodeIndex {
    const open = p.token();
    if (open.tag != .left_brace) {
        try p.report(open.span, "TSRX1008: Expected `{` after JSX control-flow directive.");
        return null;
    }

    var items = p.list();
    defer items.reset();
    _ = try parseItems(p, &items, rule) orelse return null;
    return try addNodeTo(p, .template, items.items(), open.span.start);
}

const Rule = enum { any, code_block, try_body, case };

// returns whether the last item is output
fn parseItems(p: *Parser, items: *const dialect.List, rule: Rule) Error!?bool {
    if (!try p.advance()) return null;

    var output = false;
    var output_seen = false;
    while (true) {
        const token = p.token();
        switch (token.tag) {
            .right_brace => return output,
            .eof => {
                try p.report(token.span, "Expected '}' to close the template");
                return null;
            },
            .semicolon => {
                if (!try p.advance()) return null;
                continue;
            },
            .@"break" => if (rule == .case) {
                try p.report(token.span, "TSRX2008: `break` is invalid inside `@switch` cases.");
            },
            .@"return" => if (rule == .case) {
                try p.report(token.span, "TSRX2009: `return` is invalid inside `@switch` cases.");
            },
            else => {},
        }

        const first: u32 = @intCast(p.tree().nodes.len);
        const construct = constructAt(p, token);
        output = construct != null or token.tag == .less_than;
        const item = (if (construct) |opened|
            try parseConstruct(p, opened)
        else if (output)
            try parseElement(p)
        else
            try p.parseStatement()) orelse return null;
        if (output and !try p.advance()) return null;
        try items.append(item);

        if (output_seen) try p.report(p.tree().span(item), if (output)
            "TSRX2011: A code block renders a single node; wrap multiple nodes or text in a " ++
                "fragment '<>…</>'."
        else
            "TSRX2012: Code must be at the top of '@{ }'; statements cannot follow the " ++
                "rendered output.");
        output_seen = output_seen or output;
        if (rule == .try_body or rule == .code_block and !output) try reportReturns(p, first);
    }
}

// a node comes after those it holds, so scanning back skips what a function, a loop, or a
// template checking its own returns holds
fn reportReturns(p: *Parser, first: u32) Error!void {
    const tree = p.tree();
    var skipped: ast.Span = .{ .start = 0, .end = 0 };
    var index: u32 = @intCast(tree.nodes.len);
    while (index > first) {
        index -= 1;
        const node: NodeIndex = @fromBackingInt(index);
        const span = tree.span(node);
        if (span.start >= skipped.start and span.end <= skipped.end) continue;
        switch (tree.data(node)) {
            .function,
            .arrow_function_expression,
            .for_statement,
            .for_in_statement,
            .for_of_statement,
            .while_statement,
            .do_while_statement,
            => skipped = span,
            .dialect => |data| if (data.kind == .code_block or data.kind == .@"try") {
                skipped = span;
            },
            .return_statement => try p.report(span, "TSRX2001: Return statements are not " ++
                "allowed inside TSRX templates. Move the return before the TSRX return value, " ++
                "or use conditional rendering instead."),
            else => {},
        }
    }
}

fn parseContainer(p: *Parser) Error!?NodeIndex {
    const start = p.token().span.start;
    if (!try p.advance()) return null;

    const value = if (p.token().tag == .right_brace)
        try p.tree().addNode(.{ .jsx_empty_expression = .{} }, .{
            .start = start + 1,
            .end = p.token().span.start,
        })
    else
        try p.parseExpression(ast.Precedence.Assignment) orelse return null;
    switch (p.token().tag) {
        .right_brace => return try p.tree().addNode(
            .{ .jsx_expression_container = .{ .expression = value } },
            .{ .start = start, .end = p.token().span.end },
        ),
        .semicolon => try p.report(p.token().span, "TSRX1007: TSRX expression containers do " ++
            "not use semicolons. Remove this semicolon."),
        else => try p.report(p.token().span, "Expected '}' to close the expression"),
    }
    return null;
}

fn parseIf(p: *Parser, kind: Node, start: u32) Error!?NodeIndex {
    if (!try p.advance()) return null;

    const condition = try parseHead(p) orelse return null;
    const consequent = try parseTemplate(p, .any) orelse return null;
    var alternate: NodeIndex = .null;
    if (hasClause(p, "else")) {
        if (!try enterClause(p)) return null;
        alternate = if (p.token().tag == .@"if")
            try parseIf(p, .else_if, p.token().span.start) orelse return null
        else
            try parseTemplate(p, .any) orelse return null;
    } else if (try reportedBareClause(p, "else", "if", &.{ .left_brace, .@"if" })) {
        return null;
    }
    return try addNodeTo(p, kind, &.{ condition, consequent, alternate }, start);
}

fn parseFor(p: *Parser, start: u32) Error!?NodeIndex {
    if (!try p.advance()) return null;
    const kind: Node = if (p.token().tag == .await) .for_await else .@"for";
    if (kind == .for_await) {
        if (!p.canAwait()) {
            try p.report(p.token().span, "'for await' is only valid in async functions or " ++
                "modules");
        }
        if (!try p.advance()) return null;
    }
    if (!try p.expect(.left_paren, "Expected '(' after `@for`")) return null;

    const left = try parseForLeft(p) orelse return null;
    if (p.token().tag != .of) {
        try p.report(p.token().span, "TSRX2015: TSRX `@for` currently supports `for...of` " ++
            "loops in template output.");
        return null;
    }
    if (p.tree().data(left) != .variable_declaration) try p.toPattern(left, .assignable);
    if (!try p.advance()) return null;
    const right = try p.parseExpression(ast.Precedence.Assignment) orelse return null;

    var index: NodeIndex = .null;
    var key: NodeIndex = .null;
    if (p.token().tag == .semicolon) {
        if (!try p.advance()) return null;
        if (isWord(p, p.token(), "index")) {
            if (!try p.advance()) return null;
            index = try parseForIndex(p) orelse return null;
            if (p.token().tag == .semicolon and !try p.advance()) return null;
        }
        if (isWord(p, p.token(), "key")) {
            if (!try p.advance()) return null;
            key = try p.parseExpression(ast.Precedence.Lowest) orelse return null;
        }
        if (isWord(p, p.token(), "index")) {
            try p.report(p.token().span, "TSRX1011: \"index\" must come before \"key\" in " ++
                "for-of loop");
            return null;
        }
    }
    if (!try p.expect(.right_paren, "Expected ')' to close the `@for` head")) return null;

    const body = try parseTemplate(p, .any) orelse return null;
    var empty: NodeIndex = .null;
    if (hasClause(p, "empty")) {
        if (!try enterClause(p)) return null;
        empty = try parseTemplate(p, .any) orelse return null;
    } else if (try reportedBareClause(p, "empty", "for", &.{.left_brace})) {
        return null;
    }
    return try addNodeTo(p, kind, &.{ left, right, index, key, body, empty }, start);
}

fn parseForLeft(p: *Parser) Error!?NodeIndex {
    const token = p.token();
    const kind: ast.VariableKind = switch (token.tag) {
        .@"const" => .@"const",
        .let => .let,
        .@"var" => .@"var",
        else => return p.parseExpression(ast.Precedence.Assignment),
    };
    if (!try p.advance()) return null;

    const id = try p.parseBindingPattern() orelse return null;
    const declarator = try p.tree().addNode(
        .{ .variable_declarator = .{ .id = id, .init = .null } },
        p.tree().span(id),
    );
    return try p.tree().addNode(.{ .variable_declaration = .{
        .kind = kind,
        .declarators = try p.tree().addExtra(&.{declarator}),
    } }, .{ .start = token.span.start, .end = p.tree().span(id).end });
}

fn parseForIndex(p: *Parser) Error!?NodeIndex {
    const index = try p.parseExpression(ast.Precedence.Lowest) orelse return null;
    const tree = p.tree();
    if (tree.data(index) != .identifier_reference) {
        try p.report(tree.span(index), "TSRX1011: Expected identifier after \"index\" keyword");
        return null;
    }
    const name = tree.data(index).identifier_reference.name;
    tree.setData(index, .{ .binding_identifier = .{ .name = name } });
    return index;
}

fn parseSwitch(p: *Parser, start: u32) Error!?NodeIndex {
    if (!try p.advance()) return null;
    const discriminant = try parseHead(p) orelse return null;
    if (!try p.expect(.left_brace, "Expected '{' to open the `@switch` body")) return null;

    var children = p.list();
    defer children.reset();
    try children.append(discriminant);
    var default_seen = false;
    while (p.token().tag != .right_brace) {
        const default = isWord(p, p.tokenAt(p.token().span.end), "default");
        const case = try parseCase(p) orelse return null;
        if (default and default_seen) {
            try p.report(p.tree().span(case), "A switch statement can only have one default " ++
                "clause");
        }
        default_seen = default_seen or default;
        try children.append(case);
        if (!try p.advance()) return null;
    }
    return try addNodeTo(p, .@"switch", children.items(), start);
}

fn parseCase(p: *Parser) Error!?NodeIndex {
    const at = p.token();
    const word = p.tokenAt(at.span.end);
    const case = isWord(p, word, "case");
    if (at.tag != .at or word.span.start != at.span.end or !(case or isWord(p, word, "default"))) {
        try p.report(at.span, "Expected `@case` or `@default` in a `@switch` body");
        return null;
    }
    if (!try p.advance() or !try p.advance()) return null;

    var condition: NodeIndex = .null;
    if (case) condition = try p.parseExpression(ast.Precedence.Lowest) orelse return null;
    if (!try p.expect(.colon, "Expected ':' after the case")) return null;

    const body = try parseTemplate(p, .case) orelse return null;
    return try addNodeTo(p, .case, &.{ condition, body }, at.span.start);
}

fn parseTry(p: *Parser, start: u32) Error!?NodeIndex {
    const keyword = p.token().span;
    if (!try p.advance()) return null;
    const block = try parseTemplate(p, .try_body) orelse return null;

    var pending: NodeIndex = .null;
    if (hasClause(p, "pending")) {
        if (!try enterClause(p)) return null;
        pending = try parseTemplate(p, .try_body) orelse return null;
    }
    var handler: NodeIndex = .null;
    if (hasClause(p, "catch")) {
        handler = try parseCatch(p) orelse return null;
    } else if (try reportedBareClause(p, "catch", "try", &.{ .left_brace, .left_paren })) {
        return null;
    }
    if (pending == .null and handler == .null) {
        if (try reportedBareClause(p, "pending", "try", &.{.left_brace})) return null;
        try p.report(keyword, "TSRX1010: Missing `@catch` or `@pending` after `@try` block.");
        return null;
    }
    return try addNodeTo(p, .@"try", &.{ block, pending, handler }, start);
}

fn parseCatch(p: *Parser) Error!?NodeIndex {
    const start = p.tokenAt(p.token().span.end).span.start;
    if (!try enterClause(p)) return null;

    var param: NodeIndex = .null;
    var reset: NodeIndex = .null;
    if (p.token().tag == .left_paren) {
        if (!try p.advance()) return null;
        param = try p.parseBindingPattern() orelse return null;
        if (p.token().tag == .comma) {
            if (!try p.advance()) return null;
            reset = try p.parseBindingPattern() orelse return null;
            if (p.tree().data(reset) != .binding_identifier) {
                try p.report(p.tree().span(reset), "The reset parameter of `@catch` names " ++
                    "one identifier");
            }
        }
        if (!try p.expect(.right_paren, "Expected ')' to close the `@catch` parameters")) {
            return null;
        }
    }
    const body = try parseTemplate(p, .try_body) orelse return null;
    return try addNodeTo(p, .@"catch", &.{ param, reset, body }, start);
}

fn parseHead(p: *Parser) Error!?NodeIndex {
    if (!try p.expect(.left_paren, "Expected '(' after the directive")) return null;
    const head = try p.parseExpression(ast.Precedence.Lowest) orelse return null;
    if (!try p.expect(.right_paren, "Expected ')' to close the directive head")) return null;
    return head;
}

fn hasClause(p: *const Parser, word: []const u8) bool {
    const at = p.tokenAt(p.token().span.end);
    if (at.tag != .at) return false;
    const name = p.tokenAt(at.span.end);
    return name.span.start == at.span.end and isWord(p, name, word);
}

fn enterClause(p: *Parser) Error!bool {
    return try p.advance() and try p.advance() and try p.advance();
}

fn reportedBareClause(
    p: *Parser,
    comptime word: []const u8,
    comptime directive: []const u8,
    comptime continuations: []const ast.TokenTag,
) Error!bool {
    const name = p.tokenAt(p.token().span.end);
    if (!isWord(p, name, word)) return false;
    if (std.mem.findScalar(ast.TokenTag, continuations, p.tokenAt(name.span.end).tag) == null) {
        return false;
    }
    try p.report(name.span, "TSRX1009: Expected `@" ++ word ++ "` after `@" ++ directive ++
        "` block.");
    return true;
}

fn parseElement(p: *Parser) Error!?NodeIndex {
    const tree = p.tree();
    const element = try p.parseJsxElement() orelse return null;
    if (tree.data(element) != .jsx_element) return element;
    const parts = tree.data(element).jsx_element;
    if (rawElement(tree, parts.opening_element) != .style) return element;
    const children = tree.extra(parts.children);
    if (children.len == 0 and parts.closing_element == .null) {
        return try p.addNode(.style, &.{ parts.opening_element, .null }, tree.span(element));
    }
    const sheet = switch (children.len) {
        0 => empty: {
            const at = tree.span(parts.opening_element).end;
            break :empty (try css.parse(p, .{ .start = at, .end = at })).?;
        },
        1 => if (isKind(tree, children[0], .style_sheet)) children[0] else return element,
        else => return element,
    };
    const items = .{ parts.opening_element, sheet, parts.closing_element };
    return try p.addNode(.style, &items, tree.span(element));
}

const RawElement = enum { none, style, script };

fn rawElement(tree: *const ast.Tree, opening: NodeIndex) RawElement {
    if (tree.data(opening) != .jsx_opening_element) return .none;
    const name = tree.data(opening).jsx_opening_element.name;
    if (tree.data(name) != .jsx_identifier) return .none;
    const text = tree.string(tree.data(name).jsx_identifier.name);
    return std.meta.stringToEnum(RawElement, text) orelse .none;
}

fn parseRawBody(p: *Parser, opening: NodeIndex, start: u32) Error!?Claim {
    const source = p.tree().source;
    const raw = rawElement(p.tree(), opening);
    const end = switch (raw) {
        .none => return null,
        .style => end: {
            const body = std.mem.trimStart(u8, source[start..], &std.ascii.whitespace);
            if (std.mem.startsWith(u8, body, "{")) return null;
            break :end std.mem.findPos(u8, source, start, "</style>");
        },
        .script => try scriptEnd(p, start),
    } orelse return try unclosed(p, opening);
    if (end == start) return null;
    const span: ast.Span = .{ .start = start, .end = @intCast(end) };
    if (raw == .script) return claimed(try p.addJsxText(span));
    return claimed(try css.parse(p, span) orelse try p.addJsxText(span));
}

fn scriptEnd(p: *Parser, start: u32) Error!?usize {
    const source = p.tree().source;
    const tag = "</script";
    var index: usize = start;
    while (std.mem.findPos(u8, source, index, "</")) |found| : (index = found + 2) {
        if (!std.ascii.startsWithIgnoreCase(source[found..], tag)) continue;
        const written = source[found..][0..tag.len];
        const close = std.mem.findNonePos(u8, source, found + tag.len, " \t\n\x0c\r");
        if (std.mem.eql(u8, written, tag) and close != null and source[close.?] == '>') {
            return found;
        }
        const span: ast.Span = .{ .start = @intCast(found), .end = @intCast(found + tag.len) };
        try reportFormat(p, span, "TSRX1004: '{s}' can end a script in HTML, so a '<script>' " ++
            "body can't contain it. Write '<\\/{s}' instead.", .{ written, written[2..] });
    }
    return null;
}

fn closingTag(p: *Parser, opening: NodeIndex, offset: u32) Error!Claim {
    const source = p.tree().source;
    const name = tagName(p.tree(), opening);
    const end = std.mem.findScalarPos(u8, source, offset, '>') orelse source.len;
    const closing: ast.Span = .{ .start = offset + 2, .end = @intCast(end) };
    if (std.mem.eql(u8, spanText(p, closing), spanText(p, name)) or sameName(p, name, closing)) {
        return .decline;
    }

    const span: ast.Span = .{ .start = offset, .end = @intCast(@min(end + 1, source.len)) };
    const found = std.mem.trim(u8, spanText(p, closing), &std.ascii.whitespace);
    try reportFormat(p, span, "TSRX1002: Expected closing tag to match opening tag. Expected " ++
        "'</{s}>' but found '</{s}>'", .{ spanText(p, name), found });
    return .failed;
}

fn unclosed(p: *Parser, opening: NodeIndex) Error!Claim {
    const name = spanText(p, tagName(p.tree(), opening));
    try reportFormat(p, p.tree().span(opening), "TSRX1001: Unclosed tag '<{s}>'. Expected " ++
        "'</{s}>' before end of template.", .{ name, name });
    return .failed;
}

fn tagName(tree: *const ast.Tree, opening: NodeIndex) ast.Span {
    return switch (tree.data(opening)) {
        .jsx_opening_element => |element| tree.span(element.name),
        else => .{ .start = tree.span(opening).start, .end = tree.span(opening).start },
    };
}

fn sameName(p: *const Parser, a: ast.Span, b: ast.Span) bool {
    const source = p.tree().source;
    var a_at = a.start;
    var b_at = b.start;
    while (true) {
        const a_token = p.tokenAt(a_at);
        const b_token = p.tokenAt(b_at);
        const a_done = a_token.span.start >= a.end;
        const b_done = b_token.span.start >= b.end;
        if (a_done or b_done) return a_done and b_done;
        if (!std.mem.eql(u8, a_token.text(source), b_token.text(source))) return false;
        a_at = a_token.span.end;
        b_at = b_token.span.end;
    }
}

fn invalidTagPart(tree: *const ast.Tree, node: NodeIndex) ?NodeIndex {
    switch (tree.data(node)) {
        .identifier_reference => |id| {
            const undefined_tag = std.mem.eql(u8, tree.string(id.name), "undefined");
            return if (undefined_tag) node else null;
        },
        .string_literal => return null,
        .member_expression => |member| {
            const object = switch (tree.data(member.object)) {
                .this_expression => null,
                .identifier_reference, .member_expression => invalidTagPart(tree, member.object),
                else => member.object,
            };
            if (object != null or !member.computed) return object;
            return switch (tree.data(member.property)) {
                .identifier_reference, .string_literal, .numeric_literal => null,
                .member_expression => invalidTagPart(tree, member.property),
                else => member.property,
            };
        },
        else => return node,
    }
}

fn attributeBrace(source: []const u8, offset: u32) ?u32 {
    const brace = std.mem.trimEnd(u8, source[0..offset], &std.ascii.whitespace);
    if (!std.mem.endsWith(u8, brace, "{")) return null;
    const value = std.mem.trimEnd(u8, brace[0 .. brace.len - 1], &std.ascii.whitespace);
    return if (std.mem.endsWith(u8, value, "=")) @intCast(brace.len - 1) else null;
}

fn opensTag(source: []const u8, offset: u32) bool {
    if (offset == source.len) return false;
    return switch (source[offset]) {
        'a'...'z', 'A'...'Z', '$', '_', '/', '>', '{', '@' => true,
        else => false,
    };
}

fn isOutput(tree: *const ast.Tree, node: NodeIndex) bool {
    return switch (tree.data(node)) {
        .jsx_element, .jsx_fragment, .dialect => true,
        else => false,
    };
}

fn isKind(tree: *const ast.Tree, node: NodeIndex, kind: Node) bool {
    return switch (tree.data(node)) {
        .dialect => |data| data.kind == kind,
        else => false,
    };
}

fn isElement(tree: *const ast.Tree, node: NodeIndex) bool {
    return switch (tree.data(node)) {
        .jsx_element, .jsx_fragment => true,
        .dialect => |data| data.kind == .style,
        else => false,
    };
}

fn opensStyle(p: *const Parser, offset: u32) bool {
    if (!std.mem.startsWith(u8, p.tree().source[offset..], "style")) return false;
    const name = p.tokenAt(offset);
    return name.span.start == offset and isWord(p, name, "style");
}

fn isWord(p: *const Parser, token: Token, word: []const u8) bool {
    return std.mem.eql(u8, token.text(p.tree().source), word);
}

fn spanText(p: *const Parser, span: ast.Span) []const u8 {
    return p.tree().source[span.start..span.end];
}

// ending at the current token
fn addNodeTo(p: *Parser, kind: Node, children: []const NodeIndex, start: u32) Error!NodeIndex {
    return p.addNode(kind, children, .{ .start = start, .end = p.token().span.end });
}

fn reportFormat(p: *Parser, span: ast.Span, comptime format: []const u8, args: anytype) Error!void {
    try p.report(span, try std.fmt.allocPrint(p.tree().allocator(), format, args));
}

const Comment = struct { type: ast.Comment.Type, span: ast.Span };

// `a//b` stays text
fn commentAt(source: []const u8, index: u32, run_start: u32) ?Comment {
    if (index + 1 >= source.len) return null;
    switch (source[index + 1]) {
        '*' => {
            const close = std.mem.findPos(u8, source, index + 2, "*/");
            const end = if (close) |found| found + 2 else source.len;
            return .{ .type = .block, .span = .{ .start = index, .end = @intCast(end) } };
        },
        '/' => {
            if (index != run_start and !std.ascii.isWhitespace(source[index - 1])) return null;
            const end = std.mem.findAnyPos(u8, source, index, "\r\n") orelse source.len;
            return .{ .type = .line, .span = .{ .start = index, .end = @intCast(end) } };
        },
        else => return null,
    }
}

fn textEnd(p: *const Parser, start: u32) u32 {
    const source = p.tree().source;
    var index = start;
    while (findAny(source, index, "{}<@/")) |found| : (index += 1) {
        index = @intCast(found);
        const ends = switch (source[index]) {
            '{', '}' => true,
            '<' => opensTag(source, index + 1),
            '@' => constructAt(p, p.tokenAt(index)) != null,
            '/' => commentAt(source, index, start) != null,
            else => unreachable,
        };
        if (ends) return index;
    }
    return @intCast(source.len);
}

pub fn findAny(source: []const u8, start: usize, comptime set: []const u8) ?usize {
    const table = comptime table: {
        var table: [256]bool = @splat(false);
        for (set) |byte| table[byte] = true;
        break :table table;
    };
    for (source[start..], start..) |byte, index| if (table[byte]) return index;
    return null;
}

inline fn claimed(node: NodeIndex) Claim {
    return .{ .node = node };
}
