const std = @import("std");
const common = @import("common");
const win32 = @import("win32");
const ghostty = @cImport(@cInclude("ghostty.h"));
const trolley = @cImport(@cInclude("trolley.h"));

const wam = win32.ui.windows_and_messaging;
const gdi = win32.graphics.gdi;
const gl = win32.graphics.open_gl;
const kbd = win32.ui.input.keyboard_and_mouse;
const foundation = win32.foundation;

const HWND = foundation.HWND;
const HDC = gdi.HDC;
const HGLRC = gl.HGLRC;
const LPARAM = foundation.LPARAM;
const WPARAM = foundation.WPARAM;
const LRESULT = foundation.LRESULT;
const BOOL = foundation.BOOL;
const TRUE: BOOL = 1;
const FALSE: BOOL = 0;

pub const std_options: std.Options = .{
    .log_level = .debug,
};

// ---------------------------------------------------------------------------
// Custom Win32 declarations not in zigwin32
// ---------------------------------------------------------------------------
const WM_USER = 0x0400;
const WM_DPICHANGED = 0x02E0;
const WM_SYSKEYDOWN = 0x0104;
const WM_SYSKEYUP = 0x0105;
const WM_MBUTTONDOWN = 0x0207;
const WM_MBUTTONUP = 0x0208;
const WM_MOUSEHWHEEL = 0x020E;
const WM_GETMINMAXINFO = 0x0024;
const WM_ERASEBKGND = 0x0014;
const QS_ALLINPUT = 0x04FF;

const MINMAXINFO = extern struct {
    ptReserved: foundation.POINT,
    ptMaxSize: foundation.POINT,
    ptMaxPosition: foundation.POINT,
    ptMinTrackSize: foundation.POINT,
    ptMaxTrackSize: foundation.POINT,
};

extern "user32" fn MsgWaitForMultipleObjects(
    nCount: u32,
    pHandles: ?*const ?*anyopaque,
    bWaitAll: BOOL,
    dwMilliseconds: u32,
    dwWakeMask: u32,
) callconv(.winapi) u32;

extern "user32" fn PostMessageW(
    hWnd: ?HWND,
    Msg: u32,
    wParam: WPARAM,
    lParam: LPARAM,
) callconv(.winapi) BOOL;

extern "user32" fn GetDpiForWindow(
    hwnd: HWND,
) callconv(.winapi) u32;

extern "user32" fn AdjustWindowRectEx(
    lpRect: *foundation.RECT,
    dwStyle: u32,
    bMenu: BOOL,
    dwExStyle: u32,
) callconv(.winapi) BOOL;

extern "user32" fn AdjustWindowRectExForDpi(
    lpRect: *foundation.RECT,
    dwStyle: u32,
    bMenu: BOOL,
    dwExStyle: u32,
    dpi: u32,
) callconv(.winapi) BOOL;

extern "user32" fn GetWindowLongW(
    hWnd: HWND,
    nIndex: i32,
) callconv(.winapi) i32;

extern "user32" fn SetProcessDpiAwarenessContext(
    value: isize,
) callconv(.winapi) BOOL;

extern "kernel32" fn GetModuleHandleW(
    lpModuleName: ?[*:0]const u16,
) callconv(.winapi) ?*anyopaque;

extern "kernel32" fn ExitProcess(
    uExitCode: u32,
) callconv(.winapi) noreturn;

extern "winmm" fn timeBeginPeriod(
    uPeriod: u32,
) callconv(.winapi) u32;

extern "winmm" fn timeEndPeriod(
    uPeriod: u32,
) callconv(.winapi) u32;

extern "opengl32" fn wglGetProcAddress(
    lpszProc: [*:0]const u8,
) callconv(.winapi) ?*const fn () callconv(.winapi) void;

extern "opengl32" fn wglCreateContext(
    hdc: ?HDC,
) callconv(.winapi) ?HGLRC;

extern "opengl32" fn wglMakeCurrent(
    hdc: ?HDC,
    hglrc: ?HGLRC,
) callconv(.winapi) BOOL;

extern "opengl32" fn wglDeleteContext(
    hglrc: ?HGLRC,
) callconv(.winapi) BOOL;

extern "gdi32" fn SwapBuffers(
    hdc: ?HDC,
) callconv(.winapi) BOOL;

extern "gdi32" fn ChoosePixelFormat(
    hdc: ?HDC,
    ppfd: *const gl.PIXELFORMATDESCRIPTOR,
) callconv(.winapi) i32;

extern "gdi32" fn SetPixelFormat(
    hdc: ?HDC,
    format: i32,
    ppfd: *const gl.PIXELFORMATDESCRIPTOR,
) callconv(.winapi) BOOL;

extern "kernel32" fn GetProcAddress(
    hModule: ?*anyopaque,
    lpProcName: [*:0]const u8,
) callconv(.winapi) ?*const fn () callconv(.winapi) void;

extern "kernel32" fn LoadLibraryA(
    lpLibFileName: [*:0]const u8,
) callconv(.winapi) ?*anyopaque;

extern "kernel32" fn AttachConsole(
    dwProcessId: u32,
) callconv(.winapi) BOOL;

const ATTACH_PARENT_PROCESS: u32 = 0xFFFFFFFF;

// WGL extension function types
const WglCreateContextAttribsARB = *const fn (
    hdc: ?HDC,
    hShareContext: ?HGLRC,
    attribList: [*]const i32,
) callconv(.winapi) ?HGLRC;

const WglChoosePixelFormatARB = *const fn (
    hdc: ?HDC,
    piAttribIList: [*]const i32,
    pfAttribFList: ?*const f32,
    nMaxFormats: u32,
    piFormats: *i32,
    nNumFormats: *u32,
) callconv(.winapi) BOOL;

const WglSwapIntervalEXT = *const fn (interval: i32) callconv(.winapi) BOOL;

// WGL constants
const WGL_CONTEXT_MAJOR_VERSION_ARB = 0x2091;
const WGL_CONTEXT_MINOR_VERSION_ARB = 0x2092;
const WGL_CONTEXT_PROFILE_MASK_ARB = 0x9126;
const WGL_CONTEXT_CORE_PROFILE_BIT_ARB = 0x00000001;
const WGL_DRAW_TO_WINDOW_ARB = 0x2001;
const WGL_SUPPORT_OPENGL_ARB = 0x2010;
const WGL_DOUBLE_BUFFER_ARB = 0x2011;
const WGL_PIXEL_TYPE_ARB = 0x2013;
const WGL_TYPE_RGBA_ARB = 0x202B;
const WGL_COLOR_BITS_ARB = 0x2014;
const WGL_DEPTH_BITS_ARB = 0x2022;
const WGL_STENCIL_BITS_ARB = 0x2023;

// DPI awareness context
const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;

// ---------------------------------------------------------------------------
// Global state (needed by C callbacks which don't carry user context)
// ---------------------------------------------------------------------------
var g_hwnd: ?HWND = null;
var g_hdc: ?HDC = null;
var g_hglrc: ?HGLRC = null;
var g_surface: ghostty.ghostty_surface_t = null;
var g_app: ghostty.ghostty_app_t = null;
var g_opengl32: ?*anyopaque = null;

// Window config from trolley manifest
var g_window_config: trolley.TrolleyGuiConfig = .{
    .initial_width = 0,
    .initial_height = 0,
    .resizable = -1,
    .min_width = 0,
    .min_height = 0,
    .max_width = 0,
    .max_height = 0,
    .win_precise_timer = 1,
};

// ---------------------------------------------------------------------------
// WGL ↔ ghostty OpenGL context bridge
// ---------------------------------------------------------------------------
fn makeContextCurrent(userdata: ?*anyopaque) callconv(.c) void {
    if (userdata != null) {
        _ = wglMakeCurrent(g_hdc, g_hglrc);
    } else {
        _ = wglMakeCurrent(null, null);
    }
}

fn swapBuffersCb(_: ?*anyopaque) callconv(.c) void {
    _ = SwapBuffers(g_hdc);
}

fn getProcAddress(name: [*c]const u8) callconv(.c) ?*const fn () callconv(.winapi) void {
    // Try WGL first (for GL extensions), fall back to opengl32.dll (for GL 1.1 functions)
    if (wglGetProcAddress(name)) |proc| return proc;
    if (g_opengl32) |lib| {
        return GetProcAddress(lib, name);
    }
    return null;
}

// ---------------------------------------------------------------------------
// Ghostty runtime callbacks
// ---------------------------------------------------------------------------
fn wakeupCallback(_: ?*anyopaque) callconv(.c) void {
    if (g_hwnd) |hwnd| {
        _ = PostMessageW(hwnd, WM_USER, 0, 0);
    }
}

fn actionCallback(
    _: ghostty.ghostty_app_t,
    _: ghostty.ghostty_target_s,
    action: ghostty.ghostty_action_s,
) callconv(.c) bool {
    switch (action.tag) {
        ghostty.GHOSTTY_ACTION_SET_TITLE => {
            const title = action.action.set_title.title;
            if (g_hwnd) |hwnd| {
                // Convert UTF-8 title to UTF-16 for Win32
                var buf: [512]u16 = undefined;
                const len = std.unicode.utf8ToUtf16Le(&buf, std.mem.span(title)) catch return true;
                if (len < buf.len) buf[len] = 0;
                _ = wam.SetWindowTextW(hwnd, @ptrCast(&buf));
            }
            return true;
        },
        ghostty.GHOSTTY_ACTION_QUIT => {
            if (g_hwnd) |hwnd| {
                _ = wam.DestroyWindow(hwnd);
            }
            return true;
        },
        ghostty.GHOSTTY_ACTION_CLOSE_WINDOW => {
            if (g_hwnd) |hwnd| {
                _ = wam.DestroyWindow(hwnd);
            }
            return true;
        },
        ghostty.GHOSTTY_ACTION_INITIAL_SIZE => {
            const size = action.action.initial_size;
            const hwnd = g_hwnd orelse return false;
            const dpi = GetDpiForWindow(hwnd);
            const scale: f64 = @as(f64, @floatFromInt(dpi)) / 96.0;
            // INITIAL_SIZE sends logical pixels; convert to physical for SetWindowPos
            var rect: foundation.RECT = .{
                .left = 0,
                .top = 0,
                .right = @intFromFloat(@as(f64, @floatFromInt(size.width)) * scale),
                .bottom = @intFromFloat(@as(f64, @floatFromInt(size.height)) * scale),
            };
            // Convert client area to outer window dimensions
            const GWL_STYLE: i32 = -16;
            const win_style: u32 = @bitCast(GetWindowLongW(hwnd, GWL_STYLE));
            _ = AdjustWindowRectExForDpi(&rect, win_style, FALSE, 0, dpi);
            _ = wam.SetWindowPos(
                hwnd,
                null,
                0,
                0,
                rect.right - rect.left,
                rect.bottom - rect.top,
                @bitCast(@as(u32, 0x0002 | 0x0004)), // SWP_NOMOVE | SWP_NOZORDER
            );
            return true;
        },
        ghostty.GHOSTTY_ACTION_SIZE_LIMIT => {
            // Ghostty may send size limits based on its config. We store them
            // in g_window_config so WM_GETMINMAXINFO picks them up.
            // Only override if the manifest didn't already set them.
            const limits = action.action.size_limit;
            if (g_window_config.min_width == 0 and limits.min_width > 0)
                g_window_config.min_width = limits.min_width;
            if (g_window_config.min_height == 0 and limits.min_height > 0)
                g_window_config.min_height = limits.min_height;
            if (g_window_config.max_width == 0 and limits.max_width > 0)
                g_window_config.max_width = limits.max_width;
            if (g_window_config.max_height == 0 and limits.max_height > 0)
                g_window_config.max_height = limits.max_height;
            return true;
        },
        ghostty.GHOSTTY_ACTION_SHOW_CHILD_EXITED => {
            return true;
        },
        ghostty.GHOSTTY_ACTION_MOUSE_SHAPE => {
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
    const hwnd = g_hwnd orelse return false;

    if (openClipboard(hwnd)) {
        defer closeClipboard();
        const CF_UNICODETEXT = 13;
        const handle = GetClipboardData(CF_UNICODETEXT);
        if (handle) |h| {
            const ptr = GlobalLock(h);
            if (ptr) |p| {
                defer _ = GlobalUnlock(h);
                const wide: [*:0]const u16 = @ptrCast(@alignCast(p));
                const utf8 = std.unicode.utf16LeToUtf8Alloc(std.heap.page_allocator, std.mem.span(wide)) catch return false;
                defer std.heap.page_allocator.free(utf8);
                // Need null-terminated string for ghostty
                const z = std.heap.page_allocator.dupeZ(u8, utf8) catch return false;
                defer std.heap.page_allocator.free(z);
                ghostty.ghostty_surface_complete_clipboard_request(surface, z.ptr, state, false);
                return true;
            }
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
    const hwnd = g_hwnd orelse return;

    if (openClipboard(hwnd)) {
        defer closeClipboard();
        const CF_UNICODETEXT = 13;
        const handle = GetClipboardData(CF_UNICODETEXT);
        if (handle) |h| {
            const ptr = GlobalLock(h);
            if (ptr) |p| {
                defer _ = GlobalUnlock(h);
                const wide: [*:0]const u16 = @ptrCast(@alignCast(p));
                const utf8 = std.unicode.utf16LeToUtf8Alloc(std.heap.page_allocator, std.mem.span(wide)) catch return;
                defer std.heap.page_allocator.free(utf8);
                const z = std.heap.page_allocator.dupeZ(u8, utf8) catch return;
                defer std.heap.page_allocator.free(z);
                ghostty.ghostty_surface_complete_clipboard_request(surface, z.ptr, state, false);
            }
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
    if (content == null) return;
    const hwnd = g_hwnd orelse return;
    const data = std.mem.span(content[0].data);

    // Convert UTF-8 to UTF-16
    const wide = std.unicode.utf8ToUtf16LeAlloc(std.heap.page_allocator, data) catch return;
    defer std.heap.page_allocator.free(wide);

    if (openClipboard(hwnd)) {
        defer closeClipboard();
        _ = EmptyClipboard();
        const size = (wide.len + 1) * @sizeOf(u16);
        const hmem = GlobalAlloc(0x0002, size); // GMEM_MOVEABLE
        if (hmem) |h| {
            const ptr = GlobalLock(h);
            if (ptr) |p| {
                const dest: [*]u16 = @ptrCast(@alignCast(p));
                @memcpy(dest[0..wide.len], wide);
                dest[wide.len] = 0;
                _ = GlobalUnlock(h);
                const CF_UNICODETEXT = 13;
                _ = SetClipboardData(CF_UNICODETEXT, h);
            }
        }
    }
}

fn closeSurfaceCallback(_: ?*anyopaque, _: bool) callconv(.c) void {
    if (g_hwnd) |hwnd| {
        _ = wam.DestroyWindow(hwnd);
    }
}

// ---------------------------------------------------------------------------
// Clipboard Win32 helpers
// ---------------------------------------------------------------------------
extern "user32" fn OpenClipboard(hWndNewOwner: ?HWND) callconv(.winapi) BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
extern "user32" fn GetClipboardData(uFormat: u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn SetClipboardData(uFormat: u32, hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalAlloc(uFlags: u32, dwBytes: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalLock(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(hMem: ?*anyopaque) callconv(.winapi) BOOL;

fn openClipboard(hwnd: HWND) bool {
    return OpenClipboard(hwnd) != 0;
}

fn closeClipboard() void {
    _ = CloseClipboard();
}

// ---------------------------------------------------------------------------
// Two-phase key input (same pattern as Linux runtime)
// ---------------------------------------------------------------------------
var g_pending_key_event: ?ghostty.ghostty_input_key_s = null;
var g_pending_text_buf: [5]u8 = undefined;
var g_key_text_buf: [5]u8 = undefined;
var g_high_surrogate: u16 = 0;

// ---------------------------------------------------------------------------
// Win32 modifier translation
// ---------------------------------------------------------------------------
fn keyState(vk: kbd.VIRTUAL_KEY) u16 {
    return @bitCast(kbd.GetKeyState(@intFromEnum(vk)));
}

fn translateMods() ghostty.ghostty_input_mods_e {
    var mods: c_int = ghostty.GHOSTTY_MODS_NONE;
    if (keyState(.SHIFT) & 0x8000 != 0)
        mods |= ghostty.GHOSTTY_MODS_SHIFT;
    if (keyState(.CONTROL) & 0x8000 != 0)
        mods |= ghostty.GHOSTTY_MODS_CTRL;
    if (keyState(.MENU) & 0x8000 != 0)
        mods |= ghostty.GHOSTTY_MODS_ALT;
    if (keyState(.LWIN) & 0x8000 != 0 or keyState(.RWIN) & 0x8000 != 0)
        mods |= ghostty.GHOSTTY_MODS_SUPER;
    if (keyState(.CAPITAL) & 0x0001 != 0)
        mods |= ghostty.GHOSTTY_MODS_CAPS;
    if (keyState(.NUMLOCK) & 0x0001 != 0)
        mods |= ghostty.GHOSTTY_MODS_NUM;
    return @intCast(mods);
}

/// Extract the Win32 scancode from WM_KEYDOWN/WM_KEYUP lParam.
/// The scancode byte is bits 16-23, the extended flag is bit 24.
/// Extended keys get the 0xe000 prefix to match ghostty's keycode table.
fn extractScancode(lParam: LPARAM) u32 {
    const scan: u32 = @intCast((@as(u64, @bitCast(lParam)) >> 16) & 0xFF);
    const extended: u32 = @intCast((@as(u64, @bitCast(lParam)) >> 24) & 1);
    return scan | (extended * 0xe000);
}

/// Derive the unshifted character for a virtual key code using MapVirtualKeyW.
/// Returns 0 for non-printable keys. Dead-key bit is masked off.
fn unshiftedCodepoint(vk_wparam: WPARAM) u32 {
    const vk: u32 = @intCast(vk_wparam & 0xFFFF);
    const mapped = kbd.MapVirtualKeyW(vk, wam.MAPVK_VK_TO_CHAR);
    var ch = mapped & 0x7FFFFFFF;
    if (ch >= 'A' and ch <= 'Z') ch = ch - 'A' + 'a';
    return if (ch >= 0x20) ch else 0;
}

// ---------------------------------------------------------------------------
// Window procedure
// ---------------------------------------------------------------------------
fn windowProc(hwnd: HWND, msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        wam.WM_KEYDOWN, WM_SYSKEYDOWN => {
            const surface = g_surface orelse return wam.DefWindowProcW(hwnd, msg, wParam, lParam);
            const keycode = extractScancode(lParam);
            const mods = translateMods();
            const action: ghostty.ghostty_input_action_e = if ((@as(u64, @bitCast(lParam)) >> 30) & 1 != 0)
                ghostty.GHOSTTY_ACTION_REPEAT
            else
                ghostty.GHOSTTY_ACTION_PRESS;

            // Get the unshifted codepoint from MapVirtualKeyW. This is the
            // character the key would produce without any modifiers. Required
            // for Kitty keyboard protocol encoding and legacy ctrl+shift+letter
            // handling.
            const unshifted_codepoint = unshiftedCodepoint(wParam);

            // When ctrl is held, Windows never sends WM_CHAR, so we must
            // synthesize the text here. Without text, the legacy encoder's
            // CSIu path (for ctrl+shift+letter) silently drops the event.
            const has_ctrl = (keyState(.CONTROL) & 0x8000) != 0;
            const text: ?[*]const u8 = txt: {
                if (!has_ctrl) break :txt null;
                if (unshifted_codepoint < 0x20) break :txt null;
                var cp: u21 = std.math.cast(u21, unshifted_codepoint) orelse break :txt null;
                const has_shift = (keyState(.SHIFT) & 0x8000) != 0;
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

            g_pending_key_event = null;
            const consumed = ghostty.ghostty_surface_key(surface, key_event);
            if (!consumed) {
                g_pending_key_event = key_event;
            }
            return 0;
        },
        wam.WM_KEYUP, WM_SYSKEYUP => {
            const surface = g_surface orelse return wam.DefWindowProcW(hwnd, msg, wParam, lParam);
            const keycode = extractScancode(lParam);
            const mods = translateMods();
            const unshifted_codepoint = unshiftedCodepoint(wParam);

            const key_event: ghostty.ghostty_input_key_s = .{
                .action = ghostty.GHOSTTY_ACTION_RELEASE,
                .mods = mods,
                .consumed_mods = ghostty.GHOSTTY_MODS_NONE,
                .keycode = keycode,
                .text = null,
                .unshifted_codepoint = unshifted_codepoint,
                .composing = false,
            };

            _ = ghostty.ghostty_surface_key(surface, key_event);
            return 0;
        },
        wam.WM_CHAR => {
            const surface = g_surface orelse return wam.DefWindowProcW(hwnd, msg, wParam, lParam);

            const char_code: u16 = @intCast(wParam & 0xFFFF);

            // Handle UTF-16 surrogate pairs: codepoints above U+FFFF are
            // delivered as two WM_CHAR messages (high surrogate, then low).
            if (char_code >= 0xD800 and char_code <= 0xDBFF) {
                // High surrogate — store and wait for the low surrogate
                g_high_surrogate = char_code;
                return 0;
            }

            var codepoint: u32 = char_code;
            if (char_code >= 0xDC00 and char_code <= 0xDFFF) {
                // Low surrogate — combine with stored high surrogate
                if (g_high_surrogate == 0) return 0; // orphaned low surrogate
                codepoint = (@as(u32, g_high_surrogate) - 0xD800) * 0x400 +
                    (@as(u32, char_code) - 0xDC00) + 0x10000;
                g_high_surrogate = 0;
            } else {
                g_high_surrogate = 0;
            }

            var key_event = g_pending_key_event orelse return 0;
            g_pending_key_event = null;

            const cp: u21 = std.math.cast(u21, codepoint) orelse return 0;
            const len = std.unicode.utf8Encode(cp, &g_pending_text_buf) catch return 0;
            if (len < g_pending_text_buf.len) {
                g_pending_text_buf[len] = 0;
            }

            key_event.text = &g_pending_text_buf;
            key_event.unshifted_codepoint = codepoint;
            _ = ghostty.ghostty_surface_key(surface, key_event);
            return 0;
        },
        wam.WM_LBUTTONDOWN => {
            const surface = g_surface orelse return wam.DefWindowProcW(hwnd, msg, wParam, lParam);
            _ = ghostty.ghostty_surface_mouse_button(surface, ghostty.GHOSTTY_MOUSE_PRESS, ghostty.GHOSTTY_MOUSE_LEFT, translateMods());
            return 0;
        },
        wam.WM_LBUTTONUP => {
            const surface = g_surface orelse return wam.DefWindowProcW(hwnd, msg, wParam, lParam);
            _ = ghostty.ghostty_surface_mouse_button(surface, ghostty.GHOSTTY_MOUSE_RELEASE, ghostty.GHOSTTY_MOUSE_LEFT, translateMods());
            return 0;
        },
        wam.WM_RBUTTONDOWN => {
            const surface = g_surface orelse return wam.DefWindowProcW(hwnd, msg, wParam, lParam);
            _ = ghostty.ghostty_surface_mouse_button(surface, ghostty.GHOSTTY_MOUSE_PRESS, ghostty.GHOSTTY_MOUSE_RIGHT, translateMods());
            return 0;
        },
        wam.WM_RBUTTONUP => {
            const surface = g_surface orelse return wam.DefWindowProcW(hwnd, msg, wParam, lParam);
            _ = ghostty.ghostty_surface_mouse_button(surface, ghostty.GHOSTTY_MOUSE_RELEASE, ghostty.GHOSTTY_MOUSE_RIGHT, translateMods());
            return 0;
        },
        WM_MBUTTONDOWN => {
            const surface = g_surface orelse return wam.DefWindowProcW(hwnd, msg, wParam, lParam);
            _ = ghostty.ghostty_surface_mouse_button(surface, ghostty.GHOSTTY_MOUSE_PRESS, ghostty.GHOSTTY_MOUSE_MIDDLE, translateMods());
            return 0;
        },
        WM_MBUTTONUP => {
            const surface = g_surface orelse return wam.DefWindowProcW(hwnd, msg, wParam, lParam);
            _ = ghostty.ghostty_surface_mouse_button(surface, ghostty.GHOSTTY_MOUSE_RELEASE, ghostty.GHOSTTY_MOUSE_MIDDLE, translateMods());
            return 0;
        },
        wam.WM_MOUSEMOVE => {
            const surface = g_surface orelse return wam.DefWindowProcW(hwnd, msg, wParam, lParam);
            const x: f64 = @floatFromInt(@as(i16, @truncate(@as(isize, lParam))));
            const y: f64 = @floatFromInt(@as(i16, @truncate(@as(isize, lParam) >> 16)));
            ghostty.ghostty_surface_mouse_pos(surface, x, y, translateMods());
            return 0;
        },
        wam.WM_MOUSEWHEEL => {
            const surface = g_surface orelse return wam.DefWindowProcW(hwnd, msg, wParam, lParam);
            const delta: f64 = @floatFromInt(@as(i16, @truncate(@as(isize, @bitCast(wParam)) >> 16)));
            const scroll_y = delta / 120.0; // WHEEL_DELTA = 120
            ghostty.ghostty_surface_mouse_scroll(surface, 0, scroll_y, 0);
            return 0;
        },
        WM_MOUSEHWHEEL => {
            const surface = g_surface orelse return wam.DefWindowProcW(hwnd, msg, wParam, lParam);
            const delta: f64 = @floatFromInt(@as(i16, @truncate(@as(isize, @bitCast(wParam)) >> 16)));
            const scroll_x = delta / 120.0; // WHEEL_DELTA = 120
            ghostty.ghostty_surface_mouse_scroll(surface, scroll_x, 0, 0);
            return 0;
        },
        wam.WM_SIZE => {
            const surface = g_surface orelse return wam.DefWindowProcW(hwnd, msg, wParam, lParam);
            const width: u32 = @intCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)))));
            const height: u32 = @intCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)) >> 16)));
            if (width > 0 and height > 0) {
                ghostty.ghostty_surface_set_size(surface, width, height);
            }
            return 0;
        },
        wam.WM_SETFOCUS => {
            if (g_surface) |surface| {
                ghostty.ghostty_surface_set_focus(surface, true);
            }
            return 0;
        },
        wam.WM_KILLFOCUS => {
            if (g_surface) |surface| {
                ghostty.ghostty_surface_set_focus(surface, false);
            }
            return 0;
        },
        WM_DPICHANGED => {
            const surface = g_surface orelse return wam.DefWindowProcW(hwnd, msg, wParam, lParam);
            const dpi: f32 = @floatFromInt(@as(u16, @truncate(wParam)));
            const scale = dpi / 96.0;
            ghostty.ghostty_surface_set_content_scale(surface, scale, scale);
            // Resize window to the suggested rectangle
            const rect: *const foundation.RECT = @ptrFromInt(@as(usize, @bitCast(lParam)));
            _ = wam.SetWindowPos(
                hwnd,
                null,
                rect.left,
                rect.top,
                rect.right - rect.left,
                rect.bottom - rect.top,
                @bitCast(@as(u32, 0x0004)), // SWP_NOZORDER
            );
            return 0;
        },
        WM_GETMINMAXINFO => {
            const mmi: *MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lParam)));
            const has_min = g_window_config.min_width > 0 or g_window_config.min_height > 0;
            const has_max = g_window_config.max_width > 0 or g_window_config.max_height > 0;
            if (has_min or has_max) {
                // Config values are client area dimensions; ptMinTrackSize/ptMaxTrackSize
                // are outer window dimensions. Adjust for decorations.
                const dpi = if (g_hwnd) |w| GetDpiForWindow(w) else 96;
                const GWL_STYLE: i32 = -16;
                const win_style: u32 = if (g_hwnd) |w| @bitCast(GetWindowLongW(w, GWL_STYLE)) else @bitCast(wam.WS_OVERLAPPEDWINDOW);
                if (has_min) {
                    var min_rect: foundation.RECT = .{
                        .left = 0,
                        .top = 0,
                        .right = if (g_window_config.min_width > 0) @intCast(g_window_config.min_width) else 0,
                        .bottom = if (g_window_config.min_height > 0) @intCast(g_window_config.min_height) else 0,
                    };
                    _ = AdjustWindowRectExForDpi(&min_rect, win_style, FALSE, 0, dpi);
                    if (g_window_config.min_width > 0)
                        mmi.ptMinTrackSize.x = min_rect.right - min_rect.left;
                    if (g_window_config.min_height > 0)
                        mmi.ptMinTrackSize.y = min_rect.bottom - min_rect.top;
                }
                if (has_max) {
                    var max_rect: foundation.RECT = .{
                        .left = 0,
                        .top = 0,
                        .right = if (g_window_config.max_width > 0) @intCast(g_window_config.max_width) else 0,
                        .bottom = if (g_window_config.max_height > 0) @intCast(g_window_config.max_height) else 0,
                    };
                    _ = AdjustWindowRectExForDpi(&max_rect, win_style, FALSE, 0, dpi);
                    if (g_window_config.max_width > 0)
                        mmi.ptMaxTrackSize.x = max_rect.right - max_rect.left;
                    if (g_window_config.max_height > 0)
                        mmi.ptMaxTrackSize.y = max_rect.bottom - max_rect.top;
                }
            }
            return 0;
        },
        WM_ERASEBKGND => {
            // Suppress GDI background erase — OpenGL handles all rendering
            return 1;
        },
        wam.WM_DESTROY => {
            wam.PostQuitMessage(0);
            return 0;
        },
        WM_USER => {
            // Wakeup message from ghostty — just break out of MsgWaitForMultipleObjects
            return 0;
        },
        else => return wam.DefWindowProcW(hwnd, msg, wParam, lParam),
    }
}

// Path resolution delegated to common module:
// common.common.getExeDir(), common.common.getBundledPath(), common.chdirToExeDir()

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
// Modern OpenGL context creation (GL 4.3 core via WGL)
// ---------------------------------------------------------------------------
fn createModernGLContext(hwnd: HWND) !struct { hdc: HDC, hglrc: HGLRC } {
    const hdc = gdi.GetDC(hwnd) orelse return error.GetDCFailed;

    // Step 1: Set a basic pixel format and create a legacy context
    var pfd: gl.PIXELFORMATDESCRIPTOR = std.mem.zeroes(gl.PIXELFORMATDESCRIPTOR);
    pfd.nSize = @sizeOf(gl.PIXELFORMATDESCRIPTOR);
    pfd.nVersion = 1;
    pfd.dwFlags = @bitCast(@as(u32, 0x00000004 | 0x00000020 | 0x00000001)); // PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER
    pfd.iPixelType = @enumFromInt(0); // PFD_TYPE_RGBA
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;
    pfd.cStencilBits = 8;

    const pf = ChoosePixelFormat(hdc, &pfd);
    if (pf == 0) return error.ChoosePixelFormatFailed;
    if (SetPixelFormat(hdc, pf, &pfd) == 0) return error.SetPixelFormatFailed;

    const legacy_ctx = wglCreateContext(hdc) orelse return error.WglCreateContextFailed;

    if (wglMakeCurrent(hdc, legacy_ctx) == 0) {
        _ = wglDeleteContext(legacy_ctx);
        return error.WglMakeCurrentFailed;
    }

    // Step 2: Load WGL extension functions
    const wglCreateContextAttribsARB: ?WglCreateContextAttribsARB = @ptrCast(wglGetProcAddress("wglCreateContextAttribsARB"));
    const wglChoosePixelFormatARB: ?WglChoosePixelFormatARB = @ptrCast(wglGetProcAddress("wglChoosePixelFormatARB"));

    if (wglCreateContextAttribsARB == null or wglChoosePixelFormatARB == null) {
        // No modern WGL — keep legacy context
        return .{ .hdc = hdc, .hglrc = legacy_ctx };
    }

    // Step 3: Destroy legacy context
    _ = wglMakeCurrent(null, null);
    _ = wglDeleteContext(legacy_ctx);

    // Step 4: Choose a modern pixel format
    const pixel_attribs = [_]i32{
        WGL_DRAW_TO_WINDOW_ARB, 1,
        WGL_SUPPORT_OPENGL_ARB, 1,
        WGL_DOUBLE_BUFFER_ARB,  1,
        WGL_PIXEL_TYPE_ARB,     WGL_TYPE_RGBA_ARB,
        WGL_COLOR_BITS_ARB,     32,
        WGL_DEPTH_BITS_ARB,     24,
        WGL_STENCIL_BITS_ARB,   8,
        0, // terminator
    };

    var modern_pf: i32 = 0;
    var num_formats: u32 = 0;
    if (wglChoosePixelFormatARB.?(hdc, &pixel_attribs, null, 1, &modern_pf, &num_formats) == 0 or num_formats == 0) {
        return error.WglChoosePixelFormatFailed;
    }

    // Step 5: Create GL 4.3 core context
    const context_attribs = [_]i32{
        WGL_CONTEXT_MAJOR_VERSION_ARB, 4,
        WGL_CONTEXT_MINOR_VERSION_ARB, 3,
        WGL_CONTEXT_PROFILE_MASK_ARB,  WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
        0, // terminator
    };

    const modern_ctx = wglCreateContextAttribsARB.?(hdc, null, &context_attribs) orelse {
        return error.WglCreateModernContextFailed;
    };

    if (wglMakeCurrent(hdc, modern_ctx) == 0) {
        _ = wglDeleteContext(modern_ctx);
        return error.WglMakeCurrentFailed;
    }

    return .{ .hdc = hdc, .hglrc = modern_ctx };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
pub fn main() !void {
    // When launched from a terminal (e.g. `just run`), re-attach to the
    // parent console so stdout/stderr remain visible for debugging.
    // Fails silently when double-clicked or launched from an installer shortcut.
    _ = AttachConsole(ATTACH_PARENT_PROCESS);

    // DPI awareness
    _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    // Load opengl32.dll for GL 1.1 function fallback in getProcAddress
    g_opengl32 = LoadLibraryA("opengl32.dll");

    // -- Change CWD to the exe's directory --
    common.chdirToExeDir();

    // -- Load manifest for window config --
    if (common.getBundledPath("trolley.toml")) |manifest_path| {
        var ghostty_len: usize = 0;
        _ = trolley.trolley_load_manifest(manifest_path.ptr, &g_window_config, &ghostty_len);
    }

    const precise_timer = g_window_config.win_precise_timer != 0;
    if (precise_timer) {
        _ = timeBeginPeriod(1);
    }

    // -- Load bundled environment variables (must precede ghostty_init) --
    common.loadBundledEnvironment();

    // -- Register bundled fonts (must precede ghostty_init) --
    registerBundledFonts();

    const initial_width: i32 = if (g_window_config.initial_width > 0) @intCast(g_window_config.initial_width) else 800;
    const initial_height: i32 = if (g_window_config.initial_height > 0) @intCast(g_window_config.initial_height) else 600;

    // -- Register window class --
    const hinstance: ?*anyopaque = GetModuleHandleW(null);
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("TrolleyWindow");

    const wc: wam.WNDCLASSW = .{
        .style = @bitCast(@as(u32, 0x0020)), // CS_OWNDC — private DC for persistent OpenGL context
        .lpfnWndProc = &windowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = @ptrCast(hinstance),
        .hIcon = null,
        .hCursor = wam.LoadCursorW(null, wam.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
    };

    if (wam.RegisterClassW(&wc) == 0) {
        return error.RegisterClassFailed;
    }

    // -- Determine window style based on resizable config --
    // WS_OVERLAPPEDWINDOW = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX
    var style: u32 = @bitCast(wam.WS_OVERLAPPEDWINDOW);
    if (g_window_config.resizable == 0) {
        // Remove resize grip (WS_THICKFRAME) and maximize button (WS_MAXIMIZEBOX)
        const WS_THICKFRAME: u32 = 0x00040000;
        const WS_MAXIMIZEBOX: u32 = 0x00010000;
        style &= ~WS_THICKFRAME;
        style &= ~WS_MAXIMIZEBOX;
    }

    // -- Create window --
    // Adjust for window decorations: CreateWindowExW takes outer dimensions,
    // but initial_width/height are intended as client area dimensions.
    var create_rect: foundation.RECT = .{ .left = 0, .top = 0, .right = initial_width, .bottom = initial_height };
    _ = AdjustWindowRectEx(&create_rect, style, FALSE, 0);

    const window_name = std.unicode.utf8ToUtf16LeStringLiteral("trolley");
    const hwnd = wam.CreateWindowExW(
        @bitCast(@as(u32, 0)), // no extended style
        class_name,
        window_name,
        @bitCast(style),
        @bitCast(@as(u32, 0x80000000)), // CW_USEDEFAULT
        @bitCast(@as(u32, 0x80000000)), // CW_USEDEFAULT
        create_rect.right - create_rect.left,
        create_rect.bottom - create_rect.top,
        null,
        null,
        @ptrCast(hinstance),
        null,
    ) orelse return error.CreateWindowFailed;

    g_hwnd = hwnd;

    // -- Create modern OpenGL context --
    const gl_ctx = try createModernGLContext(hwnd);
    g_hdc = gl_ctx.hdc;
    g_hglrc = gl_ctx.hglrc;

    // Enable vsync
    const wglSwapIntervalEXT: ?WglSwapIntervalEXT = @ptrCast(wglGetProcAddress("wglSwapIntervalEXT"));
    if (wglSwapIntervalEXT) |swapInterval| {
        _ = swapInterval(1);
    }

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
    g_app = app;

    // -- Create surface with OpenGL platform --
    var surface_config = ghostty.ghostty_surface_config_new();
    surface_config.platform_tag = ghostty.GHOSTTY_PLATFORM_OPENGL;
    surface_config.platform = .{
        .opengl = .{
            .get_proc_address = @ptrCast(&getProcAddress),
            .make_context_current = &makeContextCurrent,
            .swap_buffers = &swapBuffersCb,
            .gl_userdata = @ptrCast(g_hglrc),
        },
    };

    // DPI scale
    const dpi = GetDpiForWindow(hwnd);
    const scale: f32 = @as(f32, @floatFromInt(dpi)) / 96.0;
    surface_config.scale_factor = @floatCast(scale);

    const surface = ghostty.ghostty_surface_new(app, &surface_config);
    if (surface == null) {
        return error.GhosttySurfaceFailed;
    }
    g_surface = surface;

    // Set initial size from client area
    var rect: foundation.RECT = undefined;
    if (GetClientRect(hwnd, &rect) != 0) {
        const width: u32 = @intCast(rect.right - rect.left);
        const height: u32 = @intCast(rect.bottom - rect.top);
        if (width > 0 and height > 0) {
            ghostty.ghostty_surface_set_size(surface, width, height);
        }
    }

    ghostty.ghostty_surface_set_content_scale(surface, scale, scale);
    ghostty.ghostty_surface_set_focus(surface, true);

    // -- Show window --
    _ = wam.ShowWindow(hwnd, wam.SW_SHOW);

    // -- Event loop --
    var msg: wam.MSG = undefined;
    while (true) {
        while (wam.PeekMessageW(&msg, null, 0, 0, wam.PM_REMOVE) != 0) {
            if (msg.message == wam.WM_QUIT) break;
            _ = wam.TranslateMessage(&msg);
            _ = wam.DispatchMessageW(&msg);
        }
        if (msg.message == wam.WM_QUIT) break;

        ghostty.ghostty_app_tick(g_app);

        // Wait for next message or timeout (~16ms for 60fps)
        _ = MsgWaitForMultipleObjects(0, null, FALSE, 16, QS_ALLINPUT);
    }

    if (precise_timer) {
        _ = timeEndPeriod(1);
    }
    ExitProcess(0);
}

extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *foundation.RECT) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// wcwidth stub for Windows
// ---------------------------------------------------------------------------
// Ghostty's benchmark/CodepointWidth.zig declares `extern "c" fn wcwidth`,
// a POSIX function unavailable on Windows. The benchmark code is compiled
// into libghostty unconditionally via main_c.zig. Provide a stub so the
// linker resolves the symbol. The benchmark is never called at runtime.
pub export fn wcwidth(c: u32) callconv(.c) c_int {
    if (c == 0) return 0;
    if (c < 0x20 or (c >= 0x7f and c < 0xa0)) return -1;
    return 1;
}
