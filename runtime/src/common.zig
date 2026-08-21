const std = @import("std");
const builtin = @import("builtin");

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
/// failure prints to stderr. The result is leaked because it lives as long as
/// the launcher does.
pub fn collectOpenPaths(alloc: std.mem.Allocator, args: []const []const u8) ?[:0]const u8 {
    if (args.len == 0) return null;

    const cwd = std.process.getCwdAlloc(alloc) catch |err| {
        std.debug.print("trolley: cannot resolve open paths, getcwd failed: {s}\n", .{@errorName(err)});
        return null;
    };
    defer alloc.free(cwd);

    const absolute = alloc.alloc([]const u8, args.len) catch |err| {
        std.debug.print("trolley: cannot resolve open paths: {s}\n", .{@errorName(err)});
        return null;
    };
    defer alloc.free(absolute);

    var resolved: usize = 0;
    defer {
        for (absolute[0..resolved]) |path| alloc.free(path);
    }

    for (args) |arg| {
        // An empty argument resolves to the CWD, which is a directory, not a
        // file the user asked to open.
        if (arg.len == 0) continue;
        // Drop just this path rather than the whole set: the other arguments
        // are still openable.
        absolute[resolved] = std.fs.path.resolve(alloc, &.{ cwd, arg }) catch |err| {
            std.debug.print("trolley: skipping open path \"{s}\": {s}\n", .{ arg, @errorName(err) });
            continue;
        };
        resolved += 1;
    }
    if (resolved == 0) return null;

    return std.mem.joinZ(alloc, "\n", absolute[0..resolved]) catch |err| {
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
