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
    .maximized = -1,
    .min_width = 0,
    .min_height = 0,
    .max_width = 0,
    .max_height = 0,
    .win_precise_timer = 0,
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
// Key input delivers text along one of three paths:
//
// Deferral-attach (plain typing): keyCallback withholds printable
// press/repeat events with no ctrl/alt/super; charCallback — invoked by
// GLFW synchronously right after, in the same OS event — attaches the
// layout-produced text plus consumed_mods and sends once. A deferred
// press whose char never arrives (dead key, Compose middle key, an
// IM-filtered press) is sent textless — and marked composing, so the
// encoders suppress it — by flushDeferred at the next keyCallback or
// after glfwWaitEvents, then parked. Under g_sync_compose (no external
// IM, chars synchronous) a flush that lands while already composing is
// instead delivered non-composing as the compose terminator (repeats of
// the composing key excepted).
//
// Standalone commit (composing text, sync or async): a char arriving
// while composing — a dead-key finish, or an ibus/fcitx commit delivered
// in a later batch — is sent as a fabricated keycode-less press carrying
// only the text, and the suppressed press it finishes is swallowed. This
// is ghostty GTK's imCommit contract: committed text rides a key event
// only for plain typing, never for a composition commit, so no keycode
// can ever be misattributed. Remaining codepoints of a multi-codepoint
// commit (CJK) follow via g_commit_burst. The swallowed press's release
// still encodes under kitty report_events — GTK has the same asymmetry.
//
// Retry-attach (fallback): everything else is sent immediately (ctrl
// combos with synthesized text, other keys textless). If ghostty reports
// the event not consumed, it is parked; a non-composing charCallback with
// no deferred press re-sends the parked event with that text.
// ---------------------------------------------------------------------------
var g_pending_key_event: ?ghostty.ghostty_input_key_s = null;
var g_pending_text_buf: [5]u8 = undefined;
var g_key_text_buf: [5]u8 = undefined;

/// Press/repeat withheld from ghostty until charCallback supplies text.
/// GLFW invokes the char callback synchronously right after the key
/// callback, within the same OS event, so a deferred press is completed
/// (or flushed) before the next key event.
var g_deferred_key_event: ?ghostty.ghostty_input_key_s = null;

/// True while the input pipeline holds composition state for a swallowed
/// printable press (dead key, Compose middle key, IM preedit). Composing
/// events are suppressed by the encoders — kitty passes only plain
/// modifiers, legacy drops everything — matching the GTK preedit contract.
/// g_composing_keycode records the keycode of the flush that set it.
var g_composing: bool = false;

/// True after a composition commit was delivered standalone; admits the
/// remaining codepoints of a multi-codepoint commit (CJK) to the same
/// path. Cleared on the next key press/repeat and on focus loss.
var g_commit_burst: bool = false;
/// Dedicated buffer (not g_pending_text_buf) so a burst send can never
/// clobber text belonging to a still-parked event.
var g_commit_text_buf: [5]u8 = undefined;

/// True when GLFW's compose pipeline is synchronous — native Wayland
/// (GLFW has no IM integration there; chars come from in-process
/// xkb-compose) or X11 with no external XIM configured. Under this gate
/// a deferred press whose char never arrived in its batch will NEVER
/// receive one later, so a flush-while-already-composing is a compose
/// terminator, not an in-flight IM keystroke. Under an external IM
/// (XMODIFIERS=@im=fcitx etc.) chars are async and every printable
/// flushes textless — the same condition would fire on fast typing and
/// double-deliver once the async char lands, so the gate MUST stay off.
/// Computed once after glfwInit, before loadBundledEnvironment mutates
/// the environment libX11 read.
var g_sync_compose: bool = false;

/// Keycode of the press whose flush most recently set g_composing;
/// lets a held dead key's repeats (same keycode, REPEAT action) stay
/// suppressed instead of leaking through the terminator rule.
var g_composing_keycode: u32 = 0;

/// Dedicated buffer for terminator-synthesized text (mirrors the
/// g_commit_text_buf precedent: never alias a buffer a parked event
/// might still point at).
var g_terminator_text_buf: [5]u8 = undefined;

/// XIM discovery mirror: libX11 reaches an external server only via
/// XMODIFIERS "@im=<name>"; empty, "none" and "local" mean the built-in
/// input method. Returns false on non-X11 platforms.
fn detectExternalXim() bool {
    if (glfw.glfwGetPlatform() != glfw.GLFW_PLATFORM_X11) return false;
    const xmods = std.posix.getenv("XMODIFIERS") orelse return false;
    const idx = std.mem.indexOf(u8, xmods, "@im=") orelse return false;
    const rest = xmods[idx + "@im=".len ..];
    const end = std.mem.indexOfScalar(u8, rest, '@') orelse rest.len;
    const name = rest[0..end];
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, "none")) return false;
    if (std.mem.eql(u8, name, "local")) return false;
    return true;
}

/// Deliver committed IM text standalone, mirroring ghostty GTK's imCommit
/// composing/out-of-keyevent path: a press with an unmapped keycode
/// (-> .unidentified), no mods, no unshifted codepoint, composing=false.
/// Both encoders emit the utf8 raw (key_encode.zig kitty fallback /
/// legacy tail), in every kitty flag combination.
fn sendCommitText(codepoint: c_uint) void {
    const surface = g_surface orelse return;
    const cp: u21 = std.math.cast(u21, codepoint) orelse return;
    const len = std.unicode.utf8Encode(cp, &g_commit_text_buf) catch return;
    if (len < g_commit_text_buf.len) g_commit_text_buf[len] = 0;
    _ = ghostty.ghostty_surface_key(surface, .{
        .action = ghostty.GHOSTTY_ACTION_PRESS,
        .mods = ghostty.GHOSTTY_MODS_NONE,
        .consumed_mods = ghostty.GHOSTTY_MODS_NONE,
        .keycode = 0, // matches no real key -> input.Key.unidentified
        .text = &g_commit_text_buf,
        .unshifted_codepoint = 0,
        .composing = false,
    });
}

/// Send a deferred press whose charCallback never fired. The deferral
/// predicate admits only printable, modifier-free presses, so a missing
/// char means the input pipeline swallowed it: dead key, Compose middle
/// key, or an IM-filtered press — all composition, all suppressed via
/// composing=true. The event is parked unconditionally for the retry
/// path: async IMs (ibus/fcitx over X11) deliver the commit char in a
/// later batch, and a suppressed composing event's consumed result says
/// nothing about whether that retry will be needed. Exception: under
/// g_sync_compose a flush while already composing takes the terminator
/// branch — delivered with text, not parked.
fn flushDeferred() void {
    var key_event = g_deferred_key_event orelse return;
    g_deferred_key_event = null;
    const surface = g_surface orelse return;

    // Sync-compose terminator (g_sync_compose): a textless flush while
    // ALREADY composing means GLFW's compose layer swallowed this key's
    // char — a cancelled sequence's terminating key. Its char will never
    // arrive (chars are synchronous under the gate), so suppressing it
    // as composing would eat the keystroke outright; deliver it
    // non-composing with its own codepoint instead (restores master's
    // bare-q; the swallowed accent is unrecoverable, GLFW discards it).
    // Accepted cost: middle keys of 3+-key Compose sequences leak.
    if (g_sync_compose and g_composing) {
        // Held-dead-key repeats re-flush textless while composing but
        // terminate nothing: same keycode that started the composition,
        // REPEAT action. Keep today's suppression for those.
        if (key_event.action == ghostty.GHOSTTY_ACTION_REPEAT and
            key_event.keycode == g_composing_keycode)
        {
            key_event.composing = true;
            _ = ghostty.ghostty_surface_key(surface, key_event);
            g_pending_key_event = key_event;
            return;
        }

        g_composing = false;
        key_event.composing = false;
        // Synthesize the key's own text (same shape as the ctrl-combo
        // synthesis in keyCallback); on encode failure send textless —
        // kitty still CSIu-encodes it from unshifted_codepoint (the
        // master behavior this branch restores).
        text: {
            var cp: u21 = std.math.cast(u21, key_event.unshifted_codepoint) orelse break :text;
            const shifted = (key_event.mods & ghostty.GHOSTTY_MODS_SHIFT) != 0;
            if (shifted and cp >= 'a' and cp <= 'z') cp = cp - 'a' + 'A';
            const len = std.unicode.utf8Encode(cp, &g_terminator_text_buf) catch break :text;
            if (len < g_terminator_text_buf.len) g_terminator_text_buf[len] = 0;
            key_event.text = &g_terminator_text_buf;
            if (cp != key_event.unshifted_codepoint) {
                key_event.consumed_mods = key_event.mods &
                    (ghostty.GHOSTTY_MODS_SHIFT | ghostty.GHOSTTY_MODS_CAPS);
            }
        }
        _ = ghostty.ghostty_surface_key(surface, key_event);
        // Deliberately NOT parked: it was delivered with text; parking
        // would let a stray char double-deliver it via rule 3.
        return;
    }

    g_composing = true;
    g_composing_keycode = key_event.keycode;
    key_event.composing = true;
    _ = ghostty.ghostty_surface_key(surface, key_event);
    g_pending_key_event = key_event;
}

/// A bare modifier keysym (shift/ctrl/alt/super/caps). Its press reaches
/// the immediate path but is transparent to composition: pressing Shift
/// to type a capital while a dead key is pending must not cancel the
/// pending compose (unlike Enter/Escape/a letter, which legitimately
/// terminate it). Used to gate the composing-clear at the immediate path.
fn isModifierKey(glfw_key: c_int) bool {
    return switch (glfw_key) {
        glfw.GLFW_KEY_LEFT_SHIFT,
        glfw.GLFW_KEY_RIGHT_SHIFT,
        glfw.GLFW_KEY_LEFT_CONTROL,
        glfw.GLFW_KEY_RIGHT_CONTROL,
        glfw.GLFW_KEY_LEFT_ALT,
        glfw.GLFW_KEY_RIGHT_ALT,
        glfw.GLFW_KEY_LEFT_SUPER,
        glfw.GLFW_KEY_RIGHT_SUPER,
        glfw.GLFW_KEY_CAPS_LOCK,
        => true,
        else => false,
    };
}

fn keyCallback(
    _: ?*glfw.GLFWwindow,
    glfw_key: c_int,
    scancode: c_int,
    glfw_action: c_int,
    glfw_mods: c_int,
) callconv(.c) void {
    // Complete any leftover deferred press before handling a new key.
    flushDeferred();

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
        // glfwGetKeyName's key filter (input.c) returns NULL for
        // GLFW_KEY_SPACE even though its unshifted character is
        // well-defined. Without a codepoint the kitty encoder has no
        // entry for space, so modified-space chords (ctrl/alt+space)
        // encode nothing and get dropped.
        if (glfw_key == glfw.GLFW_KEY_SPACE) break :uc 0x20;
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
        // A release built right after flushDeferred marked a composition
        // (most commonly the flushed key's own release) is suppressed with
        // it. Presses always start out non-composing here: the deferral or
        // flushDeferred decides otherwise.
        .composing = if (action == ghostty.GHOSTTY_ACTION_RELEASE) g_composing else false,
    };

    // Clear any previous pending event and commit burst — press/repeat
    // only: a release (most commonly the flushed key's own) must not
    // destroy a parked retry, and raw releases can interleave the chars
    // of a multi-codepoint commit burst.
    if (action != ghostty.GHOSTTY_ACTION_RELEASE) {
        g_pending_key_event = null;
        g_commit_burst = false;
    }

    // Defer printable, modifier-free presses until charCallback supplies
    // the layout text. Sending them textless would let the kitty encoder
    // consume the press (from unshifted_codepoint alone), so the retry
    // below never fires and shifted symbols like shift+1 → "!" get lost.
    if ((action == ghostty.GHOSTTY_ACTION_PRESS or
        action == ghostty.GHOSTTY_ACTION_REPEAT) and
        (glfw_mods & (glfw.GLFW_MOD_CONTROL | glfw.GLFW_MOD_ALT | glfw.GLFW_MOD_SUPER)) == 0 and
        unshifted_codepoint >= 0x20)
    {
        g_deferred_key_event = key_event;
        return;
    }

    // Press/repeat only: keys reaching the immediate path either resolve
    // or are unaffected by composition, so a press/repeat retires the
    // composing flag — a stuck false positive still can't eat Enter or
    // Escape. Releases must NOT clear it: after a flushed dead key or
    // IM finisher, the async commit chars race the finisher's own
    // release over the input-method round-trip, and a release-time
    // clear would drop the commit at charCallback rule 5. It would also
    // let a dead key's own release (arriving between the flush and the
    // finishing char) demote the finish from the standalone rule-1 send
    // to a keycode-attached rule-2 send. Bare modifier presses are also
    // exempt: pressing Shift to reach a capital while a dead key is
    // pending (e.g. `'` then Shift+Q) must keep the composition alive so
    // the terminator can deliver Q — clearing here would strand the
    // still-deferred letter on the suppressing normal path.
    if (action != ghostty.GHOSTTY_ACTION_RELEASE and !isModifierKey(glfw_key))
        g_composing = false;

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

    // Rule 1 — composition commit. A char arriving while composing is the
    // commit of the suppressed press (sync dead-key finish, or async
    // ibus/fcitx commit from a later batch). GTK contract: deliver it
    // standalone, never attached to a keycode; the finishing press (open
    // deferral) is swallowed like GTK swallows it (keyEvent early return),
    // and the parked suppressed press is retired — its commit has landed.
    if (g_composing) {
        g_composing = false;
        g_deferred_key_event = null;
        g_pending_key_event = null;
        g_commit_burst = true;
        sendCommitText(codepoint);
        return;
    }

    // Rule 2 — plain typing: complete a press deferred by keyCallback in
    // this same OS event; the codepoint here is the layout-produced text
    // for that press.
    if (g_deferred_key_event) |deferred| {
        g_deferred_key_event = null;
        var key_event = deferred;

        // If the codepoint can't be encoded, send the press textless: the
        // keystroke is still valid, only the text half failed. Unlike
        // flushDeferred we don't park a not-consumed result — the char
        // already arrived and was garbage, there is nothing to retry with.
        text: {
            const cp: u21 = std.math.cast(u21, codepoint) orelse break :text;
            const len = std.unicode.utf8Encode(cp, &g_pending_text_buf) catch break :text;
            if (len < g_pending_text_buf.len) {
                g_pending_text_buf[len] = 0;
            }

            key_event.text = &g_pending_text_buf;
            // Shift/caps were consumed by the translation only if they
            // actually changed the produced character (shift+1 → "!").
            // If the char equals the unshifted codepoint (shift+space
            // → " "), claiming consumption would strip the modifier and
            // ghostty would send plain text instead of a CSI sequence.
            // Keep the press-time unshifted_codepoint: overwriting it
            // with the shifted char would corrupt kitty/CSIu key codes.
            if (codepoint != key_event.unshifted_codepoint) {
                key_event.consumed_mods = key_event.mods &
                    (ghostty.GHOSTTY_MODS_SHIFT | ghostty.GHOSTTY_MODS_CAPS);
            }
        }
        _ = ghostty.ghostty_surface_key(surface, key_event);
        return;
    }

    // Rule 3 — non-composing retry: a parked immediate-path press (e.g.
    // super+letter sent textless and not consumed) gets its synchronous
    // char attached. (Not alt/ctrl+letter: GLFW's `plain` gating skips
    // charCallback entirely when ctrl or alt is held.)
    if (g_pending_key_event) |pending| {
        g_pending_key_event = null;
        var key_event = pending;

        // Encode the codepoint as UTF-8 into our persistent buffer.
        const cp: u21 = std.math.cast(u21, codepoint) orelse return;
        const len = std.unicode.utf8Encode(cp, &g_pending_text_buf) catch return;

        // Null-terminate for the C API (ghostty expects a C string).
        if (len < g_pending_text_buf.len) {
            g_pending_text_buf[len] = 0;
        }

        // Update the key event with the real text. Keep the press-time
        // unshifted_codepoint: overwriting it with the produced char would
        // corrupt kitty/CSIu key codes.
        key_event.text = &g_pending_text_buf;

        // Re-send the key event to ghostty with the text populated.
        _ = ghostty.ghostty_surface_key(surface, key_event);
        return;
    }

    // Rule 4 — remainder of a multi-codepoint commit, or text injected
    // with no keystroke at all since the commit began.
    if (g_commit_burst) {
        sendCommitText(codepoint);
        return;
    }

    // Rule 5 — no context (e.g. char whose press was consumed as a
    // keybind): drop.
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
    // Focus loss invalidates any in-flight composition: a commit arriving
    // after refocus must not attach to a pre-blur press, and a stale burst
    // must not leak text past it. The open deferral is left alone — it
    // belongs to a keystroke in the current batch and the main-loop
    // flushDeferred handles it. Note that flush can then re-park the
    // pre-blur press and re-set g_composing after this clear; the
    // no-stale-attach guarantee still holds because composing routes any
    // late char to the standalone-commit rule, never the parked retry.
    if (focused != glfw.GLFW_TRUE) {
        g_composing = false;
        g_pending_key_event = null;
        g_commit_burst = false;
    }
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

    // After glfwInit (platform decided; the XIM connection, if any, is
    // made from the current environment) and before loadBundledEnvironment
    // below can mutate that environment.
    g_sync_compose = !detectExternalXim();

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

    // Maximized hint (must be set before window creation)
    if (g_window_config.maximized == 1) {
        glfw.glfwWindowHint(glfw.GLFW_MAXIMIZED, glfw.GLFW_TRUE);
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

    // -- Event loop --
    while (glfw.glfwWindowShouldClose(window) != glfw.GLFW_TRUE) {
        ghostty.ghostty_app_tick(app);
        glfw.glfwWaitEvents();
        // Complete any press whose charCallback never fired within the
        // batch just processed (dead keys, XIM-filtered presses).
        flushDeferred();
    }

    // Exit immediately. Ghostty's Surface.deinit assumes the GL context
    // can be re-acquired (catch unreachable), but on Wayland/EGL the
    // context becomes invalid once the window is closing. The OS reclaims
    // all resources on process exit.
    std.process.exit(0);
}
