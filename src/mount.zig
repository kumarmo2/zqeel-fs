const std = @import("std");
const c = @import("ffi");

// FUSE is single-threaded, so callbacks share one SQLite connection without a mutex.
// Data writes and truncations are transactional; other mutations remain unsupported.
var database: *c.sqlite3 = undefined;
var root: i64 = undefined;
var chunk_size: i64 = undefined;

// libfuse3's ABI begins fuse_file_info with int32_t flags; ffi.h verifies this
// against the installed header because translate-c cannot translate its bitfields.
const FuseFileInfoPrefix = extern struct { flags: i32 };

fn fuseOpenFlags(info: ?*c.struct_fuse_file_info) i32 {
    const ptr = info orelse return 0;
    const prefix: *const FuseFileInfoPrefix = @ptrCast(@alignCast(ptr));
    return prefix.flags;
}

const Node = struct {
    id: i64,
    mode: i64,
    uid: i64,
    gid: i64,
    links: i64,
    size: i64,
    atime: i64,
    mtime: i64,
    ctime: i64,
};

fn prepare(sql: [*:0]const u8) ?*c.sqlite3_stmt {
    var result: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(database, sql, -1, &result, null) != c.SQLITE_OK) return null;
    return result;
}

fn node(id: i64) ?Node {
    const stmt = prepare("SELECT mode,uid,gid,nlink,size,atime_ns,mtime_ns,ctime_ns FROM inodes WHERE inode_id=?") orelse return null;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_bind_int64(stmt, 1, id) != c.SQLITE_OK or c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return .{ .id = id, .mode = c.sqlite3_column_int64(stmt, 0), .uid = c.sqlite3_column_int64(stmt, 1), .gid = c.sqlite3_column_int64(stmt, 2), .links = c.sqlite3_column_int64(stmt, 3), .size = c.sqlite3_column_int64(stmt, 4), .atime = c.sqlite3_column_int64(stmt, 5), .mtime = c.sqlite3_column_int64(stmt, 6), .ctime = c.sqlite3_column_int64(stmt, 7) };
}

fn lookup(path: [*:0]const u8) ?Node {
    var current = node(root) orelse return null;
    var parts = std.mem.splitScalar(u8, std.mem.span(path), '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if ((current.mode & 0xf000) != 0x4000) return null;
        const stmt = prepare("SELECT target_inode FROM dirents WHERE parent_inode=? AND name=?") orelse return null;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, current.id) != c.SQLITE_OK or
            c.sqlite3_bind_blob(stmt, 2, part.ptr, @intCast(part.len), c.SQLITE_TRANSIENT) != c.SQLITE_OK or
            c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        current = node(c.sqlite3_column_int64(stmt, 0)) orelse return null;
    }
    return current;
}

fn timespec(ns: i64) c.struct_timespec {
    return .{ .tv_sec = @divFloor(ns, 1_000_000_000), .tv_nsec = @mod(ns, 1_000_000_000) };
}

fn getattr(path: [*c]const u8, st: [*c]c.struct_stat, _: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    const n = lookup(path) orelse return -c.ENOENT;
    st.* = std.mem.zeroes(c.struct_stat);
    st.*.st_ino = @intCast(n.id);
    st.*.st_mode = @intCast(n.mode);
    st.*.st_uid = @intCast(n.uid);
    st.*.st_gid = @intCast(n.gid);
    st.*.st_nlink = @intCast(n.links);
    st.*.st_size = n.size;
    st.*.st_blksize = 4096;
    st.*.st_blocks = @divTrunc(n.size, 512) + @intFromBool(@mod(n.size, 512) != 0);
    st.*.st_atim = timespec(n.atime);
    st.*.st_mtim = timespec(n.mtime);
    st.*.st_ctim = timespec(n.ctime);
    return 0;
}

fn readdir(path: [*c]const u8, buf: ?*anyopaque, filler: c.fuse_fill_dir_t, _: c.off_t, _: ?*c.struct_fuse_file_info, _: c.enum_fuse_readdir_flags) callconv(.c) c_int {
    const n = lookup(path) orelse return -c.ENOENT;
    if ((n.mode & 0xf000) != 0x4000) return -c.ENOTDIR;
    const fill = filler orelse return -c.EIO;
    if (fill(buf, ".", null, 0, 0) != 0 or fill(buf, "..", null, 0, 0) != 0) return 0;
    const stmt = prepare("SELECT name FROM dirents WHERE parent_inode=? ORDER BY name") orelse return -c.EIO;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_bind_int64(stmt, 1, n.id) != c.SQLITE_OK) return -c.EIO;
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return 0;
        if (rc != c.SQLITE_ROW) return -c.EIO;
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        if (len == 0 or len > 255) return -c.EIO;
        const data: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 0) orelse return -c.EIO);
        var name: [256:0]u8 = undefined;
        @memcpy(name[0..len], data[0..len]);
        name[len] = 0;
        if (fill(buf, @ptrCast(&name), null, 0, 0) != 0) return 0;
    }
}

fn open(path: [*c]const u8, fi: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    // libfuse enables atomic O_TRUNC by default, passing it to open rather than truncate.
    if ((fuseOpenFlags(fi) & c.O_TRUNC) != 0) return truncate(path, 0, fi);
    const n = lookup(path) orelse return -c.ENOENT;
    if ((n.mode & 0xf000) != 0x8000) return -c.EISDIR;
    return 0;
}

fn truncate(path: [*c]const u8, size: c.off_t, _: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    if (path == null or size < 0) return -c.EINVAL;
    if (c.sqlite3_exec(database, "BEGIN IMMEDIATE", null, null, null) != c.SQLITE_OK) return sqliteError();
    var committed = false;
    defer if (!committed) {
        _ = c.sqlite3_exec(database, "ROLLBACK", null, null, null);
    };
    const n = lookup(path) orelse return -c.ENOENT;
    if ((n.mode & 0xf000) != 0x8000) return -c.EISDIR;
    if (size < n.size) {
        const boundary = @divTrunc(size, chunk_size);
        const tail = @mod(size, chunk_size);
        // At a chunk boundary delete that chunk too; otherwise keep and trim it.
        const delete_from = boundary + @as(i64, @intFromBool(tail != 0));
        const remove = prepare("DELETE FROM file_chunks WHERE inode_id=? AND chunk_index>=?") orelse return sqliteError();
        defer _ = c.sqlite3_finalize(remove);
        if (c.sqlite3_bind_int64(remove, 1, n.id) != c.SQLITE_OK or
            c.sqlite3_bind_int64(remove, 2, delete_from) != c.SQLITE_OK or
            c.sqlite3_step(remove) != c.SQLITE_DONE) return sqliteError();
        if (tail != 0) {
            const trim = prepare("UPDATE file_chunks SET data=substr(data,1,?) WHERE inode_id=? AND chunk_index=? AND length(data)>?") orelse return sqliteError();
            defer _ = c.sqlite3_finalize(trim);
            if (c.sqlite3_bind_int64(trim, 1, tail) != c.SQLITE_OK or
                c.sqlite3_bind_int64(trim, 2, n.id) != c.SQLITE_OK or
                c.sqlite3_bind_int64(trim, 3, boundary) != c.SQLITE_OK or
                c.sqlite3_bind_int64(trim, 4, tail) != c.SQLITE_OK or
                c.sqlite3_step(trim) != c.SQLITE_DONE) return sqliteError();
        }
    }
    // Extension creates no chunks: absent ranges already read as zero.
    var clock: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_REALTIME, &clock) != 0) return -c.EIO;
    const now = timestampNs(clock) catch return -c.EOVERFLOW;
    const update = prepare("UPDATE inodes SET size=?,mtime_ns=?,ctime_ns=?,mode=(mode & ~3072) WHERE inode_id=?") orelse return sqliteError();
    defer _ = c.sqlite3_finalize(update);
    if (c.sqlite3_bind_int64(update, 1, size) != c.SQLITE_OK or
        c.sqlite3_bind_int64(update, 2, now) != c.SQLITE_OK or
        c.sqlite3_bind_int64(update, 3, now) != c.SQLITE_OK or
        c.sqlite3_bind_int64(update, 4, n.id) != c.SQLITE_OK or
        c.sqlite3_step(update) != c.SQLITE_DONE) return sqliteError();
    if (c.sqlite3_exec(database, "COMMIT", null, null, null) != c.SQLITE_OK) return sqliteError();
    committed = true;
    return 0;
}

fn sqliteError() c_int {
    return switch (c.sqlite3_errcode(database) & 0xff) {
        c.SQLITE_BUSY, c.SQLITE_LOCKED => -c.EBUSY,
        c.SQLITE_FULL => -c.ENOSPC,
        c.SQLITE_NOMEM => -c.ENOMEM,
        c.SQLITE_READONLY => -c.EROFS,
        c.SQLITE_PERM, c.SQLITE_AUTH => -c.EACCES,
        else => -c.EIO,
    };
}

// Convert through i128 so negative timestamps near i64's minimum do not overflow early.
fn timestampNs(value: c.struct_timespec) error{ InvalidTime, Overflow }!i64 {
    if (value.tv_nsec < 0 or value.tv_nsec >= 1_000_000_000) return error.InvalidTime;
    const ns: i128 = @as(i128, value.tv_sec) * 1_000_000_000 + @as(i128, value.tv_nsec);
    return std.math.cast(i64, ns) orelse error.Overflow;
}

fn utimens(path: [*c]const u8, tv: [*c]const c.struct_timespec, _: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    if (path == null) return -c.EINVAL;
    // default_permissions delegates setattr permission checks to the kernel.
    if (c.sqlite3_exec(database, "BEGIN IMMEDIATE", null, null, null) != c.SQLITE_OK) return sqliteError();
    var committed = false;
    defer if (!committed) {
        _ = c.sqlite3_exec(database, "ROLLBACK", null, null, null);
    };
    const current = lookup(path) orelse return -c.ENOENT;
    if (tv != null and tv[0].tv_nsec == c.UTIME_OMIT and tv[1].tv_nsec == c.UTIME_OMIT) {
        // No change, including ctime. Rollback closes the otherwise empty transaction.
        return 0;
    }
    var clock: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_REALTIME, &clock) != 0) return -c.EIO;
    const now = timestampNs(clock) catch return -c.EOVERFLOW;
    var values = [2]i64{ current.atime, current.mtime };
    for (0..2) |i| {
        if (tv == null or tv[i].tv_nsec == c.UTIME_NOW) {
            values[i] = now;
        } else if (tv[i].tv_nsec != c.UTIME_OMIT) {
            values[i] = timestampNs(tv[i]) catch |err| return switch (err) {
                error.InvalidTime => -c.EINVAL,
                error.Overflow => -c.EOVERFLOW,
            };
        }
    }
    const update = prepare("UPDATE inodes SET atime_ns=?, mtime_ns=?, ctime_ns=? WHERE inode_id=?") orelse return sqliteError();
    defer _ = c.sqlite3_finalize(update);
    if (c.sqlite3_bind_int64(update, 1, values[0]) != c.SQLITE_OK or
        c.sqlite3_bind_int64(update, 2, values[1]) != c.SQLITE_OK or
        c.sqlite3_bind_int64(update, 3, now) != c.SQLITE_OK or
        c.sqlite3_bind_int64(update, 4, current.id) != c.SQLITE_OK or
        c.sqlite3_step(update) != c.SQLITE_DONE) return sqliteError();
    if (c.sqlite3_exec(database, "COMMIT", null, null, null) != c.SQLITE_OK) return sqliteError();
    committed = true;
    return 0;
}

fn create(path: [*c]const u8, mode: c.mode_t, _: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    return createNode(path, mode, false);
}

fn mkdir(path: [*c]const u8, mode: c.mode_t) callconv(.c) c_int {
    return createNode(path, mode, true);
}

// Share namespace validation and the atomic inode/dirent insertion for files and directories.
fn createNode(path: [*c]const u8, mode: c.mode_t, directory: bool) c_int {
    if (path == null) return -c.EINVAL;
    const full = std.mem.span(path);
    const slash = std.mem.lastIndexOfScalar(u8, full, '/') orelse return -c.EINVAL;
    const name = full[slash + 1 ..];
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return -c.EINVAL;
    if (name.len > 255) return -c.ENAMETOOLONG;

    const parent_path = std.heap.page_allocator.dupeSentinel(u8, if (slash == 0) "/" else full[0..slash], 0) catch return -c.ENOMEM;
    defer std.heap.page_allocator.free(parent_path);
    if (c.sqlite3_exec(database, "BEGIN IMMEDIATE", null, null, null) != c.SQLITE_OK) return sqliteError();
    var committed = false;
    defer if (!committed) {
        _ = c.sqlite3_exec(database, "ROLLBACK", null, null, null);
    };

    const parent = lookup(parent_path.ptr) orelse return -c.ENOENT;
    if ((parent.mode & 0xf000) != 0x4000) return -c.ENOTDIR;
    const existing = prepare("SELECT 1 FROM dirents WHERE parent_inode=? AND name=?") orelse return sqliteError();
    defer _ = c.sqlite3_finalize(existing);
    if (c.sqlite3_bind_int64(existing, 1, parent.id) != c.SQLITE_OK or
        c.sqlite3_bind_blob(existing, 2, name.ptr, @intCast(name.len), c.SQLITE_TRANSIENT) != c.SQLITE_OK) return sqliteError();
    const found = c.sqlite3_step(existing);
    if (found == c.SQLITE_ROW) return -c.EEXIST;
    if (found != c.SQLITE_DONE) return sqliteError();

    const context = c.fuse_get_context() orelse return -c.EIO;
    var clock: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_REALTIME, &clock) != 0) return -c.EIO;
    const seconds = std.math.mul(i64, clock.tv_sec, 1_000_000_000) catch return -c.EOVERFLOW;
    const now = std.math.add(i64, seconds, clock.tv_nsec) catch return -c.EOVERFLOW;
    const gid: i64 = if ((parent.mode & 0o2000) != 0) parent.gid else @intCast(context.*.gid);
    // The kernel applies umask before calling us; a setgid parent also passes its
    // setgid bit to new subdirectories, independently of the requested permissions.
    const inherited: c.mode_t = if (directory and (parent.mode & 0o2000) != 0) 0o2000 else 0;
    const kind: c.mode_t = if (directory) 0o40000 else 0o100000;
    const inode_sql: [*:0]const u8 = if (directory)
        "INSERT INTO inodes(mode,uid,gid,nlink,size,atime_ns,mtime_ns,ctime_ns) VALUES(?,?,?,2,0,?,?,?)"
    else
        "INSERT INTO inodes(mode,uid,gid,nlink,size,atime_ns,mtime_ns,ctime_ns) VALUES(?,?,?,1,0,?,?,?)";
    const inode = prepare(inode_sql) orelse return sqliteError();
    defer _ = c.sqlite3_finalize(inode);
    if (c.sqlite3_bind_int64(inode, 1, @intCast((mode & 0o7777) | kind | inherited)) != c.SQLITE_OK or
        c.sqlite3_bind_int64(inode, 2, @intCast(context.*.uid)) != c.SQLITE_OK or
        c.sqlite3_bind_int64(inode, 3, gid) != c.SQLITE_OK or
        c.sqlite3_bind_int64(inode, 4, now) != c.SQLITE_OK or
        c.sqlite3_bind_int64(inode, 5, now) != c.SQLITE_OK or
        c.sqlite3_bind_int64(inode, 6, now) != c.SQLITE_OK or
        c.sqlite3_step(inode) != c.SQLITE_DONE) return sqliteError();
    const inode_id = c.sqlite3_last_insert_rowid(database);
    const entry = prepare("INSERT INTO dirents(parent_inode,name,target_inode) VALUES(?,?,?)") orelse return sqliteError();
    defer _ = c.sqlite3_finalize(entry);
    if (c.sqlite3_bind_int64(entry, 1, parent.id) != c.SQLITE_OK or
        c.sqlite3_bind_blob(entry, 2, name.ptr, @intCast(name.len), c.SQLITE_TRANSIENT) != c.SQLITE_OK or
        c.sqlite3_bind_int64(entry, 3, inode_id) != c.SQLITE_OK or
        c.sqlite3_step(entry) != c.SQLITE_DONE) return sqliteError();
    // A directory begins with two links; its parent gains one for the child's '..'.
    const parent_sql: [*:0]const u8 = if (directory)
        "UPDATE inodes SET mtime_ns=?, ctime_ns=?, nlink=nlink+1 WHERE inode_id=?"
    else
        "UPDATE inodes SET mtime_ns=?, ctime_ns=? WHERE inode_id=?";
    const update = prepare(parent_sql) orelse return sqliteError();
    defer _ = c.sqlite3_finalize(update);
    if (c.sqlite3_bind_int64(update, 1, now) != c.SQLITE_OK or
        c.sqlite3_bind_int64(update, 2, now) != c.SQLITE_OK or
        c.sqlite3_bind_int64(update, 3, parent.id) != c.SQLITE_OK or
        c.sqlite3_step(update) != c.SQLITE_DONE) return sqliteError();
    if (c.sqlite3_exec(database, "COMMIT", null, null, null) != c.SQLITE_OK) return sqliteError();
    committed = true;
    return 0;
}

fn write(path: [*c]const u8, buf: [*c]const u8, size: usize, off: c.off_t, fi: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    if (path == null or off < 0) return -c.EINVAL;
    if (size > std.math.maxInt(c_int)) return -c.EINVAL;
    if (c.sqlite3_exec(database, "BEGIN IMMEDIATE", null, null, null) != c.SQLITE_OK) return sqliteError();
    var committed = false;
    defer if (!committed) {
        _ = c.sqlite3_exec(database, "ROLLBACK", null, null, null);
    };
    const n = lookup(path) orelse return -c.ENOENT;
    if ((n.mode & 0xf000) != 0x8000) return -c.EISDIR;
    if (size == 0) return 0;
    if (buf == null) return -c.EINVAL;
    // With writeback caching disabled, libfuse requires us to enforce O_APPEND.
    const start: i64 = if ((fuseOpenFlags(fi) & c.O_APPEND) != 0) n.size else off;
    const end = std.math.add(i64, start, @as(i64, @intCast(size))) catch return -c.EFBIG;
    const chunk_len: usize = @intCast(chunk_size);
    const block = std.heap.page_allocator.alloc(u8, chunk_len) catch return -c.ENOMEM;
    defer std.heap.page_allocator.free(block);
    const select = prepare("SELECT data FROM file_chunks WHERE inode_id=? AND chunk_index=?") orelse return sqliteError();
    defer _ = c.sqlite3_finalize(select);
    const upsert = prepare("INSERT INTO file_chunks(inode_id,chunk_index,data) VALUES(?,?,?) ON CONFLICT(inode_id,chunk_index) DO UPDATE SET data=excluded.data") orelse return sqliteError();
    defer _ = c.sqlite3_finalize(upsert);
    var done: usize = 0;
    while (done < size) {
        const pos = start + @as(i64, @intCast(done));
        const idx = @divTrunc(pos, chunk_size);
        const within: usize = @intCast(@mod(pos, chunk_size));
        const amount = @min(size - done, chunk_len - within);
        @memset(block, 0);
        if (c.sqlite3_reset(select) != c.SQLITE_OK or
            c.sqlite3_bind_int64(select, 1, n.id) != c.SQLITE_OK or
            c.sqlite3_bind_int64(select, 2, idx) != c.SQLITE_OK) return sqliteError();
        const rc = c.sqlite3_step(select);
        var old_len: usize = 0;
        if (rc == c.SQLITE_ROW) {
            old_len = @intCast(c.sqlite3_column_bytes(select, 0));
            if (old_len == 0 or old_len > chunk_len) return -c.EIO;
            const old: [*]const u8 = @ptrCast(c.sqlite3_column_blob(select, 0) orelse return -c.EIO);
            @memcpy(block[0..old_len], old[0..old_len]);
        } else if (rc != c.SQLITE_DONE) return sqliteError();
        @memcpy(block[within..][0..amount], buf[done..][0..amount]);
        const new_len = @max(old_len, within + amount);
        if (c.sqlite3_reset(upsert) != c.SQLITE_OK or
            c.sqlite3_bind_int64(upsert, 1, n.id) != c.SQLITE_OK or
            c.sqlite3_bind_int64(upsert, 2, idx) != c.SQLITE_OK or
            c.sqlite3_bind_blob(upsert, 3, block.ptr, @intCast(new_len), c.SQLITE_TRANSIENT) != c.SQLITE_OK or
            c.sqlite3_step(upsert) != c.SQLITE_DONE) return sqliteError();
        done += amount;
    }
    var clock: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_REALTIME, &clock) != 0) return -c.EIO;
    const now = timestampNs(clock) catch return -c.EOVERFLOW;
    // A successful content change removes set-user-ID and set-group-ID bits.
    const update = prepare("UPDATE inodes SET size=?,mtime_ns=?,ctime_ns=?,mode=(mode & ~3072) WHERE inode_id=?") orelse return sqliteError();
    defer _ = c.sqlite3_finalize(update);
    if (c.sqlite3_bind_int64(update, 1, @max(n.size, end)) != c.SQLITE_OK or
        c.sqlite3_bind_int64(update, 2, now) != c.SQLITE_OK or
        c.sqlite3_bind_int64(update, 3, now) != c.SQLITE_OK or
        c.sqlite3_bind_int64(update, 4, n.id) != c.SQLITE_OK or
        c.sqlite3_step(update) != c.SQLITE_DONE) return sqliteError();
    if (c.sqlite3_exec(database, "COMMIT", null, null, null) != c.SQLITE_OK) return sqliteError();
    committed = true;
    return @intCast(size);
}

fn read(path: [*c]const u8, buf: [*c]u8, size: usize, off: c.off_t, _: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    const n = lookup(path) orelse return -c.ENOENT;
    if ((n.mode & 0xf000) != 0x8000) return -c.EISDIR;
    if (off < 0) return -c.EINVAL;
    if (off >= n.size) return 0;
    const total: usize = @intCast(@min(@as(u64, @intCast(size)), @as(u64, @intCast(n.size - off))));
    if (total > std.math.maxInt(c_int)) return -c.EINVAL;
    @memset(buf[0..total], 0);
    const stmt = prepare("SELECT data FROM file_chunks WHERE inode_id=? AND chunk_index=?") orelse return -c.EIO;
    defer _ = c.sqlite3_finalize(stmt);
    var done: usize = 0;
    while (done < total) {
        const pos = off + @as(i64, @intCast(done));
        const idx = @divTrunc(pos, chunk_size);
        const within: usize = @intCast(@mod(pos, chunk_size));
        const amount = @min(total - done, @as(usize, @intCast(chunk_size)) - within);
        _ = c.sqlite3_reset(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, n.id) != c.SQLITE_OK or c.sqlite3_bind_int64(stmt, 2, idx) != c.SQLITE_OK) return -c.EIO;
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) {
            const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
            if (len > @as(usize, @intCast(chunk_size))) return -c.EIO;
            if (len > within) {
                const data: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 0) orelse return -c.EIO);
                const copy_len = @min(amount, len - within);
                @memcpy(buf[done..][0..copy_len], data[within..][0..copy_len]);
            }
        } else if (rc != c.SQLITE_DONE) return -c.EIO;
        done += amount;
    }
    return @intCast(total);
}

pub fn mount(path: [:0]const u8, mountpoint: [:0]const u8) !void {
    var handle: ?*c.sqlite3 = null;
    const result = c.sqlite3_open_v2(path.ptr, &handle, c.SQLITE_OPEN_READWRITE, null);
    const db = handle orelse return error.DatabaseOpen;
    defer _ = c.sqlite3_close(db);
    if (result != c.SQLITE_OK) return error.DatabaseOpen;
    database = db;
    if (c.sqlite3_exec(db, "PRAGMA foreign_keys=ON", null, null, null) != c.SQLITE_OK) return error.DatabaseOpen;
    const fk = prepare("PRAGMA foreign_keys") orelse return error.DatabaseOpen;
    const fk_enabled = c.sqlite3_step(fk) == c.SQLITE_ROW and c.sqlite3_column_int(fk, 0) == 1;
    _ = c.sqlite3_finalize(fk);
    if (!fk_enabled) return error.DatabaseOpen;
    const stmt = prepare("SELECT format_version,root_inode,chunk_size FROM fs_meta WHERE singleton=1") orelse return error.InvalidFilesystem;
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW or c.sqlite3_column_int64(stmt, 0) != 1) {
        _ = c.sqlite3_finalize(stmt);
        return error.InvalidFilesystem;
    }
    root = c.sqlite3_column_int64(stmt, 1);
    chunk_size = c.sqlite3_column_int64(stmt, 2);
    _ = c.sqlite3_finalize(stmt);
    if (chunk_size <= 0 or chunk_size > 16 * 1024 * 1024) return error.InvalidFilesystem;
    const r = node(root) orelse return error.InvalidFilesystem;
    if ((r.mode & 0xf000) != 0x4000) return error.InvalidFilesystem;
    var ops = std.mem.zeroes(c.struct_fuse_operations);
    ops.getattr = getattr;
    ops.readdir = readdir;
    ops.open = open;
    ops.read = read;
    ops.create = create;
    ops.mkdir = mkdir;
    ops.utimens = utimens;
    ops.write = write;
    ops.truncate = truncate;
    var argv = [_][*c]u8{ @constCast("zqueel-fs"), @constCast("-f"), @constCast("-s"), @constCast("-o"), @constCast("default_permissions"), @constCast(mountpoint.ptr) };
    if (c.fuse_main_fn(@intCast(argv.len), &argv, &ops, null) != 0) return error.MountFailed;
}
