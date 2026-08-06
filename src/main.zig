const std = @import("std");
const Io = std.Io;

const whereiz = @import("whereiz.zig");
const platform = @import("platform.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    const program_args = args[1..];

    const cli = whereiz.parseArgs(platform.defaultArchitecture(), program_args);
    if (cli.show_usage) {
        std.debug.print("Usage: whereis [command/filename] [optional:x86/x64] [optional:working directory] [optional:executeable directory]\n", .{});
        return;
    }

    var working_dir = try platform.currentDirectory(io, arena);
    var executable_dir = try platform.executableDirectory(io, arena);

    if (cli.working_dir) |dir| {
        if (std.Io.Dir.path.isAbsolute(dir)) {
            if (Io.Dir.openDirAbsolute(io, dir, .{})) |handle| {
                handle.close(io);
                working_dir = dir;
            } else |_| {}
        }
    }
    if (cli.executable_dir) |dir| {
        if (std.Io.Dir.path.isAbsolute(dir)) {
            if (Io.Dir.openDirAbsolute(io, dir, .{})) |handle| {
                handle.close(io);
                executable_dir = dir;
            } else |_| {}
        }
    }

    const config = whereiz.Config{
        .safe_dll_search = try platform.safeDllSearch(arena),
        .working_dir = working_dir,
        .executable_dir = executable_dir,
        .system_dir = try platform.systemDirectory(arena),
        .windows_system_dir = "C:\\Windows\\System",
        .windows_dir = try platform.windowsDirectory(arena),
        .machine_path = try platform.machinePath(init.environ_map, arena),
        .known_dlls = try platform.knownDlls(arena),
        .dll_directory = try platform.dllDirectory(arena, cli.architecture),
    };

    const results = try whereiz.find(io, arena, &config, cli.query.?);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    for (results) |path| {
        try stdout_writer.print("{s}\n", .{path});
    }
    try stdout_writer.flush();
}
