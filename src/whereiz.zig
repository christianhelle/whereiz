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

pub fn commandCandidates(allocator: Allocator, command: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |candidate| allocator.free(candidate);
        list.deinit(allocator);
    }

    if (hasKnownExtension(command)) {
        try list.append(allocator, try allocator.dupe(u8, command));
    } else {
        const extensions = [_][]const u8{ ".exe", ".cmd", ".bat" };
        for (extensions) |extension| {
            const candidate = try std.fmt.allocPrint(allocator, "{s}{s}", .{ command, extension });
            errdefer allocator.free(candidate);
            try list.append(allocator, candidate);
        }
    }

    return list.toOwnedSlice(allocator);
}

fn hasKnownExtension(command: []const u8) bool {
    const extensions = [_][]const u8{ ".exe", ".cmd", ".bat" };
    for (extensions) |extension| {
        if (std.ascii.endsWithIgnoreCase(command, extension)) return true;
    }
    return false;
}

pub fn findFilePaths(io: Io, allocator: Allocator, config: *const Config, filename: []const u8) ![][]const u8 {
    var results: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (results.items) |path| allocator.free(path);
        results.deinit(allocator);
    }

    if (config.dll_directory) |dll_directory| {
        if (isKnownDll(config, filename)) {
            const candidate = try joinFilename(allocator, dll_directory, filename);
            defer allocator.free(candidate);
            if (fileExists(io, candidate)) {
                try results.append(allocator, try allocator.dupe(u8, candidate));
            }
        }
    }

    const order = try searchOrder(allocator, config);
    defer allocator.free(order);

    for (order) |directory| {
        if (!dirExists(io, directory)) continue;
        const candidate = try joinFilename(allocator, directory, filename);
        defer allocator.free(candidate);
        if (!fileExists(io, candidate)) continue;
        try results.append(allocator, try allocator.dupe(u8, candidate));
    }

    return results.toOwnedSlice(allocator);
}

fn joinFilename(allocator: Allocator, directory: []const u8, filename: []const u8) ![]u8 {
    if (std.Io.Dir.path.isAbsolute(filename)) return allocator.dupe(u8, filename);
    return std.Io.Dir.path.join(allocator, &.{ directory, filename });
}

fn isKnownDll(config: *const Config, filename: []const u8) bool {
    for (config.known_dlls) |known| {
        if (std.ascii.eqlIgnoreCase(known, filename)) return true;
    }
    return false;
}

pub fn findCommandPaths(io: Io, allocator: Allocator, config: *const Config, command: []const u8) ![][]const u8 {
    var results: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (results.items) |path| allocator.free(path);
        results.deinit(allocator);
    }

    const candidates = try commandCandidates(allocator, command);
    defer freeCandidates(allocator, candidates);

    for (candidates) |candidate| {
        const paths = try findFilePaths(io, allocator, config, candidate);
        defer freePaths(allocator, paths);
        for (paths) |path| {
            try results.append(allocator, try allocator.dupe(u8, path));
        }
    }

    return results.toOwnedSlice(allocator);
}

pub fn find(io: Io, allocator: Allocator, config: *const Config, query: []const u8) ![][]const u8 {
    if (std.mem.indexOfScalar(u8, query, '.') != null) {
        return findFilePaths(io, allocator, config, query);
    }
    return findCommandPaths(io, allocator, config, query);
}

pub const Cli = struct {
    show_usage: bool,
    query: ?[]const u8,
    architecture: Architecture,
    working_dir: ?[]const u8,
    executable_dir: ?[]const u8,
};

pub fn parseArgs(default_architecture: Architecture, args: []const []const u8) Cli {
    if (args.len == 0) {
        return .{
            .show_usage = true,
            .query = null,
            .architecture = default_architecture,
            .working_dir = null,
            .executable_dir = null,
        };
    }

    var cli = Cli{
        .show_usage = false,
        .query = args[0],
        .architecture = default_architecture,
        .working_dir = null,
        .executable_dir = null,
    };

    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "x86")) {
            cli.architecture = .x86;
        } else if (std.mem.eql(u8, args[1], "x64")) {
            cli.architecture = .x64;
        }
    }

    if (args.len > 2) cli.working_dir = args[2];
    if (args.len > 3) cli.executable_dir = args[3];

    return cli;
}

fn fileExists(io: Io, path: []const u8) bool {
    var file = Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn dirExists(io: Io, path: []const u8) bool {
    var dir = Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    dir.close(io);
    return true;
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

test "command without extension expands into exe, cmd, and bat candidates" {
    const candidates = try commandCandidates(testing.allocator, "cmd");
    defer freeCandidates(testing.allocator, candidates);

    const expected = [_][]const u8{ "cmd.exe", "cmd.cmd", "cmd.bat" };
    try expectPathsEqual(&expected, candidates);
}

test "command with exe extension is kept as is" {
    const candidates = try commandCandidates(testing.allocator, "foo.exe");
    defer freeCandidates(testing.allocator, candidates);

    const expected = [_][]const u8{"foo.exe"};
    try expectPathsEqual(&expected, candidates);
}

test "command with cmd extension is kept as is" {
    const candidates = try commandCandidates(testing.allocator, "deploy.cmd");
    defer freeCandidates(testing.allocator, candidates);

    const expected = [_][]const u8{"deploy.cmd"};
    try expectPathsEqual(&expected, candidates);
}

test "command with bat extension is kept as is" {
    const candidates = try commandCandidates(testing.allocator, "install.bat");
    defer freeCandidates(testing.allocator, candidates);

    const expected = [_][]const u8{"install.bat"};
    try expectPathsEqual(&expected, candidates);
}

test "command with uppercase exe extension is kept as is" {
    const candidates = try commandCandidates(testing.allocator, "FOO.EXE");
    defer freeCandidates(testing.allocator, candidates);

    const expected = [_][]const u8{"FOO.EXE"};
    try expectPathsEqual(&expected, candidates);
}

fn freeCandidates(allocator: Allocator, candidates: []const []const u8) void {
    for (candidates) |candidate| allocator.free(candidate);
    allocator.free(candidates);
}

test "findFilePaths returns every existing match in search order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try makeDirs(&tmp, &.{ "exe_dir", "work", "sys", "win_sys", "win", "path1", "path2" });
    try writeFileInDirs(&tmp, &.{ "exe_dir", "work", "sys", "win_sys", "win", "path1", "path2" }, "foo.txt");

    const config = try makeConfig(testing.allocator, &tmp, .{
        .safe_dll_search = true,
        .working_dir = "work",
        .executable_dir = "exe_dir",
        .system_dir = "sys",
        .windows_system_dir = "win_sys",
        .windows_dir = "win",
        .machine_path = &.{ "path1", "path2" },
        .known_dlls = &.{},
        .dll_directory = null,
    });
    defer freeConfig(testing.allocator, &config);

    const results = try findFilePaths(std.testing.io, testing.allocator, &config.config, "foo.txt");
    defer freePaths(testing.allocator, results);

    const expected = [_][]const u8{
        "exe_dir/foo.txt",
        "sys/foo.txt",
        "win_sys/foo.txt",
        "win/foo.txt",
        "work/foo.txt",
        "path1/foo.txt",
        "path2/foo.txt",
    };
    try expectResultsEqual(config.base, &expected, results);
}

test "findFilePaths skips directories that do not contain the file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try makeDirs(&tmp, &.{ "exe_dir", "work", "sys" });
    try writeFileInDirs(&tmp, &.{"exe_dir"}, "foo.txt");

    const config = try makeConfig(testing.allocator, &tmp, .{
        .safe_dll_search = true,
        .working_dir = "work",
        .executable_dir = "exe_dir",
        .system_dir = "sys",
        .windows_system_dir = "win_sys",
        .windows_dir = "win",
        .machine_path = &.{},
        .known_dlls = &.{},
        .dll_directory = null,
    });
    defer freeConfig(testing.allocator, &config);

    const results = try findFilePaths(std.testing.io, testing.allocator, &config.config, "foo.txt");
    defer freePaths(testing.allocator, results);

    const expected = [_][]const u8{"exe_dir/foo.txt"};
    try expectResultsEqual(config.base, &expected, results);
}

test "findFilePaths checks known dll directory first" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try makeDirs(&tmp, &.{ "dlldir", "sys" });
    try writeFileInDirs(&tmp, &.{ "dlldir", "sys" }, "kernel32.dll");

    const config = try makeConfig(testing.allocator, &tmp, .{
        .safe_dll_search = true,
        .working_dir = "work",
        .executable_dir = "exe_dir",
        .system_dir = "sys",
        .windows_system_dir = "win_sys",
        .windows_dir = "win",
        .machine_path = &.{},
        .known_dlls = &.{"kernel32.dll"},
        .dll_directory = "dlldir",
    });
    defer freeConfig(testing.allocator, &config);

    const results = try findFilePaths(std.testing.io, testing.allocator, &config.config, "kernel32.dll");
    defer freePaths(testing.allocator, results);

    const expected = [_][]const u8{ "dlldir/kernel32.dll", "sys/kernel32.dll" };
    try expectResultsEqual(config.base, &expected, results);
}

test "findFilePaths skips known dll directory when the file is missing there" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try makeDirs(&tmp, &.{ "sys" });
    try writeFileInDirs(&tmp, &.{"sys"}, "kernel32.dll");

    const config = try makeConfig(testing.allocator, &tmp, .{
        .safe_dll_search = true,
        .working_dir = "work",
        .executable_dir = "exe_dir",
        .system_dir = "sys",
        .windows_system_dir = "win_sys",
        .windows_dir = "win",
        .machine_path = &.{},
        .known_dlls = &.{"kernel32.dll"},
        .dll_directory = "dlldir",
    });
    defer freeConfig(testing.allocator, &config);

    const results = try findFilePaths(std.testing.io, testing.allocator, &config.config, "kernel32.dll");
    defer freePaths(testing.allocator, results);

    const expected = [_][]const u8{"sys/kernel32.dll"};
    try expectResultsEqual(config.base, &expected, results);
}

test "findFilePaths keeps an absolute filename as is" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try makeDirs(&tmp, &.{"exe_dir"});
    try writeFileInDirs(&tmp, &.{"exe_dir"}, "bar.txt");

    const config = try makeConfig(testing.allocator, &tmp, .{
        .safe_dll_search = true,
        .working_dir = "work",
        .executable_dir = "exe_dir",
        .system_dir = "sys",
        .windows_system_dir = "win_sys",
        .windows_dir = "win",
        .machine_path = &.{},
        .known_dlls = &.{},
        .dll_directory = null,
    });
    defer freeConfig(testing.allocator, &config);

    const absolute = try std.fs.path.join(testing.allocator, &.{ config.base, "exe_dir", "bar.txt" });
    defer testing.allocator.free(absolute);

    const results = try findFilePaths(std.testing.io, testing.allocator, &config.config, absolute);
    defer freePaths(testing.allocator, results);

    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings(absolute, results[0]);
}

const MakeConfigOptions = struct {
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

const OwnedConfig = struct {
    config: Config,
    base: []const u8,
    owned: []const []const u8,
};

fn makeConfig(allocator: Allocator, tmp: *testing.TmpDir, options: MakeConfigOptions) !OwnedConfig {
    var owned: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned.items) |path| allocator.free(path);
        owned.deinit(allocator);
    }

    const cwd_z = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd_z);
    const cwd = try allocator.dupe(u8, cwd_z);
    try owned.append(allocator, cwd);
    const base = try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
    try owned.append(allocator, base);

    var machine_path: std.ArrayList([]const u8) = .empty;
    errdefer machine_path.deinit(allocator);
    for (options.machine_path) |name| {
        const path = try joinConfigDir(allocator, &owned, base, name);
        try machine_path.append(allocator, path);
    }

    var known_dlls: std.ArrayList([]const u8) = .empty;
    errdefer known_dlls.deinit(allocator);
    for (options.known_dlls) |name| {
        const duplicate = try allocator.dupe(u8, name);
        try owned.append(allocator, duplicate);
        try known_dlls.append(allocator, duplicate);
    }

    var dll_directory: ?[]const u8 = null;
    if (options.dll_directory) |name| {
        dll_directory = try joinConfigDir(allocator, &owned, base, name);
    }

    const config = Config{
        .safe_dll_search = options.safe_dll_search,
        .working_dir = try joinConfigDir(allocator, &owned, base, options.working_dir),
        .executable_dir = try joinConfigDir(allocator, &owned, base, options.executable_dir),
        .system_dir = try joinConfigDir(allocator, &owned, base, options.system_dir),
        .windows_system_dir = try joinConfigDir(allocator, &owned, base, options.windows_system_dir),
        .windows_dir = try joinConfigDir(allocator, &owned, base, options.windows_dir),
        .machine_path = try machine_path.toOwnedSlice(allocator),
        .known_dlls = try known_dlls.toOwnedSlice(allocator),
        .dll_directory = dll_directory,
    };

    return .{ .config = config, .base = base, .owned = try owned.toOwnedSlice(allocator) };
}

fn joinConfigDir(allocator: Allocator, owned: *std.ArrayList([]const u8), base: []const u8, name: []const u8) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ base, name });
    errdefer allocator.free(path);
    try owned.append(allocator, path);
    return path;
}

fn freeConfig(allocator: Allocator, owned_config: *const OwnedConfig) void {
    allocator.free(owned_config.config.machine_path);
    allocator.free(owned_config.config.known_dlls);
    for (owned_config.owned) |path| allocator.free(path);
    allocator.free(owned_config.owned);
}

fn freePaths(allocator: Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

fn makeDirs(tmp: *testing.TmpDir, names: []const []const u8) !void {
    for (names) |name| try tmp.dir.createDirPath(std.testing.io, name);
}

fn writeFileInDirs(tmp: *testing.TmpDir, names: []const []const u8, filename: []const u8) !void {
    for (names) |name| {
        const sub_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ name, filename });
        defer testing.allocator.free(sub_path);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = "" });
    }
}

fn expectResultsEqual(base: []const u8, expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, 0..) |expected_relative, i| {
        const full_expected = try joinRelative(testing.allocator, base, expected_relative);
        defer testing.allocator.free(full_expected);
        try testing.expectEqualStrings(full_expected, actual[i]);
    }
}

fn joinRelative(allocator: Allocator, base: []const u8, relative: []const u8) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    try parts.append(allocator, base);
    var it = std.mem.splitScalar(u8, relative, '/');
    while (it.next()) |part| try parts.append(allocator, part);
    return std.Io.Dir.path.join(allocator, parts.items);
}

test "findCommandPaths searches every candidate extension across the search order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try makeDirs(&tmp, &.{ "exe_dir", "work", "path1", "path2" });
    try writeFileInDirs(&tmp, &.{ "exe_dir", "path1" }, "cmd.exe");
    try writeFileInDirs(&tmp, &.{"path2"}, "cmd.bat");

    const config = try makeConfig(testing.allocator, &tmp, .{
        .safe_dll_search = true,
        .working_dir = "work",
        .executable_dir = "exe_dir",
        .system_dir = "sys",
        .windows_system_dir = "win_sys",
        .windows_dir = "win",
        .machine_path = &.{ "path1", "path2" },
        .known_dlls = &.{},
        .dll_directory = null,
    });
    defer freeConfig(testing.allocator, &config);

    const results = try findCommandPaths(std.testing.io, testing.allocator, &config.config, "cmd");
    defer freePaths(testing.allocator, results);

    const expected = [_][]const u8{ "exe_dir/cmd.exe", "path1/cmd.exe", "path2/cmd.bat" };
    try expectResultsEqual(config.base, &expected, results);
}

test "find dispatches bare names to command search" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try makeDirs(&tmp, &.{"exe_dir"});
    try writeFileInDirs(&tmp, &.{"exe_dir"}, "cmd.exe");

    const config = try makeConfig(testing.allocator, &tmp, .{
        .safe_dll_search = true,
        .working_dir = "work",
        .executable_dir = "exe_dir",
        .system_dir = "sys",
        .windows_system_dir = "win_sys",
        .windows_dir = "win",
        .machine_path = &.{},
        .known_dlls = &.{},
        .dll_directory = null,
    });
    defer freeConfig(testing.allocator, &config);

    const results = try find(std.testing.io, testing.allocator, &config.config, "cmd");
    defer freePaths(testing.allocator, results);

    const expected = [_][]const u8{"exe_dir/cmd.exe"};
    try expectResultsEqual(config.base, &expected, results);
}

test "find dispatches dotted names to file search" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try makeDirs(&tmp, &.{"exe_dir"});
    try writeFileInDirs(&tmp, &.{"exe_dir"}, "kernel32.dll");

    const config = try makeConfig(testing.allocator, &tmp, .{
        .safe_dll_search = true,
        .working_dir = "work",
        .executable_dir = "exe_dir",
        .system_dir = "sys",
        .windows_system_dir = "win_sys",
        .windows_dir = "win",
        .machine_path = &.{},
        .known_dlls = &.{},
        .dll_directory = null,
    });
    defer freeConfig(testing.allocator, &config);

    const results = try find(std.testing.io, testing.allocator, &config.config, "kernel32.dll");
    defer freePaths(testing.allocator, results);

    const expected = [_][]const u8{"exe_dir/kernel32.dll"};
    try expectResultsEqual(config.base, &expected, results);
}

test "parseArgs shows usage when no arguments are given" {
    const cli = parseArgs(.x64, &.{});

    try testing.expect(cli.show_usage);
    try testing.expect(cli.query == null);
    try testing.expectEqual(Architecture.x64, cli.architecture);
    try testing.expect(cli.working_dir == null);
    try testing.expect(cli.executable_dir == null);
}

test "parseArgs takes the first argument as the query" {
    const cli = parseArgs(.x86, &.{"cmd"});

    try testing.expect(!cli.show_usage);
    try testing.expectEqualStrings("cmd", cli.query.?);
    try testing.expectEqual(Architecture.x86, cli.architecture);
    try testing.expect(cli.working_dir == null);
    try testing.expect(cli.executable_dir == null);
}

test "parseArgs overrides the architecture with x86" {
    const cli = parseArgs(.x64, &.{ "cmd", "x86" });

    try testing.expectEqual(Architecture.x86, cli.architecture);
}

test "parseArgs overrides the architecture with x64" {
    const cli = parseArgs(.x86, &.{ "cmd", "x64" });

    try testing.expectEqual(Architecture.x64, cli.architecture);
}

test "parseArgs keeps the default architecture for an unknown override" {
    const cli = parseArgs(.x64, &.{ "cmd", "arm" });

    try testing.expectEqual(Architecture.x64, cli.architecture);
}

test "parseArgs reads the working directory" {
    const cli = parseArgs(.x64, &.{ "foo.dll", "x86", "C:\\work" });

    try testing.expectEqualStrings("C:\\work", cli.working_dir.?);
    try testing.expect(cli.executable_dir == null);
}

test "parseArgs reads the executable directory" {
    const cli = parseArgs(.x64, &.{ "foo.dll", "x86", "C:\\work", "C:\\bin" });

    try testing.expectEqualStrings("C:\\work", cli.working_dir.?);
    try testing.expectEqualStrings("C:\\bin", cli.executable_dir.?);
}
