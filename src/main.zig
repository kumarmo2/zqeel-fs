const std = @import("std");
const c = @import("ffi");

const schema = @embedFile("schema.sql");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 3 and std.mem.eql(u8, args[1], "format")) {
        try format(args[2]);
    } else if (args.len == 4 and std.mem.eql(u8, args[1], "mount")) {
        try @import("mount.zig").mount(args[2], args[3]);
    } else {
        std.debug.print("Usage: zqueel-fs format <new-database>\n       zqueel-fs mount <database> <mountpoint>\n", .{});
        return error.InvalidArguments;
    }
}

fn exec(db: *c.sqlite3, sql: [*:0]const u8) !void {
    if (c.sqlite3_exec(db, sql, null, null, null) != c.SQLITE_OK) {
        std.debug.print("SQLite: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.Sqlite;
    }
}

fn format(path: [:0]const u8) !void {
    // Reserve the pathname exclusively: never format or truncate an existing file.
    const fd = c.open(path.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    if (fd < 0) {
        std.debug.print("Cannot create database exclusively: {s}\n", .{path});
        return error.CreateDatabase;
    }
    defer _ = c.close(fd);
    errdefer std.debug.print("Formatting failed; inspect the newly created file before removing it: {s}\n", .{path});
    try @import("database_lock.zig").acquire(fd, path);

    var maybe_db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2(path.ptr, &maybe_db, c.SQLITE_OPEN_READWRITE, null);
    const db = maybe_db orelse return error.Sqlite;
    defer _ = c.sqlite3_close(db);
    if (rc != c.SQLITE_OK) {
        std.debug.print("SQLite: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.Sqlite;
    }
    try exec(db, "PRAGMA foreign_keys=ON; BEGIN IMMEDIATE;");
    errdefer _ = c.sqlite3_exec(db, "ROLLBACK", null, null, null);

    // schema.sql also works standalone; its transaction wrapper is owned here by format().
    const begin = std.mem.indexOf(u8, schema, "BEGIN IMMEDIATE;") orelse return error.InvalidSchema;
    const start = begin + "BEGIN IMMEDIATE;".len;
    const end = std.mem.indexOfPos(u8, schema, start, "\nCOMMIT;") orelse return error.InvalidSchema;
    const allocator = std.heap.page_allocator;
    const ddl = try allocator.dupeSentinel(u8, schema[start..end], 0);
    defer allocator.free(ddl);
    try exec(db, ddl.ptr);

    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_REALTIME, &ts) != 0) {
        return error.Clock;
    }
    const timestamp = std.math.add(i64, try std.math.mul(i64, ts.tv_sec, 1_000_000_000), ts.tv_nsec) catch return error.Clock;
    var stmt: ?*c.sqlite3_stmt = null;
    const root_sql = "INSERT INTO inodes(mode,uid,gid,nlink,size,atime_ns,mtime_ns,ctime_ns) VALUES(?, ?, ?, 2, 0, ?, ?, ?)";
    if (c.sqlite3_prepare_v2(db, root_sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.Sqlite;
    }
    const s = stmt orelse return error.Sqlite;
    defer _ = c.sqlite3_finalize(s);
    if (c.sqlite3_bind_int(s, 1, 0o40755) != c.SQLITE_OK or
        c.sqlite3_bind_int64(s, 2, @intCast(c.geteuid())) != c.SQLITE_OK or
        c.sqlite3_bind_int64(s, 3, @intCast(c.getegid())) != c.SQLITE_OK or
        c.sqlite3_bind_int64(s, 4, timestamp) != c.SQLITE_OK or
        c.sqlite3_bind_int64(s, 5, timestamp) != c.SQLITE_OK or
        c.sqlite3_bind_int64(s, 6, timestamp) != c.SQLITE_OK or
        c.sqlite3_step(s) != c.SQLITE_DONE)
    {
        return error.Sqlite;
    }
    try exec(db, "INSERT INTO fs_meta VALUES(1, 1, last_insert_rowid(), 65536);");
    try exec(db, "COMMIT;");
    std.debug.print("Formatted new filesystem database: {s}\n", .{path});
}
