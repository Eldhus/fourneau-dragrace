//! The fourneau-zig competitor: a Zig app on fourneau, built from the
//! fourneau checkout beside this repository (../fourneau).
//!
//!   zig build          zig-out/bin/fourneau-zig, as the race builds it
//!   zig build test     the handler's own tests

const std = @import("std");

pub fn build(b: *std.Build) void {
    // The race's CPU level (CONTRIBUTING.md, "The contract"): x86-64-v3 with AES
    // and PCLMUL, so std.crypto's AES-GCM and GHASH are the hardware's.
    const target = b.standardTargetOptions(.{ .default_target = .{
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 },
        .cpu_features_add = std.Target.x86.featureSet(&.{ .aes, .pclmul }),
    } });
    // ReleaseSafe, as fourneau ships: assertions on.
    const optimize = b.option(std.builtin.Optimize, "optimize", "The mode (default safe)") orelse
        .safe;
    const fourneau = b.dependency("fourneau", .{});
    // The conduit workload's SQLite: the amalgamation roux vendors, in the
    // roux checkout beside this repository, compiled
    // in; its header translated for Zig.
    const sqlite_dir = "../../../roux/vendor/sqlite/";
    const sqlite_c = b.addTranslateC(.{
        .root_source_file = b.path(sqlite_dir ++ "sqlite3.h"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "fourneau-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fourneau", .module = fourneau.module("fourneau") },
                .{ .name = "zig_io_evented", .module = fourneau.module("zig_io_evented") },
                .{ .name = "sqlite_c", .module = sqlite_c.createModule() },
            },
            .link_libc = true,
        }),
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path(sqlite_dir ++ "sqlite3.c"),
        // Each shard's connection is its thread's alone: multi-thread mode.
        .flags = &.{ "-DSQLITE_THREADSAFE=2", "-DSQLITE_DQS=0", "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_OMIT_DEPRECATED" },
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
