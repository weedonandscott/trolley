# Changelog

## Unreleased

### Runtime

- [linux] Strip debug info from release builds, cutting the binary from 126 MB
        to 31 MB; in exchange a release panic prints no stack trace at all, and
        the symbol table is gone for gdb and perf

### CLI

- [windows] Fix icon globs silently matching nothing since 0.10.0, which left
        desktop, Start menu and taskbar shortcuts on the generic icon
- [windows] Sanity test now packages with an icon and asserts both `app.ico` in
        the bundle and a non-zero icon count on the stamped runtime exe
- [macos] Fix release binaries linking Homebrew's `liblzma.dylib`, which is
        absent on end-user machines: liblzma is now compiled into the CLI
        (`xz2`'s `static` feature)
- [macos] Pin the CLI's minimum macOS to rustc's own defaults per target (10.12
        on x86_64, 11.0 on arm64) and assert it in CI, so a toolchain update
        can't raise the floor unnoticed
- [all] CI: new `just check-linkage --target <triple>` runs on every release
        target and fails if the CLI depends on anything only the build machine
        has
- [all] CI: `check-linkage` now also checks the runtime (`--cli` / `--runtime`
        select one, neither means both) and fails on a build-machine path in its
        ELF interpreter or RPATH/RUNPATH, on a `DT_NEEDED` soname beyond a base
        glibc system, on a Mach-O `LC_RPATH`, or on a `dlopen` path — which no
        link metadata records
- [all] CI: unit tests now run on macOS and Windows as well as Linux
- [all] Test the `.tar.xz` decode the runtime download depends on

## 0.10.0

### CLI

- [all] **BREAKING:** derive package filenames from the trolley config.
        Previously decided by `cargo-packager` (which carried the internal
        `_runtime` suffix on Windows). Installers use the display name (`My_App_1.2.3_x86_64-setup.exe`),
        package-manager artifacts the slug (`myapp_1.2.3_amd64.deb`). pacman
        still delegated to `cargo-packager` since there's PKGBUILD <> tarball
        coordination there. Full scheme in README → Artifact naming.
- [all] **BREAKING:** Validate `display_name` at config load: reject path
        separators, control characters, and Windows-reserved filename characters
- [all] `dist/` no longer contains the `.cargo-packager` intermediates directory
        packaging runs in a staging dir and only finished artifacts are moved in
- [all] Fix icon globs resolving against the process working directory instead
        of the project directory (RPM icons were silently dropped when packaging
        from elsewhere), and escape glob metacharacters in the project path
        (e.g. a directory named `app [beta]`)
- [all] CI: releases are now gated on the test suite, and per-target sanity runs
        diff the packaged `dist/` listing against committed snapshots (`tests/sanity/listings/`)
        and verify icons are embedded in Linux packages
- [linux] Fix RPM packaging failing on prerelease versions: hyphens in
        `app.version` (e.g. ) are illegal in the RPM Version
        header, so they are encoded as `~` (`1.2.3-beta.1` -> `1.2.3~beta.1`)
        Filenames keep the configured version verbatim

## 0.9.0

### Runtime

- [macos] Add IME and dead-key support: preedit (marked text) now renders at the cursor and the candidate window is positioned correctly; committed text is delivered whether finished by keyboard or clicked with the mouse
- [macos] Fix focus tracking so switching away with Cmd+Tab reports focus loss (previously only first-responder changes did)
- [macos] Fix releasing one of two held modifiers (e.g. one of two Shifts) reporting a press, leaving the modifier stuck for kitty-protocol apps
- [macos] Fix ctrl+shift+letter encoding nothing, and arrow/function keys typing raw private-use bytes into kitty-protocol apps
- [windows] Fix dead-key sequences: the pending accent is now held during composition and committed on the finishing key, including dead-then-dead (e.g. two accents) and accents flushed by Enter/Backspace/Escape
- [linux] Deliver input-method commits from async IMEs (ibus, fcitx over X11) that arrive after the keystroke, including multi-codepoint (CJK) commits
- [linux] Fix a cancelled Compose/dead-key sequence swallowing its terminating key on setups with no external input method

## 0.8.0

### Runtime

- [macos] Add a minimal application menu with a standard About panel and Quit (#35)
- [windows, linux] Fix shifted symbols typing the unshifted character (e.g. shift+1 producing "1" instead of "!") in apps using the kitty keyboard protocol (#36)
- [windows, linux] Fix composed input (dead keys, Compose, input methods) reporting wrong key codes to kitty-protocol apps, and no longer drop the keystroke when its text can't be encoded (#36)
- [windows, linux] Fix modified space chords: ctrl/alt+space were dropped entirely and shift+space lost its modifier in apps using the kitty keyboard protocol (#36)

## 0.7.0

### Runtime

- [windows] Add precise timer (#26)
- [windows] Fix exe icon embedding / WM_SETICON safe-build panic (#28)
- [windows] Update zigwin32 (#33)

### CLI

- [all] Add `[embeds]` config: embeddable theme, custom shaders, embedded data paths (#23)
- [all] Support per-platform CLI arguments for the bundled TUI (#25)
- [windows] Embed icons into the runtime exe (#28)
- [windows, macos] Add code signing support (#32)
- [all] Update Rust dependencies (#33)

## 0.6.1

### Runtime

- [windows] Fix console window showing in packaged apps (#19)

### CLI

- [all] improve icon handling (#19)
- [windows] Fix packager failing on missing TLS dependency (#19)

## 0.6.0

### Runtime

- [all] Pass key modifiers to the running TUI (#15)
- [all] Update Ghostty (#16)
- [windows] Fix runtime on windows so it launches (#16)

### CLI

- [all] Ensure Ghostty working directory is cwd (#13)
- [all] The `[ghostty]` config now expands arrays into repeated key lines. (#15)
  For example, the following:

  ```toml
  [ghostty]
  keybind = [
      "ctrl+==increase_font_size:1",
      "ctrl+-=decrease_font_size:1",
  ]
  ```

  produces:

  ```
  keybind = ctrl+==increase_font_size:1
  keybind = ctrl+-=decrease_font_size:1
  ```

## 0.5.0

### Runtime

- [all] Allow Ghostty config to override `command` (#5)

### CLI

- [macos] Fix CLI linked to nix store paths (#7)

## 0.4.2

### Runtime

_No changes_

### CLI

- [linux] Statically link CLI binary

## 0.4.1

### Runtime

- [linux] Fix build

### CLI

_No changes_

## 0.4.0

### Runtime

- [linux] Add Wayland support

### CLI

_No changes_

## 0.3.1

### Runtime

- [linux] Dependency fix

### CLI

_No changes_

## 0.3.0

### Runtime

- [linux] Statically link

### CLI

_No changes_

## 0.2.0

### Runtime

- Initial release

### CLI

- Initial release
