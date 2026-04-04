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
    initial_width: 0, initial_height: 0, resizable: -1,
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
    private var pendingKeyEvent: ghostty_input_key_s?
    private var keyTextAccumulator: [String]?

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
        gSurface.map { ghostty_surface_set_focus($0, true) }
        return true
    }

    override func resignFirstResponder() -> Bool {
        gSurface.map { ghostty_surface_set_focus($0, false) }
        return true
    }

    // MARK: - Keyboard input

    override func keyDown(with event: NSEvent) {
        guard let surface = gSurface else { return }
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Two-phase input: first send raw key, then use interpretKeyEvents
        // to get composed text from the input method.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        interpretKeyEvents([event])

        if let texts = keyTextAccumulator, !texts.isEmpty {
            for text in texts {
                sendKey(action, event: event, text: text)
            }
        } else {
            sendKey(action, event: event, text: event.characters)
        }
    }

    override func keyUp(with event: NSEvent) {
        sendKey(GHOSTTY_ACTION_RELEASE, event: event, text: nil)
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
        let action = (mods.rawValue & mod != 0) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        sendKey(action, event: event, text: nil)
    }

    private func sendKey(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        text: String?
    ) {
        guard let surface = gSurface else { return }

        var key_ev = ghostty_input_key_s()
        key_ev.action = action
        key_ev.keycode = UInt32(event.keyCode)
        key_ev.mods = ghosttyMods(event.modifierFlags)
        key_ev.consumed_mods = ghosttyMods(
            event.modifierFlags.subtracting([.control, .command])
        )
        key_ev.composing = false
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

        keyTextAccumulator?.append(chars)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    func unmarkText() {}
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { false }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
    func characterIndex(for point: NSPoint) -> Int { 0 }

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
        if gWindowConfig.resizable != 0 {  // -1 (unset) or 1 (true) → resizable
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
