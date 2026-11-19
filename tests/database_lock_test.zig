const std = @import("std");
const lock = @import("database_lock");

test "exclusive ownership contends across processes and releases on close" {
    const linux = std.os.linux;
    // An anonymous file avoids touching an existing database or leaving artifacts.
    const fd_result = linux.memfd_create("zqueel-lock-test", 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(fd_result));
    const fd: linux.fd_t = @intCast(fd_result);
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/fd/{d}", .{ linux.getpid(), fd }, 0);
    try lock.acquire(fd, path);

    const child_result = linux.fork();
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(child_result));
    if (child_result == 0) {
        // Drop the inherited open-file description before trying a new one.
        _ = linux.close(fd);
        const other = lock.open(path) catch |err| {
            linux.exit_group(if (err == error.DatabaseInUse) 0 else 2);
        };
        _ = linux.close(other);
        linux.exit_group(1);
    }
    const child: linux.pid_t = @intCast(child_result);
    var status: i32 = 0;
    while (true) {
        const result = linux.waitpid(child, &status, 0);
        if (linux.errno(result) == .INTR) {
            continue;
        }
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(result));
        try std.testing.expectEqual(child_result, result);
        break;
    }
    try std.testing.expectEqual(@as(i32, 0), status);

    // Separate open descriptions contend even in one process.
    try std.testing.expectError(error.DatabaseInUse, lock.open(path));
    const keeper_result = linux.open(path.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(keeper_result));
    const keeper: linux.fd_t = @intCast(keeper_result);
    defer _ = linux.close(keeper);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.close(fd)));
    const keeper_path = try std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/fd/{d}", .{ linux.getpid(), keeper }, 0);
    const next = try lock.open(keeper_path);
    _ = linux.close(next);
}
