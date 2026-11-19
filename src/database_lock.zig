const std = @import("std");

// This advisory lock coordinates cooperating zqueel-fs instances only. The
// database pathname must remain stable while SQLite and this descriptor are open.
pub fn acquire(fd: c_int, path: [:0]const u8) !void {
    const result = std.os.linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB);
    // EINTR is reported as a lock error for now; revisit retries with shutdown handling.
    switch (std.os.linux.errno(result)) {
        .SUCCESS => return,
        .AGAIN => {
            std.debug.print("Database is already in use: {s}\n", .{path});
            return error.DatabaseInUse;
        },
        else => |errno| {
            std.debug.print("Cannot lock database: {s} (errno {d})\n", .{ path, @backingInt(errno) });
            return error.DatabaseLock;
        },
    }
}

pub fn open(path: [:0]const u8) !c_int {
    const result = std.os.linux.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);

    const fd: c_int = switch (std.os.linux.errno(result)) {
        .SUCCESS => @as(std.os.linux.fd_t, @intCast(result)),
        else => |errno| {
            std.debug.print("Cannot open database for locking, erro: {d}, path: {s}\n", .{ @backingInt(errno), path });
            return error.DatabaseOpen;
        },
    };

    errdefer _ = std.os.linux.close(fd);
    try acquire(fd, path);
    return fd;
}
