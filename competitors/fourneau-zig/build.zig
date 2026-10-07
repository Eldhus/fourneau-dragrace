//! The fourneau-zig competitor: a Zig app on fourneau, built from the
//! fourneau checkout beside this repository (../fourneau; see
//! RACING.md, "Layout").
//!
//!   zig build -Doptimize=safe     ReleaseSafe, as fourneau ships
//!   zig build test                the handler's own tests

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const fourneau = b.dependency("fourneau", .{});
    const exe = b.addExecutable(.{
        .name = "fourneau-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fourneau", .module = fourneau.module("fourneau") },
                .{ .name = "zig_io_evented", .module = fourneau.module("zig_io_evented") },
            },
        }),
    });
    b.installArtifact(exe);

    // The modules with no fourneau in them, tested alone.
    const test_step = b.step("test", "Run the handler's tests");
    for ([_][]const u8{ "src/datastar.zig", "src/template.zig" }) |path| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }) });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
