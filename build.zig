const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = addWhereizExecutable(b, target, optimize);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const whereiz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/whereiz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_whereiz_tests = b.addRunArtifact(whereiz_tests);

    const registry_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/registry.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_registry_tests = b.addRunArtifact(registry_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_whereiz_tests.step);
    test_step.dependOn(&run_registry_tests.step);

    const release_exe = addWhereizExecutable(b, target, .ReleaseSmall);
    const install_release_step = b.step("install-release", "Build ReleaseSmall and install to the docs install directory");
    const installer = b.addExecutable(.{
        .name = "install_release",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/install_release.zig"),
            .target = b.graph.host,
        }),
    });
    const install_release = b.addRunArtifact(installer);
    install_release.setName(b.fmt("install {s}", .{release_exe.out_filename}));
    install_release.has_side_effects = true;
    install_release.addFileArg(release_exe.getEmittedBin());
    install_release.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix } }, .{ .make_absolute = true });
    install_release.addDirectoryArg2(b.path("zig-out"), .{ .make_absolute = true });
    install_release.addArg(release_exe.out_filename);
    install_release_step.dependOn(&install_release.step);
}

fn addWhereizExecutable(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "whereiz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
}
