//! Build graph for `mana`. This function mutates the build graph; it does not
//! build directly. It wires the enforced module import DAG:
//!   core → (nothing above)
//!   data, ecs, gpu, platform, script → core
//!   engine → core + data + ecs + gpu + platform
//!   runtime (exe) → engine
//! Backend/adapter selection for the `gpu` and `platform` ports happens here at
//! comptime via build options; both default to their stub/null adapter.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Comptime port-adapter selection. Both real backends are deferred, so these
    // default to false and the ports compile their null/headless adapter.
    const enable_vulkan = b.option(
        bool,
        "enable-vulkan",
        "Compile the Vulkan gpu backend (deferred — not yet implemented)",
    ) orelse false;
    const enable_sdl3 = b.option(
        bool,
        "enable-sdl3",
        "Compile the SDL3 platform adapter (deferred — not yet implemented)",
    ) orelse false;

    const options = b.addOptions();
    options.addOption(bool, "enable_vulkan", enable_vulkan);
    options.addOption(bool, "enable_sdl3", enable_sdl3);
    const build_options = options.createModule();

    // --- Module DAG ---------------------------------------------------------
    const core = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
    });

    const data = b.createModule(.{
        .root_source_file = b.path("src/data/data.zig"),
        .target = target,
        .optimize = optimize,
    });
    data.addImport("core", core);

    const ecs = b.createModule(.{
        .root_source_file = b.path("src/ecs/ecs.zig"),
        .target = target,
        .optimize = optimize,
    });
    ecs.addImport("core", core);

    const gpu = b.createModule(.{
        .root_source_file = b.path("src/gpu/gpu.zig"),
        .target = target,
        .optimize = optimize,
    });
    gpu.addImport("core", core);
    gpu.addImport("build_options", build_options);

    // The Vulkan backend and its bindings are only wired in when enabled. The deps
    // are lazy, so the default/CI build neither fetches nor compiles them.
    if (enable_vulkan) {
        if (b.lazyDependency("vulkan_headers", .{})) |vk_headers| {
            const registry = vk_headers.path("registry/vk.xml");
            if (b.lazyDependency("vulkan_zig", .{ .registry = registry })) |vulkan_zig| {
                gpu.addImport("vulkan", vulkan_zig.module("vulkan-zig"));
            }
        }
    }

    const platform = b.createModule(.{
        .root_source_file = b.path("src/platform/platform.zig"),
        .target = target,
        .optimize = optimize,
    });
    platform.addImport("core", core);
    platform.addImport("build_options", build_options);

    const script = b.createModule(.{
        .root_source_file = b.path("src/script/script.zig"),
        .target = target,
        .optimize = optimize,
    });
    script.addImport("core", core);

    const engine = b.createModule(.{
        .root_source_file = b.path("src/engine/engine.zig"),
        .target = target,
        .optimize = optimize,
    });
    engine.addImport("core", core);
    engine.addImport("data", data);
    engine.addImport("ecs", ecs);
    engine.addImport("gpu", gpu);
    engine.addImport("platform", platform);

    // --- Runner executable --------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "mana",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "engine", .module = engine },
                .{ .name = "core", .module = core },
                .{ .name = "data", .module = data },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the mana runtime (headless)");
    run_step.dependOn(&run_cmd.step);

    // --- Tests --------------------------------------------------------------
    // Zig tests one module (compilation unit) at a time, so we add a test run
    // per module. Each module's root file pulls in its sibling files' tests.
    const test_step = b.step("test", "Run all unit + integration tests");
    const tested = [_]*std.Build.Module{ core, data, ecs, gpu, platform, script, engine };
    for (tested) |m| {
        const unit = b.addTest(.{ .root_module = m });
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // Integration tests (tests/) — headless engine runs, determinism, hot reload.
    // These may reference the game corpus and fixtures; nothing in src/** may.
    const integration_imports = [_]std.Build.Module.Import{
        .{ .name = "core", .module = core },
        .{ .name = "data", .module = data },
        .{ .name = "engine", .module = engine },
    };
    for ([_][]const u8{ "tests/determinism.zig", "tests/hot_reload.zig" }) |path| {
        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &integration_imports,
        });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    }
}
