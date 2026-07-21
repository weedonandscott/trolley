# Changelog

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
