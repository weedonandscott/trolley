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

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Platform-appropriate getenv. Returns the value or null.
pub fn getenvZ(name: [*:0]const u8) ?[*:0]const u8 {
    if (comptime builtin.os.tag == .windows) {
        return getenv(name);
    } else {
        const val = std.posix.getenv(std.mem.span(name)) orelse return null;
        return val.ptr;
    }
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
