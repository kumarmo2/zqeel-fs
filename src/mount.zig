const std = @import("std");
const builtin = @import("builtin");
const c = @import("ffi");
const store = @import("store.zig");
const runtime = @import("runtime.zig");
const allocator = std.heap.page_allocator;

// Single-threaded session; SQLite and runtime state stay alive through teardown.
var live: runtime.Runtime = undefined;
// Only inodes whose last name was removed by this session belong here.
var pending_reclaims: std.AutoHashMap(i64, store.RemovalKind) = undefined;

// translate-c treats fuse_file_info as opaque because it contains C bitfields.
// Locate a scalar field by its header-derived byte offset and return a pointer
// without assuming alignment stronger than one byte. The caller must pair the
// correct field type with its offset and use fi only while libfuse keeps it valid.
fn field(comptime T: type, fi: *c.struct_fuse_file_info, offset: usize) *align(1) T {
    const bytes: [*]u8 = @ptrCast(fi);
    return @ptrCast(bytes + offset);
}

fn openFlags(fi: *c.struct_fuse_file_info) i32 {
    return field(i32, fi, c.ZQ_FI_FLAGS_OFFSET).*;
}

fn handleId(fi: *c.struct_fuse_file_info) u64 {
    return field(u64, fi, c.ZQ_FI_FH_OFFSET).*;
}

fn setHandle(fi: *c.struct_fuse_file_info, id: u64) void {
    field(u64, fi, c.ZQ_FI_FH_OFFSET).* = id;
}

// Internal storage helpers return negative errno; low-level replies use positive errno.
fn replyStatus(req: c.fuse_req_t, status: c_int) void {
    _ = c.fuse_reply_err(req, if (status < 0) -status else status);
}

fn memoryError(err: anyerror) c_int {
    return if (err == error.OutOfMemory) -c.ENOMEM else -c.EOVERFLOW;
}

fn dbInode(req: c.fuse_req_t, ino: c.fuse_ino_t) ?i64 {
    return store.fromFuse(ino) orelse {
        replyStatus(req, -c.ENOENT);
        return null;
    };
}

fn validInfo(fi: ?*c.struct_fuse_file_info, id: i64) bool {
    const info = fi orelse return true;
    const handle = live.handles.get(handleId(info)) orelse return false;
    return handle.inode == id;
}

fn entry(n: store.Node) c.struct_fuse_entry_param {
    return .{ .ino = store.toFuse(n.id), .generation = 0, .attr = store.attributes(n), .attr_timeout = 1.0, .entry_timeout = 1.0 };
}

fn replyEntry(req: c.fuse_req_t, n: store.Node) void {
    live.addLookupReserved(n.id) catch |err| {
        replyStatus(req, memoryError(err));
        return;
    };
    var result = entry(n);
    if (c.fuse_reply_entry(req, &result) != 0) {
        _ = live.forget(n.id, 1);
    }
}

fn init(_: ?*anyopaque, conn: ?*c.struct_fuse_conn_info) callconv(.c) void {
    if (builtin.mode == .debug) {
        std.debug.print("[fuse] init conn={any}\n", .{conn});
    }
    // Preserve synchronous writes, daemon-enforced append, kernel umask, and real handles.
    c.fuse_unset_feature_flag(conn, c.FUSE_CAP_WRITEBACK_CACHE);
    c.fuse_unset_feature_flag(conn, c.FUSE_CAP_DONT_MASK);
    c.fuse_unset_feature_flag(conn, c.FUSE_CAP_NO_OPEN_SUPPORT);
    c.fuse_unset_feature_flag(conn, c.FUSE_CAP_NO_OPENDIR_SUPPORT);
    c.fuse_unset_feature_flag(conn, c.FUSE_CAP_HANDLE_KILLPRIV_V2);
    _ = c.fuse_set_feature_flag(conn, c.FUSE_CAP_HANDLE_KILLPRIV);
    _ = c.fuse_set_feature_flag(conn, c.FUSE_CAP_ATOMIC_O_TRUNC);
}

fn lookup(req: c.fuse_req_t, parent: c.fuse_ino_t, name: [*c]const u8) callconv(.c) void {
    if (builtin.mode == .debug) {
        std.debug.print("[fuse] lookup parent={d} name=\"{s}\"\n", .{ parent, std.mem.span(name) });
    }
    const id = dbInode(req, parent) orelse return;
    var n: store.Node = undefined;
    const rc = store.findChild(id, std.mem.span(name), &n);
    if (rc != 0) {
        replyStatus(req, rc);
        return;
    }
    live.reserveLookup() catch |err| {
        replyStatus(req, memoryError(err));
        return;
    };
    replyEntry(req, n);
}

fn forget(req: c.fuse_req_t, ino: c.fuse_ino_t, count: u64) callconv(.c) void {
    if (builtin.mode == .debug) {
        std.debug.print("[fuse] forget inode={d} count={d}\n", .{ ino, count });
    }
    dropLookup(ino, count);
    c.fuse_reply_none(req);
}

fn forgetMulti(req: c.fuse_req_t, count: usize, items: [*c]c.struct_fuse_forget_data) callconv(.c) void {
    if (builtin.mode == .debug) {
        std.debug.print("[fuse] forget_multi count={d}\n", .{count});
    }
    for (items[0..count]) |item| {
        dropLookup(item.ino, item.nlookup);
    }
    c.fuse_reply_none(req);
}

fn dropLookup(ino: c.fuse_ino_t, count: u64) void {
    const id = store.fromFuse(ino) orelse return;
    if (!live.forget(id, count)) {
        std.debug.print("FUSE lookup reference underflow: inode={d} count={d}\n", .{ ino, count });
        return;
    }
    tryReclaim(id);
}

fn getattr(req: c.fuse_req_t, ino: c.fuse_ino_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    if (builtin.mode == .debug) {
        std.debug.print("[fuse] getattr inode={d} fi={any}\n", .{ ino, fi });
    }
    const id = dbInode(req, ino) orelse return;
    if (!validInfo(fi, id)) {
        replyStatus(req, -c.EBADF);
        return;
    }
    const n = store.node(id) catch |err| {
        replyStatus(req, store.nodeError(err));
        return;
    };
    var st = store.attributes(n);
    _ = c.fuse_reply_attr(req, &st, 1.0);
}

fn setattr(req: c.fuse_req_t, ino: c.fuse_ino_t, attr: [*c]c.struct_stat, mask: c_int, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    if (builtin.mode == .debug) {
        std.debug.print("[fuse] setattr inode={d} mask=0x{x} fi={any}", .{ ino, mask, fi });
        if ((mask & c.FUSE_SET_ATTR_SIZE) != 0) {
            std.debug.print(" size={d}", .{attr.*.st_size});
        }
        if ((mask & c.FUSE_SET_ATTR_ATIME_NOW) != 0) {
            std.debug.print(" atime=NOW", .{});
        } else if ((mask & c.FUSE_SET_ATTR_ATIME) != 0) {
            std.debug.print(" atime={any}", .{attr.*.st_atim});
        }
        if ((mask & c.FUSE_SET_ATTR_MTIME_NOW) != 0) {
            std.debug.print(" mtime=NOW", .{});
        } else if ((mask & c.FUSE_SET_ATTR_MTIME) != 0) {
            std.debug.print(" mtime={any}", .{attr.*.st_mtim});
        }
        std.debug.print("\n", .{});
    }
    const id = dbInode(req, ino) orelse return;
    if (!validInfo(fi, id)) {
        replyStatus(req, -c.EBADF);
        return;
    }
    const rc = store.setAttributes(id, attr, mask);
    if (rc != 0) {
        replyStatus(req, rc);
        return;
    }
    const n = store.node(id) catch |err| {
        replyStatus(req, store.nodeError(err));
        return;
    };
    var st = store.attributes(n);
    _ = c.fuse_reply_attr(req, &st, 1.0);
}

fn open(req: c.fuse_req_t, ino: c.fuse_ino_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    const info = fi orelse {
        replyStatus(req, -c.EIO);
        return;
    };
    const flags = openFlags(info);
    if (builtin.mode == .debug) {
        std.debug.print("[fuse] open inode={d} flags=0x{x}\n", .{ ino, flags });
    }
    const id = dbInode(req, ino) orelse return;
    const n = store.node(id) catch |err| {
        replyStatus(req, store.nodeError(err));
        return;
    };
    if ((n.mode & 0xf000) != 0x8000) {
        replyStatus(req, -c.EISDIR);
        return;
    }
    live.reserve() catch |err| {
        replyStatus(req, memoryError(err));
        return;
    };
    const fh = live.addOpenReserved(.{ .inode = id, .flags = flags, .kind = .file });
    if ((flags & c.O_TRUNC) != 0) {
        var attr = std.mem.zeroes(c.struct_stat);
        attr.st_size = 0;
        const rc = store.setAttributes(id, &attr, c.FUSE_SET_ATTR_SIZE);
        if (rc != 0) {
            _ = live.close(fh, id, .file);
            replyStatus(req, rc);
            return;
        }
    }
    setHandle(info, fh);
    if (c.fuse_reply_open(req, info) != 0) {
        _ = live.close(fh, id, .file);
    }
}

fn create(req: c.fuse_req_t, parent: c.fuse_ino_t, name: [*c]const u8, mode: c.mode_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    const info = fi orelse {
        replyStatus(req, -c.EIO);
        return;
    };
    const flags = openFlags(info);
    if (builtin.mode == .debug) {
        std.debug.print("[fuse] create parent={d} name=\"{s}\" mode=0o{o} flags=0x{x}\n", .{ parent, std.mem.span(name), mode, flags });
    }
    const id = dbInode(req, parent) orelse return;
    live.reserve() catch |err| {
        replyStatus(req, memoryError(err));
        return;
    };
    const ctx = c.fuse_req_ctx(req);
    var n: store.Node = undefined;
    const rc = store.createNode(id, std.mem.span(name), mode, false, ctx.*.uid, ctx.*.gid, &n);
    if (rc != 0) {
        replyStatus(req, rc);
        return;
    }
    const fh = live.addOpenReserved(.{ .inode = n.id, .flags = flags, .kind = .file });
    live.addLookupReserved(n.id) catch unreachable; // A newly allocated DB inode has no prior references.
    setHandle(info, fh);
    var result = entry(n);
    if (c.fuse_reply_create(req, &result, info) != 0) {
        _ = live.forget(n.id, 1);
        _ = live.close(fh, n.id, .file);
    }
}

fn mkdir(req: c.fuse_req_t, parent: c.fuse_ino_t, name: [*c]const u8, mode: c.mode_t) callconv(.c) void {
    if (builtin.mode == .debug) {
        std.debug.print("[fuse] mkdir parent={d} name=\"{s}\" mode=0o{o}\n", .{ parent, std.mem.span(name), mode });
    }
    const id = dbInode(req, parent) orelse return;
    live.reserveLookup() catch |err| {
        replyStatus(req, memoryError(err));
        return;
    };
    const ctx = c.fuse_req_ctx(req);
    var n: store.Node = undefined;
    const rc = store.createNode(id, std.mem.span(name), mode, true, ctx.*.uid, ctx.*.gid, &n);
    if (rc != 0) {
        replyStatus(req, rc);
        return;
    }
    replyEntry(req, n);
}

fn read(req: c.fuse_req_t, ino: c.fuse_ino_t, size: usize, off: c.off_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    if (builtin.mode == .debug) {
        std.debug.print("[fuse] read inode={d} size={d} offset={d} fi={any}\n", .{ ino, size, off, fi });
    }
    const id = dbInode(req, ino) orelse return;
    const info = fi orelse {
        replyStatus(req, -c.EBADF);
        return;
    };
    if (live.get(handleId(info), id, .file) == null) {
        replyStatus(req, -c.EBADF);
        return;
    }
    if (size > std.math.maxInt(c_int)) {
        replyStatus(req, -c.EINVAL);
        return;
    }
    const buf = allocator.alloc(u8, size) catch {
        replyStatus(req, -c.ENOMEM);
        return;
    };
    defer allocator.free(buf);
    const rc = store.read(id, buf.ptr, size, off);
    if (rc < 0) {
        replyStatus(req, rc);
        return;
    }
    _ = c.fuse_reply_buf(req, buf.ptr, @intCast(rc));
}

fn write(req: c.fuse_req_t, ino: c.fuse_ino_t, buf: [*c]const u8, size: usize, off: c.off_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    if (builtin.mode == .debug) {
        std.debug.print("[fuse] write inode={d} size={d} offset={d} fi={any}\n", .{ ino, size, off, fi });
    }
    const id = dbInode(req, ino) orelse return;
    const info = fi orelse {
        replyStatus(req, -c.EBADF);
        return;
    };
    if (live.get(handleId(info), id, .file) == null) {
        replyStatus(req, -c.EBADF);
        return;
    }
    // Linux write requests carry current flags, including fcntl(F_SETFL) changes.
    // mmap writeback must use its supplied offset, not the original O_APPEND flag.
    const rc = store.write(id, buf, size, off, openFlags(info));
    if (rc < 0) {
        replyStatus(req, rc);
        return;
    }
    _ = c.fuse_reply_write(req, @intCast(rc));
}

fn release(req: c.fuse_req_t, ino: c.fuse_ino_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    if (builtin.mode == .debug) {
        std.debug.print("[fuse] release inode={d} fi={any}\n", .{ ino, fi });
    }
    closeHandle(req, ino, fi, .file);
}

fn closeHandle(req: c.fuse_req_t, ino: c.fuse_ino_t, fi: ?*c.struct_fuse_file_info, kind: runtime.Kind) void {
    const id = dbInode(req, ino) orelse return;
    const info = fi orelse {
        replyStatus(req, -c.EBADF);
        return;
    };
    if (!live.close(handleId(info), id, kind)) {
        replyStatus(req, -c.EBADF);
        return;
    }
    tryReclaim(id);
    replyStatus(req, 0);
}

fn appendEntry(entries: *std.ArrayList(runtime.DirEntry), name: []const u8, id: i64, mode: u32) !void {
    const copy = try allocator.dupeSentinel(u8, name, 0);
    errdefer allocator.free(copy);
    try entries.append(allocator, .{ .name = copy, .inode = id, .mode = mode });
}

fn snapshot(id: i64, out: *[]runtime.DirEntry) c_int {
    const n = store.node(id) catch |err| return store.nodeError(err);
    if ((n.mode & 0xf000) != 0x4000) {
        return -c.ENOTDIR;
    }
    if (n.links == 0) {
        return -c.ENOENT;
    }
    var parent: store.Node = undefined;
    const rc = store.findChild(id, "..", &parent);
    if (rc != 0) {
        return rc;
    }
    var entries: std.ArrayList(runtime.DirEntry) = .empty;
    defer {
        for (entries.items) |item| {
            allocator.free(item.name);
        }
        entries.deinit(allocator);
    }
    appendEntry(&entries, ".", id, @intCast(n.mode)) catch return -c.ENOMEM;
    appendEntry(&entries, "..", parent.id, @intCast(parent.mode)) catch return -c.ENOMEM;
    const stmt = store.prepare("SELECT d.name,d.target_inode,i.mode FROM dirents d JOIN inodes i ON i.inode_id=d.target_inode WHERE d.parent_inode=? ORDER BY d.name") orelse return store.sqliteError();
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_bind_int64(stmt, 1, id) != c.SQLITE_OK) {
        return store.sqliteError();
    }
    while (true) {
        const step = c.sqlite3_step(stmt);
        if (step == c.SQLITE_DONE) {
            break;
        }
        if (step != c.SQLITE_ROW) {
            return store.sqliteError();
        }
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        if (len == 0 or len > 255) {
            return -c.EIO;
        }
        const name: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 0) orelse return -c.EIO);
        appendEntry(&entries, name[0..len], c.sqlite3_column_int64(stmt, 1), @intCast(c.sqlite3_column_int64(stmt, 2))) catch return -c.ENOMEM;
    }
    out.* = entries.toOwnedSlice(allocator) catch return -c.ENOMEM;
    return 0;
}

fn opendir(req: c.fuse_req_t, ino: c.fuse_ino_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    if (builtin.mode == .debug) {
        std.debug.print("[fuse] opendir inode={d} fi={any}\n", .{ ino, fi });
    }
    const id = dbInode(req, ino) orelse return;
    const info = fi orelse {
        replyStatus(req, -c.EIO);
        return;
    };
    live.reserve() catch |err| {
        replyStatus(req, memoryError(err));
        return;
    };
    var entries: []runtime.DirEntry = undefined;
    const rc = snapshot(id, &entries);
    if (rc != 0) {
        replyStatus(req, rc);
        return;
    }
    const fh = live.addOpenReserved(.{ .inode = id, .flags = openFlags(info), .kind = .directory, .entries = entries });
    setHandle(info, fh);
    if (c.fuse_reply_open(req, info) != 0) {
        _ = live.close(fh, id, .directory);
    }
}

// Cookies are positions in an immutable snapshot, never offsets into a live SQL query.
fn readdir(req: c.fuse_req_t, ino: c.fuse_ino_t, size: usize, off: c.off_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    if (builtin.mode == .debug) {
        std.debug.print("[fuse] readdir inode={d} size={d} offset={d} fi={any}\n", .{ ino, size, off, fi });
    }
    const id = dbInode(req, ino) orelse return;
    const info = fi orelse {
        replyStatus(req, -c.EBADF);
        return;
    };
    const handle = live.get(handleId(info), id, .directory) orelse {
        replyStatus(req, -c.EBADF);
        return;
    };
    if (off < 0 or @as(u64, @intCast(off)) > handle.entries.len) {
        replyStatus(req, -c.EINVAL);
        return;
    }
    // The open snapshot belongs to the old directory, not a replacement
    // with the same name. Once detached it behaves as end-of-directory.
    if (pending_reclaims.get(id) == .directory) {
        _ = c.fuse_reply_buf(req, null, 0);
        return;
    }
    const buf = allocator.alloc(u8, size) catch {
        replyStatus(req, -c.ENOMEM);
        return;
    };
    defer allocator.free(buf);
    var used: usize = 0;
    for (handle.entries[@intCast(off)..], @as(usize, @intCast(off))..) |item, index| {
        var st = std.mem.zeroes(c.struct_stat);
        st.st_ino = store.toFuse(item.inode);
        st.st_mode = item.mode;
        const needed = c.fuse_add_direntry(req, buf.ptr + used, size - used, item.name.ptr, &st, @intCast(index + 1));
        if (needed > size - used) {
            break;
        }
        used += needed;
    }
    _ = c.fuse_reply_buf(req, buf.ptr, used);
}

fn unlink(req: c.fuse_req_t, parent: c.fuse_ino_t, name: [*c]const u8) callconv(.c) void {
    const name_slice = std.mem.span(name);
    if (builtin.mode == .debug) {
        std.debug.print("[fuse] unlink parent={d} name=\"{s}\"\n", .{ parent, name_slice });
    }
    removeName(req, parent, name_slice, .file);
}

fn rmdir(req: c.fuse_req_t, parent: c.fuse_ino_t, name: [*c]const u8) callconv(.c) void {
    const name_slice = std.mem.span(name);
    if (builtin.mode == .debug) {
        std.debug.print("[fuse] rmdir parent={d} name=\"{s}\"\n", .{ parent, name_slice });
    }
    removeName(req, parent, name_slice, .directory);
}

fn removeName(req: c.fuse_req_t, parent: c.fuse_ino_t, name: []const u8, kind: store.RemovalKind) void {
    const id = dbInode(req, parent) orelse return;
    // A committed removal must be trackable even if later allocations fail.
    pending_reclaims.ensureUnusedCapacity(1) catch {
        replyStatus(req, -c.ENOMEM);
        return;
    };
    const removal = switch (kind) {
        .file => store.unlinkName(id, name, hasReferences),
        .directory => store.rmdirName(id, name, hasReferences),
    };
    const deferred = removal catch |err| {
        replyStatus(req, unlinkErrno(err));
        return;
    };
    if (deferred) |target| {
        pending_reclaims.putAssumeCapacity(target, kind);
    }
    replyStatus(req, 0);
}

fn unlinkErrno(err: store.UnlinkError) c_int {
    return switch (err) {
        error.NotFound => c.ENOENT,
        error.NotDirectory => c.ENOTDIR,
        error.IsDirectory => c.EISDIR,
        error.NotEmpty => c.ENOTEMPTY,
        error.InvalidName => c.EINVAL,
        error.NameTooLong => c.ENAMETOOLONG,
        error.Busy => c.EBUSY,
        error.DiskFull => c.ENOSPC,
        error.OutOfMemory => c.ENOMEM,
        error.ReadOnly => c.EROFS,
        error.AccessDenied => c.EACCES,
        error.Io => c.EIO,
    };
}

fn hasReferences(id: i64) bool {
    const refs = live.refs.get(id) orelse return false;
    return refs.opens != 0 or refs.lookups != 0;
}

fn tryReclaim(id: i64) void {
    const kind = pending_reclaims.get(id) orelse return;
    if (!hasReferences(id) and reclaim(id, kind)) {
        _ = pending_reclaims.remove(id);
    }
}

fn reclaim(id: i64, kind: store.RemovalKind) bool {
    store.reclaimUnlinked(id, kind) catch |err| {
        std.debug.print("FUSE could not reclaim unlinked inode {d}: {s}\n", .{ id, @errorName(err) });
        return false;
    };
    return true;
}

fn reclaimAfterSession() bool {
    // The session is gone. The kernel may not have delivered all releases or
    // forgets. Retry only inodes recorded by this session, never old orphans.
    var ok = true;
    var it = pending_reclaims.iterator();
    while (it.next()) |pending| {
        if (!reclaim(pending.key_ptr.*, pending.value_ptr.*)) {
            ok = false;
        }
    }
    return ok;
}

fn releasedir(req: c.fuse_req_t, ino: c.fuse_ino_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    if (builtin.mode == .debug) {
        std.debug.print("[fuse] releasedir inode={d} fi={any}\n", .{ ino, fi });
    }
    closeHandle(req, ino, fi, .directory);
}

pub fn mount(path: [:0]const u8, mountpoint: [:0]const u8) !void {
    const lock_fd = try @import("database_lock.zig").open(path);
    defer _ = c.close(lock_fd);
    var handle: ?*c.sqlite3 = null;
    const result = c.sqlite3_open_v2(path.ptr, &handle, c.SQLITE_OPEN_READWRITE, null);
    const db = handle orelse return error.DatabaseOpen;
    defer _ = c.sqlite3_close(db);
    if (result != c.SQLITE_OK) {
        return error.DatabaseOpen;
    }
    store.database = db;
    if (c.sqlite3_exec(db, "PRAGMA foreign_keys=ON", null, null, null) != c.SQLITE_OK) {
        return error.DatabaseOpen;
    }
    const fk = store.prepare("PRAGMA foreign_keys") orelse return error.DatabaseOpen;
    const fk_enabled = c.sqlite3_step(fk) == c.SQLITE_ROW and c.sqlite3_column_int(fk, 0) == 1;
    _ = c.sqlite3_finalize(fk);
    if (!fk_enabled) {
        return error.DatabaseOpen;
    }
    const stmt = store.prepare("SELECT format_version,root_inode,chunk_size FROM fs_meta WHERE singleton=1") orelse return error.InvalidFilesystem;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW or c.sqlite3_column_int64(stmt, 0) != 1) {
        return error.InvalidFilesystem;
    }
    store.root = c.sqlite3_column_int64(stmt, 1);
    store.chunk_size = c.sqlite3_column_int64(stmt, 2);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE or store.root <= 0 or store.chunk_size <= 0 or store.chunk_size > 16 * 1024 * 1024 or !std.math.isPowerOfTwo(@as(u64, @intCast(store.chunk_size)))) {
        return error.InvalidFilesystem;
    }
    const r = store.node(store.root) catch return error.InvalidFilesystem;
    if ((r.mode & 0xf000) != 0x4000) {
        return error.InvalidFilesystem;
    }
    live = runtime.Runtime.init(allocator);
    defer live.deinit();
    pending_reclaims = .init(allocator);
    defer pending_reclaims.deinit();
    const session_result = runSession(mountpoint);
    const reclaimed = reclaimAfterSession();
    try session_result;
    if (!reclaimed) {
        return error.ReclamationFailed;
    }
}

fn runSession(mountpoint: [:0]const u8) !void {
    var ops = std.mem.zeroes(c.struct_fuse_lowlevel_ops);
    ops.init = init;
    ops.lookup = lookup;
    ops.forget = forget;
    ops.forget_multi = forgetMulti;
    ops.getattr = getattr;
    ops.setattr = setattr;
    ops.open = open;
    ops.create = create;
    ops.mkdir = mkdir;
    ops.read = read;
    ops.write = write;
    ops.release = release;
    ops.opendir = opendir;
    ops.readdir = readdir;
    ops.releasedir = releasedir;
    ops.unlink = unlink;
    ops.rmdir = rmdir;

    // Foreground, single-threaded: mountpoint is separate from session options.
    var argv = [_][*c]u8{ @constCast("zqueel-fs"), @constCast("-o"), @constCast("default_permissions") };
    var args = c.struct_fuse_args{ .argc = argv.len, .argv = &argv, .allocated = 0 };
    defer c.fuse_opt_free_args(&args);
    const session = c.fuse_session_new_fn(&args, &ops, @sizeOf(c.struct_fuse_lowlevel_ops), null) orelse return error.MountFailed;
    defer c.fuse_session_destroy(session);
    if (c.fuse_set_signal_handlers(session) != 0) {
        return error.MountFailed;
    }
    defer c.fuse_remove_signal_handlers(session);
    if (c.fuse_session_mount(session, mountpoint.ptr) != 0) {
        return error.MountFailed;
    }
    defer c.fuse_session_unmount(session);
    const loop_result = c.fuse_session_loop(session);
    if (loop_result < 0) {
        return error.MountFailed;
    }
}
