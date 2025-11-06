const std = @import("std");

const Module = std.Build.Module;
const ResolvedTarget = std.Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const NAME = "prompt";
    const suffix = switch (optimize) {
        .Debug => "-dbg",
        .ReleaseFast => "",
        .ReleaseSafe => "-s",
        .ReleaseSmall => "-sm",
    };

    var name_buf: [NAME.len + 4]u8 = undefined;
    const bin_name = std.fmt.bufPrint(@constCast(&name_buf), "{s}{s}", .{ NAME, suffix }) catch unreachable;

    const deps = .{"zut"};

    const lib_module = b.addModule(NAME, .{ .root_source_file = b.path("src/" ++ NAME ++ ".zig") });
    addDependencies(b, lib_module, target, optimize, deps);

    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addDependencies(b, main_module, target, optimize, deps);
    main_module.addImport(NAME, lib_module);

    const tests = addBuild(b, main_module, bin_name, .tests);
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run tests").dependOn(&run_tests.step);

    const exe = addBuild(b, main_module, bin_name, .exe);
    b.installArtifact(exe);

    const check = addBuild(b, main_module, bin_name, .exe);
    const check_step = b.step("check", "Build for LSP Diagnostics");
    check_step.dependOn(&check.step);
    check_step.dependOn(&b.addTest(.{ .root_module = main_module }).step);
}

fn addBuild(
    b: *std.Build,
    main_module: *std.Build.Module,
    bin_name: []const u8,
    kind: enum { tests, exe },
) *std.Build.Step.Compile {
    const exe = if (kind == .tests)
        b.addTest(.{ .name = bin_name, .root_module = main_module })
    else
        b.addExecutable(.{ .name = bin_name, .root_module = main_module });

    return exe;
}

fn addDependencies(b: *std.Build, module: *Module, target: ResolvedTarget, optimize: OptimizeMode, deps: anytype) void {
    inline for (deps) |name| {
        const dep = b.dependency(name, .{ .target = target, .optimize = optimize });
        module.addImport(name, dep.module(name));
    }
}
