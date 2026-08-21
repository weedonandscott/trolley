> NOTE: This software is _pre-alpha_. Functionality and design expected to be broken.

# Trolley

**Run terminal apps anywhere.**

Trolley lets you bundle any TUI executable together with a terminal emulator
runtime, allowing you to distribute TUI applications to non-technical users.

Trolley targets Linux and MacOS, and Windows.

Other targets like iOS and Android are possible. Please open an issue if 
interested.

Although mostly simple, two recent developments make it quite powerful:

1. Improvements in terminal functionality and performance 
2. Flourishing of easy to use, powerful TUI libraries

If you are building software that fits the textual interface style, you'll be able
to create performant, _cross-platform_ applications. Launching in under a second is typical.
Combined with TUI frameworks like OpenTUI, Bubbletea & Ratatui, it is extremely easy 
to create apps with a developer experience not much different than a webapp's.

## Giants and their shoulders

Trolley is built on top of [Ghostty](https://github.com/ghostty-org/ghostty/),
which powers most of everything the end user will see and do, and enables the
aforementioned functionality. Even the GUI wrappers are stripped down versions
of Ghostty's.

For packaging, [cargo-packager](https://github.com/crabnebula-dev/cargo-packager)
does most of the heavy lifting.

Trolley, then, is an ergonomic wrapper around those two.

## Install

**macOS / Linux (Homebrew):**

```
brew install weedonandscott/tap/trolley
```

**Linux (manual):**

```
curl -sL https://github.com/weedonandscott/trolley/releases/latest/download/trolley-cli-x86_64-linux.tar.xz | tar xJ
mv trolley ~/.local/bin/
```

**Nix flake (builds from source):**

```nix
{
  inputs.trolley.url = "github:weedonandscott/trolley";
}
```

Then add `inputs.trolley.packages.${system}.default` to your packages.

Binaries for all platforms are available on [GitHub Releases](https://github.com/weedonandscott/trolley/releases).

## Quickstart

```
trolley init my-app
```

This scaffolds a `trolley.toml` manifest. Point it at your TUI binary:

```toml
[app]
identifier = "com.example.my-app"
display_name = "My App"
slug = "my-app"
version = "0.1.0"
icons = ["assets/icon.png"]

[linux]
binaries = { x86_64 = "target/release/my-app" }

[gui]
initial_width = 800
initial_height = 600

[fonts]
families = [{ nerdfont = "JetBrainsMono" }]

[embeds]
theme = "themes/dracula"
shaders = ["shaders/crt.glsl", "shaders/bloom.glsl"]
data = ["assets", "config/defaults.json"]

[ghostty]
font-size = 14
```

Then run to see how it works:

```
trolley run
```

Or package to send to your end users:

```
trolley package
```

## How it works

Trolley bundles your TUI, assets, and config next to a terminal emulator runtime. It
instructs it to launch your executable.

Trolley's runtime is a thin native wrapper around
[libghostty](https://github.com/ghostty-org/ghostty), the core library of
the Ghostty terminal emulator. libghostty handles VT parsing, PTY management,
GPU rendering, font shaping, and input encoding. Trolley provides the native
window and kiosk behavior.

| Platform | Runtime language | Windowing | Renderer |
|----------|------------------|-----------|----------|
| macOS    | Swift (AppKit)   | NSWindow  | Metal    |
| Linux    | Zig (GLFW)       | GLFW      | OpenGL   |
| Windows  | Zig (Win32)      | Win32     | OpenGL   |

### Development Prerequisites

- [Nix](https://nixos.org/) with flakes enabled (provides all build tools), or:
- Rust toolchain, Zig compiler, and platform dependencies (GLFW, X11 libs on Linux)

## Manifest

The manifest file `trolley.toml` has the following sections:

### `[app]` -- required

| Field          | Description                                |
|----------------|--------------------------------------------|
| `identifier`   | Reverse-DNS identifier (e.g. `com.foo.bar`)|
| `display_name` | Human-readable application name            |
| `slug`         | Filesystem-safe name (lowercase, hyphens)  |
| `version`      | Version string                             |
| `icons`        | List of icon paths/globs ([see Icons](#icons)) |
| `file_associations` | File types the app registers as a handler for ([see below](#file-associations)) |

`display_name` flows is used for packages filenames, so it must be safe:
non-empty, no leading/trailing whitespace, no path separators (`/`, `\`),
no control characters, and no characters invalid in Windows filenames
(`:`, `*`, `?`, `"`, `<`, `>`, `|`).

#### File associations

```toml
[app]
file_associations = [
  { extensions = ["md", "markdown"], mime_type = "text/markdown", description = "Markdown document", role = "editor" },
  { extensions = ["csv"], mime_type = "text/csv", role = "viewer" },
]
```

Both mime types above are standard ones the system already defines, which is
what makes the example work on Linux — read the Linux note below before
inventing a type of your own.

| Field         | Required | Description |
|---------------|----------|-------------|
| `extensions`  | yes      | Bare extensions, no leading `.`; lowercase ASCII alphanumerics plus `.`, `+`, `-`, `_`. Windows and macOS match files on these; Linux never sees them (see below) |
| `mime_type`   | yes      | The file's type, e.g. `text/markdown`. On Linux it must be one the system already defines (see below). No whitespace, control characters or `;` |
| `description` | no       | Windows only — the text shown in Explorer's `Type` column. No control characters, `"`, `$` or `` ` `` |
| `role`        | yes      | macOS only — what the app does with the type: `editor`, `viewer`, `shell`, `ql_generator` or `none` |

**On Linux, only a mime type the system already defines will ever match your
files.** Trolley does not emit a `shared-mime-info` XML, so `extensions` never 
reaches Linux at all: the `.desktop` entry only *references* `mime_type`, and
the desktop environment decides on its own what type a file is.

- A **standard** type (`text/markdown`, `text/csv`, `application/json`, …)
  works out of the box: `shared-mime-info` already maps the extension to it, so
  the app appears as a handler and double-clicking opens it.
- A **custom** type (`application/x-myapp`) makes the app a handler for a type
  no file is ever detected as. Double-clicking `notes.myapp` does nothing: the
  file resolves to `text/plain`, which the app never claimed. Windows and macOS
  are unaffected — they match on `extensions`.

There is no workaround: trolley cannot install a `shared-mime-info` XML, and
offers no hook for you to install one. On Linux, use a standard type.

`role` has no default and must be stated on every association. Use `editor`
unless you have a reason not to. **`none` is not a way to leave it
unspecified** — it declares the app is *not* a handler for the type, which
stops the association registering on macOS.

An extension containing a dot (`tar.gz`) is accepted, but Windows only ever
matches the final component of a filename, so the generated
`Software\Classes\.tar.gz` key is never consulted. Such an extension works on
Linux (which associates by mime type) and on macOS, not on Windows.

Per platform:

| Platform | Where it lands |
|----------|----------------|
| Linux (deb, rpm, pacman) | `MimeType=` in the `.desktop` entry, plus `Exec=<slug> %F` — matches files only for mime types the system already defines (see above) |
| Linux (AppImage) | The same `.desktop` is inside the AppDir, but nothing installs it into `~/.local/share/applications`. An AppImage-only ship registers no association at all unless the user integrates it (AppImageLauncher or similar) |
| Windows (NSIS) | `Software\Classes` registry entries mapping every extension of an association to its `<slug>.<first extension>` ProgID |
| macOS (app, dmg) | `CFBundleDocumentTypes` in `Info.plist` |

##### `TROLLEY_OPEN_PATHS`

Trolley runtimes forward launched file paths into the TUI process's environment:

- `TROLLEY_OPEN_PATHS` is set in the TUI core's environment whenever the
  runtime receives path arguments — in practice, an open from a file manager or
  the Finder. A normal launch passes none, so the variable is unset.
- The value is absolute paths, newline-joined, order preserved.
- Paths are absolutized **lexically** against the pre-`chdir` working directory:
  no existence check, no symlink canonicalization. Paths containing a newline
  are not supported.
- Multi-file: Linux (`%F`) and macOS (`openFiles`) may deliver several at once.
  Windows invokes `<slug>_runtime.exe "%1"` once per file, so each open is a
  separate instance carrying a single path.
- Second open while the app is running: Windows and Linux launch a new
  instance. On macOS the surface's command is frozen when the surface is
  created, so the delegate replies `.failure` and the event is dropped.
  Launch Services turns that reply into a "document could not be opened"
  alert, so the user sees an error rather than a silent no-op. Opening into a
  running instance is not supported.

##### Known limitations

- On Linux a custom mime type is referenced but never defined, so it matches no
  file. Use a standard type.
- macOS gets no document-type icons and no UTI declarations.

##### Windows caveats

- Uninstalling leaves the associations behind: the extension mapping and the
  ProgID key survive, pointing at a deleted executable.
- The executable path in the registry's open command is unquoted, which is a
  path-interception hazard. Opening files works regardless.
- A new association may go unnoticed by Explorer until the next login.

These are cargo-packager bugs, reported upstream rather than worked around.

### `[linux]`, `[macos]`, `[windows]` -- at least one required

```toml
[linux]
binaries = { x86_64 = "path/to/binary", aarch64 = "path/to/binary" }
args = ["--verbose", "--port=9000"]
```

`args` is optional and platform-specific. Trolley appends these entries to the
default bundled command it generates for your app.

This comes with an important caveat: arguments must not contain whitespace or
control characters. The culprit is Ghostty's current `direct:` command parser,
which splits arguments on spaces instead of accepting a structured argv array.
That means values such as `"Jane Doe"` or `"--message=hello world"` cannot be
represented safely through Trolley's default command path today.

If you need full shell quoting or arguments containing spaces, you must fall
back to `[ghostty].command` and accept shell semantics. `args` cannot be used
together with `[ghostty].command`.

`[linux]` accepts an optional `category`, which sets the `Categories=` key of
the generated `.desktop` entry (deb, rpm, pacman) — the desktop menu section
the app appears under. An AppImage carries the same `.desktop` internally, but
nothing installs it, so the menu section only appears once the user integrates
the AppImage.

```toml
[linux]
binaries = { x86_64 = "path/to/binary" }
category = "Utility"
```

The value is matched fuzzily against cargo-packager's `AppCategory` list
(`Business`, `Developer Tool`, `Education`, `Entertainment`, `Finance`, `Game`
and its sub-genres, `Graphics and Design`, `Healthcare and Fitness`,
`Lifestyle`, `Medical`, `Music`, `News`, `Photography`, `Productivity`,
`Reference`, `Social Networking`, `Sports`, `Travel`, `Utility`, `Video`,
`Weather`), so `"developer-tool"` and `"Developer Tool"` both work. An
unrecognized value is an error, with a suggestion when there is a near match.

On Windows, 1ms timer resolution is enabled by default instead of the usual
~15.6ms. This reduces timer jitter and can improve animation smoothness, but
might slightly increase CPU usage. Set `precise_timer = false` to opt out.

```toml
[windows]
binaries = { x86_64 = "path/to/app.exe" }
precise_timer = false
```

#### Code signing -- optional

`[macos]` and `[windows]` accept a `signing` table. It holds only **non-secret
selectors** -- all secret material (certificates, passwords, API keys, Azure
credentials) is read from the **environment** at build time, so nothing secret
goes in `trolley.toml`. Signing applies to the `nsis` (Windows) and `app`/`dmg`
(macOS) formats.

```toml
[macos]
binaries = { aarch64 = "...", x86_64 = "..." }
# identity is optional; omit it to take APPLE_SIGNING_IDENTITY from the env.
signing = { identity = "Developer ID Application: ACME Inc (TEAMID)" }
# signing = { entitlements = "app.entitlements" }   # optional extras
# signing = { identity = "-" }                      # ad-hoc (local dev only)

[windows]
binaries = { x86_64 = "..." }
# Local cert in the Windows store (requires a Windows build host):
signing = { thumbprint = "A1B2C3…", timestamp_url = "http://timestamp.digicert.com" }
# …or a custom command such as Azure Artifact Signing (works on any host,
# required when cross-compiling Windows from Linux/macOS). `%1` = file to sign:
# signing = { sign_command = "trusted-signing-cli -e https://wus2.codesigning.azure.net -a MyAccount -c MyProfile -d MyApp %1" }
```

`[windows.signing]` requires at least one of `thumbprint` or `sign_command`.
When signing via `thumbprint`, `timestamp_url` is **required**: a non-timestamped
signature becomes invalid once the certificate expires, which would invalidate
already-released binaries. On the `sign_command` path, timestamping is the
command's job (Azure Artifact Signing does it automatically). Other optional
keys: `digest_algorithm` (default `sha256`), `tsp`. macOS signatures are always
timestamped automatically.

#### macOS environment variables

Read from the environment at build time. All are optional — supply only what
your signing/notarization method needs:

| Purpose | Variables |
| --- | --- |
| Signing identity (if not set in config) | `APPLE_SIGNING_IDENTITY` |
| Certificate on CI (else the keychain is used) | `APPLE_CERTIFICATE` (base64 `.p12`) + `APPLE_CERTIFICATE_PASSWORD` |
| Notarization — pick one group | `APPLE_KEYCHAIN_PROFILE` · or `APPLE_ID` + `APPLE_PASSWORD` + `APPLE_TEAM_ID` · or `APPLE_API_KEY` + `APPLE_API_ISSUER` + `APPLE_API_KEY_PATH` |

`APPLE_API_KEY_PATH` may be omitted if the `AuthKey_<KEY>.p8` file sits in
`./private_keys`, `~/private_keys`, `~/.private_keys`, or
`~/.appstoreconnect/private_keys`. A signed macOS build automatically gets the
hardened runtime + a secure timestamp, and is notarized (then stapled) when one
notarization group is present — otherwise it is signed but not notarized. macOS
sign/notarize must run on a macOS host.

#### Windows environment variables

**trolley itself reads no Windows env vars** — all Windows signing configuration
lives in `[windows.signing]` above. The `thumbprint` path needs none (the cert
comes from the Windows certificate store). On the `sign_command` path, the env
vars that matter are the ones **the tool in your command** reads, e.g.:

| Tool | Variables |
| --- | --- |
| Azure Artifact Signing (`trusted-signing-cli`) | `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID` |
| DigiCert KeyLocker (`smctl`/`signtool`) | `SM_HOST`, `SM_API_KEY`, `SM_CLIENT_CERT_FILE`, `SM_CLIENT_CERT_PASSWORD` |

Consult your signing tool's docs for its exact variables; trolley just runs the
command you give it.

### `[gui]` -- optional

`initial_width`, `initial_height`, `resizable`, `maximized`, `min_width`,
`min_height`, `max_width`, `max_height`.

`maximized = true` opens the window maximized, with the initial size kept as
the restore size; it cannot be combined with `resizable = false` or with
`max_width`/`max_height`.

### `[fonts]` -- optional

```toml
[fonts]
families = [
    { nerdfont = "Inconsolata" },      # auto-downloaded from Nerd Fonts
    { path = "fonts/Custom.ttf" },     # local font file
]
```

### `[environment]` -- optional

```toml
[environment]
env_file = ".env"
variables = { MY_VAR = "value" }
```

### `[embeds]` -- optional

Embed portable Ghostty resources into the generated bundle. Relative paths are
resolved from the directory containing `trolley.toml`.

```toml
[embeds]
theme = "themes/dracula"
shaders = ["shaders/crt.glsl", "shaders/bloom.glsl"]
data = ["assets", "config/defaults.json"]
```

`theme` inlines a local Ghostty theme file into the generated `ghostty.conf`.
This is the portable way to ship a theme with your app, because it does not
depend on Ghostty's external theme catalog being installed on the target
machine.

`shaders` bundles one or more custom shader files and wires them into Ghostty
as repeated `custom-shader` entries. Each shader path must be a clean relative
path; Trolley copies every shader into the bundle at the same relative path so
`trolley run` and packaged apps behave the same.

`data` copies files or directories into the bundle root at the same
relative paths. This is useful for application assets or default data files
that your TUI loads relative to the runtime working directory.

### `[ghostty]` -- optional

Pass-through configuration for the Ghostty terminal engine. Accepts any
Ghostty config key with a scalar value (string, integer, float, or boolean)
or an array of scalars. Arrays are expanded into repeated key lines, which is
how Ghostty handles multi-value options like `keybind`.
Note that configs meant for Ghostty's GUI will not take effect (obviously).
If you want to ship a theme file with your app, prefer `[embeds].theme` over setting
`theme = "..."` here.
If you want to bundle shaders with your app, prefer `[embeds].shaders` over setting
`custom-shader` here.
If you set `command` here, do not also set per-platform `args`; Trolley treats
`[ghostty].command` as an explicit override.

```toml
[ghostty]
font-size = 14
keybind = [
    "ctrl+==increase_font_size:1",
    "ctrl+-=decrease_font_size:1",
]
```

### Ghostty Logging

To see Ghostty log output when using `trolley run`, add this to your `variables`: 
```toml
variables = { 
  GHOSTTY_LOG = "stderr" 
}
```

### Window title

You can set a fixed window title for your application via the Ghostty `title`
config:

```toml
[ghostty]
title = "My App"
```

This sets the native window title on all platforms. When set, it overrides any
title escape sequences sent by your TUI program. If your TUI doesn't set a title
itself, the window would otherwise show a default — so it's generally a good idea
to set one.

> **Tip:** Trolley clears all default Ghostty keybindings so they don't
> interfere with your TUI. If you want to re-add some of them (e.g. zoom),
> use the `keybind` array:
>
> ```toml
> [ghostty]
> keybind = [
>     "ctrl+==increase_font_size:1",
>     "ctrl+plus=increase_font_size:1",
>     "ctrl+-=decrease_font_size:1",
>     "ctrl+0=reset_font_size",
>     "super+==increase_font_size:1",
>     "super+plus=increase_font_size:1",
>     "super+-=decrease_font_size:1",
>     "super+0=reset_font_size",
> ]
> ```
>
> See [Ghostty's keybind docs](https://ghostty.org/docs/config/keybind) for
> the full list of available actions.

## Icons

Icons are not needed for `trolley run` or `--bundle-only`, but most package
formats require them. Provide icon paths or globs in the `[app]` section:

```toml
[app]
icons = ["assets/icon.png"]
```

Different formats need different icon types:

| Format              | Icon type     | Required |
|---------------------|---------------|----------|
| AppImage            | Square `.png` | Yes      |
| .deb, .rpm, pacman  | `.png`        | No       |
| NSIS (Windows)      | `.ico`        | No       |
| .app, .dmg (macOS)  | `.icns`       | No       |
| .tar.gz             | --            | --       |

To support all platforms, provide multiple icons:

```toml
icons = ["assets/icon.png", "assets/icon.ico", "assets/icon.icns"]
```

On Windows, the first resolved `.ico` is bundled into the runtime for the app
window icon, and when packaging on Windows it is also embedded into the bundled
`*_runtime.exe`.

Glob patterns are also supported (e.g. `"assets/icon.*"`).

## Package formats

| Platform | Default formats                       |
|----------|---------------------------------------|
| Linux    | AppImage, .deb, .rpm, pacman, .tar.gz |
| macOS    | .app, .dmg, .tar.gz                   |
| Windows  | NSIS installer                        |

Select specific formats with `--formats`:

```
trolley package --formats appimage,deb
```

Use `--skip-failed-formats` to continue building remaining formats if one fails
(e.g. when icons are missing for some formats):

```
trolley package --skip-failed-formats
```

### Packages naming

Artifacts in `dist/` are dervices from the `[app]` config, so the filename
structure is a stable contract. Those are the derivations:

| Format   | Filename                                    |
|----------|---------------------------------------------|
| NSIS     | `{display_name}_{version}_{arch}-setup.exe` |
| .dmg     | `{display_name}_{version}_{arch}.dmg`       |
| AppImage | `{display_name}_{version}_{arch}.AppImage`  |
| .app     | `{display name}.app`                        |
| .deb     | `{slug}_{version}_{amd64\|arm64}.deb`       |
| .rpm     | `{slug}-{version}.{arch}.rpm`               |
| .tar.gz  | `{slug}-{version}-{target}.tar.gz`          |
| pacman   | kept as produced (see below)                |

- `{arch}` is `x86_64` or `aarch64`
- `{target}` is the full target like `x86_64-linux`
- Spaces in `display_name` become underscores, except in the `.app` bundle name,
  which keeps the display name verbatim for Finder.
- pacman is the only one still named by cargo-packager, because `PKGBUILD`
  references the tarball filename byte-for-byte
- Filenames always use `version` verbatim. Inside the RPM package header,
  hyphens are encoded as `~` (`1.2.3-beta.1` → `1.2.3~beta.1`) because RPM
  reserves `-` as the version-release delimiter; `~` is the RPM prerelease
  convention and sorts before the plain version, matching semver.

## BUNDLING != SANDBOXING

Trolley simply runs your executable inside a terminal, and in that sense, provides no
extra security or sandbox guarantees.

## License

MIT
