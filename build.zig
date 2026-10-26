const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const yuku = b.dependency("yuku", .{
        .target = target,
        .optimize = optimize,
        .dialect = b.path("src/tsrx.zig"),
    });

    const parser = yuku.module("parser");
    b.modules.put(b.graph.arena, "parser", parser) catch @panic("OOM");

    b.installArtifact(@import("yuku").addWasm(b, yuku, "yuku-tsrx"));
    @import("yuku").addAddons(b, yuku);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/parse.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "parser", .module = parser }},
    }) });
    b.step("test", "Run the Zig tests").dependOn(&b.addRunArtifact(tests).step);
}
