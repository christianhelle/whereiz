//! registry.zig is a thin, typed wrapper over the Windows registry API
//! (advapi32). It exposes an open key as a `Key` value whose methods query
//! values by their native types, so callers never touch raw HKEY handles or
//! registry status codes.

const std = @import("std");
const builtin = @import("builtin");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const windows = std.os.windows;

const HKEY = windows.HKEY;
const LSTATUS = windows.LSTATUS;
const REGSAM = windows.REGSAM;
const DWORD = windows.DWORD;
const LPCWSTR = windows.LPCWSTR;
const LPWSTR = windows.LPWSTR;

const ERROR_SUCCESS: LSTATUS = 0;
const ERROR_MORE_DATA: LSTATUS = 234;
const ERROR_NO_MORE_ITEMS: LSTATUS = 259;

const REG_SZ: DWORD = 1;
const REG_DWORD: DWORD = 4;

const KEY_READ: REGSAM = @bitCast(@as(u32, 0x0002_0019));
const KEY_ALL_ACCESS: REGSAM = @bitCast(@as(u32, 0x000F_003F));

extern "advapi32" fn RegOpenKeyExW(
    h_key: HKEY,
    lp_sub_key: ?LPCWSTR,
    ul_options: DWORD,
    sam_desired: REGSAM,
    phk_result: *HKEY,
) callconv(.winapi) LSTATUS;

extern "advapi32" fn RegCloseKey(h_key: HKEY) callconv(.winapi) LSTATUS;

extern "advapi32" fn RegQueryValueExW(
    h_key: HKEY,
    lp_value_name: ?LPCWSTR,
    lp_reserved: ?*DWORD,
    lp_type: ?*DWORD,
    lp_data: ?[*]u8,
    lpcb_data: *DWORD,
) callconv(.winapi) LSTATUS;

extern "advapi32" fn RegEnumValueW(
    h_key: HKEY,
    dw_index: DWORD,
    lp_value_name: LPWSTR,
    lpcch_value_name: *DWORD,
    lp_reserved: ?*DWORD,
    lp_type: ?*DWORD,
    lp_data: ?[*]u8,
    lpcb_data: ?*DWORD,
) callconv(.winapi) LSTATUS;

// The write-side externs below only serve the module's tests, which create a
// scratch key in HKCU to exercise the read abstraction deterministically.

extern "advapi32" fn RegCreateKeyExW(
    h_key: HKEY,
    lp_sub_key: LPCWSTR,
    reserved: DWORD,
    lp_class: ?LPWSTR,
    dw_options: DWORD,
    sam_desired: REGSAM,
    lp_security_attributes: ?*const anyopaque,
    phk_result: *HKEY,
    lpdw_disposition: ?*DWORD,
) callconv(.winapi) LSTATUS;

extern "advapi32" fn RegSetValueExW(
    h_key: HKEY,
    lp_value_name: LPCWSTR,
    reserved: DWORD,
    dw_type: DWORD,
    lp_data: ?[*]const u8,
    cb_data: DWORD,
) callconv(.winapi) LSTATUS;

extern "advapi32" fn RegDeleteValueW(h_key: HKEY, lp_value_name: LPCWSTR) callconv(.winapi) LSTATUS;

extern "advapi32" fn RegDeleteKeyW(h_key: HKEY, lp_sub_key: LPCWSTR) callconv(.winapi) LSTATUS;

comptime {
    if (builtin.os.tag != .windows) @compileError("registry module only supports Windows");
}

/// An open registry key. Close it with `close`; the handle is not managed
/// by the allocator.
pub const Key = struct {
    handle: HKEY,

    /// Opens the key at `path` below `root`, walking each backslash segment
    /// so a missing intermediate segment yields `null`.
    pub fn open(allocator: Allocator, root: HKEY, path: []const u8) !?Key {
        var result: ?Key = null;
        var parent = root;
        var it = std.mem.splitScalar(u8, path, '\\');
        while (it.next()) |segment| {
            if (segment.len == 0) continue;
            const segment_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, segment);
            defer allocator.free(segment_w);

            var child: HKEY = undefined;
            const status = RegOpenKeyExW(parent, segment_w.ptr, 0, KEY_READ, &child);

            if (result) |opened| opened.close();
            result = null;
            if (status != ERROR_SUCCESS) return null;

            result = .{ .handle = child };
            parent = child;
        }
        return result;
    }

    pub fn close(self: Key) void {
        _ = RegCloseKey(self.handle);
    }

    /// Returns the REG_SZ value named `name`, or `null` when the value does
    /// not exist or is not a well-formed wide string.
    pub fn queryString(self: Key, allocator: Allocator, name: []const u8) !?[]const u8 {
        const name_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, name);
        defer allocator.free(name_w);

        var value_type: DWORD = 0;
        var size: DWORD = 0;
        if (RegQueryValueExW(self.handle, name_w.ptr, null, &value_type, null, &size) != ERROR_SUCCESS) return null;
        if (size == 0 or size % 2 != 0) return null;

        const buffer = try allocator.alloc(u16, size / 2);
        defer allocator.free(buffer);
        if (RegQueryValueExW(self.handle, name_w.ptr, null, &value_type, @ptrCast(buffer.ptr), &size) != ERROR_SUCCESS) return null;

        var end: usize = buffer.len;
        while (end > 0 and buffer[end - 1] == 0) end -= 1;
        return try std.unicode.wtf16LeToWtf8Alloc(allocator, buffer[0..end]);
    }

    /// Returns the REG_DWORD value named `name`, or `null` when the value
    /// does not exist or is not a dword.
    pub fn queryDword(self: Key, allocator: Allocator, name: []const u8) !?u32 {
        const name_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, name);
        defer allocator.free(name_w);

        var value_type: DWORD = 0;
        var value: DWORD = 0;
        var size: DWORD = @sizeOf(DWORD);
        if (RegQueryValueExW(self.handle, name_w.ptr, null, &value_type, @ptrCast(&value), &size) != ERROR_SUCCESS) return null;
        if (value_type != REG_DWORD) return null;
        return value;
    }

    /// Returns the names of every value stored under the key, in no
    /// particular order. Free the result with `freeValueNames`.
    pub fn enumValueNames(self: Key, allocator: Allocator) ![]const []const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (names.items) |name| allocator.free(name);
            names.deinit(allocator);
        }

        var index: DWORD = 0;
        while (true) {
            var buffer: [4096:0]u16 = undefined;
            var name_length: DWORD = buffer.len;
            const status = RegEnumValueW(self.handle, index, &buffer, &name_length, null, null, null, null);
            switch (status) {
                ERROR_NO_MORE_ITEMS => break,
                ERROR_SUCCESS => {},
                ERROR_MORE_DATA => return error.NameTooLong,
                else => break,
            }
            const name = try std.unicode.wtf16LeToWtf8Alloc(allocator, buffer[0..name_length]);
            errdefer allocator.free(name);
            try names.append(allocator, name);
            index += 1;
        }

        return names.toOwnedSlice(allocator);
    }
};

/// Frees a slice returned by `Key.enumValueNames`, including every name in it.
pub fn freeValueNames(allocator: Allocator, names: []const []const u8) void {
    for (names) |name| allocator.free(name);
    allocator.free(names);
}

const scratch_key_path = "Software\\whereiz_registry_test";

test "Key.open returns a key for an existing path and null for a missing child" {
    const key = try createScratchKey();
    _ = key;
    defer cleanupScratchKey();

    const opened = try Key.open(testing.allocator, windows.HKEY_CURRENT_USER, scratch_key_path) orelse return error.KeyNotFound;
    defer opened.close();

    const missing = try Key.open(testing.allocator, windows.HKEY_CURRENT_USER, scratch_key_path ++ "\\nope");
    try testing.expect(missing == null);
}

test "Key.queryString returns the stored string value" {
    const key = try createScratchKey();
    defer cleanupScratchKey();
    try setStringValue(key, "TestString", "hello world");

    const opened = try Key.open(testing.allocator, windows.HKEY_CURRENT_USER, scratch_key_path) orelse return error.KeyNotFound;
    defer opened.close();

    const value = (try opened.queryString(testing.allocator, "TestString")) orelse return error.ValueNotFound;
    defer testing.allocator.free(value);
    try testing.expectEqualStrings("hello world", value);
}

test "Key.queryString returns null for a missing value" {
    const key = try createScratchKey();
    _ = key;
    defer cleanupScratchKey();

    const opened = try Key.open(testing.allocator, windows.HKEY_CURRENT_USER, scratch_key_path) orelse return error.KeyNotFound;
    defer opened.close();

    const value = try opened.queryString(testing.allocator, "Missing");
    try testing.expect(value == null);
}

test "Key.queryDword returns the stored dword value" {
    const key = try createScratchKey();
    defer cleanupScratchKey();
    try setDwordValue(key, "TestDword", 42);

    const opened = try Key.open(testing.allocator, windows.HKEY_CURRENT_USER, scratch_key_path) orelse return error.KeyNotFound;
    defer opened.close();

    const value = (try opened.queryDword(testing.allocator, "TestDword")) orelse return error.ValueNotFound;
    try testing.expectEqual(@as(u32, 42), value);
}

test "Key.enumValueNames returns every stored value name" {
    const key = try createScratchKey();
    defer cleanupScratchKey();
    try setStringValue(key, "Alpha", "a");
    try setStringValue(key, "Beta", "b");
    try setDwordValue(key, "Count", 7);

    const opened = try Key.open(testing.allocator, windows.HKEY_CURRENT_USER, scratch_key_path) orelse return error.KeyNotFound;
    defer opened.close();

    const names = try opened.enumValueNames(testing.allocator);
    defer freeValueNames(testing.allocator, names);

    try expectContains(names, "Alpha");
    try expectContains(names, "Beta");
    try expectContains(names, "Count");
}

test "Key.enumValueNames returns an empty slice for a key without values" {
    const key = try createScratchKey();
    _ = key;
    defer cleanupScratchKey();

    const opened = try Key.open(testing.allocator, windows.HKEY_CURRENT_USER, scratch_key_path) orelse return error.KeyNotFound;
    defer opened.close();

    const names = try opened.enumValueNames(testing.allocator);
    defer freeValueNames(testing.allocator, names);

    try testing.expectEqual(@as(usize, 0), names.len);
}

fn expectContains(names: []const []const u8, needle: []const u8) !void {
    for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return;
    }
    return error.NameMissing;
}

fn createScratchKey() !HKEY {
    const path_w = try std.unicode.wtf8ToWtf16LeAllocZ(testing.allocator, scratch_key_path);
    defer testing.allocator.free(path_w);

    var key: HKEY = undefined;
    const status = RegCreateKeyExW(windows.HKEY_CURRENT_USER, path_w.ptr, 0, null, 0, KEY_ALL_ACCESS, null, &key, null);
    if (status != ERROR_SUCCESS) return error.CreateScratchKeyFailed;
    return key;
}

fn setStringValue(key: HKEY, name: []const u8, value: []const u8) !void {
    const name_w = try std.unicode.wtf8ToWtf16LeAllocZ(testing.allocator, name);
    defer testing.allocator.free(name_w);
    const value_w = try std.unicode.wtf8ToWtf16LeAllocZ(testing.allocator, value);
    defer testing.allocator.free(value_w);

    const status = RegSetValueExW(key, name_w.ptr, 0, REG_SZ, @ptrCast(value_w.ptr), @intCast(value_w.len * @sizeOf(u16)));
    if (status != ERROR_SUCCESS) return error.SetScratchValueFailed;
}

fn setDwordValue(key: HKEY, name: []const u8, value: u32) !void {
    const name_w = try std.unicode.wtf8ToWtf16LeAllocZ(testing.allocator, name);
    defer testing.allocator.free(name_w);

    var dword: DWORD = @intCast(value);
    const status = RegSetValueExW(key, name_w.ptr, 0, REG_DWORD, @ptrCast(&dword), @sizeOf(DWORD));
    if (status != ERROR_SUCCESS) return error.SetScratchValueFailed;
}

fn cleanupScratchKey() void {
    const path_w = std.unicode.wtf8ToWtf16LeAllocZ(testing.allocator, scratch_key_path) catch return;
    defer testing.allocator.free(path_w);

    var key: HKEY = undefined;
    const open_status = RegOpenKeyExW(windows.HKEY_CURRENT_USER, path_w.ptr, 0, KEY_ALL_ACCESS, &key);
    if (open_status != ERROR_SUCCESS) return;
    defer _ = RegCloseKey(key);

    const value_names = [_][]const u8{ "TestString", "TestDword", "Alpha", "Beta", "Count", "Missing" };
    for (value_names) |name| {
        const name_w = std.unicode.wtf8ToWtf16LeAllocZ(testing.allocator, name) catch continue;
        defer testing.allocator.free(name_w);
        _ = RegDeleteValueW(key, name_w.ptr);
    }
    _ = RegDeleteKeyW(windows.HKEY_CURRENT_USER, path_w.ptr);
}
