const std = @import("std");
const c = @import("ffi");

// Single-threaded storage context. No pathname reconstruction or FUSE replies here.
pub var database: *c.sqlite3 = undefined;
pub var root: i64 = undefined;
pub var chunk_size: i64 = undefined;

pub const Node = struct {
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

pub fn prepare(sql: [*:0]const u8) ?*c.sqlite3_stmt {
    var result: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(database, sql, -1, &result, null) != c.SQLITE_OK) {
        return null;
    }
    return result;
}

pub const NodeError = error{ NotFound, Database };
pub fn nodeError(err: NodeError) c_int {
    return switch (err) {
        error.NotFound => -c.ENOENT,
        error.Database => sqliteError(),
    };
}

pub fn node(id: i64) NodeError!Node {
    const stmt = prepare("SELECT mode,uid,gid,nlink,size,atime_ns,mtime_ns,ctime_ns FROM inodes WHERE inode_id=?") orelse return error.Database;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_bind_int64(stmt, 1, id) != c.SQLITE_OK) {
        return error.Database;
    }
    const rc = c.sqlite3_step(stmt);
    if (rc == c.SQLITE_DONE) {
        return error.NotFound;
    }
    if (rc != c.SQLITE_ROW) {
        return error.Database;
    }
    return .{ .id = id, .mode = c.sqlite3_column_int64(stmt, 0), .uid = c.sqlite3_column_int64(stmt, 1), .gid = c.sqlite3_column_int64(stmt, 2), .links = c.sqlite3_column_int64(stmt, 3), .size = c.sqlite3_column_int64(stmt, 4), .atime = c.sqlite3_column_int64(stmt, 5), .mtime = c.sqlite3_column_int64(stmt, 6), .ctime = c.sqlite3_column_int64(stmt, 7) };
}

// Swap root and 1 so FUSE_ROOT_ID is respected without assuming the DB root is 1.
pub fn toFuse(id: i64) c.fuse_ino_t {
    if (id == root) {
        return c.FUSE_ROOT_ID;
    }
    if (id == c.FUSE_ROOT_ID) {
        return @intCast(root);
    }
    return @intCast(id);
}

pub fn fromFuse(ino: c.fuse_ino_t) ?i64 {
    const id = std.math.cast(i64, ino) orelse return null;
    if (id <= 0) {
        return null;
    }
    if (id == c.FUSE_ROOT_ID) {
        return root;
    }
    if (id == root) {
        return c.FUSE_ROOT_ID;
    }
    return id;
}

pub fn validateName(name: []const u8) c_int {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or std.mem.indexOfAny(u8, name, "/\x00") != null) {
        return -c.EINVAL;
    }
    if (name.len > 255) {
        return -c.ENAMETOOLONG;
    }
    return 0;
}

pub fn findChild(parent_id: i64, name: []const u8, found: *Node) c_int {
    const parent = node(parent_id) catch |err| return nodeError(err);
    if ((parent.mode & 0xf000) != 0x4000) {
        return -c.ENOTDIR;
    }
    if (std.mem.eql(u8, name, ".")) {
        found.* = parent;
        return 0;
    }
    if (std.mem.eql(u8, name, "..")) {
        if (parent_id == root) {
            found.* = parent;
            return 0;
        }
        const stmt = prepare("SELECT parent_inode FROM dirents WHERE target_inode=?") orelse return sqliteError();
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, parent_id) != c.SQLITE_OK) {
            return sqliteError();
        }
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) {
            return -c.EIO;
        }
        const id = c.sqlite3_column_int64(stmt, 0);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return -c.EIO;
        }
        found.* = node(id) catch |err| return nodeError(err);
        return 0;
    }
    const valid = validateName(name);
    if (valid != 0) {
        return valid;
    }
    const stmt = prepare("SELECT target_inode FROM dirents WHERE parent_inode=? AND name=?") orelse return sqliteError();
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_bind_int64(stmt, 1, parent_id) != c.SQLITE_OK or
        c.sqlite3_bind_blob(stmt, 2, name.ptr, @intCast(name.len), c.SQLITE_TRANSIENT) != c.SQLITE_OK)
    {
        return sqliteError();
    }
    const rc = c.sqlite3_step(stmt);
    if (rc == c.SQLITE_DONE) {
        return -c.ENOENT;
    }
    if (rc != c.SQLITE_ROW) {
        return sqliteError();
    }
    found.* = node(c.sqlite3_column_int64(stmt, 0)) catch |err| return nodeError(err);
    return 0;
}

pub fn attributes(n: Node) c.struct_stat {
    var st = std.mem.zeroes(c.struct_stat);
    st.st_ino = toFuse(n.id);
    st.st_mode = @intCast(n.mode);
    st.st_uid = @intCast(n.uid);
    st.st_gid = @intCast(n.gid);
    st.st_nlink = @intCast(n.links);
    st.st_size = n.size;
    st.st_blksize = 4096;
    st.st_blocks = @divTrunc(n.size, 512) + @as(i64, @intFromBool(@mod(n.size, 512) != 0));
    st.st_atim = timespec(n.atime);
    st.st_mtim = timespec(n.mtime);
    st.st_ctim = timespec(n.ctime);
    return st;
}

fn timespec(ns: i64) c.struct_timespec {
    return .{ .tv_sec = @divFloor(ns, 1_000_000_000), .tv_nsec = @mod(ns, 1_000_000_000) };
}

pub fn nowNs() ?i64 {
    var clock: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_REALTIME, &clock) != 0) {
        return null;
    }
    return timestampNs(clock) catch return null;
}
pub fn sqliteError() c_int {
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
pub fn timestampNs(value: c.struct_timespec) error{ InvalidTime, Overflow }!i64 {
    if (value.tv_nsec < 0 or value.tv_nsec >= 1_000_000_000) {
        return error.InvalidTime;
    }
    const ns: i128 = @as(i128, value.tv_sec) * 1_000_000_000 + @as(i128, value.tv_nsec);
    return std.math.cast(i64, ns) orelse error.Overflow;
}

// SIZE and timestamp changes share a transaction; explicit times override resize defaults.
pub fn setAttributes(id: i64, attr: *const c.struct_stat, mask: c_int) c_int {
    const controls = c.FUSE_SET_ATTR_FORCE | c.FUSE_SET_ATTR_FILE | c.FUSE_SET_ATTR_OPEN | c.FUSE_SET_ATTR_TIMES_SET | c.FUSE_SET_ATTR_TOUCH;
    const changes = c.FUSE_SET_ATTR_SIZE | c.FUSE_SET_ATTR_ATIME | c.FUSE_SET_ATTR_MTIME | c.FUSE_SET_ATTR_ATIME_NOW | c.FUSE_SET_ATTR_MTIME_NOW | c.FUSE_SET_ATTR_CTIME | c.FUSE_SET_ATTR_KILL_SUID | c.FUSE_SET_ATTR_KILL_SGID | c.FUSE_SET_ATTR_KILL_PRIV;
    if ((mask & ~(controls | changes)) != 0) {
        return -c.EOPNOTSUPP;
    }
    if (c.sqlite3_exec(database, "BEGIN IMMEDIATE", null, null, null) != c.SQLITE_OK) {
        return sqliteError();
    }
    var committed = false;
    defer if (!committed) {
        _ = c.sqlite3_exec(database, "ROLLBACK", null, null, null);
    };
    const n = node(id) catch |err| return nodeError(err);
    var mode = n.mode;
    var size = n.size;
    const resizing = (mask & c.FUSE_SET_ATTR_SIZE) != 0;
    if (resizing) {
        if ((n.mode & 0xf000) != 0x8000) {
            return -c.EISDIR;
        }
        if (attr.st_size < 0) {
            return -c.EINVAL;
        }
        size = attr.st_size;
        mode &= ~@as(i64, 0o6000);
    }
    if ((mask & (c.FUSE_SET_ATTR_KILL_SUID | c.FUSE_SET_ATTR_KILL_PRIV)) != 0) {
        mode &= ~@as(i64, 0o4000);
    }
    if ((mask & (c.FUSE_SET_ATTR_KILL_SGID | c.FUSE_SET_ATTR_KILL_PRIV)) != 0) {
        mode &= ~@as(i64, 0o2000);
    }
    if ((mask & changes) == 0 and mode == n.mode) {
        return 0;
    }
    const now = nowNs() orelse return -c.EIO;
    var atime = n.atime;
    var mtime = if (resizing) now else n.mtime;
    var ctime = now;
    if ((mask & c.FUSE_SET_ATTR_ATIME_NOW) != 0) {
        atime = now;
    } else if ((mask & c.FUSE_SET_ATTR_ATIME) != 0) {
        atime = timestampNs(attr.st_atim) catch |err| return timeError(err);
    }
    if ((mask & c.FUSE_SET_ATTR_MTIME_NOW) != 0) {
        mtime = now;
    } else if ((mask & c.FUSE_SET_ATTR_MTIME) != 0) {
        mtime = timestampNs(attr.st_mtim) catch |err| return timeError(err);
    }
    if ((mask & c.FUSE_SET_ATTR_CTIME) != 0) {
        ctime = timestampNs(attr.st_ctim) catch |err| return timeError(err);
    }
    if (resizing and size < n.size) {
        const rc = resizeChunks(id, size);
        if (rc != 0) {
            return rc;
        }
    }
    const update = prepare("UPDATE inodes SET size=?,mode=?,atime_ns=?,mtime_ns=?,ctime_ns=? WHERE inode_id=?") orelse return sqliteError();
    defer _ = c.sqlite3_finalize(update);
    const values = [_]i64{ size, mode, atime, mtime, ctime, id };
    for (values, 1..) |value, index| {
        if (c.sqlite3_bind_int64(update, @intCast(index), value) != c.SQLITE_OK) {
            return sqliteError();
        }
    }
    if (c.sqlite3_step(update) != c.SQLITE_DONE or c.sqlite3_exec(database, "COMMIT", null, null, null) != c.SQLITE_OK) {
        return sqliteError();
    }
    committed = true;
    return 0;
}

fn timeError(err: error{ InvalidTime, Overflow }) c_int {
    return switch (err) {
        error.InvalidTime => -c.EINVAL,
        error.Overflow => -c.EOVERFLOW,
    };
}

// Caller owns the transaction and inode metadata update. Extension allocates no chunks.
fn resizeChunks(id: i64, size: i64) c_int {
    const boundary = @divTrunc(size, chunk_size);
    const tail = @mod(size, chunk_size);
    const delete_from = boundary + @as(i64, @intFromBool(tail != 0));
    const remove = prepare("DELETE FROM file_chunks WHERE inode_id=? AND chunk_index>=?") orelse return sqliteError();
    defer _ = c.sqlite3_finalize(remove);
    if (c.sqlite3_bind_int64(remove, 1, id) != c.SQLITE_OK or
        c.sqlite3_bind_int64(remove, 2, delete_from) != c.SQLITE_OK or
        c.sqlite3_step(remove) != c.SQLITE_DONE)
    {
        return sqliteError();
    }
    if (tail != 0) {
        const trim = prepare("UPDATE file_chunks SET data=substr(data,1,?) WHERE inode_id=? AND chunk_index=? AND length(data)>?") orelse return sqliteError();
        defer _ = c.sqlite3_finalize(trim);
        if (c.sqlite3_bind_int64(trim, 1, tail) != c.SQLITE_OK or
            c.sqlite3_bind_int64(trim, 2, id) != c.SQLITE_OK or
            c.sqlite3_bind_int64(trim, 3, boundary) != c.SQLITE_OK or
            c.sqlite3_bind_int64(trim, 4, tail) != c.SQLITE_OK or
            c.sqlite3_step(trim) != c.SQLITE_DONE)
        {
            return sqliteError();
        }
    }
    return 0;
}

pub fn createNode(parent_id: i64, name: []const u8, mode: c.mode_t, directory: bool, uid: c.uid_t, owner_gid: c.gid_t, created: *Node) c_int {
    const valid = validateName(name);
    if (valid != 0) {
        return valid;
    }
    if (c.sqlite3_exec(database, "BEGIN IMMEDIATE", null, null, null) != c.SQLITE_OK) {
        return sqliteError();
    }
    var committed = false;
    defer if (!committed) {
        _ = c.sqlite3_exec(database, "ROLLBACK", null, null, null);
    };

    const parent = node(parent_id) catch |err| return nodeError(err);
    if ((parent.mode & 0xf000) != 0x4000) {
        return -c.ENOTDIR;
    }
    const existing = prepare("SELECT 1 FROM dirents WHERE parent_inode=? AND name=?") orelse return sqliteError();
    defer _ = c.sqlite3_finalize(existing);
    if (c.sqlite3_bind_int64(existing, 1, parent.id) != c.SQLITE_OK or
        c.sqlite3_bind_blob(existing, 2, name.ptr, @intCast(name.len), c.SQLITE_TRANSIENT) != c.SQLITE_OK)
    {
        return sqliteError();
    }
    const found = c.sqlite3_step(existing);
    if (found == c.SQLITE_ROW) {
        return -c.EEXIST;
    }
    if (found != c.SQLITE_DONE) {
        return sqliteError();
    }

    var clock: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_REALTIME, &clock) != 0) {
        return -c.EIO;
    }
    const seconds = std.math.mul(i64, clock.tv_sec, 1_000_000_000) catch return -c.EOVERFLOW;
    const now = std.math.add(i64, seconds, clock.tv_nsec) catch return -c.EOVERFLOW;
    const gid: i64 = if ((parent.mode & 0o2000) != 0) parent.gid else @intCast(owner_gid);
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
        c.sqlite3_bind_int64(inode, 2, @intCast(uid)) != c.SQLITE_OK or
        c.sqlite3_bind_int64(inode, 3, gid) != c.SQLITE_OK or
        c.sqlite3_bind_int64(inode, 4, now) != c.SQLITE_OK or
        c.sqlite3_bind_int64(inode, 5, now) != c.SQLITE_OK or
        c.sqlite3_bind_int64(inode, 6, now) != c.SQLITE_OK or
        c.sqlite3_step(inode) != c.SQLITE_DONE)
    {
        return sqliteError();
    }
    const inode_id = c.sqlite3_last_insert_rowid(database);
    const entry = prepare("INSERT INTO dirents(parent_inode,name,target_inode) VALUES(?,?,?)") orelse return sqliteError();
    defer _ = c.sqlite3_finalize(entry);
    if (c.sqlite3_bind_int64(entry, 1, parent.id) != c.SQLITE_OK or
        c.sqlite3_bind_blob(entry, 2, name.ptr, @intCast(name.len), c.SQLITE_TRANSIENT) != c.SQLITE_OK or
        c.sqlite3_bind_int64(entry, 3, inode_id) != c.SQLITE_OK or
        c.sqlite3_step(entry) != c.SQLITE_DONE)
    {
        return sqliteError();
    }
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
        c.sqlite3_step(update) != c.SQLITE_DONE)
    {
        return sqliteError();
    }
    created.* = node(inode_id) catch |err| return nodeError(err);
    if (c.sqlite3_exec(database, "COMMIT", null, null, null) != c.SQLITE_OK) {
        return sqliteError();
    }
    committed = true;
    return 0;
}

pub fn write(id: i64, buf: [*c]const u8, size: usize, off: c.off_t, flags: i32) c_int {
    if (off < 0) {
        return -c.EINVAL;
    }
    if (size > std.math.maxInt(c_int)) {
        return -c.EINVAL;
    }
    if (c.sqlite3_exec(database, "BEGIN IMMEDIATE", null, null, null) != c.SQLITE_OK) {
        return sqliteError();
    }
    var committed = false;
    defer if (!committed) {
        _ = c.sqlite3_exec(database, "ROLLBACK", null, null, null);
    };
    const n = node(id) catch |err| return nodeError(err);
    if ((n.mode & 0xf000) != 0x8000) {
        return -c.EISDIR;
    }
    if (size == 0) {
        return 0;
    }
    if (buf == null) {
        return -c.EINVAL;
    }
    // With writeback caching disabled, libfuse requires us to enforce O_APPEND.
    const start: i64 = if ((flags & c.O_APPEND) != 0) n.size else off;
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
            c.sqlite3_bind_int64(select, 2, idx) != c.SQLITE_OK)
        {
            return sqliteError();
        }
        const rc = c.sqlite3_step(select);
        var old_len: usize = 0;
        if (rc == c.SQLITE_ROW) {
            old_len = @intCast(c.sqlite3_column_bytes(select, 0));
            if (old_len == 0 or old_len > chunk_len) {
                return -c.EIO;
            }
            const old: [*]const u8 = @ptrCast(c.sqlite3_column_blob(select, 0) orelse return -c.EIO);
            @memcpy(block[0..old_len], old[0..old_len]);
        } else if (rc != c.SQLITE_DONE) {
            return sqliteError();
        }
        @memcpy(block[within..][0..amount], buf[done..][0..amount]);
        const new_len = @max(old_len, within + amount);
        if (c.sqlite3_reset(upsert) != c.SQLITE_OK or
            c.sqlite3_bind_int64(upsert, 1, n.id) != c.SQLITE_OK or
            c.sqlite3_bind_int64(upsert, 2, idx) != c.SQLITE_OK or
            c.sqlite3_bind_blob(upsert, 3, block.ptr, @intCast(new_len), c.SQLITE_TRANSIENT) != c.SQLITE_OK or
            c.sqlite3_step(upsert) != c.SQLITE_DONE)
        {
            return sqliteError();
        }
        done += amount;
    }
    var clock: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_REALTIME, &clock) != 0) {
        return -c.EIO;
    }
    const now = timestampNs(clock) catch return -c.EOVERFLOW;
    // A successful content change removes set-user-ID and set-group-ID bits.
    const update = prepare("UPDATE inodes SET size=?,mtime_ns=?,ctime_ns=?,mode=(mode & ~3072) WHERE inode_id=?") orelse return sqliteError();
    defer _ = c.sqlite3_finalize(update);
    if (c.sqlite3_bind_int64(update, 1, @max(n.size, end)) != c.SQLITE_OK or
        c.sqlite3_bind_int64(update, 2, now) != c.SQLITE_OK or
        c.sqlite3_bind_int64(update, 3, now) != c.SQLITE_OK or
        c.sqlite3_bind_int64(update, 4, n.id) != c.SQLITE_OK or
        c.sqlite3_step(update) != c.SQLITE_DONE)
    {
        return sqliteError();
    }
    if (c.sqlite3_exec(database, "COMMIT", null, null, null) != c.SQLITE_OK) {
        return sqliteError();
    }
    committed = true;
    return @intCast(size);
}

pub fn read(id: i64, buf: [*c]u8, size: usize, off: c.off_t) c_int {
    const n = node(id) catch |err| return nodeError(err);
    if ((n.mode & 0xf000) != 0x8000) {
        return -c.EISDIR;
    }
    if (off < 0) {
        return -c.EINVAL;
    }
    if (off >= n.size) {
        return 0;
    }
    const total: usize = @intCast(@min(@as(u64, @intCast(size)), @as(u64, @intCast(n.size - off))));
    if (total > std.math.maxInt(c_int)) {
        return -c.EINVAL;
    }
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
        if (c.sqlite3_bind_int64(stmt, 1, n.id) != c.SQLITE_OK or c.sqlite3_bind_int64(stmt, 2, idx) != c.SQLITE_OK) {
            return -c.EIO;
        }
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) {
            const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
            if (len > @as(usize, @intCast(chunk_size))) {
                return -c.EIO;
            }
            if (len > within) {
                const data: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 0) orelse return -c.EIO);
                const copy_len = @min(amount, len - within);
                @memcpy(buf[done..][0..copy_len], data[within..][0..copy_len]);
            }
        } else if (rc != c.SQLITE_DONE) {
            return -c.EIO;
        }
        done += amount;
    }
    return @intCast(total);
}
