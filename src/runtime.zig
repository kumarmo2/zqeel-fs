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
