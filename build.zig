const std = @import("std");

const C_SOURCES = [_][]const u8{
    "sokol_log.c",
    "sokol_app.c",
    "sokol_gfx.c",
    "sokol_time.c",
    "sokol_audio.c",
    "sokol_gl.c",
    "sokol_debugtext.c",
    "sokol_shape.c",
    "sokol_glue.c",
    "sokol_fetch.c",
    "sokol_imgui.c",
};

const CPP_SOURCES = [_][]const u8{
    "third_party/cimgui/cimgui.cpp",
    "third_party/cimgui/imgui/imgui.cpp",
    "third_party/cimgui/imgui/imgui_demo.cpp",
    "third_party/cimgui/imgui/imgui_draw.cpp",
    "third_party/cimgui/imgui/imgui_tables.cpp",
    "third_party/cimgui/imgui/imgui_widgets.cpp",
};

const Backend = enum {
    metal,
    gl,
    d3d11,
    gles3,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const emsdk_root_opt = b.option(
        []const u8,
        "emsdk",
        "Path to emsdk root (required for `zig build web`)",
    );

    const mod_sokol_native = b.createModule(.{
        .root_source_file = b.path("third_party/sokol/sokol.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib_sokol_native = buildLibSokol(b, "sokol_clib_native", target, optimize, null);
    const native_module = createAppModule(b, target, optimize, mod_sokol_native, null);
    native_module.linkLibrary(lib_sokol_native);

    const exe = b.addExecutable(.{
        .name = "zequence",
        .root_module = native_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.setCwd(b.path("."));
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    b.step("run", "Run native build").dependOn(&run_cmd.step);

    const web_step = b.step("web", "Build browser bundle in zig-out/web (requires emsdk + emcc)");
    if (emsdk_root_opt) |emsdk_root| {
        const web_target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .emscripten,
        });

        const mod_sokol_web = b.createModule(.{
            .root_source_file = b.path("third_party/sokol/sokol.zig"),
            .target = web_target,
            .optimize = optimize,
        });
        const lib_sokol_web = buildLibSokol(
            b,
            "sokol_clib_web",
            web_target,
            optimize,
            emsdk_root,
        );
        const web_module = createAppModule(b, web_target, optimize, mod_sokol_web, emsdk_root);
        web_module.linkLibrary(lib_sokol_web);

        const web_lib = b.addLibrary(.{
            .name = "zequence_web",
            .root_module = web_module,
        });

        const web_install = makeWebLinkStep(b, .{
            .name = "zequence",
            .optimize = optimize,
            .lib_main = web_lib,
            .emsdk_root = emsdk_root,
        });
        web_step.dependOn(&web_install.step);
    } else {
        web_step.dependOn(&b.addFail("`zig build web` requires `-Demsdk=/path/to/emsdk`").step);
    }
}

fn createAppModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mod_sokol: *std.Build.Module,
    emsdk_root: ?[]const u8,
) *std.Build.Module {
    const cflags: []const []const u8 = if (target.result.os.tag == .emscripten)
        &.{ "-std=c++17", "-fno-sanitize=undefined" }
    else
        &.{"-std=c++17"};

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "sokol", .module = mod_sokol },
        },
    });
    mod.addIncludePath(b.path("third_party/cimgui"));
    mod.addIncludePath(b.path("third_party/cimgui/imgui"));

    inline for (CPP_SOURCES) |src| {
        mod.addCSourceFile(.{
            .file = b.path(src),
            .flags = cflags,
        });
    }

    if (target.result.os.tag == .emscripten) {
        if (emsdk_root) |root| {
            mod.addSystemIncludePath(.{
                .cwd_relative = b.pathJoin(&.{ root, "upstream", "emscripten", "cache", "sysroot", "include" }),
            });
        }
    }
    return mod;
}

fn buildLibSokol(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    emsdk_root: ?[]const u8,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const lib = b.addLibrary(.{
        .name = name,
        .root_module = mod,
    });

    const backend = resolveBackend(target.result);

    var cflags_buf: [12][]const u8 = undefined;
    var cflags = std.ArrayListUnmanaged([]const u8).initBuffer(&cflags_buf);
    cflags.appendAssumeCapacity("-DIMPL");
    cflags.appendAssumeCapacity(backendDefine(backend));

    if (optimize != .Debug) {
        cflags.appendAssumeCapacity("-DNDEBUG");
    }
    if (target.result.os.tag.isDarwin()) {
        cflags.appendAssumeCapacity("-ObjC");
    }
    if (target.result.os.tag == .emscripten) {
        cflags.appendAssumeCapacity("-fno-sanitize=undefined");
        if (emsdk_root) |root| {
            mod.addSystemIncludePath(.{
                .cwd_relative = b.pathJoin(&.{ root, "upstream", "emscripten", "cache", "sysroot", "include" }),
            });
        }
    }

    mod.addIncludePath(b.path("third_party/sokol/c"));
    mod.addIncludePath(b.path("third_party/cimgui"));

    inline for (C_SOURCES) |src| {
        mod.addCSourceFile(.{
            .file = b.path("third_party/sokol/c/" ++ src),
            .flags = cflags.items,
        });
    }

    linkSystemLibs(mod, target.result, backend);
    return lib;
}

fn resolveBackend(target: std.Target) Backend {
    if (target.os.tag.isDarwin()) return .metal;
    if (target.os.tag == .windows) return .d3d11;
    if (target.os.tag == .emscripten) return .gles3;
    return .gl;
}

fn backendDefine(backend: Backend) []const u8 {
    return switch (backend) {
        .metal => "-DSOKOL_METAL",
        .gl => "-DSOKOL_GLCORE",
        .d3d11 => "-DSOKOL_D3D11",
        .gles3 => "-DSOKOL_GLES3",
    };
}

fn linkSystemLibs(mod: *std.Build.Module, target: std.Target, backend: Backend) void {
    if (target.os.tag.isDarwin()) {
        mod.linkFramework("Foundation", .{});
        mod.linkFramework("AudioToolbox", .{});
        mod.linkFramework("Cocoa", .{});
        mod.linkFramework("QuartzCore", .{});
        switch (backend) {
            .metal => mod.linkFramework("Metal", .{}),
            .gl => mod.linkFramework("OpenGL", .{}),
            else => {},
        }
        mod.linkSystemLibrary("c++", .{});
    } else if (target.os.tag == .linux) {
        mod.linkSystemLibrary("asound", .{});
        mod.linkSystemLibrary("GL", .{});
        mod.linkSystemLibrary("X11", .{});
        mod.linkSystemLibrary("Xi", .{});
        mod.linkSystemLibrary("Xcursor", .{});
        mod.linkSystemLibrary("stdc++", .{});
    } else if (target.os.tag == .windows) {
        mod.linkSystemLibrary("kernel32", .{});
        mod.linkSystemLibrary("user32", .{});
        mod.linkSystemLibrary("gdi32", .{});
        mod.linkSystemLibrary("ole32", .{});
        mod.linkSystemLibrary("d3d11", .{});
        mod.linkSystemLibrary("dxgi", .{});
    }
}

const WebLinkOptions = struct {
    name: []const u8,
    optimize: std.builtin.OptimizeMode,
    lib_main: *std.Build.Step.Compile,
    emsdk_root: []const u8,
};

fn makeWebLinkStep(b: *std.Build, options: WebLinkOptions) *std.Build.Step.InstallDir {
    const emcc_py = b.pathJoin(&.{ options.emsdk_root, "upstream", "emscripten", "emcc.py" });
    const emsdk_python = findEmsdkPython(b, options.emsdk_root);
    const emcc = b.addSystemCommand(&.{ emsdk_python, emcc_py });
    emcc.setName("emcc");
    emcc.setEnvironmentVariable("EMSDK", options.emsdk_root);
    emcc.setEnvironmentVariable("EMSDK_PYTHON", emsdk_python);

    if (options.optimize == .Debug) {
        emcc.addArgs(&.{ "-Og", "-sSAFE_HEAP=1", "-sSTACK_OVERFLOW_CHECK=1" });
    } else {
        emcc.addArgs(&.{ "-O3", "-sASSERTIONS=0", "-flto" });
    }

    emcc.addArgs(&.{
        "-sUSE_WEBGL2=1",
        "-sALLOW_MEMORY_GROWTH=1",
        "-sSTACK_SIZE=2MB",
        "--shell-file",
        "web/shell.html",
    });

    emcc.addArtifactArg(options.lib_main);
    for (options.lib_main.getCompileDependencies(false)) |item| {
        if (item.kind == .lib) {
            emcc.addArtifactArg(item);
        }
    }

    emcc.addArg("-o");
    const out_file = emcc.addOutputFileArg(b.fmt("{s}.html", .{options.name}));

    const install = b.addInstallDirectory(.{
        .source_dir = out_file.dirname(),
        .install_dir = .prefix,
        .install_subdir = "web",
    });
    install.step.dependOn(&emcc.step);
    return install;
}

fn findEmsdkPython(b: *std.Build, emsdk_root: []const u8) []const u8 {
    const python_root = b.pathJoin(&.{ emsdk_root, "python" });
    var dir = std.fs.cwd().openDir(python_root, .{ .iterate = true }) catch {
        return b.pathJoin(&.{ emsdk_root, "python", "3.13.3_64bit", "bin", "python3" });
    };
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const candidate = b.pathJoin(&.{ python_root, entry.name, "bin", "python3" });
        if (std.fs.cwd().access(candidate, .{})) {
            return candidate;
        } else |_| {}
    }
    return b.pathJoin(&.{ emsdk_root, "python", "3.13.3_64bit", "bin", "python3" });
}
