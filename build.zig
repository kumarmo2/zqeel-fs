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

    const test_step = b.step("test", "Run database lock, storage, and runtime tests");
    for ([_][]const u8{ "database_lock", "store", "runtime" }) |component| {
        const implementation = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{component})),
            .optimize = optimize,
            .target = target,
        });
        const suite = b.createModule(.{
            .root_source_file = b.path(b.fmt("tests/{s}_test.zig", .{component})),
            .optimize = optimize,
            .target = target,
        });
        suite.addImport(component, implementation);
        if (std.mem.eql(u8, component, "store")) {
            const bindings = ffi.createModule();
            implementation.addImport("ffi", bindings);
            suite.addImport("ffi", bindings);
            suite.addAnonymousImport("schema.sql", .{ .root_source_file = b.path("schema.sql") });
            suite.link_libc = true;
            suite.linkSystemLibrary("sqlite3", .{});
            suite.linkSystemLibrary("fuse3", .{});
        }
        const artifact = b.addTest(.{ .name = b.fmt("{s}_test", .{component}), .root_module = suite });
        test_step.dependOn(&b.addRunArtifact(artifact).step);
    }
}
