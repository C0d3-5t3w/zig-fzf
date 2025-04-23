const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zig_fzf",
        .root_module = exe_mod,
    });

    // Explicitly link with C library for terminal functionality
    exe.linkLibC();

    // On macOS, we might need additional frameworks
    // Access the OS tag via target.result.os.tag in Zig 0.14.0
    if (target.result.os.tag == .macos) {
        // Add system frameworks if needed (though termios is part of libc)
        // exe.linkFramework("CoreFoundation");
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    // Also link C library for tests
    exe_unit_tests.linkLibC();

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    if (b.args) |args| {
        run_exe_unit_tests.addArgs(args);
    }

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    const interactive_test = b.addRunArtifact(exe);
    interactive_test.addArg("--interactive-test");

    const interactive_test_step = b.step("interactive-test", "Run interactive fuzzy finder test");
    interactive_test_step.dependOn(&interactive_test.step);
}
