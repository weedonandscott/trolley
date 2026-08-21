const std = @import("std");
const builtin = @import("builtin");
const trolley = @cImport(@cInclude("trolley.h"));

/// Get the directory containing the current executable.
/// Caller must free the returned slice.
pub fn getExeDir() ?[]const u8 {
    const self_exe = std.fs.selfExePathAlloc(std.heap.page_allocator) catch return null;
    defer std.heap.page_allocator.free(self_exe);
    const dir = std.fs.path.dirname(self_exe) orelse return null;
    return std.heap.page_allocator.dupe(u8, dir) catch return null;
}

/// Find a bundled file next to the executable.
/// Returns a null-terminated absolute path. Callers should handle open failures
/// rather than relying on the path existing (the file won't disappear at runtime).
pub fn getBundledPath(filename: []const u8) ?[:0]const u8 {
    const dir = getExeDir() orelse return null;
    defer std.heap.page_allocator.free(dir);

    return std.fs.path.joinZ(std.heap.page_allocator, &.{ dir, filename }) catch return null;
}

/// Change the working directory to the directory containing the executable.
/// The bundle directory contains the TUI binary, ghostty.conf, fonts, etc.
/// Ghostty resolves `command = direct:./app` relative to CWD.
pub fn chdirToExeDir() void {
    const dir_path = getExeDir() orelse return;
    defer std.heap.page_allocator.free(dir_path);

    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return;
    defer dir.close();

    dir.setAsCwd() catch {};
}

/// Absolutize launch arguments against the current working directory and join
/// them with newlines, for TROLLEY_OPEN_PATHS. Lexical only — no existence
/// check, no symlink canonicalization. Must run before chdirToExeDir.
/// Returns null when there is nothing to open or when collection fails; every
/// failure prints to stderr. The caller passes an arena that lives as long as
/// the process; nothing is freed.
pub fn collectOpenPaths(arena: std.mem.Allocator, args: []const []const u8) ?[:0]const u8 {
    if (args.len == 0) return null;

    const cwd = std.process.getCwdAlloc(arena) catch |err| {
        std.debug.print("trolley: cannot resolve open paths, getcwd failed: {s}\n", .{@errorName(err)});
        return null;
    };

    const absolute = arena.alloc([]const u8, args.len) catch |err| {
        std.debug.print("trolley: cannot resolve open paths: {s}\n", .{@errorName(err)});
        return null;
    };

    var resolved: usize = 0;
    for (args) |arg| {
        // An empty argument resolves to the CWD, which is a directory, not a
        // file the user asked to open.
        if (arg.len == 0) continue;
        // Drop just this path rather than the whole set: the other arguments
        // are still openable.
        absolute[resolved] = std.fs.path.resolve(arena, &.{ cwd, arg }) catch |err| {
            std.debug.print("trolley: skipping open path \"{s}\": {s}\n", .{ arg, @errorName(err) });
            continue;
        };
        resolved += 1;
    }
    if (resolved == 0) return null;

    return std.mem.joinZ(arena, "\n", absolute[0..resolved]) catch |err| {
        std.debug.print("trolley: cannot resolve open paths: {s}\n", .{@errorName(err)});
        return null;
    };
}

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// Platform-appropriate setenv. Returns true on success.
pub fn setenvZ(name: [*:0]const u8, value: [*:0]const u8) bool {
    if (comptime builtin.os.tag == .windows) {
        return _putenv_s(name, value) == 0;
    } else {
        return setenv(name, value, 1) == 0;
    }
}
extern "c" fn _putenv_s(name: [*:0]const u8, value: [*:0]const u8) c_int;

extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) c_int;

/// Remove a variable from the environment ghostty copies into the TUI: the
/// libc environ on POSIX, the process environment block on Windows.
pub fn unsetenvZ(name: [:0]const u8) bool {
    if (comptime builtin.os.tag == .windows) {
        const wide = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, name) catch return false;
        defer std.heap.page_allocator.free(wide);
        return SetEnvironmentVariableW(wide, null) != 0;
    } else {
        return unsetenv(name) == 0;
    }
}

/// Set by the runtime to the files the app was opened with; the name comes from
/// the config crate, shared with the packager and the macOS runtime.
pub fn openPathsVar() [:0]const u8 {
    return std.mem.span(trolley.trolley_open_paths_var());
}

/// The TUI inherits the runtime's environment, so a value inherited from a
/// parent launch would otherwise reach it as if this launch had been given paths.
pub fn clearInheritedOpenPaths() void {
    _ = unsetenvZ(openPathsVar());
}

test "clearInheritedOpenPaths hides the variable from getEnvMap" {
    try std.testing.expect(setenvZ(openPathsVar().ptr, "/inherited/path"));
    {
        var env = try std.process.getEnvMap(std.testing.allocator);
        defer env.deinit();
        try std.testing.expectEqualStrings("/inherited/path", env.get(openPathsVar()).?);
    }

    clearInheritedOpenPaths();

    var env = try std.process.getEnvMap(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(env.get(openPathsVar()) == null);
}

/// Read the bundled `environment` file and call setenv for each KEY=VALUE line.
/// Skips blank lines and lines starting with `#`.
/// Must be called before ghostty_init so the child process inherits them.
pub fn loadBundledEnvironment() void {
    const path = getBundledPath("environment") orelse return;
    defer std.heap.page_allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    const contents = file.readToEndAlloc(std.heap.page_allocator, 1024 * 1024) catch return;
    defer std.heap.page_allocator.free(contents);

    var iter = std.mem.splitScalar(u8, contents, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
            const key = std.mem.trim(u8, trimmed[0..eq], " \t");
            if (key.len == 0) continue;
            const value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");

            // Null-terminate key and value for the C API
            const key_z = std.heap.page_allocator.dupeZ(u8, key) catch continue;
            defer std.heap.page_allocator.free(key_z);
            const value_z = std.heap.page_allocator.dupeZ(u8, value) catch continue;
            defer std.heap.page_allocator.free(value_z);

            _ = setenvZ(key_z, value_z);
        }
    }
}
