#!/usr/bin/env bash
# Assert a release CLI depends on nothing that only exists on the build machine
# — such a dependency links and runs in CI and fails on every user's machine.
#
# Usage: check-linkage.sh <trolley-target> <cli-path> <macos-deployment-target>
# Normally invoked as `just check-linkage --target <triple>`.
set -euo pipefail

target="${1:?target required}"
cli="${2:?cli path required}"
expected_macos_minos="${3:-}"   # macOS targets only; empty elsewhere

if [ ! -f "$cli" ]; then
    echo "Error: release CLI not found at $cli" >&2
    echo "Build it first: just release-cli --target $target" >&2
    exit 1
fi

echo "==> check-linkage $cli"

case "$target" in
*-macos)
    if [ -z "$expected_macos_minos" ]; then
        echo "Error: no deployment target given for $target" >&2
        exit 1
    fi

    # tail -n +2 drops otool's echo of the file itself.
    libs=$(otool -L "$cli" | tail -n +2 | awk '{print $1}')
    if [ -z "$libs" ]; then
        # Empty means otool broke, not that the binary is clean — and the grep
        # below needs `|| true`, which would mask it.
        echo "Error: read no linked libraries from $cli — otool output unrecognized" >&2
        exit 1
    fi

    # /usr/lib and /System/Library are the dyld shared cache, on every Mac;
    # anything else (/opt/homebrew, /nix/store, an @rpath entry) is runner-only.
    foreign=$(printf '%s\n' "$libs" | grep -v -e '^/usr/lib/' -e '^/System/Library/' || true)
    if [ -n "$foreign" ]; then
        echo "Error: $cli links libraries from outside the OS:" >&2
        printf '%s\n' "$foreign" | sed 's/^/  /' >&2
        echo "Only /usr/lib and /System/Library are present on end-user machines." >&2
        exit 1
    fi

    # An unset MACOSX_DEPLOYMENT_TARGET silently raises the floor to the runner's
    # SDK. Below 10.14 that floor is LC_VERSION_MIN_MACOSX's "version", above it
    # LC_BUILD_VERSION's "minos" — which precedes the linker's own "version" line.
    macos_minos=$(vtool -show-build "$cli" | awk '$1 == "minos" || $1 == "version" { print $2; exit }')
    # vtool prints "13.0" where the env var may say "13"; compare loosely.
    if [ "${macos_minos%.0}" != "${expected_macos_minos%.0}" ]; then
        echo "Error: $cli minimum macOS is '${macos_minos:-<none>}', expected '$expected_macos_minos'" >&2
        echo "MACOSX_DEPLOYMENT_TARGET did not reach the release build." >&2
        exit 1
    fi
    echo "==> OK: system dylibs only, minimum macOS $macos_minos"
    ;;

*-linux)
    # ldd says "not a dynamic executable" for a classic static binary and
    # "statically linked" for the static-PIE rustc emits; accept either.
    out=$(ldd "$cli" 2>&1 || true)
    case "$out" in
    *"not a dynamic executable"* | *"statically linked"*) ;;
    *)
        echo "Error: $cli is a dynamic executable; the musl build must be static:" >&2
        printf '%s\n' "$out" | sed 's/^/  /' >&2
        exit 1
        ;;
    esac
    echo "==> OK: statically linked"
    ;;

*-windows)
    # rustup's windows-gnu toolchain ships no binutils; objdump comes from the
    # runner's MSYS2/mingw install.
    objdump=""
    for candidate in objdump x86_64-w64-mingw32-objdump /c/msys64/mingw64/bin/objdump /c/msys64/usr/bin/objdump; do
        if command -v "$candidate" >/dev/null 2>&1; then objdump="$candidate"; break; fi
    done
    if [ -z "$objdump" ]; then
        echo "Error: no objdump on PATH; cannot read the import table of $cli" >&2
        echo "Install MSYS2 binutils or add C:\\msys64\\mingw64\\bin to PATH." >&2
        exit 1
    fi

    dlls=$("$objdump" -p "$cli" | awk '$1 == "DLL" && $2 == "Name:" { print $3 }')
    if [ -z "$dlls" ]; then
        # Every PE imports something; an empty list means the parse broke, not
        # that the binary is clean.
        echo "Error: read no DLL imports from $cli — objdump output unrecognized" >&2
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
        echo "Error: $cli imports DLLs that are not part of Windows:$foreign" >&2
        echo "MinGW runtime DLLs (libgcc_s_seh-1.dll, libwinpthread-1.dll) mean a C" >&2
        echo "dependency linked against the runner's gcc instead of statically." >&2
        exit 1
    fi
    echo "==> OK: Windows system DLLs only"
    ;;

*)
    echo "Error: unknown target $target" >&2
    exit 1
    ;;
esac
