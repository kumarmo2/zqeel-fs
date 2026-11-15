const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const exe = b.addExecutable(.{
        .name = "zqueel-fs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = target,
        }),
    });

    const ffi = b.addTranslateC(.{ .root_source_file = b.path("src/ffi.h"), .target = target, .optimize = optimize });
    exe.root_module.addImport("ffi", ffi.createModule());
    exe.root_module.link_libc = true;
    exe.root_module.linkSystemLibrary("sqlite3", .{});
    exe.root_module.linkSystemLibrary("fuse3", .{});
    exe.root_module.addAnonymousImport("schema.sql", .{ .root_source_file = b.path("schema.sql") });

    b.installArtifact(exe);
}
