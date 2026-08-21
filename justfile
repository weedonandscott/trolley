# Names the files a target vendors, one per line, from its manifest. The
# manifest is the only place that list lives; see runtime/vendor/README.md.
_vendored-files target:
    #!/usr/bin/env bash
    set -euo pipefail
    manifest="{{ justfile_directory() }}/runtime/vendor/{{ target }}/vendor.json"
    [ -f "$manifest" ] || exit 0
    just _require-jq
    # keys_unsorted keeps the manifest's own order, so this output reads the
    # same way the file does.
    #
    # tr -d '\r': a native Windows jq.exe writes stdout in text mode, so every
    # line arrives with a trailing CR, and callers put these straight into
    # filenames — `tar: conpty.dll\r: Cannot stat`. Stopgap. The real fix is
    # jq's --raw-output0, which emits no newline for text mode to translate.
    # Safe to strip unconditionally: names are validated to [A-Za-z0-9._+-].
    jq -r '.files | keys_unsorted[]' "$manifest" | tr -d '\r'

# The manifests are read by the build (real JSON) and by these recipes. Parsing
# them by hand here would agree with the build only for one exact formatting.
_require-jq:
    #!/usr/bin/env bash
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq is required to read the vendor manifests" >&2
        echo "  Debian/Ubuntu: apt install jq   macOS: brew install jq   MSYS2: pacman -S jq" >&2
        exit 1
    fi

# Map trolley target to Zig target triple
# Linux needs explicit -gnu suffix; without it Zig defaults to musl.
_zig-target target:
    #!/usr/bin/env bash
    case "{{ target }}" in
        x86_64-linux)    echo "x86_64-linux-gnu" ;;
        aarch64-linux)   echo "aarch64-linux-gnu" ;;
        *)               echo "{{ target }}" ;;
    esac

# rustc's own defaults, pinned so a toolchain update can't move the floor
# unnoticed. Not the runtime's `.macOS(.v13)` — that bounds the packaged app.
_macos-deployment-target target:
    #!/usr/bin/env bash
    case "{{ target }}" in
        x86_64-macos)    echo "10.12" ;;
        aarch64-macos)   echo "11.0" ;;
        *)               echo "" ;;
    esac

# Map trolley target to Rust CLI target triple.
# Linux uses musl for a fully static, portable binary.
_cli-target target:
    #!/usr/bin/env bash
    case "{{ target }}" in
        x86_64-linux)    echo "x86_64-unknown-linux-musl" ;;
        aarch64-linux)   echo "aarch64-unknown-linux-musl" ;;
        x86_64-macos)    echo "x86_64-apple-darwin" ;;
        aarch64-macos)   echo "aarch64-apple-darwin" ;;
        x86_64-windows)  echo "x86_64-pc-windows-gnu" ;;
        aarch64-windows) echo "aarch64-pc-windows-gnu" ;;
        *)               echo "Unknown target: {{ target }}" >&2; exit 1 ;;
    esac

# Map trolley target to Rust runtime target triple.
# Linux uses glibc because the config staticlib is linked into the Zig
# runtime, which needs glibc for dlopen (X11/Wayland/GL).
_runtime-target target:
    #!/usr/bin/env bash
    case "{{ target }}" in
        x86_64-linux)    echo "x86_64-unknown-linux-gnu" ;;
        aarch64-linux)   echo "aarch64-unknown-linux-gnu" ;;
        x86_64-macos)    echo "x86_64-apple-darwin" ;;
        aarch64-macos)   echo "aarch64-apple-darwin" ;;
        x86_64-windows)  echo "x86_64-pc-windows-gnu" ;;
        aarch64-windows) echo "aarch64-pc-windows-gnu" ;;
        *)               echo "Unknown target: {{ target }}" >&2; exit 1 ;;
    esac

# Run Rust unit tests (CLI + config crates)
test *flags:
    cargo test --workspace {{ flags }}

# Build the trolley CLI

# Flags: [--release] [--target <triple>]
build-cli *flags:
    #!/usr/bin/env bash
    set -euo pipefail
    cargo_args=""
    target=""
    release=""
    next_is_target=""
    for flag in {{ flags }}; do
        if [ -n "$next_is_target" ]; then
            target="$flag"
            next_is_target=""
            continue
        fi
        case "$flag" in
            --target)  next_is_target=1 ;;
            --release) release=1 ;;
            *)         echo "Unknown flag: $flag" >&2; exit 1 ;;
        esac
    done
    if [ -n "$release" ]; then
        cargo_args="$cargo_args --release"
    fi
    if [ -n "$target" ]; then
        rust_target=$(just _cli-target "$target")
        cargo_args="$cargo_args --target $rust_target"
    fi
    cargo build -p trolley --quiet $cargo_args

# Build the config staticlib (manifest parsing, linked into the runtime)

# Flags: [--release] [--target <triple>]
build-config *flags:
    #!/usr/bin/env bash
    set -euo pipefail
    cargo_args=""
    target=""
    release=""
    next_is_target=""
    for flag in {{ flags }}; do
        if [ -n "$next_is_target" ]; then
            target="$flag"
            next_is_target=""
            continue
        fi
        case "$flag" in
            --target)  next_is_target=1 ;;
            --release) release=1 ;;
            *)         echo "Unknown flag: $flag" >&2; exit 1 ;;
        esac
    done
    if [ -n "$release" ]; then
        cargo_args="$cargo_args --release"
    fi
    if [ -n "$target" ]; then
        rust_target=$(just _runtime-target "$target")
        cargo_args="$cargo_args --target $rust_target"
    fi
    cargo build -p trolley-config --quiet $cargo_args

# Build the trolley runtime
# Flags: [--release] [--target <triple>] [--system <path>]
# No target flag = host default
# Examples:
#   just build-runtime --target x86_64-linux
#   just build-runtime --target aarch64-macos --release
#   just build-runtime --release --system /nix/store/...-zig-packages
build-runtime *flags:
    #!/usr/bin/env bash
    set -euo pipefail
    target=""
    zig_target=""
    optimize=""
    prefix="zig-out-debug"
    cargo_profile="debug"
    release=""
    system=""
    next_is_target=""
    next_is_system=""
    for flag in {{ flags }}; do
        if [ -n "$next_is_target" ]; then
            target="$flag"
            next_is_target=""
            continue
        fi
        if [ -n "$next_is_system" ]; then
            system="$flag"
            next_is_system=""
            continue
        fi
        case "$flag" in
            --target)  next_is_target=1 ;;
            --system)  next_is_system=1 ;;
            --release) release=1; optimize="-Doptimize=ReleaseSafe"; prefix="zig-out-release"; cargo_profile="release" ;;
            *)         echo "Unknown flag: $flag" >&2; exit 1 ;;
        esac
    done

    # Build config staticlib.
    # Zig uses LLD (GNU-style linking), so on Windows the config crate must
    # be built with the GNU ABI target even when the host default is MSVC.
    config_flags=""
    if [ -n "$release" ]; then config_flags="--release"; fi
    if [ -n "$target" ]; then
        config_flags="$config_flags --target $target"
    elif [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "$(uname -o 2>/dev/null)" == "Msys" || -n "${WINDIR:-}" ]]; then
        config_flags="$config_flags --target x86_64-windows"
    fi
    just build-config $config_flags

    # Determine config lib path
    if [ -n "$target" ]; then
        rust_target=$(just _runtime-target "$target")
        config_dir="{{ justfile_directory() }}/target/$rust_target/$cargo_profile"
        zig_target="-Dtarget=$(just _zig-target "$target")"
    elif [ -n "${WINDIR:-}" ]; then
        # Host Windows build forced to GNU target above
        config_dir="{{ justfile_directory() }}/target/x86_64-pc-windows-gnu/$cargo_profile"
    else
        config_dir="{{ justfile_directory() }}/target/$cargo_profile"
    fi

    # Detect correct library filename: MSVC produces trolley_config.lib,
    # GNU produces libtrolley_config.a
    if [ -f "$config_dir/libtrolley_config.a" ]; then
        config_lib="$config_dir/libtrolley_config.a"
    elif [ -f "$config_dir/trolley_config.lib" ]; then
        config_lib="$config_dir/trolley_config.lib"
    else
        echo "Error: config lib not found in $config_dir" >&2
        echo "Expected libtrolley_config.a or trolley_config.lib" >&2
        exit 1
    fi

    # Step 1: zig build (libghostty + exe on Linux/Windows, libghostty only on macOS)
    zig_system=""
    if [ -n "$system" ]; then zig_system="--system $system"; fi
    # Build all C deps from source so the binary only needs libc at runtime.
    # (--system enables all integrations by default; explicitly disable them.)
    sys_flags="-fno-sys=freetype -fno-sys=harfbuzz -fno-sys=fontconfig -fno-sys=oniguruma -fno-sys=libpng -fno-sys=zlib"
    # fontconfig (Linux-only, lazy on macOS) depends on libxml2; disable it
    # so it builds from source too.  The integration isn't registered on macOS.
    if [[ "$target" == *"-linux" ]] || { [ -z "$target" ] && [[ "$(uname -s)" == "Linux" ]]; }; then
        sys_flags="$sys_flags -fno-sys=libxml2"
    fi
    cd runtime && zig build $zig_target $optimize $zig_system $sys_flags -Dconfig-lib="$config_lib" --prefix "$prefix"

    # Step 2: macOS needs a separate Swift build for the executable
    is_macos=false
    if [[ "$target" == *"-macos" ]]; then
        is_macos=true
    elif [ -z "$target" ] && [[ "$(uname -s)" == "Darwin" ]]; then
        is_macos=true
        arch=$(uname -m); if [ "$arch" = "arm64" ]; then arch="aarch64"; fi
        rust_target=$(just _runtime-target "$arch-macos")
    fi
    if $is_macos; then
        swift_config="debug"
        if [ -n "$release" ]; then swift_config="release"; fi
        # When no --target was given, cargo outputs to target/$cargo_profile (no triple).
        if [ -n "$target" ]; then
            config_link_dir="../../target/$rust_target/$cargo_profile"
        else
            config_link_dir="../../target/$cargo_profile"
        fi
        cd macos && swift build -c "$swift_config" \
            -Xlinker -L../$prefix/lib \
            -Xlinker -L$config_link_dir
        mkdir -p ../$prefix/bin
        cp ".build/$swift_config/trolley" "../$prefix/bin/trolley"
    fi

# Build everything

# Flags: [--release] [--target <triple>]
build *flags: (build-cli flags) (build-runtime flags)

# Build and package the CLI for release
# Requires: --target <triple>
# Ignores: --system (accepted for compatibility with release command)
release-cli *flags:
    #!/usr/bin/env bash
    set -euo pipefail
    target=""
    next_is_target=""
    skip_next=""
    for flag in {{ flags }}; do
        if [ -n "$skip_next" ]; then
            skip_next=""
            continue
        fi
        if [ -n "$next_is_target" ]; then
            target="$flag"
            next_is_target=""
            continue
        fi
        case "$flag" in
            --target)  next_is_target=1 ;;
            --system)  skip_next=1 ;;
            *)         echo "Unknown flag: $flag" >&2; exit 1 ;;
        esac
    done
    if [ -z "$target" ]; then
        echo "Error: --target is required" >&2; exit 1
    fi

    # Exported, not just set: it has to reach the cc invocations of native
    # dependencies, not only rustc.
    if [[ "$target" == *-macos ]]; then
        export MACOSX_DEPLOYMENT_TARGET="$(just _macos-deployment-target "$target")"
    fi

    TROLLEY_RUNTIME_SOURCE="https://github.com/weedonandscott/trolley/releases/download/v{version}/trolley-runtime-{target}.tar.xz" \
        just build-cli --release --target "$target"

    rust_target=$(just _cli-target "$target")
    exe="trolley"; if [[ "$target" == *-windows ]]; then exe="trolley.exe"; fi
    mkdir -p dist
    tar cJf "dist/trolley-cli-${target}.tar.xz" \
        -C "target/$rust_target/release" "$exe"

# Build and package the runtime for release
# Requires: --target <triple>
# Optional: --system <path> (pre-built zig deps from nix build .#deps)
release-runtime *flags:
    #!/usr/bin/env bash
    set -euo pipefail
    target=""
    system=""
    next_is_target=""
    next_is_system=""
    for flag in {{ flags }}; do
        if [ -n "$next_is_target" ]; then
            target="$flag"
            next_is_target=""
            continue
        fi
        if [ -n "$next_is_system" ]; then
            system="$flag"
            next_is_system=""
            continue
        fi
        case "$flag" in
            --target)  next_is_target=1 ;;
            --system)  next_is_system=1 ;;
            *)         echo "Unknown flag: $flag" >&2; exit 1 ;;
        esac
    done
    if [ -z "$target" ]; then
        echo "Error: --target is required" >&2; exit 1
    fi

    build_flags="--release --target $target"
    if [ -n "$system" ]; then build_flags="$build_flags --system $system"; fi
    # Prove the vendored files are what their manifest says before they go into
    # a release artifact.
    just verify-vendored

    just build-runtime $build_flags

    exe="trolley"; if [[ "$target" == *-windows ]]; then exe="trolley.exe"; fi
    files=("$exe")
    # Whatever this target vendors travels with it; the build installed these
    # beside the exe. See runtime/vendor/README.md.
    #
    # Captured rather than piped in as `done < <(...)`: that form ends the loop
    # without bash ever seeing the producer's exit status, so a failure here
    # would tar up the exe alone and the check below would then confirm that
    # shortened list.
    vendored=$(just _vendored-files "$target")
    while IFS= read -r name; do
        [ -n "$name" ] && files+=("$name")
    done <<< "$vendored"
    mkdir -p dist
    tarball="dist/trolley-runtime-${target}.tar.xz"
    tar cJf "$tarball" -C "runtime/zig-out-release/bin" "${files[@]}"

    # Nothing downstream unpacks this tarball until a user does, so prove every
    # file is in it here. The CLI hard-fails on a runtime missing any of them.
    listing=$(tar tf "$tarball")
    for f in "${files[@]}"; do
        if ! printf '%s\n' "$listing" | grep -qxF "$f"; then
            echo "Error: $tarball is missing $f" >&2
            exit 1
        fi
    done

# Build and package everything for release
# Requires: --target <triple>
release *flags: (release-cli flags) (release-runtime flags)

# Assert the release binaries depend on nothing that only exists on the build
# machine — such a dependency links and runs in CI and fails on every user's
# machine. Run after release-cli / release-runtime; not part of `just release`.
# Requires: --target <triple>; --cli / --runtime pick one, neither means both
check-linkage *flags:
    #!/usr/bin/env bash
    set -euo pipefail
    target=""
    cli=""
    runtime=""
    next_is_target=""
    for flag in {{ flags }}; do
        if [ -n "$next_is_target" ]; then
            target="$flag"
            next_is_target=""
            continue
        fi
        case "$flag" in
            --target)  next_is_target=1 ;;
            --cli)     cli=1 ;;
            --runtime) runtime=1 ;;
            *)         echo "Unknown flag: $flag" >&2; exit 1 ;;
        esac
    done
    if [ -z "$target" ]; then
        echo "Error: --target is required" >&2; exit 1
    fi
    if [ -z "$cli" ] && [ -z "$runtime" ]; then cli=1; runtime=1; fi

    rust_target=$(just _cli-target "$target")
    exe="trolley"; if [[ "$target" == *-windows ]]; then exe="trolley.exe"; fi
    script="{{ justfile_directory() }}/scripts/check-linkage.sh"

    if [ -n "$cli" ]; then
        "$script" "$target" cli \
            "{{ justfile_directory() }}/target/$rust_target/release/$exe" \
            "$(just _macos-deployment-target "$target")"
    fi
    if [ -n "$runtime" ]; then
        "$script" "$target" runtime \
            "{{ justfile_directory() }}/runtime/zig-out-release/bin/$exe" \
            ""
    fi

# Sanity-test the release artifacts: init a project, package all default
# formats, diff dist/ against its committed listing snapshot
# Requires: --target <triple>; --bless rewrites the dist listing snapshot
sanity-test *flags:
    #!/usr/bin/env bash
    set -euo pipefail
    target=""
    bless=""
    next_is_target=""
    for flag in {{ flags }}; do
        if [ -n "$next_is_target" ]; then
            target="$flag"
            next_is_target=""
            continue
        fi
        case "$flag" in
            --target)  next_is_target=1 ;;
            --bless)   bless=1 ;;
            *)         echo "Unknown flag: $flag" >&2; exit 1 ;;
        esac
    done
    if [ -z "$target" ]; then
        echo "Error: --target is required" >&2; exit 1
    fi

    rust_target=$(just _cli-target "$target")
    exe="trolley"; if [[ "$target" == *-windows ]]; then exe="trolley.exe"; fi
    cli="{{ justfile_directory() }}/target/$rust_target/release/$exe"
    runtime="{{ justfile_directory() }}/runtime/zig-out-release/bin/$exe"

    test_dir="{{ justfile_directory() }}/.sanity-test"
    rm -rf "$test_dir"
    trap 'rm -rf "$test_dir"' EXIT

    echo "==> trolley --version"
    cli_version=$("$cli" --version)
    expected="trolley version $(cat VERSION | tr -d '[:space:]')"
    if [ "$cli_version" != "$expected" ]; then
        echo "Error: --version output '$cli_version' does not match expected '$expected'" >&2; exit 1
    fi

    echo "==> trolley init .sanity-test/project"
    "$cli" init "$test_dir/project"

    if [ ! -f "$test_dir/project/trolley.toml" ]; then
        echo "Error: trolley.toml was not created" >&2; exit 1
    fi

    # Two-word display name so the rename layer is observable: cargo-packager's
    # default AppImage/dmg/NSIS names differ from the composed Project_Sanity_*
    # names, so a broken rename fails the dist listing diff on every OS.
    # (sed -i.bak + rm is portable across GNU and BSD sed.)
    sed -i.bak 's/^display_name = .*/display_name = "Project Sanity"/' "$test_dir/project/trolley.toml" && rm "$test_dir/project/trolley.toml.bak"

    mkdir -p "$test_dir/project/path/to"
    cp "$cli" "$test_dir/project/path/to/project"

    echo "==> trolley package --bundle-only"
    TROLLEY_RUNTIME_SOURCE="$runtime" \
        "$cli" package --bundle-only --config "$test_dir/project/trolley.toml"

    # Full packaging with the target's default formats, then diff the dist/
    # listing against a committed snapshot. This catches builders bypassing
    # the artifact naming API — the dist filename structure is a released
    # contract, so a mismatch here is a breaking change.
    echo "==> trolley package (default formats)"
    arch="${target%%-*}"
    if [[ "$target" == *-linux ]]; then
        # AppImage requires a square icon; give the init project one.
        cp "{{ justfile_directory() }}/tests/sanity/icon.png" "$test_dir/project/icon.png"
        sed -i '/^\[app\]$/a icons = ["icon.png"]' "$test_dir/project/trolley.toml"
        # A file association and a category, so the .desktop assertions below
        # have something to find. The scaffold emits a [linux] header with
        # category commented out; a real one goes right after the header.
        sed -i '/^\[app\]$/a file_associations = [{ extensions = ["snty"], mime_type = "text/x-sanity", role = "editor" }]' "$test_dir/project/trolley.toml"
        sed -i '/^\[linux\]$/a category = "Utility"' "$test_dir/project/trolley.toml"
        # CI runners have no FUSE; tell linuxdeploy to self-extract instead
        export APPIMAGE_EXTRACT_AND_RUN=1
    elif [[ "$target" == *-windows ]]; then
        # Must be a real .ico: parse_ico validates the header, and the icon
        # assertions below need an image Windows can actually draw.
        cp "{{ justfile_directory() }}/tests/sanity/icon.ico" "$test_dir/project/icon.ico"
        sed -i '/^\[app\]$/a icons = ["icon.ico"]' "$test_dir/project/trolley.toml"
        # The same association the Linux branch injects, so makensis actually
        # compiles the file-association block and the .nsi assertion below has
        # something to find.
        sed -i '/^\[app\]$/a file_associations = [{ extensions = ["snty"], mime_type = "text/x-sanity", role = "editor" }]' "$test_dir/project/trolley.toml"
    fi
    TROLLEY_RUNTIME_SOURCE="$runtime" \
        "$cli" package --config "$test_dir/project/trolley.toml" | tee "$test_dir/package.log"

    dist="$test_dir/project/trolley/build/com.example.project/$target/dist"
    snap="{{ justfile_directory() }}/tests/sanity/listings/${target}.list"
    actual=$(cd "$dist" && LC_ALL=C ls -A | LC_ALL=C sort)
    if [ -n "$bless" ]; then
        printf '%s\n' "$actual" > "$snap"
        echo "==> blessed $snap"
    else
        # A real file, not process substitution: MSYS diff on the Windows
        # runner cannot open /dev/fd/NN.
        printf '%s\n' "$actual" > "$test_dir/listing.actual"
        if ! diff -u "$snap" "$test_dir/listing.actual"; then
            echo "Error: dist/ listing does not match $snap (run with --bless to update, then review the git diff)" >&2
            exit 1
        fi
    fi
    if [[ "$target" == *-linux ]]; then
        # The generated PKGBUILD must point at the pacman tarball the listing
        # proved exists — guards both names drifting in lock-step.
        if ! grep -qF "source=(\"project_0.1.0_${arch}.tar.gz\")" "$dist/PKGBUILD"; then
            echo "Error: PKGBUILD source=() does not reference project_0.1.0_${arch}.tar.gz" >&2
            exit 1
        fi

        # The icon must be embedded in each Linux package — the listing diff
        # only proves filenames, not contents.
        icon_path="usr/share/icons/hicolor/256x256/apps/project.png"
        deb_arch="amd64"; if [ "$arch" = "aarch64" ]; then deb_arch="arm64"; fi
        # Not grep -q: it exits at the first match, the producer dies of
        # SIGPIPE, and pipefail turns that into a false failure.
        if ! dpkg-deb -c "$dist/project_0.1.0_${deb_arch}.deb" | grep -F "$icon_path" >/dev/null; then
            echo "Error: deb is missing $icon_path" >&2
            exit 1
        fi
        if ! rpm -qlp "$dist/project-0.1.0.${arch}.rpm" | grep -F "/$icon_path" >/dev/null; then
            echo "Error: rpm is missing /$icon_path" >&2
            exit 1
        fi
        (cd "$test_dir" && "$dist/Project_Sanity_0.1.0_${arch}.AppImage" --appimage-extract "$icon_path" >/dev/null)
        if [ ! -f "$test_dir/squashfs-root/$icon_path" ]; then
            echo "Error: AppImage is missing $icon_path" >&2
            exit 1
        fi

        # The .desktop entry carries the file association and the category.
        # Only the deb's contents are read: rpm's entry is pinned byte-for-byte
        # by the desktop_entry unit tests, and extracting from an rpm would need
        # tools the CI runners do not have.
        desktop_path="usr/share/applications/project.desktop"
        # Leading * in the pattern so it matches whether or not the member is
        # stored with a ./ prefix. `-f -` because tar's default archive is a
        # compiled-in device that $TAPE overrides. `|| true` so a missing member
        # reports the message below instead of tar's.
        deb_desktop=$(dpkg-deb --fsys-tarfile "$dist/project_0.1.0_${deb_arch}.deb" | tar -xO -f - --wildcards "*$desktop_path" || true)
        if ! rpm -qlp "$dist/project-0.1.0.${arch}.rpm" | grep -F "/$desktop_path" >/dev/null; then
            echo "Error: rpm is missing /$desktop_path" >&2
            exit 1
        fi
        for line in "Exec=project %F" "MimeType=text/x-sanity" "Categories=Utility;"; do
            if ! printf '%s\n' "$deb_desktop" | grep -F "$line" >/dev/null; then
                echo "Error: deb $desktop_path is missing '$line'" >&2
                exit 1
            fi
        done
    fi
    if [[ "$target" == *-windows ]]; then
        bundle="$test_dir/project/trolley/build/com.example.project/$target/bundle"

        # Two independent icon paths, neither covered by the listing diff:
        # app.ico, which the runtime loads for its window icon, and the exe's
        # embedded resource.
        if [ ! -f "$bundle/app.ico" ]; then
            echo "Error: bundle is missing app.ico (icon glob resolved nothing)" >&2
            exit 1
        fi
        if ! grep -F "(Windows exe icon stamped)" "$test_dir/package.log" >/dev/null; then
            echo "Error: packager did not report stamping the exe icon" >&2
            exit 1
        fi

        # Shortcuts use the embedded resource, so ask Windows to count it:
        # PrivateExtractIcons with a null buffer and nIcons 0 returns the count,
        # and zero sizes stop it filtering. Run from $bundle with relative paths
        # — MSYS rewrites Unix-looking arguments before PowerShell sees them.
        cat > "$bundle/icon-count.ps1" <<'PS1'
    $sig = '[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int PrivateExtractIcons(string f, int i, int cx, int cy, IntPtr[] h, int[] id, int n, int flags);'
    Add-Type -Namespace Trolley -Name Ico -MemberDefinition $sig
    [Trolley.Ico]::PrivateExtractIcons((Resolve-Path $args[0]).Path, 0, 0, 0, $null, $null, 0, 0)
    PS1
        # `|| true` so a throwing Add-Type cannot kill the recipe here under
        # `set -e`, before the message below says what happened. stderr goes to a
        # file rather than into $icons: PowerShell emits a CLIXML progress record
        # there on a machine's first Add-Type, which would fail the digit check.
        icon_err="$test_dir/icon-count.err"
        icons=$(cd "$bundle" && powershell -NoProfile -ExecutionPolicy Bypass -File icon-count.ps1 project_runtime.exe 2>"$icon_err" | tr -d '[:space:]') || true
        rm "$bundle/icon-count.ps1"
        # Match on digits first: `[ non-numeric -lt 1 ]` exits 2, which `if`
        # reads as false and would pass the assertion on garbled output.
        if ! [[ "$icons" =~ ^[0-9]+$ ]] || [ "$icons" -lt 1 ]; then
            echo "Error: project_runtime.exe has no embedded icon (PrivateExtractIcons returned '${icons}')" >&2
            if [ -s "$icon_err" ]; then sed 's/^/  /' "$icon_err" >&2; fi
            exit 1
        fi

        # The runtime refuses to start without the files it vendors, and the
        # dist listing can't see inside the bundle, so check it here.
        vendored_files=$(just _vendored-files "$target")
        # Read by line, not by word: a name may contain a space.
        while IFS= read -r vendored_file; do
            [ -n "$vendored_file" ] || continue
            if [ ! -f "$bundle/$vendored_file" ]; then
                echo "Error: bundle is missing $vendored_file (vendored file)" >&2
                exit 1
            fi
        done <<< "$vendored_files"

        # The installer ships only what the manifest declares, by a different
        # mechanism than the archive — the listing diff only proves filenames,
        # not contents. A drop here is a hard startup failure for every user.
        setup="$dist/Project_Sanity_0.1.0_${arch}-setup.exe"
        # 7-Zip ships with Windows runners but is not on the MSYS PATH there.
        sevenzip=""
        for candidate in 7z "/c/Program Files/7-Zip/7z.exe" "/c/Program Files (x86)/7-Zip/7z.exe"; do
            if command -v "$candidate" >/dev/null 2>&1; then sevenzip="$candidate"; break; fi
        done
        if [ -z "$sevenzip" ]; then
            echo "Error: 7z not found; cannot verify the contents of $setup" >&2
            echo "Install 7-Zip, or put its directory on PATH." >&2
            exit 1
        fi
        setup_listing=$("$sevenzip" l -ba "$setup")
        while IFS= read -r vendored_file; do
            [ -n "$vendored_file" ] || continue
            if ! printf '%s\n' "$setup_listing" | grep -qF "$vendored_file"; then
                echo "Error: installer is missing $vendored_file (vendored file)" >&2
                exit 1
            fi
        done <<< "$vendored_files"

        # The registry writes live in a handlebars-rendered NSIS script and the
        # installer is opaque, so assert on the script makensis was handed. It
        # is UTF-16LE, hence the NUL strip. Not grep -q: see the note above.
        nsis_arch="x64"; if [ "$arch" = "aarch64" ]; then nsis_arch="arm64"; fi
        nsi="$test_dir/project/trolley/build/com.example.project/$target/packager/.cargo-packager/nsis/$nsis_arch/installer.nsi"
        if ! tr -d '\000' < "$nsi" | grep -aF 'APP_ASSOCIATE "snty" "project.snty"' >/dev/null; then
            echo "Error: $nsi does not associate .snty with the project.snty ProgID" >&2
            exit 1
        fi
    fi

    echo "==> Sanity test passed"

# Use like the real CLI: just trolley <args>

# Rebuilds automatically via cargo run
trolley *args:
    cargo run -p trolley --quiet -- {{ args }}

# Run an example by name: just example hello [--release]
example name *flags: (build-runtime flags)
    #!/usr/bin/env bash
    set -euo pipefail
    prefix="zig-out-debug"
    for flag in {{ flags }}; do
        if [ "$flag" = "--release" ]; then prefix="zig-out-release"; fi
    done
    exe_suffix=""; if [ -n "${WINDIR:-}" ]; then exe_suffix=".exe"; fi
    TROLLEY_RUNTIME_SOURCE='{{ justfile_directory() }}/runtime/'$prefix'/bin/trolley'$exe_suffix \
        cargo run -p trolley --quiet -- run --config 'examples/{{ name }}/trolley.toml'

# Bump version in all files: just bump 0.2.0
bump version:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "{{ version }}" > VERSION
    sed -i 's/^version = ".*"/version = "{{ version }}"/' cli/Cargo.toml config/Cargo.toml
    sed -i 's/\.version = ".*"/.version = "{{ version }}"/' runtime/build.zig.zon
    cargo update --workspace --quiet

# Clean font cache
clean-fonts:
    rm -rf trolley/cache/fonts

# Pre-fetch Zig dependencies for offline/cached builds.
# Copies ghostty's dep file out of the submodule (nix flakes can't see
# inside submodules), then builds the combined dep store via nix.
# Outputs the store path on stdout.
build-deps:
    #!/usr/bin/env bash
    set -euo pipefail
    cp ghostty/build.zig.zon.nix nix/ghostty-deps.nix
    git add -f nix/ghostty-deps.nix nix/extra-zig-deps.nix
    nix build -L -v .#deps
    readlink ./result

# Re-hash every vendored file against its target's manifest
verify-vendored:
    #!/usr/bin/env bash
    set -euo pipefail
    # Catches a corrupted or hand-edited file. It cannot prove the bytes came
    # from upstream: a manifest is written by whoever vendored the files.
    vendor="{{ justfile_directory() }}/runtime/vendor"
    sha256=$(just _sha256-cmd)
    just _require-jq
    checked=0

    # Same source in more than one target has to mean the same bytes; recorded
    # here as we go so the licence copies cannot drift apart unnoticed.
    seen_from=""

    # Every target that vendors anything, so a newly added one is covered
    # without touching this recipe.
    for manifest in "$vendor"/*/vendor.json; do
        [ -e "$manifest" ] || continue
        target=$(basename "$(dirname "$manifest")")

        # A target directory that lists nothing would otherwise be walked over
        # in silence, since the totals below are only checked across all targets.
        listed=$(jq -r '.files | length' "$manifest")
        if [ "$listed" -eq 0 ]; then
            echo "Error: $target/vendor.json lists no files" >&2
            exit 1
        fi

        # One pass over the manifest, parsed as JSON rather than scraped, so
        # this agrees with the build for any formatting of the file.
        # Unit separator, not tab: bash folds runs of tabs into one delimiter,
        # so an absent field would shift every later one along.
        #
        # Read in full before checking anything. Fed straight into the loop as
        # `done < <(jq ...)`, a jq that dies partway just ends the loop, bash
        # never sees its status, and a half-read manifest reports OK. As an
        # assignment it is `set -e`'s to catch.
        records=$(jq -r '.files | to_entries[] | [
                      .key,
                      (.value.sha256 // ""),
                      ((.value.size // "") | tostring),
                      (.value.from // "")
                  ] | join("\u001f")' "$manifest" | tr -d '\r')

        target_checked=0
        while IFS=$'\037' read -r name expected expected_size from; do
            [ -n "$name" ] || continue
            # Lowercased: tools differ on the case they print a digest in.
            expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
            if [ -z "$expected" ]; then
                echo "Error: $target/vendor.json records no sha256 for $name" >&2
                exit 1
            fi
            if [ ! -f "$vendor/$target/$name" ]; then
                echo "Error: $target/vendor.json lists $name, which is not there" >&2
                exit 1
            fi
            # Redirected, not named: a path holding a backslash makes GNU
            # coreutils escape the filename and prefix the whole line with one.
            actual=$($sha256 < "$vendor/$target/$name" | cut -d' ' -f1 | tr 'A-F' 'a-f')
            if [ "$actual" != "$expected" ]; then
                echo "Error: $target/$name does not match its manifest" >&2
                echo "  recorded: $expected" >&2
                echo "  actual:   $actual" >&2
                exit 1
            fi

            # Recorded size is otherwise decorative; nothing else reads it.
            if [ -n "$expected_size" ]; then
                actual_size=$(wc -c < "$vendor/$target/$name" | tr -d ' ')
                if [ "$actual_size" != "$expected_size" ]; then
                    echo "Error: $target/$name is $actual_size bytes, manifest says $expected_size" >&2
                    exit 1
                fi
            fi

            if [ -n "$from" ]; then
                # grep -F and a real tab, not sed: `\t` in a BRE is a GNU
                # extension that BSD sed matches as a literal `t`, so on a Mac
                # outside the nix shell this lookup never fired and the check
                # passed vacuously. -F also keeps a `from` with a regex
                # metacharacter in it from changing what matches.
                # `|| true` because no prior record is the normal case for the
                # first target, and grep exits 1 on no match, which pipefail
                # would otherwise turn into a silent recipe failure.
                prior=$(printf '%s' "$seen_from" | grep -F "$name	$from	" | head -1 | cut -f3 || true)
                if [ -n "$prior" ] && [ "$prior" != "$actual" ]; then
                    echo "Error: $name comes from $from in more than one target, with different bytes" >&2
                    exit 1
                fi
                seen_from="$seen_from$name	$from	$actual
    "
            fi
            checked=$((checked + 1))
            target_checked=$((target_checked + 1))
        done <<< "$records"

        # Belt to the assignment's brace: if jq ever exits clean while emitting
        # a different number of records than the manifest has entries, the ones
        # it skipped went unhashed and this run proved nothing about them.
        if [ "$target_checked" -ne "$listed" ]; then
            echo "Error: $target/vendor.json lists $listed files but $target_checked were checked" >&2
            exit 1
        fi

        # The build installs exactly what the manifest lists, so a file sitting
        # here unlisted is one somebody expected to ship and which silently
        # will not.
        for path in "$vendor/$target"/*; do
            name=$(basename "$path")
            [ "$name" = "vendor.json" ] && continue
            if ! just _vendored-files "$target" | grep -qxF "$name"; then
                echo "Error: $target/$name is not listed in $target/vendor.json" >&2
                exit 1
            fi
        done
    done

    if [ "$checked" -eq 0 ]; then
        echo "Error: no vendored files found under $vendor" >&2
        exit 1
    fi
    echo "==> OK: $checked vendored files match their manifests"

# sha256sum is GNU; macOS ships shasum instead.
_sha256-cmd:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v sha256sum >/dev/null 2>&1; then
        echo "sha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        echo "shasum -a 256"
    else
        echo "Error: need sha256sum or shasum" >&2
        exit 1
    fi

# Clean all build artifacts
clean:
    cargo clean
    cd runtime && rm -rf zig-out-debug zig-out-release .zig-cache
    cd runtime/macos && rm -rf .build
    rm -rf trolley/build trolley/cache dist
