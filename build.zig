// SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pie = b.option(bool, "pie", "Build with PIE support (by default false)") orelse false;
    const strip = b.option(bool, "strip", "Strip debugging info (by default false)") orelse false;

    const exe = b.addExecutable(.{
        .name = "ncdu",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
    });

    exe.pie = pie;
    exe.root_module.linkSystemLibrary("ncursesw", .{});
    exe.root_module.linkSystemLibrary("libzstd", .{});
    // https://github.com/ziglang/zig/blob/faccd79ca5debbe22fe168193b8de54393257604/build.zig#L745-L748
    if (target.result.os.tag.isDarwin()) {
        // useful for package maintainers
        exe.headerpad_max_install_names = true;
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    unit_tests.pie = pie;
    unit_tests.root_module.linkSystemLibrary("ncursesw", .{});
    unit_tests.root_module.linkSystemLibrary("libzstd", .{});

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
