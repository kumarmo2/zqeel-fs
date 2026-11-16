const std = @import("std");
const c = @import("ffi");

// This advisory lock coordinates cooperating zqueel-fs instances only. The
// database pathname must remain stable while SQLite and this descriptor are open.
pub fn acquire(fd: c_int, path: [:0]const u8) !void {
    while (true) {
        const result = std.os.linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB);
        switch (std.os.linux.errno(result)) {
            .SUCCESS => return,
            .INTR => continue,
            .AGAIN => {
                std.debug.print("Database is already in use: {s}\n", .{path});
                return error.DatabaseInUse;
            },
            else => |errno| {
                std.debug.print("Cannot lock database: {s} (errno {d})\n", .{ path, @intFromEnum(errno) });
                return error.DatabaseLock;
            },
        }
    }
}

pub fn open(path: [:0]const u8) !c_int {
    const fd = c.open(path.ptr, c.O_RDWR | c.O_CLOEXEC);
    if (fd < 0) {
        std.debug.print("Cannot open database for locking: {s}\n", .{path});
        return error.DatabaseOpen;
    }
    errdefer _ = c.close(fd);
    try acquire(fd, path);
    return fd;
}

test "exclusive ownership contends across processes and releases on close" {
    const linux = std.os.linux;
    // An anonymous file avoids touching an existing database or leaving artifacts.
    const fd_result = linux.memfd_create("zqueel-lock-test", 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(fd_result));
    const fd: linux.fd_t = @intCast(fd_result);
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/fd/{d}", .{ linux.getpid(), fd }, 0);
    try acquire(fd, path);

    const child_result = linux.fork();
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(child_result));
    if (child_result == 0) {
        // Drop the inherited open-file description before trying a new one.
        _ = linux.close(fd);
        const other = open(path) catch |err| {
            linux.exit_group(if (err == error.DatabaseInUse) 0 else 2);
        };
        _ = linux.close(other);
        linux.exit_group(1);
    }
    const child: linux.pid_t = @intCast(child_result);
    var status: i32 = 0;
    while (true) {
        const result = linux.waitpid(child, &status, 0);
        if (linux.errno(result) == .INTR) continue;
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(result));
        try std.testing.expectEqual(child_result, result);
        break;
    }
    try std.testing.expectEqual(@as(i32, 0), status);

    // Separate open descriptions contend even in one process.
    try std.testing.expectError(error.DatabaseInUse, open(path));
    const keeper_result = linux.open(path.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(keeper_result));
    const keeper: linux.fd_t = @intCast(keeper_result);
    defer _ = linux.close(keeper);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.close(fd)));
    const keeper_path = try std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/fd/{d}", .{ linux.getpid(), keeper }, 0);
    const next = try open(keeper_path);
    _ = linux.close(next);
}
