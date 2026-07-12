//! Build graph for `mana`. This function mutates the build graph; it does not
//! build directly. It wires the enforced module import DAG:
//!   core → (nothing above)
//!   data, ecs, gpu, platform, physics, script → core
//!   engine → core + data + ecs + gpu + platform + physics + script
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
    const enable_lua = b.option(
        bool,
        "enable-lua",
        "Compile the Lua 5.4 scripting backend (ziglua/zlua)",
    ) orelse false;
    const enable_tracy = b.option(
        bool,
        "enable-tracy",
        "Compile the Tracy profiler client (ztracy) — zones/plots/alloc tracking",
    ) orelse false;

    const options = b.addOptions();
    options.addOption(bool, "enable_vulkan", enable_vulkan);
    options.addOption(bool, "enable_sdl3", enable_sdl3);
    options.addOption(bool, "enable_lua", enable_lua);
    options.addOption(bool, "enable_tracy", enable_tracy);
    const build_options = options.createModule();

    // --- Module DAG ---------------------------------------------------------
    const core = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    // `core` reads `build_options` for the comptime Tracy flag (ADR 0023). This is a
    // build-time constant module, not a DAG dependency, so "core imports only std"
    // holds in spirit — the same exception gpu/platform/script already rely on.
    core.addImport("build_options", build_options);

    // The Tracy profiler client (zig-gamedev/ztracy, module `root`, artifact
    // `tracy`) is wired into `core` only under `-Denable-tracy`. The dep is lazy:
    // `lazyDependency` is called only under the flag, so the default/CI build never
    // *compiles* the Tracy C++ client. `core.tracy` (`src/core/tracy.zig`) imports
    // `ztracy` inside a comptime-true branch, so a default build never resolves it,
    // and links the static `tracy` artifact — which propagates transitively to every
    // artifact that imports `core` (exe + all test binaries). `.enable_ztracy = true`
    // turns on the markers inside the vendored client.
    if (enable_tracy) {
        if (b.lazyDependency("ztracy", .{
            .target = target,
            .optimize = optimize,
            .enable_ztracy = true,
        })) |ztracy| {
            core.addImport("ztracy", ztracy.module("root"));
            core.linkLibrary(ztracy.artifact("tracy"));
        }
    }

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
    // are lazy: `lazyDependency` is called only under the flag, so the default/CI
    // build never *compiles* them. (`.lazy` defers compilation, not the source
    // fetch — zig still fetches the tarball into zig-pkg/ on a plain build.)
    if (enable_vulkan) {
        if (b.lazyDependency("vulkan_headers", .{})) |vk_headers| {
            const registry = vk_headers.path("registry/vk.xml");
            if (b.lazyDependency("vulkan_zig", .{ .registry = registry })) |vulkan_zig| {
                gpu.addImport("vulkan", vulkan_zig.module("vulkan-zig"));
            }
        }
    }

    // When BOTH the Vulkan backend and the SDL3 adapter are enabled, link the SDL3
    // artifact into the `gpu` module too: the Vulkan backend calls
    // `SDL_Vulkan_CreateSurface` (declared as C externs in the backend, NOT a
    // `platform` import) to turn the window's opaque handle into a `VkSurfaceKHR`
    // (ADR 0012, "Vulkan surface creation"). This is a build-level *link*, not a module
    // import, so the DAG (`gpu → core`, never `gpu → platform`) is unchanged, and SDL +
    // Vulkan stay out of the default/CI build. `lazyDependency` returns the same `sdl`
    // dep the platform block uses; libc is required for the C symbols.
    if (enable_vulkan and enable_sdl3) {
        if (b.lazyDependency("sdl", .{ .target = target, .optimize = optimize })) |sdl| {
            gpu.link_libc = true;
            gpu.linkLibrary(sdl.artifact("SDL3"));
        }
    }

    const platform = b.createModule(.{
        .root_source_file = b.path("src/platform/platform.zig"),
        .target = target,
        .optimize = optimize,
    });
    platform.addImport("core", core);
    platform.addImport("build_options", build_options);

    // The SDL3 adapter and its dependency (castholm/SDL, artifact `SDL3`, built from
    // source) are only wired in when enabled. The dep is lazy: `lazyDependency` is
    // called only under the flag, so the default/CI build never *compiles* it. (`.lazy`
    // defers compilation, not the source fetch — zig still fetches the tarball into
    // zig-pkg/ on a plain build.) Linking the artifact propagates its installed
    // `SDL3/*.h` headers, so the adapter's `@cInclude("SDL3/SDL.h")` resolves; libc is
    // required for the C import. Nothing here imports gpu/vulkan — the port stays
    // decoupled and Vulkan never leaks upward (CLAUDE.md #4).
    if (enable_sdl3) {
        if (b.lazyDependency("sdl", .{ .target = target, .optimize = optimize })) |sdl| {
            platform.link_libc = true;
            platform.linkLibrary(sdl.artifact("SDL3"));
        }
    }

    const physics = b.createModule(.{
        .root_source_file = b.path("src/physics/physics.zig"),
        .target = target,
        .optimize = optimize,
    });
    physics.addImport("core", core);

    const script = b.createModule(.{
        .root_source_file = b.path("src/script/script.zig"),
        .target = target,
        .optimize = optimize,
    });
    script.addImport("core", core);
    script.addImport("build_options", build_options);

    // The Lua backend and its bindings (ziglua/zlua, module name `zlua`) are only
    // wired in when enabled. The dep is lazy: `lazyDependency` is called only under
    // the flag, so the default/CI build never *compiles* it. (`.lazy` defers
    // compilation, not the source fetch — zig still fetches the tarball into
    // zig-pkg/ on a plain build.) `.lang = .lua54` selects Lua 5.4 (zlua vendors it).
    // We keep a handle to the `zlua` module so the tests section can add a dedicated
    // test rooted at the Lua backend file (its tests would otherwise not be pulled
    // into the script module's test binary — see the tests section).
    var zlua_module: ?*std.Build.Module = null;
    if (enable_lua) {
        if (b.lazyDependency("zlua", .{
            .target = target,
            .optimize = optimize,
            .lang = .lua54,
        })) |zlua| {
            const m = zlua.module("zlua");
            script.addImport("zlua", m);
            zlua_module = m;
        }
    }

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
    engine.addImport("physics", physics);
    // Scripting (ADR 0003, accepted): the engine dispatches Sim events to a
    // Lua handler table. `script` compiles as a stub without `-Denable-lua`, so
    // this import adds no Lua to a default build — the dispatch path is a
    // comptime no-op there (see `src/engine/script_runtime.zig`).
    engine.addImport("script", script);

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
    const tested = [_]*std.Build.Module{ core, data, ecs, gpu, platform, physics, script, engine };
    for (tested) |m| {
        const unit = b.addTest(.{ .root_module = m });
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // Lua backend tests (gated to `-Denable-lua`). `script.zig` imports `lua.zig`
    // only inside a comptime-false branch by default, and in test mode Zig does not
    // analyze that unreferenced decl — so `lua.zig`'s tests never enter the `script`
    // test binary. We compile them explicitly here as their own unit, rooted at
    // `lua.zig` with the `zlua` import, so `zig build -Denable-lua test` runs them.
    if (zlua_module) |zlua| {
        const lua_mod = b.createModule(.{
            .root_source_file = b.path("src/script/lua.zig"),
            .target = target,
            .optimize = optimize,
        });
        lua_mod.addImport("zlua", zlua);
        lua_mod.addImport("core", core); // host.zig (ADR 0015) uses core.Vec3
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = lua_mod })).step);
    }

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
