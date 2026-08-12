#!/usr/bin/env bash
# Assert a release binary depends on nothing that only exists on the build
# machine — such a dependency links and runs in CI and fails on every user's
# machine.
#
# Usage: check-linkage.sh <trolley-target> <cli|runtime> <path> <macos-deployment-target>
# Normally invoked as `just check-linkage --target <triple> [--cli] [--runtime]`.
set -euo pipefail

target="${1:?target required}"
kind="${2:?kind required}"
bin="${3:?binary path required}"
expected_macos_minos="${4:-}"   # macOS CLI only; empty elsewhere

case "$kind" in
cli) label="CLI" ;;
runtime) label="runtime" ;;
*)
    echo "Error: unknown kind '$kind', expected cli or runtime" >&2
    exit 1
    ;;
esac

case "$kind:$target" in
runtime:*-windows)
    # A DLL allowlist here would have to be guessed, and a guessed one fails CI
    # on correct artifacts. Skipped before the file check so callers need no
    # per-target conditional.
    echo "==> skipped: no linkage check for the Windows runtime"
    exit 0
    ;;
esac

if [ ! -f "$bin" ]; then
    echo "Error: release $label not found at $bin" >&2
    echo "Build it first: just release-$kind --target $target" >&2
    exit 1
fi

echo "==> check-linkage $bin"

# Shared by both macOS branches.
check_macho_system_libs() {
    # tail -n +2 drops otool's echo of the file itself.
    local libs
    libs=$(otool -L "$bin" | tail -n +2 | awk '{print $1}')
    if [ -z "$libs" ]; then
        # Empty means otool broke, not that the binary is clean — and the grep
        # below needs `|| true`, which would mask it.
        echo "Error: read no linked libraries from $bin — otool output unrecognized" >&2
        exit 1
    fi

    # /usr/lib and /System/Library are the dyld shared cache, on every Mac;
    # anything else (/opt/homebrew, /nix/store, an @rpath entry) is runner-only.
    local foreign
    foreign=$(printf '%s\n' "$libs" | grep -v -e '^/usr/lib/' -e '^/System/Library/' || true)
    if [ -n "$foreign" ]; then
        echo "Error: $bin links libraries from outside the OS:" >&2
        printf '%s\n' "$foreign" | sed 's/^/  /' >&2
        echo "Only /usr/lib and /System/Library are present on end-user machines." >&2
        exit 1
    fi
}

case "$kind:$target" in
cli:*-macos)
    if [ -z "$expected_macos_minos" ]; then
        echo "Error: no deployment target given for $target" >&2
        exit 1
    fi

    check_macho_system_libs

    # An unset MACOSX_DEPLOYMENT_TARGET silently raises the floor to the runner's
    # SDK. Below 10.14 that floor is LC_VERSION_MIN_MACOSX's "version", above it
    # LC_BUILD_VERSION's "minos" — which precedes the linker's own "version" line.
    macos_minos=$(vtool -show-build "$bin" | awk '$1 == "minos" || $1 == "version" { print $2; exit }')
    # vtool prints "13.0" where the env var may say "13"; compare loosely.
    if [ "${macos_minos%.0}" != "${expected_macos_minos%.0}" ]; then
        echo "Error: $bin minimum macOS is '${macos_minos:-<none>}', expected '$expected_macos_minos'" >&2
        echo "MACOSX_DEPLOYMENT_TARGET did not reach the release build." >&2
        exit 1
    fi
    echo "==> OK: system dylibs only, minimum macOS $macos_minos"
    ;;

cli:*-linux)
    # ldd says "not a dynamic executable" for a classic static binary and
    # "statically linked" for the static-PIE rustc emits; accept either.
    out=$(ldd "$bin" 2>&1 || true)
    case "$out" in
    *"not a dynamic executable"* | *"statically linked"*) ;;
    *)
        echo "Error: $bin is a dynamic executable; the musl build must be static:" >&2
        printf '%s\n' "$out" | sed 's/^/  /' >&2
        exit 1
        ;;
    esac
    echo "==> OK: statically linked"
    ;;

cli:*-windows)
    # rustup's windows-gnu toolchain ships no binutils; objdump comes from the
    # runner's MSYS2/mingw install.
    objdump=""
    for candidate in objdump x86_64-w64-mingw32-objdump /c/msys64/mingw64/bin/objdump /c/msys64/usr/bin/objdump; do
        if command -v "$candidate" >/dev/null 2>&1; then objdump="$candidate"; break; fi
    done
    if [ -z "$objdump" ]; then
        echo "Error: no objdump on PATH; cannot read the import table of $bin" >&2
        echo "Install MSYS2 binutils or add C:\\msys64\\mingw64\\bin to PATH." >&2
        exit 1
    fi

    dlls=$("$objdump" -p "$bin" | awk '$1 == "DLL" && $2 == "Name:" { print $3 }')
    if [ -z "$dlls" ]; then
        # Every PE imports something; an empty list means the parse broke, not
        # that the binary is clean.
        echo "Error: read no DLL imports from $bin — objdump output unrecognized" >&2
        exit 1
    fi

    # Allowlist: every entry below ships with Windows itself.
    foreign=""
    for dll in $dlls; do
        case "$(printf '%s' "$dll" | tr 'A-Z' 'a-z')" in
        # Core Win32.
        kernel32.dll | ntdll.dll | advapi32.dll | user32.dll | shell32.dll | shlwapi.dll | userenv.dll | ws2_32.dll | dbghelp.dll) ;;
        # COM/OLE.
        ole32.dll | oleaut32.dll | combase.dll) ;;
        # Kernel Transaction Manager, used by std's filesystem code.
        ktmw32.dll) ;;
        # Windows' own C runtime, which the -gnu target links by design. The
        # MSVC redistributables (vcruntime140.dll, msvcp140.dll) stay off.
        msvcrt.dll) ;;
        # Crypto and RNG used by std and rustls.
        bcrypt.dll | bcryptprimitives.dll | crypt32.dll | ncrypt.dll | secur32.dll) ;;
        # API sets: loader-resolved forwarders into the above.
        api-ms-win-*.dll | ext-ms-win-*.dll) ;;
        *) foreign="$foreign $dll" ;;
        esac
    done
    if [ -n "$foreign" ]; then
        echo "Error: $bin imports DLLs that are not part of Windows:$foreign" >&2
        echo "MinGW runtime DLLs (libgcc_s_seh-1.dll, libwinpthread-1.dll) mean a C" >&2
        echo "dependency linked against the runner's gcc instead of statically." >&2
        exit 1
    fi
    echo "==> OK: Windows system DLLs only"
    ;;

runtime:*-linux)
    # readelf, not ldd: ldd resolves through the build machine's loader, so a
    # build-machine path in the binary looks satisfied instead of broken.
    if ! command -v readelf >/dev/null 2>&1; then
        echo "Error: no readelf on PATH; cannot read the link metadata of $bin" >&2
        echo "Install binutils." >&2
        exit 1
    fi

    case "$target" in
    x86_64-linux) expected_interp="/lib64/ld-linux-x86-64.so.2" ;;
    aarch64-linux) expected_interp="/lib/ld-linux-aarch64.so.1" ;;
    *)
        echo "Error: no known program interpreter for $target" >&2
        exit 1
        ;;
    esac

    # The interpreter is the one absolute path that must be there; a wrong one
    # fails to exec before main. LC_ALL=C because the match is on a translated
    # binutils message.
    interp=$(LC_ALL=C readelf -l "$bin" | awk -F'[][]' '/Requesting program interpreter/ { print $2 }' | awk '{print $NF}')
    if [ -z "$interp" ]; then
        # The runtime is dynamically linked, so it has one; empty means the
        # parse broke, not that the binary is clean.
        echo "Error: read no program interpreter from $bin — readelf output unrecognized" >&2
        exit 1
    fi
    if [ "$interp" != "$expected_interp" ]; then
        echo "Error: $bin requests program interpreter '$interp'" >&2
        echo "Only $expected_interp exists on end-user machines." >&2
        exit 1
    fi

    dynamic=$(LC_ALL=C readelf -d "$bin")

    # Only $ORIGIN-relative search paths survive leaving the build machine.
    rpaths=$(printf '%s\n' "$dynamic" | awk -F'[][]' '/\(RPATH\)|\(RUNPATH\)/ { print $2 }' | tr ':' '\n')
    foreign=$(printf '%s\n' "$rpaths" | grep -v -e '^$' -e '^[$]ORIGIN' || true)
    if [ -n "$foreign" ]; then
        echo "Error: $bin carries build-machine library search paths:" >&2
        printf '%s\n' "$foreign" | sed 's/^/  /' >&2
        echo "A shipped runtime must have no absolute RPATH/RUNPATH." >&2
        exit 1
    fi

    needed=$(printf '%s\n' "$dynamic" | awk -F'[][]' '/\(NEEDED\)/ { print $2 }')
    if [ -z "$needed" ]; then
        # The runtime is dynamically linked; an empty list means the parse
        # broke, not that the binary is clean.
        echo "Error: read no NEEDED libraries from $bin — readelf output unrecognized" >&2
        exit 1
    fi

    # Allowlist: every entry below is part of a base glibc install. A soname
    # outside it resolves on the runner via -L and is absent on a user's machine.
    foreign=""
    for lib in $needed; do
        case "$lib" in
        libc.so.6 | libm.so.6 | libdl.so.2 | libpthread.so.0 | librt.so.1 | libutil.so.1 | libresolv.so.2) ;;
        libgcc_s.so.1) ;;
        # The interpreter is also listed as NEEDED on some targets.
        ld-linux-x86-64.so.2 | ld-linux-aarch64.so.1) ;;
        *) foreign="$foreign $lib" ;;
        esac
    done
    if [ -n "$foreign" ]; then
        echo "Error: $bin needs libraries beyond a base glibc system:$foreign" >&2
        echo "Anything else must be linked statically or loaded with dlopen." >&2
        exit 1
    fi

    # GLFW loads X11/Wayland/GL with dlopen, whose paths sit in .rodata where
    # none of the checks above can see them.
    if ! command -v strings >/dev/null 2>&1; then
        echo "Error: no strings on PATH; cannot scan $bin for dlopen paths" >&2
        echo "Install binutils." >&2
        exit 1
    fi
    # Captured before filtering: empty output is this scan's pass condition, so
    # a `|| true` on the pipeline would turn a strings failure into a pass.
    if ! bin_strings=$(strings "$bin") || [ -z "$bin_strings" ]; then
        echo "Error: read no strings from $bin — strings failed" >&2
        exit 1
    fi
    foreign=$(printf '%s\n' "$bin_strings" | grep -E '^/[^ ]*\.so(\.[0-9]+)*$' | grep -vxF "$expected_interp" || true)
    if [ -n "$foreign" ]; then
        echo "Error: $bin names shared libraries by absolute path:" >&2
        printf '%s\n' "$foreign" | sed 's/^/  /' >&2
        echo "Only a bare soname resolves on an end-user machine." >&2
        exit 1
    fi
    echo "==> OK: interpreter $interp, no build-machine paths"
    ;;

runtime:*-macos)
    check_macho_system_libs

    # otool -L cannot see a /nix/store LC_RPATH unless something references
    # @rpath/, and the runtime is the one binary built inside nix develop.
    # A binary may legitimately carry no LC_RPATH, so only a tool failure is
    # an error here — emptiness is not.
    if ! load_commands=$(otool -l "$bin"); then
        echo "Error: otool -l failed on $bin; cannot read its LC_RPATH entries" >&2
        exit 1
    fi
    rpaths=$(printf '%s\n' "$load_commands" | awk '$1 == "path" { print $2 }')
    foreign=$(printf '%s\n' "$rpaths" | grep -v -e '^$' -e '^@executable_path' -e '^@loader_path' || true)
    if [ -n "$foreign" ]; then
        echo "Error: $bin carries build-machine runtime search paths:" >&2
        printf '%s\n' "$foreign" | sed 's/^/  /' >&2
        echo "Only @executable_path/@loader_path-relative LC_RPATH entries survive shipping." >&2
        exit 1
    fi

    # A dlopen path lives in __cstring, not in the load commands otool -L reads.
    # Captured before filtering, for the reason given in the Linux branch.
    if ! command -v strings >/dev/null 2>&1; then
        echo "Error: no strings on PATH; cannot scan $bin for dlopen paths" >&2
        echo "Install the Xcode command line tools." >&2
        exit 1
    fi
    if ! bin_strings=$(strings "$bin") || [ -z "$bin_strings" ]; then
        echo "Error: read no strings from $bin — strings failed" >&2
        exit 1
    fi
    foreign=$(printf '%s\n' "$bin_strings" | grep -E '^/[^ ]*\.dylib$' | grep -v -e '^/usr/lib/' -e '^/System/Library/' || true)
    if [ -n "$foreign" ]; then
        echo "Error: $bin names dylibs from outside the OS by absolute path:" >&2
        printf '%s\n' "$foreign" | sed 's/^/  /' >&2
        exit 1
    fi
    echo "==> OK: system dylibs only, no absolute rpaths"
    ;;

*)
    echo "Error: unknown target $target" >&2
    exit 1
    ;;
esac
