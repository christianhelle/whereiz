const std = @import("std");
const builtin = @import("builtin");

const whereiz = @import("whereiz.zig");
const registry = @import("registry.zig");

const windows = std.os.windows;
const Architecture = whereiz.Architecture;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const LSTATUS = windows.LSTATUS;
const HKEY = windows.HKEY;
const REGSAM = windows.REGSAM;
const DWORD = windows.DWORD;
const UINT = windows.UINT;
const LPCWSTR = windows.LPCWSTR;
const LPWSTR = windows.LPWSTR;

const ERROR_SUCCESS: LSTATUS = 0;
const ERROR_MORE_DATA: LSTATUS = 234;
const ERROR_NO_MORE_ITEMS: LSTATUS = 259;

const REG_DWORD: DWORD = 4;

const KEY_READ: REGSAM = @bitCast(@as(u32, 0x0002_0019));

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

extern "kernel32" fn GetSystemDirectoryW(lp_buffer: LPWSTR, u_size: UINT) callconv(.winapi) UINT;

extern "kernel32" fn GetWindowsDirectoryW(lp_buffer: LPWSTR, u_size: UINT) callconv(.winapi) UINT;

comptime {
    if (builtin.os.tag != .windows) @compileError("whereiz only supports Windows");
}

const known_dlls_path = "SYSTEM\\CurrentControlSet\\Control\\Session Manager\\KnownDLLs";
const exclude_from_known_dlls_path = "SYSTEM\\CurrentControlSet\\Control\\Session Manager\\ExcludeFromKnownDlls";
const session_manager_path = "SYSTEM\\CurrentControlSet\\Control\\Session Manager";

pub fn defaultArchitecture() Architecture {
    return switch (builtin.cpu.arch) {
        .x86_64, .aarch64 => .x64,
        else => .x86,
    };
}

pub fn currentDirectory(io: Io, allocator: Allocator) ![]const u8 {
    return std.process.currentPathAlloc(io, allocator);
}

pub fn executableDirectory(io: Io, allocator: Allocator) ![]const u8 {
    return std.process.executableDirPathAlloc(io, allocator);
}

pub fn systemDirectory(allocator: Allocator) ![]const u8 {
    var buffer: [windows.PATH_MAX_WIDE:0]u16 = undefined;
    const length = GetSystemDirectoryW(&buffer, buffer.len);
    return std.unicode.wtf16LeToWtf8Alloc(allocator, buffer[0..length]);
}

pub fn windowsDirectory(allocator: Allocator) ![]const u8 {
    var buffer: [windows.PATH_MAX_WIDE:0]u16 = undefined;
    const length = GetWindowsDirectoryW(&buffer, buffer.len);
    return std.unicode.wtf16LeToWtf8Alloc(allocator, buffer[0..length]);
}

pub fn safeDllSearch(allocator: Allocator) !bool {
    const key = try registry.Key.open(allocator, windows.HKEY_LOCAL_MACHINE, session_manager_path) orelse return true;
    defer key.close();
    const value = try key.queryDword(allocator, "SafeDllSearchMode") orelse return true;
    return value != 0;
}

pub fn machinePath(environ_map: *std.process.Environ.Map, allocator: Allocator) ![]const []const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (dirs.items) |dir| allocator.free(dir);
        dirs.deinit(allocator);
    }

    const raw = environ_map.get("PATH") orelse return try dirs.toOwnedSlice(allocator);

    var it = std.mem.splitScalar(u8, raw, ';');
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        try dirs.append(allocator, try allocator.dupe(u8, entry));
    }

    return dirs.toOwnedSlice(allocator);
}

pub fn knownDlls(allocator: Allocator) ![]const []const u8 {
    var results: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (results.items) |value| allocator.free(value);
        results.deinit(allocator);
    }

    const key = try registry.Key.open(allocator, windows.HKEY_LOCAL_MACHINE, known_dlls_path) orelse return try results.toOwnedSlice(allocator);
    defer key.close();

    const exclude_key = try registry.Key.open(allocator, windows.HKEY_LOCAL_MACHINE, exclude_from_known_dlls_path);
    if (exclude_key) |exclude| {
        defer exclude.close();
        const exclude_names = try exclude.enumValueNames(allocator);
        defer registry.freeValueNames(allocator, exclude_names);

        const value_names = try key.enumValueNames(allocator);
        defer registry.freeValueNames(allocator, value_names);

        for (value_names) |name| {
            if (std.mem.eql(u8, name, "DllDirectory") or std.mem.eql(u8, name, "DllDirectory32")) continue;
            if (containsIgnoreCase(exclude_names, name)) continue;
            if (try key.queryString(allocator, name)) |value| {
                try results.append(allocator, value);
            }
        }
    } else {
        const value_names = try key.enumValueNames(allocator);
        defer registry.freeValueNames(allocator, value_names);

        for (value_names) |name| {
            if (std.mem.eql(u8, name, "DllDirectory") or std.mem.eql(u8, name, "DllDirectory32")) continue;
            if (try key.queryString(allocator, name)) |value| {
                try results.append(allocator, value);
            }
        }
    }

    return results.toOwnedSlice(allocator);
}

pub fn dllDirectory(allocator: Allocator, architecture: Architecture) !?[]const u8 {
    const key = try registry.Key.open(allocator, windows.HKEY_LOCAL_MACHINE, known_dlls_path) orelse return null;
    defer key.close();

    const value_name = switch (architecture) {
        .x64 => "DllDirectory",
        .x86 => "DllDirectory32",
    };
    return key.queryString(allocator, value_name);
}

fn openSubKeyPath(allocator: Allocator, root: HKEY, path: []const u8) !?HKEY {
    var result: ?HKEY = null;
    var parent = root;
    var it = std.mem.splitScalar(u8, path, '\\');
    while (it.next()) |segment| {
        if (segment.len == 0) continue;
        const segment_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, segment);
        defer allocator.free(segment_w);

        var child: HKEY = undefined;
        const status = RegOpenKeyExW(parent, segment_w.ptr, 0, KEY_READ, &child);

        if (result) |opened| _ = RegCloseKey(opened);
        result = null;
        if (status != ERROR_SUCCESS) return null;

        result = child;
        parent = child;
    }
    return result;
}

fn queryStringValue(allocator: Allocator, key: HKEY, name: []const u8) !?[]const u8 {
    const name_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, name);
    defer allocator.free(name_w);

    var value_type: DWORD = 0;
    var size: DWORD = 0;
    if (RegQueryValueExW(key, name_w.ptr, null, &value_type, null, &size) != ERROR_SUCCESS) return null;
    if (size == 0 or size % 2 != 0) return null;

    const buffer = try allocator.alloc(u16, size / 2);
    defer allocator.free(buffer);
    if (RegQueryValueExW(key, name_w.ptr, null, &value_type, @ptrCast(buffer.ptr), &size) != ERROR_SUCCESS) return null;

    var end: usize = buffer.len;
    while (end > 0 and buffer[end - 1] == 0) end -= 1;
    return try std.unicode.wtf16LeToWtf8Alloc(allocator, buffer[0..end]);
}

fn queryDwordValue(allocator: Allocator, key: HKEY, name: []const u8) !?u32 {
    const name_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, name);
    defer allocator.free(name_w);

    var value_type: DWORD = 0;
    var value: DWORD = 0;
    var size: DWORD = @sizeOf(DWORD);
    if (RegQueryValueExW(key, name_w.ptr, null, &value_type, @ptrCast(&value), &size) != ERROR_SUCCESS) return null;
    if (value_type != REG_DWORD) return null;
    return value;
}

fn enumValueNames(allocator: Allocator, key: HKEY) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var index: DWORD = 0;
    while (true) {
        var buffer: [4096:0]u16 = undefined;
        var name_length: DWORD = buffer.len;
        const status = RegEnumValueW(key, index, &buffer, &name_length, null, null, null, null);
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

fn freeValueNames(allocator: Allocator, names: []const []const u8) void {
    for (names) |name| allocator.free(name);
    allocator.free(names);
}

fn containsIgnoreCase(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |entry| {
        if (std.ascii.eqlIgnoreCase(entry, needle)) return true;
    }
    return false;
}
