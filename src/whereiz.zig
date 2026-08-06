//! By convention, whereiz.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const Architecture = enum {
    x86,
    x64,
};

pub const Config = struct {
    safe_dll_search: bool,
    working_dir: []const u8,
    executable_dir: []const u8,
    system_dir: []const u8,
    windows_system_dir: []const u8,
    windows_dir: []const u8,
    machine_path: []const []const u8,
    known_dlls: []const []const u8,
    dll_directory: ?[]const u8,
};

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

pub fn searchOrder(allocator: Allocator, config: *const Config) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);

    try list.append(allocator, config.executable_dir);
    if (!config.safe_dll_search) try list.append(allocator, config.working_dir);
    try list.append(allocator, config.system_dir);
    try list.append(allocator, config.windows_system_dir);
    try list.append(allocator, config.windows_dir);
    if (config.safe_dll_search) try list.append(allocator, config.working_dir);
    try list.appendSlice(allocator, config.machine_path);

    return list.toOwnedSlice(allocator);
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}

test "search order places working dir after system dirs when safe dll search is enabled" {
    var dirs = [_][]const u8{ "C:\\path1", "C:\\path2" };
    const config = Config{
        .safe_dll_search = true,
        .working_dir = "C:\\work",
        .executable_dir = "C:\\exe",
        .system_dir = "C:\\Windows\\System32",
        .windows_system_dir = "C:\\Windows\\System",
        .windows_dir = "C:\\Windows",
        .machine_path = &dirs,
        .known_dlls = &.{},
        .dll_directory = null,
    };

    const order = try searchOrder(testing.allocator, &config);
    defer testing.allocator.free(order);

    const expected = [_][]const u8{
        "C:\\exe",
        "C:\\Windows\\System32",
        "C:\\Windows\\System",
        "C:\\Windows",
        "C:\\work",
        "C:\\path1",
        "C:\\path2",
    };
    try expectPathsEqual(&expected, order);
}

test "search order places working dir right after executable dir when safe dll search is disabled" {
    var dirs = [_][]const u8{"C:\\path1"};
    const config = Config{
        .safe_dll_search = false,
        .working_dir = "C:\\work",
        .executable_dir = "C:\\exe",
        .system_dir = "C:\\Windows\\System32",
        .windows_system_dir = "C:\\Windows\\System",
        .windows_dir = "C:\\Windows",
        .machine_path = &dirs,
        .known_dlls = &.{},
        .dll_directory = null,
    };

    const order = try searchOrder(testing.allocator, &config);
    defer testing.allocator.free(order);

    const expected = [_][]const u8{
        "C:\\exe",
        "C:\\work",
        "C:\\Windows\\System32",
        "C:\\Windows\\System",
        "C:\\Windows",
        "C:\\path1",
    };
    try expectPathsEqual(&expected, order);
}

fn expectPathsEqual(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, 0..) |expected_path, i| {
        try testing.expectEqualStrings(expected_path, actual[i]);
    }
}
