const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main library target (this is the correct way for Zig libraries)
    const lib = b.addStaticLibrary(.{
        .name = "zsqlite",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.linkSystemLibrary("sqlite3");
    lib.linkLibC();
    b.installArtifact(lib);

    // CLI executable (separate from library)
    const cli_exe = b.addExecutable(.{
        .name = "zsl",
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_exe.linkSystemLibrary("sqlite3");
    cli_exe.linkLibC();
    b.installArtifact(cli_exe);

    // Demo executable (shows how to use the library)
    const demo_exe = b.addExecutable(.{
        .name = "zsqlite-demo",
        .root_source_file = b.path("examples/demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_exe.root_module.addImport("zsqlite", lib.root_module);
    demo_exe.linkSystemLibrary("sqlite3");
    demo_exe.linkLibC();
    b.installArtifact(demo_exe);

    // Unit tests (test the library)
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_unit_tests.linkSystemLibrary("sqlite3");
    lib_unit_tests.linkLibC();

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(lib_unit_tests).step);

    // Run steps
    const run_cli = b.addRunArtifact(cli_exe);
    const run_demo = b.addRunArtifact(demo_exe);

    const cli_step = b.step("cli", "Run the ZSQLite CLI (zsl)");
    cli_step.dependOn(&run_cli.step);

    const demo_step = b.step("demo", "Run the ZSQLite demo");
    demo_step.dependOn(&run_demo.step);

    // Default run step runs demo
    const run_step = b.step("run", "Run the demo");
    run_step.dependOn(&run_demo.step);
}
