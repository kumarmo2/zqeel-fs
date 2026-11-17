const std = @import("std");

pub const DirEntry = struct { name: [:0]u8, inode: i64, mode: u32 };
pub const Kind = enum { file, directory };
pub const Handle = struct {
    inode: i64,
    flags: i32,
    kind: Kind,
    entries: []DirEntry = &.{},
};
pub const References = struct { lookups: u64 = 0, opens: u64 = 0 };

// Volatile accounting only: dropping references never deletes database rows yet.
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    handles: std.AutoHashMap(u64, Handle),
    refs: std.AutoHashMap(i64, References),
    next_handle: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Runtime {
        return .{ .allocator = allocator, .handles = .init(allocator), .refs = .init(allocator) };
    }

    pub fn freeEntries(self: *Runtime, entries: []DirEntry) void {
        for (entries) |entry| {
            self.allocator.free(entry.name);
        }
        self.allocator.free(entries);
    }

    pub fn deinit(self: *Runtime) void {
        var it = self.handles.valueIterator();
        while (it.next()) |handle| {
            self.freeEntries(handle.entries);
        }
        self.handles.deinit();
        self.refs.deinit();
    }

    // Reserve before committing file creation or changing contents in open(O_TRUNC).
    pub fn reserve(self: *Runtime) !void {
        if (self.next_handle == std.math.maxInt(u64)) {
            return error.Overflow;
        }
        try self.handles.ensureUnusedCapacity(1);
        try self.refs.ensureUnusedCapacity(1);
    }

    pub fn reserveLookup(self: *Runtime) !void {
        try self.refs.ensureUnusedCapacity(1);
    }

    pub fn addOpenReserved(self: *Runtime, handle: Handle) u64 {
        const ref = self.refs.getOrPutAssumeCapacity(handle.inode);
        if (!ref.found_existing) {
            ref.value_ptr.* = .{};
        }
        // Live handles consume memory; reaching u64 opens is not representable in RAM.
        ref.value_ptr.opens += 1;
        const id = self.next_handle;
        self.next_handle += 1;
        self.handles.putAssumeCapacity(id, handle);
        return id;
    }

    pub fn addLookupReserved(self: *Runtime, inode: i64) !void {
        const ref = self.refs.getOrPutAssumeCapacity(inode);
        if (!ref.found_existing) {
            ref.value_ptr.* = .{};
        }
        ref.value_ptr.lookups = try std.math.add(u64, ref.value_ptr.lookups, 1);
    }

    pub fn get(self: *Runtime, id: u64, inode: i64, kind: Kind) ?*Handle {
        const handle = self.handles.getPtr(id) orelse return null;
        if (handle.inode != inode or handle.kind != kind) {
            return null;
        }
        return handle;
    }

    fn trim(self: *Runtime, inode: i64) void {
        const ref = self.refs.get(inode) orelse return;
        if (ref.lookups == 0 and ref.opens == 0) {
            _ = self.refs.remove(inode);
        }
    }

    pub fn forget(self: *Runtime, inode: i64, count: u64) bool {
        const ref = self.refs.getPtr(inode) orelse return count == 0;
        if (count > ref.lookups) {
            return false;
        }
        ref.lookups -= count;
        self.trim(inode);
        return true;
    }

    pub fn close(self: *Runtime, id: u64, inode: i64, kind: Kind) bool {
        const handle = self.get(id, inode, kind) orelse return false;
        self.freeEntries(handle.entries);
        _ = self.handles.remove(id);
        self.refs.getPtr(inode).?.opens -= 1;
        self.trim(inode);
        return true;
    }
};

test "allocation failure reserves no handles or references" {
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var rt = Runtime.init(failing.allocator());
        defer rt.deinit();
        try std.testing.expectError(error.OutOfMemory, rt.reserve());
        try std.testing.expectEqual(@as(u32, 0), rt.handles.count());
        try std.testing.expectEqual(@as(u32, 0), rt.refs.count());
        try std.testing.expectEqual(@as(u64, 1), rt.next_handle);
    }
}

test "lookups and opens are independent, handles validate identity and kind" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();
    try rt.reserve();
    const a = rt.addOpenReserved(.{ .inode = 42, .flags = 1, .kind = .file });
    try rt.reserve();
    const b = rt.addOpenReserved(.{ .inode = 42, .flags = 2, .kind = .file });
    try rt.reserveLookup();
    try rt.addLookupReserved(42);
    try rt.addLookupReserved(42);
    try std.testing.expect(a != b);
    try std.testing.expectEqual(@as(u64, 2), rt.refs.get(42).?.opens);
    try std.testing.expect(rt.get(a, 43, .file) == null);
    try std.testing.expect(rt.get(a, 42, .directory) == null);
    try std.testing.expect(!rt.forget(42, 3));
    try std.testing.expect(rt.forget(42, 1));
    try std.testing.expect(rt.close(a, 42, .file));
    try std.testing.expect(!rt.close(a, 42, .file));
    try std.testing.expectEqual(@as(i32, 2), rt.get(b, 42, .file).?.flags);
    try std.testing.expect(rt.forget(42, 1));
    try std.testing.expect(rt.close(b, 42, .file));
    try std.testing.expect(rt.refs.get(42) == null);
}

test "lookup overflow and shutdown without release do not leak memory" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();
    try rt.reserve();
    const entries = try std.testing.allocator.alloc(DirEntry, 1);
    entries[0] = .{ .name = try std.testing.allocator.dupeSentinel(u8, "file", 0), .inode = 2, .mode = 0o100644 };
    _ = rt.addOpenReserved(.{ .inode = 1, .flags = 0, .kind = .directory, .entries = entries });
    rt.refs.getPtr(1).?.lookups = std.math.maxInt(u64);
    try std.testing.expectError(error.Overflow, rt.addLookupReserved(1));
    try std.testing.expect(!rt.close(1, 1, .file));
}
