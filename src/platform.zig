const std = @import("std");
const builtin = @import("builtin");

const whereiz = @import("whereiz.zig");
const registry = @import("registry.zig");

const windows = std.os.windows;
const Architecture = whereiz.Architecture;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const UINT = windows.UINT;
const LPWSTR = windows.LPWSTR;

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

fn containsIgnoreCase(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |entry| {
        if (std.ascii.eqlIgnoreCase(entry, needle)) return true;
    }
    return false;
}
