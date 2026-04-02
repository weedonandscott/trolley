const std = @import("std");
const common = @import("common");
const ghostty = @cImport(@cInclude("ghostty.h"));
const glfw = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", {});
    @cInclude("GLFW/glfw3.h");
});
const trolley = @cImport(@cInclude("trolley.h"));

// Enable all log levels so we can see ghostty's internal logging.
pub const std_options: std.Options = .{
    .log_level = .debug,
};

// ---------------------------------------------------------------------------
// Global state (needed by C callbacks which don't carry user context)
// ---------------------------------------------------------------------------
var g_window: ?*glfw.GLFWwindow = null;
var g_surface: ghostty.ghostty_surface_t = null;
var g_app: ghostty.ghostty_app_t = null;

// Window config from trolley manifest
var g_window_config: trolley.TrolleyGuiConfig = .{
    .initial_width = 0,
    .initial_height = 0,
    .resizable = -1,
    .min_width = 0,
    .min_height = 0,
    .max_width = 0,
    .max_height = 0,
    .inject_pid_variable = null,
};

// ---------------------------------------------------------------------------
// GLFW ↔ ghostty OpenGL context bridge
// ---------------------------------------------------------------------------
fn makeContextCurrent(userdata: ?*anyopaque) callconv(.c) void {
    const win: ?*glfw.GLFWwindow = if (userdata) |ud| @ptrCast(@alignCast(ud)) else null;
    glfw.glfwMakeContextCurrent(win);
    const err = glfw.glfwGetError(null);
    if (err != glfw.GLFW_NO_ERROR) {
        std.debug.print("trolley: makeContextCurrent GLFW error: {d}\n", .{err});
    }
}

fn swapBuffers(userdata: ?*anyopaque) callconv(.c) void {
    const win: *glfw.GLFWwindow = @ptrCast(@alignCast(userdata orelse return));
    glfw.glfwSwapBuffers(win);
}

// ---------------------------------------------------------------------------
// Ghostty runtime callbacks
// ---------------------------------------------------------------------------
fn wakeupCallback(_: ?*anyopaque) callconv(.c) void {
    glfw.glfwPostEmptyEvent();
}

fn actionCallback(
    _: ghostty.ghostty_app_t,
    _: ghostty.ghostty_target_s,
    action: ghostty.ghostty_action_s,
) callconv(.c) bool {
    switch (action.tag) {
        ghostty.GHOSTTY_ACTION_SET_TITLE => {
            const title = action.action.set_title.title;
            if (g_window) |win| {
                glfw.glfwSetWindowTitle(win, title);
            }
            return true;
        },
        ghostty.GHOSTTY_ACTION_QUIT => {
            if (g_window) |win| {
                glfw.glfwSetWindowShouldClose(win, glfw.GLFW_TRUE);
            }
            return true;
        },
        ghostty.GHOSTTY_ACTION_CLOSE_WINDOW => {
            if (g_window) |win| {
                glfw.glfwSetWindowShouldClose(win, glfw.GLFW_TRUE);
            }
            return true;
        },
        ghostty.GHOSTTY_ACTION_SIZE_LIMIT => {
            const limits = action.action.size_limit;
            // Only override if the manifest didn't already set them.
            if (g_window_config.min_width == 0 and limits.min_width > 0)
                g_window_config.min_width = limits.min_width;
            if (g_window_config.min_height == 0 and limits.min_height > 0)
                g_window_config.min_height = limits.min_height;
            if (g_window_config.max_width == 0 and limits.max_width > 0)
                g_window_config.max_width = limits.max_width;
            if (g_window_config.max_height == 0 and limits.max_height > 0)
                g_window_config.max_height = limits.max_height;
            if (g_window) |win| {
                glfw.glfwSetWindowSizeLimits(
                    win,
                    if (g_window_config.min_width > 0) @intCast(g_window_config.min_width) else glfw.GLFW_DONT_CARE,
                    if (g_window_config.min_height > 0) @intCast(g_window_config.min_height) else glfw.GLFW_DONT_CARE,
                    if (g_window_config.max_width > 0) @intCast(g_window_config.max_width) else glfw.GLFW_DONT_CARE,
                    if (g_window_config.max_height > 0) @intCast(g_window_config.max_height) else glfw.GLFW_DONT_CARE,
                );
            }
            return true;
        },
        ghostty.GHOSTTY_ACTION_INITIAL_SIZE => {
            const size = action.action.initial_size;
            if (g_window) |win| {
                glfw.glfwSetWindowSize(win, @intCast(size.width), @intCast(size.height));
            }
            return true;
        },
        ghostty.GHOSTTY_ACTION_SHOW_CHILD_EXITED => {
            // Suppress the "Process exited" message — trolley closes
            // the window immediately when the TUI binary exits.
            return true;
        },
        ghostty.GHOSTTY_ACTION_MOUSE_SHAPE => {
            // TODO: set cursor shape
            return false;
        },
        else => return false,
    }
}

fn readClipboardCallback(
    _: ?*anyopaque,
    _: ghostty.ghostty_clipboard_e,
    state: ?*anyopaque,
) callconv(.c) bool {
    const surface = g_surface orelse return false;
    if (g_window) |win| {
        const clip = glfw.glfwGetClipboardString(win);
        if (clip) |str| {
            ghostty.ghostty_surface_complete_clipboard_request(surface, str, state, false);
            return true;
        }
    }
    return false;
}

fn confirmReadClipboardCallback(
    _: ?*anyopaque,
    _: [*c]const u8,
    state: ?*anyopaque,
    _: ghostty.ghostty_clipboard_request_e,
) callconv(.c) void {
    const surface = g_surface orelse return;
    if (g_window) |win| {
        const clip = glfw.glfwGetClipboardString(win);
        if (clip) |str| {
            ghostty.ghostty_surface_complete_clipboard_request(surface, str, state, false);
        }
    }
}

fn writeClipboardCallback(
    _: ?*anyopaque,
    _: ghostty.ghostty_clipboard_e,
    content: [*c]const ghostty.ghostty_clipboard_content_s,
    _: usize,
    _: bool,
) callconv(.c) void {
    if (g_window) |win| {
        if (content != null) {
            glfw.glfwSetClipboardString(win, content[0].data);
        }
    }
}

fn closeSurfaceCallback(_: ?*anyopaque, _: bool) callconv(.c) void {
    if (g_window) |win| {
        glfw.glfwSetWindowShouldClose(win, glfw.GLFW_TRUE);
    }
}

// ---------------------------------------------------------------------------
// GLFW input callbacks → ghostty
//
// Two-phase key input (same pattern as ghostty's deleted GLFW apprt):
//   1. keyCallback sends the key event with inferred ASCII text.
//   2. If ghostty ignores it (not consumed), we store the event.
//   3. charCallback fires with the real Unicode codepoint, updates the
//      stored event's text, and re-sends it to ghostty.
// ---------------------------------------------------------------------------
var g_pending_key_event: ?ghostty.ghostty_input_key_s = null;
var g_pending_text_buf: [5]u8 = undefined;
var g_key_text_buf: [5]u8 = undefined;

fn keyCallback(
    _: ?*glfw.GLFWwindow,
    glfw_key: c_int,
    scancode: c_int,
    glfw_action: c_int,
    glfw_mods: c_int,
) callconv(.c) void {
    const surface = g_surface orelse return;

    const action: ghostty.ghostty_input_action_e = switch (glfw_action) {
        glfw.GLFW_PRESS => ghostty.GHOSTTY_ACTION_PRESS,
        glfw.GLFW_RELEASE => ghostty.GHOSTTY_ACTION_RELEASE,
        glfw.GLFW_REPEAT => ghostty.GHOSTTY_ACTION_REPEAT,
        else => return,
    };

    const mods = translateMods(glfw_mods);

    // Ghostty's keycode table on Linux uses XKB keycodes (evdev + 8).
    // GLFW on Wayland provides raw evdev scancodes, so we add 8.
    // On X11, GLFW already provides XKB keycodes, but adding 8 would be
    // wrong. We detect the backend to handle both correctly.
    const evdev_offset: c_int = if (glfw.glfwGetPlatform() == glfw.GLFW_PLATFORM_WAYLAND) 8 else 0;
    const keycode: u32 = if (scancode >= 0) @intCast(scancode + evdev_offset) else 0;

    // Get the unshifted codepoint from GLFW. This is the character the key
    // would produce without any modifiers, equivalent to GTK's
    // keyval_unicode_unshifted. Required for Kitty keyboard protocol encoding
    // and legacy ctrl+shift+letter handling.
    const unshifted_codepoint: u32 = uc: {
        const key_name = glfw.glfwGetKeyName(glfw_key, scancode);
        if (key_name) |name_ptr| {
            const name: [*:0]const u8 = name_ptr;
            const len = std.unicode.utf8ByteSequenceLength(name[0]) catch break :uc 0;
            const cp = std.unicode.utf8Decode(name[0..len]) catch break :uc 0;
            break :uc @intCast(cp);
        }
        break :uc 0;
    };

    // When ctrl is held, GLFW never fires charCallback, so we must
    // synthesize the text here. Without text, the legacy encoder's CSIu
    // path (for ctrl+shift+letter) silently drops the event.
    const has_ctrl = (glfw_mods & glfw.GLFW_MOD_CONTROL) != 0;
    const text: ?[*]const u8 = txt: {
        if (!has_ctrl) break :txt null;
        if (unshifted_codepoint < 0x20) break :txt null;
        var cp: u21 = std.math.cast(u21, unshifted_codepoint) orelse break :txt null;
        const has_shift = (glfw_mods & glfw.GLFW_MOD_SHIFT) != 0;
        if (has_shift and cp >= 'a' and cp <= 'z') {
            cp = cp - 'a' + 'A';
        }
        const len = std.unicode.utf8Encode(cp, &g_key_text_buf) catch break :txt null;
        if (len < g_key_text_buf.len) {
            g_key_text_buf[len] = 0;
        }
        break :txt &g_key_text_buf;
    };

    const key_event: ghostty.ghostty_input_key_s = .{
        .action = action,
        .mods = mods,
        .consumed_mods = ghostty.GHOSTTY_MODS_NONE,
        .keycode = keycode,
        .text = text,
        .unshifted_codepoint = unshifted_codepoint,
        .composing = false,
    };

    // Clear any previous pending event.
    g_pending_key_event = null;

    const consumed = ghostty.ghostty_surface_key(surface, key_event);

    // If ghostty didn't consume this press/repeat, store it so charCallback
    // can retry with the real text from the input method.
    if (!consumed and (action == ghostty.GHOSTTY_ACTION_PRESS or
        action == ghostty.GHOSTTY_ACTION_REPEAT))
    {
        g_pending_key_event = key_event;
    }
}

fn charCallback(_: ?*glfw.GLFWwindow, codepoint: c_uint) callconv(.c) void {
    const surface = g_surface orelse return;

    // charCallback only matters if we have a pending (ignored) key event.
    var key_event = g_pending_key_event orelse return;
    g_pending_key_event = null;

    // Encode the codepoint as UTF-8 into our persistent buffer.
    const cp: u21 = std.math.cast(u21, codepoint) orelse return;
    const len = std.unicode.utf8Encode(cp, &g_pending_text_buf) catch return;

    // Null-terminate for the C API (ghostty expects a C string).
    if (len < g_pending_text_buf.len) {
        g_pending_text_buf[len] = 0;
    }

    // Update the key event with the real text and codepoint.
    key_event.text = &g_pending_text_buf;
    key_event.unshifted_codepoint = codepoint;

    // Re-send the key event to ghostty with the text populated.
    _ = ghostty.ghostty_surface_key(surface, key_event);
}

fn mouseButtonCallback(
    _: ?*glfw.GLFWwindow,
    button: c_int,
    glfw_action: c_int,
    glfw_mods: c_int,
) callconv(.c) void {
    const surface = g_surface orelse return;

    const state: ghostty.ghostty_input_mouse_state_e = switch (glfw_action) {
        glfw.GLFW_PRESS => ghostty.GHOSTTY_MOUSE_PRESS,
        glfw.GLFW_RELEASE => ghostty.GHOSTTY_MOUSE_RELEASE,
        else => return,
    };

    const ghost_button: ghostty.ghostty_input_mouse_button_e = switch (button) {
        glfw.GLFW_MOUSE_BUTTON_LEFT => ghostty.GHOSTTY_MOUSE_LEFT,
        glfw.GLFW_MOUSE_BUTTON_RIGHT => ghostty.GHOSTTY_MOUSE_RIGHT,
        glfw.GLFW_MOUSE_BUTTON_MIDDLE => ghostty.GHOSTTY_MOUSE_MIDDLE,
        else => return,
    };

    const mods = translateMods(glfw_mods);
    _ = ghostty.ghostty_surface_mouse_button(surface, state, ghost_button, mods);
}

fn cursorPosCallback(_: ?*glfw.GLFWwindow, xpos: f64, ypos: f64) callconv(.c) void {
    const surface = g_surface orelse return;
    ghostty.ghostty_surface_mouse_pos(surface, xpos, ypos, ghostty.GHOSTTY_MODS_NONE);
}

fn scrollCallback(_: ?*glfw.GLFWwindow, xoffset: f64, yoffset: f64) callconv(.c) void {
    const surface = g_surface orelse return;
    // GLFW doesn't provide scroll mods, pass 0
    ghostty.ghostty_surface_mouse_scroll(surface, xoffset, yoffset, 0);
}

fn framebufferSizeCallback(_: ?*glfw.GLFWwindow, width: c_int, height: c_int) callconv(.c) void {
    const surface = g_surface orelse return;
    if (width > 0 and height > 0) {
        ghostty.ghostty_surface_set_size(surface, @intCast(width), @intCast(height));
    }
}

fn focusCallback(_: ?*glfw.GLFWwindow, focused: c_int) callconv(.c) void {
    const surface = g_surface orelse return;
    ghostty.ghostty_surface_set_focus(surface, focused == glfw.GLFW_TRUE);
}

fn contentScaleCallback(_: ?*glfw.GLFWwindow, xscale: f32, yscale: f32) callconv(.c) void {
    const surface = g_surface orelse return;
    ghostty.ghostty_surface_set_content_scale(surface, xscale, yscale);
}

fn translateMods(glfw_mods: c_int) ghostty.ghostty_input_mods_e {
    var mods: c_int = ghostty.GHOSTTY_MODS_NONE;
    if (glfw_mods & glfw.GLFW_MOD_SHIFT != 0) mods |= ghostty.GHOSTTY_MODS_SHIFT;
    if (glfw_mods & glfw.GLFW_MOD_CONTROL != 0) mods |= ghostty.GHOSTTY_MODS_CTRL;
    if (glfw_mods & glfw.GLFW_MOD_ALT != 0) mods |= ghostty.GHOSTTY_MODS_ALT;
    if (glfw_mods & glfw.GLFW_MOD_SUPER != 0) mods |= ghostty.GHOSTTY_MODS_SUPER;
    if (glfw_mods & glfw.GLFW_MOD_CAPS_LOCK != 0) mods |= ghostty.GHOSTTY_MODS_CAPS;
    if (glfw_mods & glfw.GLFW_MOD_NUM_LOCK != 0) mods |= ghostty.GHOSTTY_MODS_NUM;
    return @intCast(mods);
}

// Path resolution delegated to common module:
// common.common.getExeDir(), common.common.getBundledPath(), common.chdirToExeDir()

// ---------------------------------------------------------------------------
// PID file path (set from TROLLEY_PID_FILE env var) and signal cleanup
// ---------------------------------------------------------------------------
var g_pid_file_path: ?[*:0]const u8 = null;

/// Signal handler for PID file cleanup. Only raw syscalls are used here
/// to stay async-signal-safe (no stdlib filesystem APIs).
fn cleanupSignalHandler(sig: c_int) callconv(.c) void {
    const linux = std.os.linux;

    // unlinkat(AT_FDCWD, path, 0) — raw syscall, async-signal-safe.
    if (g_pid_file_path) |path| {
        _ = linux.unlinkat(linux.AT.FDCWD, path, 0);
    }

    // Restore default disposition for this signal and re-raise so the
    // process exits with the correct signal status.
    const sig_u8: u8 = @intCast(sig);
    var sa: linux.Sigaction = .{
        .handler = .{ .handler = linux.SIG.DFL },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(sig_u8, &sa, null);
    _ = linux.tkill(linux.gettid(), sig);
}

// ---------------------------------------------------------------------------
// Font registration via FONTCONFIG_FILE
// ---------------------------------------------------------------------------
/// If a bundled fonts.conf exists (generated by the CLI when fonts are
/// bundled), set FONTCONFIG_FILE so fontconfig picks up the bundled fonts
/// directory. Must be called BEFORE ghostty_init.
fn registerBundledFonts() void {
    const path = common.getBundledPath("fonts.conf") orelse return;
    _ = common.setenvZ("FONTCONFIG_FILE", path.ptr);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
fn glfwErrorCallback(err: c_int, description: [*c]const u8) callconv(.c) void {
    std.debug.print("GLFW error {d}: {s}\n", .{ err, description });
}

pub fn main() !void {
    // -- Change CWD to the exe's directory --
    common.chdirToExeDir();

    // -- Load manifest for window config --
    if (common.getBundledPath("trolley.toml")) |manifest_path| {
        var ghostty_len: usize = 0;
        _ = trolley.trolley_load_manifest(manifest_path.ptr, &g_window_config, &ghostty_len);
    }

    const initial_width: c_int = if (g_window_config.initial_width > 0) @intCast(g_window_config.initial_width) else 800;
    const initial_height: c_int = if (g_window_config.initial_height > 0) @intCast(g_window_config.initial_height) else 600;

    // -- GLFW init --
    _ = glfw.glfwSetErrorCallback(&glfwErrorCallback);
    if (glfw.glfwInit() != glfw.GLFW_TRUE) {
        return error.GlfwInitFailed;
    }
    defer glfw.glfwTerminate();

    // Request OpenGL 4.3 core profile (ghostty minimum)
    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MAJOR, 4);
    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MINOR, 3);
    glfw.glfwWindowHint(glfw.GLFW_OPENGL_PROFILE, glfw.GLFW_OPENGL_CORE_PROFILE);
    glfw.glfwWindowHint(glfw.GLFW_OPENGL_FORWARD_COMPAT, glfw.GLFW_TRUE);
    glfw.glfwWindowHint(glfw.GLFW_VISIBLE, glfw.GLFW_TRUE);
    glfw.glfwWindowHint(glfw.GLFW_FOCUSED, glfw.GLFW_TRUE);

    // Resizable hint (must be set before window creation)
    if (g_window_config.resizable == 0) {
        glfw.glfwWindowHint(glfw.GLFW_RESIZABLE, glfw.GLFW_FALSE);
    }

    const window = glfw.glfwCreateWindow(initial_width, initial_height, "trolley", null, null) orelse {
        return error.GlfwWindowFailed;
    };
    defer glfw.glfwDestroyWindow(window);
    g_window = window;

    // Apply min/max size limits from manifest
    {
        const min_w: c_int = if (g_window_config.min_width > 0) @intCast(g_window_config.min_width) else glfw.GLFW_DONT_CARE;
        const min_h: c_int = if (g_window_config.min_height > 0) @intCast(g_window_config.min_height) else glfw.GLFW_DONT_CARE;
        const max_w: c_int = if (g_window_config.max_width > 0) @intCast(g_window_config.max_width) else glfw.GLFW_DONT_CARE;
        const max_h: c_int = if (g_window_config.max_height > 0) @intCast(g_window_config.max_height) else glfw.GLFW_DONT_CARE;
        if (min_w != glfw.GLFW_DONT_CARE or min_h != glfw.GLFW_DONT_CARE or
            max_w != glfw.GLFW_DONT_CARE or max_h != glfw.GLFW_DONT_CARE)
        {
            glfw.glfwSetWindowSizeLimits(window, min_w, min_h, max_w, max_h);
        }
    }

    glfw.glfwMakeContextCurrent(window);
    glfw.glfwSwapInterval(1);
    glfw.glfwShowWindow(window);
    glfw.glfwFocusWindow(window);

    // -- Load bundled environment variables (must precede ghostty_init) --
    common.loadBundledEnvironment();

    // -- Inject runtime PID as environment variable if configured --
    var pid_buf: [16]u8 = undefined;
    const pid_str = std.fmt.bufPrintZ(&pid_buf, "{d}", .{std.os.linux.getpid()}) catch unreachable;
    if (g_window_config.inject_pid_variable) |varname| {
        _ = common.setenvZ(varname, pid_str.ptr);
    }

    // -- Register bundled fonts (must precede ghostty_init) --
    registerBundledFonts();

    // -- Ghostty init --
    const init_result = ghostty.ghostty_init(0, null);
    if (init_result != ghostty.GHOSTTY_SUCCESS) {
        return error.GhosttyInitFailed;
    }

    const config = ghostty.ghostty_config_new();
    if (config == null) {
        return error.GhosttyConfigFailed;
    }

    // Load bundled ghostty.conf next to the executable.
    if (common.getBundledPath("ghostty.conf")) |path| {
        ghostty.ghostty_config_load_file(config, path.ptr);
    }

    ghostty.ghostty_config_finalize(config);

    var runtime_config: ghostty.ghostty_runtime_config_s = .{
        .userdata = null,
        .supports_selection_clipboard = false,
        .wakeup_cb = &wakeupCallback,
        .action_cb = &actionCallback,
        .read_clipboard_cb = &readClipboardCallback,
        .confirm_read_clipboard_cb = &confirmReadClipboardCallback,
        .write_clipboard_cb = &writeClipboardCallback,
        .close_surface_cb = &closeSurfaceCallback,
    };

    const app = ghostty.ghostty_app_new(&runtime_config, config);
    if (app == null) {
        ghostty.ghostty_config_free(config);
        return error.GhosttyAppFailed;
    }
    ghostty.ghostty_config_free(config);
    // NOTE: no defer for ghostty_app_free — see std.process.exit(0) below.
    g_app = app;

    // -- Create surface with Linux platform (OpenGL) --
    var surface_config = ghostty.ghostty_surface_config_new();
    surface_config.platform_tag = ghostty.GHOSTTY_PLATFORM_OPENGL;
    surface_config.platform = .{
        .opengl = .{
            .get_proc_address = @ptrCast(&glfw.glfwGetProcAddress),
            .make_context_current = &makeContextCurrent,
            .swap_buffers = &swapBuffers,
            .gl_userdata = @ptrCast(window),
        },
    };

    // Content scale
    var xscale: f32 = 1.0;
    var yscale: f32 = 1.0;
    glfw.glfwGetWindowContentScale(window, &xscale, &yscale);
    surface_config.scale_factor = @floatCast(xscale);

    const surface = ghostty.ghostty_surface_new(app, &surface_config);
    if (surface == null) {
        return error.GhosttySurfaceFailed;
    }
    // NOTE: no defer for ghostty_surface_free — see std.process.exit(0) below.
    g_surface = surface;

    // Set initial size from framebuffer
    var fb_width: c_int = 0;
    var fb_height: c_int = 0;
    glfw.glfwGetFramebufferSize(window, &fb_width, &fb_height);
    if (fb_width > 0 and fb_height > 0) {
        ghostty.ghostty_surface_set_size(surface, @intCast(fb_width), @intCast(fb_height));
    }

    // Set content scale
    ghostty.ghostty_surface_set_content_scale(surface, @floatCast(xscale), @floatCast(yscale));

    // Set focus
    ghostty.ghostty_surface_set_focus(surface, true);

    // -- Register GLFW callbacks --
    _ = glfw.glfwSetKeyCallback(window, &keyCallback);
    _ = glfw.glfwSetCharCallback(window, &charCallback);
    _ = glfw.glfwSetMouseButtonCallback(window, &mouseButtonCallback);
    _ = glfw.glfwSetCursorPosCallback(window, &cursorPosCallback);
    _ = glfw.glfwSetScrollCallback(window, &scrollCallback);
    _ = glfw.glfwSetFramebufferSizeCallback(window, &framebufferSizeCallback);
    _ = glfw.glfwSetWindowFocusCallback(window, &focusCallback);
    _ = glfw.glfwSetWindowContentScaleCallback(window, &contentScaleCallback);

    // -- Write PID file after successful init --
    // Install signal handlers before creating the file so cleanup is ready
    // for an immediate signal.
    if (common.getenvZ("TROLLEY_PID_FILE")) |path| {
        g_pid_file_path = path;

        var sa: std.posix.Sigaction = .{
            .handler = .{ .handler = cleanupSignalHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
        std.posix.sigaction(std.posix.SIG.INT, &sa, null);

        const file = std.fs.cwd().createFileZ(path, .{}) catch {
            std.debug.print("trolley: failed to create PID file: {s}\n", .{path});
            return error.PidFileCreateFailed;
        };
        file.writeAll(pid_str) catch {
            std.debug.print("trolley: failed to write PID file: {s}\n", .{path});
            return error.PidFileWriteFailed;
        };
        file.close();
    }

    // -- Event loop --
    while (glfw.glfwWindowShouldClose(window) != glfw.GLFW_TRUE) {
        ghostty.ghostty_app_tick(app);
        glfw.glfwWaitEvents();
    }

    // Clean up PID file before exit.
    if (g_pid_file_path) |path| {
        std.fs.cwd().deleteFileZ(path) catch {};
    }

    // Exit immediately. Ghostty's Surface.deinit assumes the GL context
    // can be re-acquired (catch unreachable), but on Wayland/EGL the
    // context becomes invalid once the window is closing. The OS reclaims
    // all resources on process exit.
    std.process.exit(0);
}
