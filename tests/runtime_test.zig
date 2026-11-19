const std = @import("std");
const runtime = @import("runtime");

test "allocation failure reserves no handles or references" {
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var rt = runtime.Runtime.init(failing.allocator());
        defer rt.deinit();
        try std.testing.expectError(error.OutOfMemory, rt.reserve());
        try std.testing.expectEqual(@as(u32, 0), rt.handles.count());
        try std.testing.expectEqual(@as(u32, 0), rt.refs.count());
        try std.testing.expectEqual(@as(u64, 1), rt.next_handle);
    }
}

test "lookups and opens are independent, handles validate identity and kind" {
    var rt = runtime.Runtime.init(std.testing.allocator);
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
    var rt = runtime.Runtime.init(std.testing.allocator);
    defer rt.deinit();
    try rt.reserve();
    const entries = try std.testing.allocator.alloc(runtime.DirEntry, 1);
    entries[0] = .{ .name = try std.testing.allocator.dupeSentinel(u8, "file", 0), .inode = 2, .mode = 0o100644 };
    _ = rt.addOpenReserved(.{ .inode = 1, .flags = 0, .kind = .directory, .entries = entries });
    rt.refs.getPtr(1).?.lookups = std.math.maxInt(u64);
    try std.testing.expectError(error.Overflow, rt.addLookupReserved(1));
    try std.testing.expect(!rt.close(1, 1, .file));
}
