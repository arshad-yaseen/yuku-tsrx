const std = @import("std");
const parser = @import("parser");

const testing = std.testing;

test "the parser module reads TSRX into dialect nodes" {
    const source =
        \\export function Card({ title }) @{
        \\  <article>
        \\    <h1>{title}</h1>
        \\    <style>h1 { color: red }</style>
        \\  </article>
        \\}
    ;
    var tree = try parser.parse(testing.allocator, source, .{});
    defer tree.deinit();
    try testing.expectEqual(0, tree.diagnostics.items.len);

    var kinds: std.EnumArray(parser.dialect.Kind, u32) = .initFill(0);
    for (tree.nodes.items(.data)) |data| switch (data) {
        .dialect => |node| kinds.getPtr(node.kind).* += 1,
        else => {},
    };
    try testing.expectEqual(1, kinds.get(.style));
    try testing.expectEqual(1, kinds.get(.style_sheet));
    try testing.expectEqual(1, kinds.get(.declaration));
}
