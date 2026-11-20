const std = @import("std");
const c = @import("ffi");
const fs = @import("store");

fn sql(statement: [*:0]const u8) !void {
    if (c.sqlite3_exec(fs.database, statement, null, null, null) != c.SQLITE_OK) {
        std.debug.print("test SQL: {s}\n", .{c.sqlite3_errmsg(fs.database)});
        return error.TestSql;
    }
}

fn setup() !void {
    var db: ?*c.sqlite3 = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(":memory:", &db));
    fs.database = db.?;
    errdefer _ = c.sqlite3_close(fs.database);
    const schema = @embedFile("schema.sql");
    const ddl = try std.testing.allocator.dupeSentinel(u8, schema, 0);
    defer std.testing.allocator.free(ddl);
    try sql(ddl);
    // Exercise a root other than 1, including a real file whose DB inode is 1.
    try sql("INSERT INTO inodes VALUES(1,33188,100,200,1,0,0,0,0),(10,16877,100,200,2,0,0,0,0); INSERT INTO dirents VALUES(10,x'78',1);");
    fs.root = 10;
    fs.chunk_size = 8;
}

fn teardown() void {
    std.debug.assert(c.sqlite3_close(fs.database) == c.SQLITE_OK);
}

fn scalar(statement: [*:0]const u8) !i64 {
    const stmt = fs.prepare(statement) orelse return error.TestSql;
    defer _ = c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    return c.sqlite3_column_int64(stmt, 0);
}

test "root mapping, byte names, child lookup, dot and dotdot" {
    try setup();
    defer teardown();
    try std.testing.expectEqual(@as(c.fuse_ino_t, 1), fs.toFuse(10));
    try std.testing.expectEqual(@as(c.fuse_ino_t, 10), fs.toFuse(1));
    try std.testing.expectEqual(@as(?i64, 10), fs.fromFuse(1));
    try std.testing.expectEqual(@as(?i64, 1), fs.fromFuse(10));
    try std.testing.expect(fs.fromFuse(0) == null);
    try std.testing.expect(fs.fromFuse(std.math.maxInt(u64)) == null);
    var n: fs.Node = undefined;
    try std.testing.expectEqual(@as(c_int, 0), fs.findChild(10, "x", &n));
    try std.testing.expectEqual(@as(i64, 1), n.id);
    try std.testing.expectEqual(@as(c_int, -c.ENOTDIR), fs.findChild(1, "child", &n));
    try std.testing.expectEqual(@as(c_int, -c.ENOENT), fs.findChild(10, "missing", &n));
    try std.testing.expectEqual(@as(c_int, 0), fs.findChild(10, "..", &n));
    try std.testing.expectEqual(@as(i64, 10), n.id);
    var dir: fs.Node = undefined;
    try std.testing.expectEqual(@as(c_int, 0), fs.createNode(10, "dir", 0o755, true, 100, 200, &dir));
    try std.testing.expectEqual(@as(c_int, 0), fs.findChild(dir.id, "..", &n));
    try std.testing.expectEqual(@as(i64, 10), n.id);
    try std.testing.expectEqual(@as(c_int, 0), fs.findChild(dir.id, ".", &n));
    try std.testing.expectEqual(dir.id, n.id);
    try std.testing.expectEqual(@as(c_int, 0), fs.createNode(10, "\xff", 0o600, false, 100, 200, &n));
    const id = n.id;
    try std.testing.expectEqual(@as(c_int, 0), fs.findChild(10, "\xff", &n));
    try std.testing.expectEqual(id, n.id);
    try sql("DROP TABLE dirents;");
    try std.testing.expectEqual(@as(c_int, -c.EIO), fs.findChild(10, "x", &n));
}

test "creation preserves directory links setgid and rollback" {
    try setup();
    defer teardown();
    try sql("UPDATE inodes SET mode=17917,gid=77 WHERE inode_id=10;"); // 042775
    var n: fs.Node = undefined;
    try std.testing.expectEqual(@as(c_int, 0), fs.createNode(10, "dir", 0o755, true, 123, 456, &n));
    try std.testing.expectEqual(@as(i64, 123), n.uid);
    try std.testing.expectEqual(@as(i64, 77), n.gid);
    try std.testing.expectEqual(@as(i64, 0o42755), n.mode);
    try std.testing.expectEqual(@as(i64, 2), n.links);
    try std.testing.expectEqual(@as(i64, 3), (try fs.node(10)).links);
    try std.testing.expectEqual(@as(c_int, -c.EEXIST), fs.createNode(10, "dir", 0o755, true, 123, 456, &n));
    const before = try scalar("SELECT count(*) FROM inodes");
    try sql("CREATE TRIGGER fail_parent BEFORE UPDATE ON inodes WHEN OLD.inode_id=10 BEGIN SELECT RAISE(ABORT,'injected'); END;");
    try std.testing.expect(fs.createNode(10, "fail", 0o755, true, 123, 456, &n) < 0);
    try std.testing.expectEqual(before, try scalar("SELECT count(*) FROM inodes"));
    try std.testing.expectEqual(@as(i64, 0), try scalar("SELECT count(*) FROM dirents WHERE name=x'6661696c'"));
    try std.testing.expectEqual(@as(i64, 0), try scalar("SELECT count(*) FROM pragma_foreign_key_check"));
}

test "sparse chunk IO append and shrink then extend" {
    try setup();
    defer teardown();
    try std.testing.expectEqual(@as(c_int, 6), fs.write(1, "abcdef", 6, 6, 0));
    var buf: [24]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 12), fs.read(1, &buf, buf.len, 0));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0 }, buf[0..6]);
    try std.testing.expectEqualStrings("abcdef", buf[6..12]);
    try std.testing.expectEqual(@as(c_int, 1), fs.write(1, "Z", 1, 0, c.O_APPEND));
    try std.testing.expectEqual(@as(i64, 13), (try fs.node(1)).size);
    var attr = std.mem.zeroes(c.struct_stat);
    attr.st_size = 9;
    try std.testing.expectEqual(@as(c_int, 0), fs.setAttributes(1, &attr, c.FUSE_SET_ATTR_SIZE));
    attr.st_size = 16;
    try std.testing.expectEqual(@as(c_int, 0), fs.setAttributes(1, &attr, c.FUSE_SET_ATTR_SIZE));
    try std.testing.expectEqual(@as(c_int, 16), fs.read(1, &buf, buf.len, 0));
    try std.testing.expectEqualStrings("abc", buf[6..9]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0 }, buf[9..16]);
    try std.testing.expectEqual(@as(c_int, 0), fs.read(1, &buf, buf.len, 16));
}

test "combined setattr timestamps override resize defaults; omitted fields stay unchanged" {
    try setup();
    defer teardown();
    var attr = std.mem.zeroes(c.struct_stat);
    attr.st_size = 19;
    attr.st_mtim = .{ .tv_sec = -1, .tv_nsec = 500_000_000 };
    try std.testing.expectEqual(@as(c_int, 0), fs.setAttributes(1, &attr, c.FUSE_SET_ATTR_SIZE | c.FUSE_SET_ATTR_MTIME | c.FUSE_SET_ATTR_ATIME_NOW));
    const n = try fs.node(1);
    try std.testing.expectEqual(@as(i64, 19), n.size);
    try std.testing.expectEqual(@as(i64, -500_000_000), n.mtime);
    try std.testing.expectEqual(n.atime, n.ctime);
    try std.testing.expect(n.atime > 0);
    try std.testing.expectEqual(@as(c_int, 0), fs.setAttributes(1, &attr, 0));
    try std.testing.expectEqual(n.ctime, (try fs.node(1)).ctime);
    attr.st_mtim.tv_nsec = 1_000_000_000;
    try std.testing.expectEqual(@as(c_int, -c.EINVAL), fs.setAttributes(1, &attr, c.FUSE_SET_ATTR_SIZE | c.FUSE_SET_ATTR_MTIME));
    try std.testing.expectEqual(n.size, (try fs.node(1)).size);
    attr.st_size = 0;
    attr.st_mode = 0o100600;
    try std.testing.expectEqual(@as(c_int, -c.EOPNOTSUPP), fs.setAttributes(1, &attr, c.FUSE_SET_ATTR_SIZE | c.FUSE_SET_ATTR_MODE));
    try std.testing.expectEqual(n.size, (try fs.node(1)).size);
    try std.testing.expectEqual(@as(c_int, -c.EOPNOTSUPP), fs.setAttributes(1, &attr, c.FUSE_SET_ATTR_UID | c.FUSE_SET_ATTR_SIZE));
}

test "write and combined setattr rollback restore chunks and metadata" {
    try setup();
    defer teardown();
    try std.testing.expectEqual(@as(c_int, 16), fs.write(1, "abcdefghijklmnop", 16, 0, 0));
    const before = try fs.node(1);
    try sql("CREATE TRIGGER fail_update BEFORE UPDATE ON inodes WHEN OLD.inode_id=1 BEGIN SELECT RAISE(ABORT,'injected'); END;");
    var attr = std.mem.zeroes(c.struct_stat);
    attr.st_size = 3;
    try std.testing.expect(fs.setAttributes(1, &attr, c.FUSE_SET_ATTR_SIZE | c.FUSE_SET_ATTR_MTIME_NOW) < 0);
    try std.testing.expect(fs.write(1, "XXXXXXXXXXXXXXXX", 16, 0, 0) < 0);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 16), fs.read(1, &buf, buf.len, 0));
    try std.testing.expectEqualStrings("abcdefghijklmnop", &buf);
    const after = try fs.node(1);
    try std.testing.expectEqual(before.size, after.size);
    try std.testing.expectEqual(before.mtime, after.mtime);
    try std.testing.expectEqual(before.ctime, after.ctime);
    try std.testing.expectEqual(@as(i64, 0), try scalar("SELECT count(*) FROM pragma_foreign_key_check"));
}

fn noReferences(_: i64) bool {
    return false;
}

fn hasReferences(_: i64) bool {
    return true;
}

test "unlink with other names preserves data, and the final unreferenced unlink reclaims it" {
    try setup();
    defer teardown();
    try std.testing.expectEqual(@as(c_int, 3), fs.write(1, "old", 3, 0, 0));
    try sql("INSERT INTO dirents VALUES(10,x'79',1); UPDATE inodes SET nlink=2,ctime_ns=7 WHERE inode_id=1;");
    const before = try fs.node(1);
    const parent_before = try fs.node(10);

    try std.testing.expectEqual(@as(?i64, null), try fs.unlinkName(10, "x", noReferences));
    var target: fs.Node = undefined;
    try std.testing.expectEqual(@as(c_int, -c.ENOENT), fs.findChild(10, "x", &target));
    try std.testing.expectEqual(@as(c_int, 0), fs.findChild(10, "y", &target));
    try std.testing.expectEqual(before.id, target.id);
    try std.testing.expectEqual(@as(i64, 1), target.links);
    try std.testing.expectEqual(before.size, target.size);
    try std.testing.expectEqual(before.mtime, target.mtime);
    try std.testing.expectEqual(before.atime, target.atime);
    const parent_after = try fs.node(10);
    try std.testing.expectEqual(parent_before.links, parent_after.links);
    try std.testing.expect(target.ctime != before.ctime);
    try std.testing.expectEqual(target.ctime, parent_after.ctime);
    try std.testing.expectEqual(target.ctime, parent_after.mtime);
    try std.testing.expectEqual(@as(i64, 1), try scalar("SELECT count(*) FROM file_chunks WHERE inode_id=1"));

    try std.testing.expectEqual(@as(?i64, null), try fs.unlinkName(10, "y", noReferences));
    try std.testing.expectError(error.NotFound, fs.node(1));
    try std.testing.expectEqual(@as(i64, 0), try scalar("SELECT count(*) FROM file_chunks"));
    try std.testing.expectEqual(@as(i64, 0), try scalar("SELECT count(*) FROM pragma_foreign_key_check"));
}

test "unlinked referenced inode can be used independently of a replacement name" {
    try setup();
    defer teardown();
    try std.testing.expectEqual(@as(c_int, 3), fs.write(1, "old", 3, 0, 0));
    try std.testing.expectEqual(@as(?i64, 1), try fs.unlinkName(10, "x", hasReferences));
    try std.testing.expectEqual(@as(i64, 0), (try fs.node(1)).links);
    try std.testing.expectError(error.NotFound, fs.unlinkName(10, "x", hasReferences));

    var replacement: fs.Node = undefined;
    try std.testing.expectEqual(@as(c_int, 0), fs.createNode(10, "x", 0o644, false, 100, 200, &replacement));
    try std.testing.expect(replacement.id != 1);
    try std.testing.expectEqual(@as(c_int, 3), fs.write(replacement.id, "new", 3, 0, 0));
    try std.testing.expectEqual(@as(c_int, 1), fs.write(1, "!", 1, 3, 0));
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 4), fs.read(1, &buf, buf.len, 0));
    try std.testing.expectEqualStrings("old!", buf[0..4]);
    var attr = std.mem.zeroes(c.struct_stat);
    attr.st_size = 2;
    try std.testing.expectEqual(@as(c_int, 0), fs.setAttributes(1, &attr, c.FUSE_SET_ATTR_SIZE));

    try fs.reclaimUnlinkedFile(1);
    try std.testing.expectError(error.NotFound, fs.node(1));
    try std.testing.expectEqual(@as(i64, 0), try scalar("SELECT count(*) FROM file_chunks WHERE inode_id=1"));
    try std.testing.expectEqual(@as(c_int, 3), fs.read(replacement.id, &buf, buf.len, 0));
    try std.testing.expectEqualStrings("new", buf[0..3]);
}

test "unlink rejects directories invalid names and inconsistent link counts" {
    try setup();
    defer teardown();
    var dir: fs.Node = undefined;
    try std.testing.expectEqual(@as(c_int, 0), fs.createNode(10, "dir", 0o755, true, 100, 200, &dir));
    try std.testing.expectError(error.IsDirectory, fs.unlinkName(10, "dir", noReferences));
    try std.testing.expectError(error.InvalidName, fs.unlinkName(10, ".", noReferences));
    try std.testing.expectError(error.NotDirectory, fs.unlinkName(1, "x", noReferences));
    try std.testing.expectError(error.NotFound, fs.unlinkName(10, "absent", noReferences));
    try sql("INSERT INTO dirents VALUES(10,x'79',1);");
    try std.testing.expectError(error.Io, fs.unlinkName(10, "x", hasReferences));
    try std.testing.expectEqual(@as(i64, 2), try scalar("SELECT count(*) FROM dirents WHERE target_inode=1"));
    try std.testing.expectEqual(@as(i64, 1), (try fs.node(1)).links);
    try sql("DELETE FROM dirents WHERE name=x'79'; UPDATE inodes SET nlink=2 WHERE inode_id=1;");
    try std.testing.expectError(error.Io, fs.unlinkName(10, "x", noReferences));
    try std.testing.expectEqual(@as(i64, 1), try scalar("SELECT count(*) FROM dirents WHERE target_inode=1"));
    try std.testing.expectEqual(@as(i64, 2), (try fs.node(1)).links);
}

test "unlink and deferred reclamation roll back on failure" {
    try setup();
    defer teardown();
    try std.testing.expectEqual(@as(c_int, 3), fs.write(1, "old", 3, 0, 0));
    const before = try fs.node(1);
    const parent_before = try fs.node(10);

    try sql("CREATE TRIGGER fail_unlink_parent BEFORE UPDATE ON inodes WHEN OLD.inode_id=10 BEGIN SELECT RAISE(ABORT,'injected'); END;");
    try std.testing.expectError(error.Io, fs.unlinkName(10, "x", noReferences));
    try std.testing.expectEqualDeep(before, try fs.node(1));
    try std.testing.expectEqualDeep(parent_before, try fs.node(10));
    try std.testing.expectEqual(@as(i64, 1), try scalar("SELECT count(*) FROM dirents WHERE target_inode=1"));

    try sql("DROP TRIGGER fail_unlink_parent; CREATE TRIGGER fail_reclaim BEFORE DELETE ON inodes WHEN OLD.inode_id=1 BEGIN SELECT RAISE(ABORT,'injected'); END;");
    try std.testing.expectError(error.Io, fs.unlinkName(10, "x", noReferences));
    try std.testing.expectEqualDeep(before, try fs.node(1));
    try std.testing.expectEqualDeep(parent_before, try fs.node(10));
    try std.testing.expectEqual(@as(i64, 1), try scalar("SELECT count(*) FROM dirents WHERE target_inode=1"));
    try std.testing.expectEqual(@as(i64, 1), try scalar("SELECT count(*) FROM file_chunks WHERE inode_id=1"));

    try std.testing.expectEqual(@as(?i64, 1), try fs.unlinkName(10, "x", hasReferences));
    try std.testing.expectError(error.Io, fs.reclaimUnlinkedFile(1));
    try std.testing.expectEqual(@as(i64, 0), (try fs.node(1)).links);
    try std.testing.expectEqual(@as(i64, 1), try scalar("SELECT count(*) FROM file_chunks WHERE inode_id=1"));
    try sql("DROP TRIGGER fail_reclaim;");
    try fs.reclaimUnlinkedFile(1);
    try std.testing.expectEqual(@as(i64, 0), try scalar("SELECT count(*) FROM file_chunks"));
}

test "privilege stripping is supported without general chmod" {
    try setup();
    defer teardown();
    try sql("UPDATE inodes SET mode=36333 WHERE inode_id=1;"); // 0106755
    var attr = std.mem.zeroes(c.struct_stat);
    attr.st_mode = 0o100755;
    try std.testing.expectEqual(@as(c_int, -c.EOPNOTSUPP), fs.setAttributes(1, &attr, c.FUSE_SET_ATTR_MODE));
    try std.testing.expectEqual(@as(c_int, 0), fs.setAttributes(1, &attr, c.FUSE_SET_ATTR_KILL_SUID | c.FUSE_SET_ATTR_KILL_SGID));
    try std.testing.expectEqual(@as(i64, 0o100755), (try fs.node(1)).mode);
    attr.st_mode = 0o106755;
    try std.testing.expectEqual(@as(c_int, -c.EOPNOTSUPP), fs.setAttributes(1, &attr, c.FUSE_SET_ATTR_MODE));
}
