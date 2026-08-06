const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("whereiz", .{
        .root_source_file = b.path("src/whereiz.zig"),
        .target = target,
    });

    const exe = addWhereizExecutable(b, mod, target, optimize);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    const release_exe = addWhereizExecutable(b, mod, target, .ReleaseSmall);
    const install_release_step = b.step("install-release", "Build ReleaseSmall and install to the docs install directory");
    const install_release = InstallReleaseStep.create(b, release_exe.getEmittedBin(), getInstallPrefix(b), release_exe.out_filename);
    install_release_step.dependOn(&install_release.step);
}

fn addWhereizExecutable(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "whereiz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "whereiz", .module = mod },
            },
        }),
    });
}

fn getInstallPrefix(b: *std.Build) []const u8 {
    const default_prefix = b.build_root.join(b.allocator, &.{"zig-out"}) catch @panic("OOM");
    if (!std.mem.eql(u8, b.install_prefix, default_prefix)) {
        return b.install_prefix;
    }

    if (b.graph.environ_map.get("INSTALL_DIR")) |install_dir| {
        if (install_dir.len > 0) return install_dir;
    }

    if (b.graph.environ_map.get("HOME")) |home| {
        if (home.len > 0) return b.pathJoin(&.{ home, ".local", "bin" });
    }
    if (b.graph.environ_map.get("USERPROFILE")) |home| {
        if (home.len > 0) return b.pathJoin(&.{ home, ".local", "bin" });
    }

    @panic("unable to determine install directory: set HOME, USERPROFILE, or INSTALL_DIR");
}

const InstallReleaseStep = struct {
    step: std.Build.Step,
    source: std.Build.LazyPath,
    dest_dir: []const u8,
    dest_name: []const u8,

    fn create(
        b: *std.Build,
        source: std.Build.LazyPath,
        dest_dir: []const u8,
        dest_name: []const u8,
    ) *InstallReleaseStep {
        const self = b.allocator.create(InstallReleaseStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("install {s} to {s}", .{ dest_name, dest_dir }),
                .owner = b,
                .makeFn = make,
            }),
            .source = source.dupe(b),
            .dest_dir = b.dupePath(dest_dir),
            .dest_name = b.dupePath(dest_name),
        };
        source.addStepDependencies(&self.step);
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const b = step.owner;
        const self: *InstallReleaseStep = @fieldParentPtr("step", step);
        const dest_path = b.pathResolve(&.{ self.dest_dir, self.dest_name });
        const p = try step.installFile(self.source, dest_path);
        step.result_cached = p == .fresh;
    }
};
