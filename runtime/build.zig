const std = @import("std");

const Renderer = enum { opengl, metal };

const FontBackend = enum { freetype, fontconfig_freetype, coretext };

const Platform = struct {
    root_source_file: ?std.Build.LazyPath,
    renderer: Renderer,
    font_backend: FontBackend,
    system_libs: []const []const u8,
    lib_only: bool,

    fn fromOS(os: std.Target.Os.Tag, b: *std.Build) Platform {
        return switch (os) {
            .linux => .{
                .root_source_file = b.path("src/platform/linux.zig"),
                .renderer = .opengl,
                .font_backend = .fontconfig_freetype,
                .system_libs = &.{},
                .lib_only = false,
            },
            .windows => .{
                .root_source_file = b.path("src/platform/windows.zig"),
                .renderer = .opengl,
                .font_backend = .fontconfig_freetype,
                .system_libs = &.{ "opengl32", "gdi32", "user32", "mswsock", "userenv", "ws2_32", "ntdll", "winmm" },
                .lib_only = false,
            },
            .macos => .{
                .root_source_file = null,
                .renderer = .metal,
                .font_backend = .coretext,
                .system_libs = &.{},
                .lib_only = true,
            },
            else => @panic("unsupported target OS"),
        };
    }
};

/// Find a named artifact from a dependency, filtering by target to avoid
/// ambiguity when the dependency installs multiple artifacts with the same
/// name (e.g. ghostty installs one per XCFramework target on macOS).
fn findArtifact(
    dep: *std.Build.Dependency,
    name: []const u8,
    target: std.Build.ResolvedTarget,
) *std.Build.Step.Compile {
    for (dep.builder.install_tls.step.dependencies.items) |dep_step| {
        const inst = dep_step.cast(std.Build.Step.InstallArtifact) orelse continue;
        if (!std.mem.eql(u8, inst.artifact.name, name)) continue;
        const art_target = inst.artifact.rootModuleTarget();
        if (art_target.cpu.arch == target.result.cpu.arch and
            art_target.os.tag == target.result.os.tag)
        {
            return inst.artifact;
        }
    }
    @panic("unable to find artifact");
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;
    const platform = Platform.fromOS(os, b);

    // Build libghostty with platform-appropriate renderer.
    const ghostty_dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"app-runtime" = .none,
        .renderer = platform.renderer,
        .@"font-backend" = platform.font_backend,
        .sentry = false,
        .i18n = false,
    });

    // On macOS, ghostty's build creates multiple artifacts named "ghostty"
    // (one per XCFramework target), so we disambiguate by matching our target.
    // On other platforms there's only one, but findArtifact works either way.
    const ghostty_lib = findArtifact(ghostty_dep, "ghostty", target);

    // Pre-built Rust staticlib for manifest/config parsing.
    // Built by `cargo build` in ../config before zig build runs (see justfile).
    const config_lib_path = b.option(
        []const u8,
        "config-lib",
        "Path to the pre-built libtrolley_config.a",
    );

    if (platform.lib_only) {
        // macOS: the Swift build links a single libghostty.a, so we need a
        // fat archive that bundles ghostty + all its deps (freetype, spirv-cross,
        // etc.).  This is the same approach as GhosttyLib.initStatic: walk the
        // module graph to collect every linked .a, then merge with libtool.
        var lib_sources: std.ArrayListUnmanaged(std.Build.LazyPath) = .empty;
        for (ghostty_lib.root_module.getGraph().modules) |mod| {
            for (mod.link_objects.items) |lo| {
                switch (lo) {
                    .other_step => |step| lib_sources.append(b.allocator, step.getEmittedBin()) catch @panic("OOM"),
                    else => {},
                }
            }
        }
        lib_sources.append(b.allocator, ghostty_lib.getEmittedBin()) catch @panic("OOM");

        const libtool = std.Build.Step.Run.create(b, "libtool ghostty-fat");
        libtool.addArgs(&.{ "libtool", "-static", "-o" });
        const fat_lib = libtool.addOutputFileArg("libghostty.a");
        for (lib_sources.items) |source| libtool.addFileArg(source);
        libtool.step.dependOn(&ghostty_lib.step);

        const install_lib = b.addInstallLibFile(fat_lib, "libghostty.a");
        b.getInstallStep().dependOn(&install_lib.step);
        return;
    }

    // Zig-based platforms: build the trolley executable.
    const run_step = b.step("run", "Run the app");
    const test_step = b.step("test", "Run unit tests");

    const exe_mod = b.createModule(.{
        .root_source_file = platform.root_source_file.?,
        .target = target,
        .optimize = optimize,
    });
    exe_mod.link_libc = true;
    exe_mod.link_libcpp = true;

    for (platform.system_libs) |lib| {
        exe_mod.linkSystemLibrary(lib, .{});
    }

    // Build GLFW from source on Linux so the binary has no libglfw.so.3
    // runtime dependency.  GLFW 3.4 loads X11/Wayland/GL via dlopen.
    if (os == .linux) {
        if (b.lazyDependency("glfw", .{})) |glfw_dep| {
            const glfw_src = glfw_dep.path("src");
            const glfw_include = glfw_dep.path("include");
            const glfw_deps = glfw_dep.path("deps/wayland");

            exe_mod.addIncludePath(glfw_include);
            exe_mod.addIncludePath(glfw_src);

            // X11 headers needed for GLFW compilation (types/structs only;
            // GLFW 3.4 loads libX11 etc. via dlopen so --as-needed means no
            // NEEDED entry in the binary).
            exe_mod.linkSystemLibrary("x11", .{});
            exe_mod.linkSystemLibrary("xrandr", .{});
            exe_mod.linkSystemLibrary("xrender", .{});
            exe_mod.linkSystemLibrary("xfixes", .{});
            exe_mod.linkSystemLibrary("xinerama", .{});
            exe_mod.linkSystemLibrary("xcursor", .{});
            exe_mod.linkSystemLibrary("xi", .{});
            exe_mod.linkSystemLibrary("xext", .{});

            // Wayland headers needed for GLFW compilation (GLFW loads
            // libwayland-client etc. via dlopen at runtime).
            exe_mod.linkSystemLibrary("wayland-client", .{});
            exe_mod.linkSystemLibrary("xkbcommon", .{});

            // Generate Wayland protocol C bindings from XML via wayland-scanner.
            const wl_protocols = [_][]const u8{
                "wayland",
                "viewporter",
                "xdg-shell",
                "idle-inhibit-unstable-v1",
                "pointer-constraints-unstable-v1",
                "relative-pointer-unstable-v1",
                "fractional-scale-v1",
                "xdg-activation-v1",
                "xdg-decoration-unstable-v1",
            };

            for (wl_protocols) |protocol| {
                const xml_path = glfw_deps.path(b, b.fmt("{s}.xml", .{protocol}));
                // wayland-scanner client-header <xml> <header>
                const header_cmd = b.addSystemCommand(&.{"wayland-scanner"});
                header_cmd.addArg("client-header");
                header_cmd.addFileArg(xml_path);
                const header = header_cmd.addOutputFileArg(b.fmt("{s}-client-protocol.h", .{protocol}));
                // wayland-scanner private-code <xml> <code>
                const code_cmd = b.addSystemCommand(&.{"wayland-scanner"});
                code_cmd.addArg("private-code");
                code_cmd.addFileArg(xml_path);
                const code = code_cmd.addOutputFileArg(b.fmt("{s}-client-protocol-code.h", .{protocol}));
                exe_mod.addIncludePath(header.dirname());
                exe_mod.addIncludePath(code.dirname());
            }

            exe_mod.addCSourceFiles(.{
                .root = glfw_src,
                .files = &.{
                    // Core
                    "context.c",
                    "init.c",
                    "input.c",
                    "monitor.c",
                    "platform.c",
                    "vulkan.c",
                    "window.c",
                    "egl_context.c",
                    "osmesa_context.c",
                    // Null backend (required by platform.c)
                    "null_init.c",
                    "null_monitor.c",
                    "null_window.c",
                    "null_joystick.c",
                    // POSIX
                    "posix_module.c",
                    "posix_time.c",
                    "posix_thread.c",
                    "posix_poll.c",
                    // Linux
                    "linux_joystick.c",
                    // X11
                    "x11_init.c",
                    "x11_monitor.c",
                    "x11_window.c",
                    "xkb_unicode.c",
                    "glx_context.c",
                    // Wayland
                    "wl_init.c",
                    "wl_monitor.c",
                    "wl_window.c",
                },
                .flags = &.{
                    "-D_GLFW_X11",
                    "-D_GLFW_WAYLAND",
                    "-D_DEFAULT_SOURCE",
                    "-std=c99",
                },
            });
        }
    }

    if (os == .windows) {
        if (b.lazyDependency("zigwin32", .{})) |dep| {
            exe_mod.addImport("win32", dep.module("win32"));
        }
    }

    exe_mod.addImport("common", b.createModule(.{
        .root_source_file = b.path("src/common.zig"),
        .target = target,
        .optimize = optimize,
    }));

    exe_mod.addIncludePath(ghostty_dep.path("include"));
    exe_mod.linkLibrary(ghostty_lib);

    // Link the config staticlib (manifest parsing).
    exe_mod.addIncludePath(b.path("../config/include"));
    if (config_lib_path) |lib_path| {
        exe_mod.addObjectFile(.{ .cwd_relative = lib_path });
    }

    const exe = b.addExecutable(.{
        .name = "trolley",
        .root_module = exe_mod,
    });
    // On Windows, use the GUI subsystem so no console window is spawned.
    if (os == .windows) exe.subsystem = .Windows;
    // GLFW loads X11/Wayland/GL via dlopen at runtime — the system libs
    // linked above are only needed for headers, not actual linking.
    // When cross-compiling, the host .so files may reference glibc symbols
    // absent from the target, so allow undefined symbols in shared libs.
    if (os == .linux) exe.linker_allow_shlib_undefined = true;
    b.installArtifact(exe);

    // Run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // Test
    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    test_step.dependOn(&run_exe_unit_tests.step);
}
