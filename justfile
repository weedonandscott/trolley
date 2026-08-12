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
    just build-runtime $build_flags

    exe="trolley"; if [[ "$target" == *-windows ]]; then exe="trolley.exe"; fi
    mkdir -p dist
    tar cJf "dist/trolley-runtime-${target}.tar.xz" \
        -C "runtime/zig-out-release/bin" "$exe"

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
        base64 -d > "$test_dir/project/icon.png" <<'ICON'
    iVBORw0KGgoAAAANSUhEUgAAAQAAAAEAAQMAAABmvDolAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGUExURWYzmf///129H+IAAAABYktHRAH/Ai3eAAAAH0lEQVRo3u3BAQ0AAADCoPdPbQ43oAAAAAAAAAAAvg0hAAABfxmcpwAAAABJRU5ErkJggg==
    ICON
        sed -i '/^\[app\]$/a icons = ["icon.png"]' "$test_dir/project/trolley.toml"
        # CI runners have no FUSE; tell linuxdeploy to self-extract instead
        export APPIMAGE_EXTRACT_AND_RUN=1
    fi
    TROLLEY_RUNTIME_SOURCE="$runtime" \
        "$cli" package --config "$test_dir/project/trolley.toml"

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

# Clean all build artifacts
clean:
    cargo clean
    cd runtime && rm -rf zig-out-debug zig-out-release .zig-cache
    cd runtime/macos && rm -rf .build
    rm -rf trolley/build trolley/cache dist
