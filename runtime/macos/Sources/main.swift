import AppKit
import CGhostty
import CTrolley

// ---------------------------------------------------------------------------
// Global state (needed by C callbacks which don't carry user context)
// ---------------------------------------------------------------------------
var gWindow: NSWindow?
var gSurface: ghostty_surface_t?
var gApp: ghostty_app_t?
var gWindowConfig = TrolleyGuiConfig(
    initial_width: 0, initial_height: 0,
    resizable: 1, maximized: 0,
    min_width: 0, min_height: 0, max_width: 0, max_height: 0,
    win_precise_timer: 0
)

// ---------------------------------------------------------------------------
// Modifier translation
// ---------------------------------------------------------------------------
func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift)   { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option)  { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock){ mods |= GHOSTTY_MODS_CAPS.rawValue }
    return ghostty_input_mods_e(mods)
}

extension NSEvent {
    /// The text to attach to a key event for ghostty.
    ///
    /// Filters what raw `characters` reports for two cases ghostty handles
    /// itself in its key encoder:
    ///   - A single control character (ctrl+letter etc.): re-derive the
    ///     printable char by dropping ctrl from the translation, so the
    ///     legacy encoder's ctrlSeq/CSIu paths get text to work with.
    ///     Without this, ctrl+shift+letter encodes nothing at all — the
    ///     same bug class the linux/windows backends synthesize text for.
    ///   - A single private-use-area codepoint (arrows, F-keys, Home/End/
    ///     Delete/PageUp/PageDown report U+F700-F8FF): return nil, or the
    ///     kitty encoder's plain-text fast path types the raw PUA bytes
    ///     into kitty-protocol apps instead of encoding a CSI sequence.
    ///
    /// Only valid on key events (.keyDown/.keyUp): `characters` traps on
    /// other event types.
    var ghosttyCharacters: String? {
        // If we have no characters associated with this event we do nothing.
        guard let characters else { return nil }

        if characters.count == 1,
           let scalar = characters.unicodeScalars.first {
            // If we have a single control character, then we return the
            // characters without control pressed. We do this because we
            // handle control character encoding directly within ghostty's
            // key encoder.
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }

            // If we have a single value in the PUA, then it's a function
            // key and we don't want to send PUA ranges down to ghostty.
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }
}

// ---------------------------------------------------------------------------
// Ghostty runtime callbacks
// ---------------------------------------------------------------------------
func wakeupCallback(_ userdata: UnsafeMutableRawPointer?) {
    DispatchQueue.main.async {
        guard let app = gApp else { return }
        ghostty_app_tick(app)
    }
}

func actionCallback(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    switch action.tag {
    case GHOSTTY_ACTION_SET_TITLE:
        let title = String(cString: action.action.set_title.title)
        gWindow?.title = title
        return true

    case GHOSTTY_ACTION_QUIT:
        NSApp.terminate(nil)
        return true

    case GHOSTTY_ACTION_CLOSE_WINDOW:
        gWindow?.close()
        return true

    case GHOSTTY_ACTION_INITIAL_SIZE:
        let size = action.action.initial_size
        gWindow?.setContentSize(NSSize(
            width: CGFloat(size.width),
            height: CGFloat(size.height)
        ))
        return true

    case GHOSTTY_ACTION_SIZE_LIMIT:
        let limits = action.action.size_limit
        // Only override if the manifest didn't already set them.
        if gWindowConfig.min_width == 0 && limits.min_width > 0 {
            gWindowConfig.min_width = limits.min_width
        }
        if gWindowConfig.min_height == 0 && limits.min_height > 0 {
            gWindowConfig.min_height = limits.min_height
        }
        if gWindowConfig.max_width == 0 && limits.max_width > 0 {
            gWindowConfig.max_width = limits.max_width
        }
        if gWindowConfig.max_height == 0 && limits.max_height > 0 {
            gWindowConfig.max_height = limits.max_height
        }
        // Apply the (possibly merged) values
        gWindow?.minSize = NSSize(
            width: gWindowConfig.min_width > 0 ? CGFloat(gWindowConfig.min_width) : 0,
            height: gWindowConfig.min_height > 0 ? CGFloat(gWindowConfig.min_height) : 0
        )
        gWindow?.maxSize = NSSize(
            width: gWindowConfig.max_width > 0 ? CGFloat(gWindowConfig.max_width) : CGFloat.greatestFiniteMagnitude,
            height: gWindowConfig.max_height > 0 ? CGFloat(gWindowConfig.max_height) : CGFloat.greatestFiniteMagnitude
        )
        return true

    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
        return true

    default:
        return false
    }
}

func readClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ loc: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    guard let surface = gSurface else { return false }
    if let str = NSPasteboard.general.string(forType: .string) {
        str.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
        }
        return true
    }
    return false
}

func confirmReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ content: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    readClipboardCallback(userdata, GHOSTTY_CLIPBOARD_STANDARD, state)
}

func writeClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ loc: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ len: Int,
    _ confirm: Bool
) {
    guard let content, len > 0 else { return }
    let data = String(cString: content[0].data)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(data, forType: .string)
}

func closeSurfaceCallback(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {
    NSApp.terminate(nil)
}

// ---------------------------------------------------------------------------
// Path resolution — all resources are next to the executable
// ---------------------------------------------------------------------------
func getExeDir() -> String {
    let exe = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
    return (exe as NSString).deletingLastPathComponent
}

func getBundledPath(_ filename: String) -> String? {
    // Check Resources dir first (macOS .app bundle)
    if let resourcePath = Bundle.main.resourcePath {
        let path = (resourcePath as NSString).appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: path) { return path }
    }
    // Fall back to exe dir (flat layout / development)
    let path = (getExeDir() as NSString).appendingPathComponent(filename)
    return FileManager.default.fileExists(atPath: path) ? path : nil
}

// ---------------------------------------------------------------------------
// Font registration via CoreText
// ---------------------------------------------------------------------------
import CoreText

func registerBundledFonts() {
    let fm = FileManager.default

    // Check Resources dir first (macOS .app bundle), fall back to exe dir
    var fontsDir = (getExeDir() as NSString).appendingPathComponent("fonts")
    if let resourcePath = Bundle.main.resourcePath {
        let resourceFonts = (resourcePath as NSString).appendingPathComponent("fonts")
        if fm.fileExists(atPath: resourceFonts) { fontsDir = resourceFonts }
    }

    guard fm.fileExists(atPath: fontsDir) else { return }
    guard let files = try? fm.contentsOfDirectory(atPath: fontsDir) else { return }

    for file in files {
        let ext = (file as NSString).pathExtension.lowercased()
        guard ext == "ttf" || ext == "otf" else { continue }

        let fontPath = (fontsDir as NSString).appendingPathComponent(file)
        let fontURL = URL(fileURLWithPath: fontPath) as CFURL
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(fontURL, .process, &error) {
            fputs("trolley: warning: failed to register font \(file)\n", stderr)
        }
    }
}

// ---------------------------------------------------------------------------
// Environment loading
// ---------------------------------------------------------------------------

/// Read the bundled `environment` file and call setenv for each KEY=VALUE line.
/// Skips blank lines and lines starting with `#`.
func loadBundledEnvironment() {
    guard let path = getBundledPath("environment") else { return }
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return }
    for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
        let key = trimmed[trimmed.startIndex..<eqIdx].trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
        setenv(key, value, 1)
    }
}

// ---------------------------------------------------------------------------
// TrolleyView — NSView subclass that hosts the ghostty Metal surface
// ---------------------------------------------------------------------------
class TrolleyView: NSView, NSTextInputClient {
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    // Two-phase key input state
    private var keyTextAccumulator: [String]?

    // Marked (preedit) text from the input method. Non-empty means we're
    // mid-composition: dead-key accent or IME preedit. Composing events are
    // suppressed by the encoders — kitty passes only plain modifiers, legacy
    // drops everything — matching the GTK/Win32 preedit contract.
    private var markedText = NSMutableAttributedString()

    // Whether we last told libghostty we're focused. Fed by two sources —
    // window key state and first-responder state — last writer wins; the
    // cache dedupes them so set_focus is only sent on transitions. That's
    // sound only while this view is the window's sole, permanent first
    // responder; a second responder would need a real AND of both states.
    private var focused: Bool = false

    private func focusDidChange(_ focused: Bool) {
        guard let surface = gSurface else { return }
        guard self.focused != focused else { return }
        self.focused = focused

        if !focused {
            // Focus loss invalidates any in-flight composition, and the
            // input context is told so the IME's own state doesn't go stale.
            inputContext?.discardMarkedText()
            unmarkText()
        }

        ghostty_surface_set_focus(surface, focused)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Resize & DPI

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let surface = gSurface else { return }
        let backed = convertToBacking(newSize)
        if backed.width > 0 && backed.height > 0 {
            ghostty_surface_set_size(surface, UInt32(backed.width), UInt32(backed.height))
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface = gSurface else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        focusDidChange(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        focusDidChange(false)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // Cmd+tab / app activation changes window key state without touching
        // first responder, so the responder hooks alone never report focus
        // loss on app switch. Observe our window's key transitions directly.
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        center.addObserver(
            self, selector: #selector(windowKeyStateDidChange(_:)),
            name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(
            self, selector: #selector(windowKeyStateDidChange(_:)),
            name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func windowKeyStateDidChange(_ notification: Notification) {
        focusDidChange(window?.isKeyWindow ?? false)
    }

    // MARK: - Keyboard input

    override func keyDown(with event: NSEvent) {
        guard gSurface != nil else { return }
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Two-phase input: first send raw key, then use interpretKeyEvents
        // to get composed text from the input method.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        // Whether marked text existed before this event tells us if the event
        // cleared a composition without committing (e.g. Escape canceling a
        // dead key) — that keystroke must be suppressed too.
        let markedTextBefore = markedText.length > 0

        interpretKeyEvents([event])

        // Mirror the (possibly changed) marked text to ghostty's preedit so
        // the pending accent/preedit renders at the cursor.
        syncPreedit(clearIfNeeded: markedTextBefore)

        if let texts = keyTextAccumulator, !texts.isEmpty {
            // Committed text is never composing — it's the result of one.
            for text in texts {
                sendKey(action, event: event, text: text)
            }
        } else {
            sendKey(
                action, event: event, text: event.ghosttyCharacters,
                composing: markedText.length > 0 || markedTextBefore
            )
        }
    }

    override func keyUp(with event: NSEvent) {
        // The dead key's own release lands mid-composition and is
        // suppressed like its press.
        sendKey(GHOSTTY_ACTION_RELEASE, event: event, text: nil,
                composing: markedText.length > 0)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        let mods = ghosttyMods(event.modifierFlags)

        // If the modifier is still active it's a press — unless the event's
        // own side of the modifier is no longer down, in which case this is
        // the release of one side while the other side keeps the flag set.
        // Without this, releasing one of two held shifts sends a PRESS for
        // the released key and it appears stuck to report-events consumers.
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let sidePressed: Bool
            switch event.keyCode {
            case 0x38:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICELSHIFTKEYMASK) != 0
            case 0x3C:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3B:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICELCTLKEYMASK) != 0
            case 0x3E:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3A:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICELALTKEYMASK) != 0
            case 0x3D:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x37:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICELCMDKEYMASK) != 0
            case 0x36:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default:
                sidePressed = true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }

        sendKey(action, event: event, text: nil)
    }

    private func sendKey(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        text: String?,
        composing: Bool = false
    ) {
        guard let surface = gSurface else { return }

        var key_ev = ghostty_input_key_s()
        key_ev.action = action
        key_ev.keycode = UInt32(event.keyCode)
        key_ev.mods = ghosttyMods(event.modifierFlags)
        key_ev.consumed_mods = ghosttyMods(
            event.modifierFlags.subtracting([.control, .command])
        )
        key_ev.composing = composing
        key_ev.text = nil
        key_ev.unshifted_codepoint = 0

        // Set unshifted codepoint
        if event.type == .keyDown || event.type == .keyUp {
            if let chars = event.characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                key_ev.unshifted_codepoint = codepoint.value
            }
        }

        if let text, !text.isEmpty,
           let first = text.utf8.first, first >= 0x20 {
            text.withCString { ptr in
                key_ev.text = ptr
                _ = ghostty_surface_key(surface, key_ev)
            }
        } else {
            _ = ghostty_surface_key(surface, key_ev)
        }
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let chars: String
        switch string {
        case let s as NSAttributedString: chars = s.string
        case let s as String: chars = s
        default: return
        }

        // If insertText is called, our preedit is over.
        unmarkText()

        // Inside a keyDown the text is accumulated and sent with the key
        // event; outside one (e.g. IME candidate clicked with the mouse,
        // Character Viewer) there is no key event to attach it to.
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }

        guard let surface = gSurface else { return }
        chars.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(chars.utf8.count))
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: return
        }

        // Outside a keyDown (e.g. keyboard layout switched mid-composition)
        // nobody else will sync the preedit, so do it here.
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func selectedRange() -> NSRange { NSRange() }
    func markedRange() -> NSRange { markedText.length > 0 ? NSRange(0...(markedText.length - 1)) : NSRange() }
    func hasMarkedText() -> Bool { markedText.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface = gSurface, let window = self.window else { return .zero }

        // Ghostty tells us where the IME candidate window should render,
        // in top-left-origin view points; AppKit wants bottom-left screen coords.
        var x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        let viewRect = NSRect(x: x, y: frame.size.height - y, width: width, height: height)
        return window.convertToScreen(convert(viewRect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    /// Mirror markedText to libghostty's preedit so the pending
    /// accent/preedit renders at the cursor.
    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface = gSurface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            str.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(str.utf8.count))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    override func doCommand(by selector: Selector) {
        // Prevents NSBeep for unhandled key equivalents
    }

    // MARK: - Mouse input

    override func mouseDown(with event: NSEvent) {
        guard let surface = gSurface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, ghosttyMods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface = gSurface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, ghosttyMods(event.modifierFlags))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface = gSurface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, ghosttyMods(event.modifierFlags))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface = gSurface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, ghosttyMods(event.modifierFlags))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface = gSurface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, ghosttyMods(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface = gSurface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, ghosttyMods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface = gSurface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, Double(pos.x), Double(frame.height - pos.y), ghosttyMods(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface = gSurface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            x *= 2
            y *= 2
        }
        var mods: Int32 = 0
        if precision { mods |= 0b0000_0001 }
        // Momentum phase in bits 1-3
        let momentum: UInt8
        switch event.momentumPhase {
        case .began: momentum = 1
        case .stationary: momentum = 2
        case .changed: momentum = 3
        case .ended: momentum = 4
        case .cancelled: momentum = 5
        case .mayBegin: momentum = 6
        default: momentum = 0
        }
        mods |= Int32(momentum) << 1
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }
}

// ---------------------------------------------------------------------------
// Application menu
// ---------------------------------------------------------------------------
// Build a minimal application menu so the packaged app has the expected macOS
// menu bar: an app menu with the standard "About <App>" panel and Quit. The app
// name is read from the bundle's Info.plist (CFBundleDisplayName / CFBundleName)
// so it matches the packaged product name, falling back to plain labels for
// unbundled `trolley run` invocations. The About item uses AppKit's standard
// panel, which reads the name/version/icon straight from the Info.plist.
func buildMainMenu() -> NSMenu {
    let appName = (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String)
        ?? (Bundle.main.infoDictionary?["CFBundleName"] as? String)

    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)

    let appMenu = NSMenu()
    appMenu.addItem(
        withTitle: appName.map { "About \($0)" } ?? "About",
        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
        keyEquivalent: ""
    )
    appMenu.addItem(.separator())
    appMenu.addItem(
        withTitle: appName.map { "Quit \($0)" } ?? "Quit",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )
    appMenuItem.submenu = appMenu

    return mainMenu
}

// ---------------------------------------------------------------------------
// AppDelegate
// ---------------------------------------------------------------------------
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // -- Set CWD to exe dir so relative paths (e.g. command = direct:./<slug>_core) resolve --
        FileManager.default.changeCurrentDirectoryPath(getExeDir())

        // -- Load manifest for window config --
        if let manifestPath = getBundledPath("trolley.toml") {
            var ghosttyLen: Int = 0
            manifestPath.withCString { ptr in
                _ = trolley_load_manifest(ptr, &gWindowConfig, &ghosttyLen)
            }
        }

        // -- Load bundled environment variables (must precede ghostty_init) --
        loadBundledEnvironment()

        // -- Register bundled fonts --
        registerBundledFonts()

        // -- Ghostty init --
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            fputs("trolley: ghostty_init failed\n", stderr)
            exit(1)
        }

        guard let config = ghostty_config_new() else {
            fputs("trolley: ghostty_config_new failed\n", stderr)
            exit(1)
        }

        // Load bundled ghostty.conf next to the executable.
        if let path = getBundledPath("ghostty.conf") {
            path.withCString { ptr in
                ghostty_config_load_file(config, ptr)
            }
        }
        ghostty_config_finalize(config)

        // -- Create app --
        var runtimeConfig = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: wakeupCallback,
            action_cb: actionCallback,
            read_clipboard_cb: readClipboardCallback,
            confirm_read_clipboard_cb: confirmReadClipboardCallback,
            write_clipboard_cb: writeClipboardCallback,
            close_surface_cb: closeSurfaceCallback
        )

        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            ghostty_config_free(config)
            fputs("trolley: ghostty_app_new failed\n", stderr)
            exit(1)
        }
        ghostty_config_free(config)
        gApp = app

        // -- Create window --
        let initialWidth = gWindowConfig.initial_width > 0 ? CGFloat(gWindowConfig.initial_width) : 800
        let initialHeight = gWindowConfig.initial_height > 0 ? CGFloat(gWindowConfig.initial_height) : 600

        var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if gWindowConfig.resizable != 0 {
            styleMask.insert(.resizable)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "trolley"

        // Min/max size limits (each dimension independent)
        if gWindowConfig.min_width > 0 || gWindowConfig.min_height > 0 {
            window.minSize = NSSize(
                width: gWindowConfig.min_width > 0 ? CGFloat(gWindowConfig.min_width) : 0,
                height: gWindowConfig.min_height > 0 ? CGFloat(gWindowConfig.min_height) : 0
            )
        }
        if gWindowConfig.max_width > 0 || gWindowConfig.max_height > 0 {
            window.maxSize = NSSize(
                width: gWindowConfig.max_width > 0 ? CGFloat(gWindowConfig.max_width) : CGFloat.greatestFiniteMagnitude,
                height: gWindowConfig.max_height > 0 ? CGFloat(gWindowConfig.max_height) : CGFloat.greatestFiniteMagnitude
            )
        }

        window.center()

        // Zoom after center() so un-zoom restores the centered frame.
        if gWindowConfig.maximized == 1 {
            window.zoom(nil)
        }

        gWindow = window

        // -- Create view and surface --
        let view = TrolleyView(frame: window.contentView!.bounds)
        view.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(view)
        window.makeFirstResponder(view)

        // Accept mouse move events
        window.acceptsMouseMovedEvents = true

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        surfaceConfig.scale_factor = window.backingScaleFactor

        guard let surface = ghostty_surface_new(app, &surfaceConfig) else {
            fputs("trolley: ghostty_surface_new failed\n", stderr)
            exit(1)
        }
        gSurface = surface

        // Set initial size
        let backed = view.convertToBacking(view.bounds.size)
        ghostty_surface_set_size(surface, UInt32(backed.width), UInt32(backed.height))
        ghostty_surface_set_content_scale(surface, Double(window.backingScaleFactor), Double(window.backingScaleFactor))
        ghostty_surface_set_focus(surface, true)

        // -- Install the application menu --
        NSApp.mainMenu = buildMainMenu()

        // -- Show window --
        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------
let delegate = AppDelegate()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
