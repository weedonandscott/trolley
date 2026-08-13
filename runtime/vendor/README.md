# Vendored files

Third-party files the runtime ships beside its executable, one directory per target:

```
runtime/vendor/<target>/
    vendor.json     what this target vendors, and the sha256 of each file
    <files>         stored under the name they are installed as
```

`build.zig` reads `vendor/<target>/vendor.json`, installs everything it lists into
`zig-out*/bin/`, and generates the list of files the runtime verifies at startup. A target with
no directory vendors nothing and needs no other change. `vendor.json` is the only place the
file list lives.

Today only the Windows targets vendor anything: Microsoft's redistributable ConPTY.

## vendor.json

```json
{
  "source": { "package": "…", "version": "…", "nupkg_sha256": "…" },
  "files": {
    "conpty.dll": { "from": "runtimes/win-x64/native/conpty.dll",
                    "size": 109920, "sha256": "…", "verify_at_startup": true }
  }
}
```

`source` is provenance, for identifying a shipped file later. Each key under `files` is the
installed filename; `from` records where it came from. `verify_at_startup` marks a file the
runtime hashes before anything loads it — set it for code, not for a licence notice nobody
executes.

`just verify-vendored` re-hashes every file in every target directory against its manifest. It
also fails on a file that is present but unlisted, which would otherwise ship without ever being
checked. It runs in CI before the Windows build, and `just release` runs it for every target, so
a corrupted or hand-edited file cannot reach a release artifact.

It needs `jq`, which the nix devShell provides. Outside that shell: `apt install jq`,
`brew install jq`, or `pacman -S jq` under MSYS2.

That is an integrity check, not a provenance one: each manifest is written from the same
download it later validates, so it proves the bytes have not changed since they were vendored,
not that they are upstream's. Establishing the latter means comparing against the publisher's
digest at refresh time, which this does not do.

The same hashes are compiled into the runtime and checked at startup. That catches a truncated
or quarantine-damaged file, and on a machine with an application-control policy it covers the
gap those policies leave: executables are validated at load, the libraries beside them usually
are not.

## Why ConPTY is vendored

The Windows console host translates terminal input into console input records and re-encodes it
for the client. Before [microsoft/terminal#17741][pr] (Aug 2024, `release-1.22`) it *dropped*
input sequences it did not recognize instead of passing them through. Every kitty keyboard
sequence that carries a colon sub-parameter — `ESC[98:66;134u` for ctrl+shift+B, and every key
release under the event-types flag — is such a sequence, so on any Windows whose console predates
that fix those keys never reach the app at all.

conhost is versioned with the OS build, so an affected machine (Windows Server 2022 is pinned to
build 20348) never receives the fix through updates. Bundling the redistributable pair decouples
us from the OS version. Windows Terminal, wezterm, alacritty and node-pty all do the same.

`conpty.dll` looks for `OpenConsole.exe` in its own directory and silently falls back to the
system console host if it is missing, which is why both are installed flat beside the executable
and why the runtime refuses to start when either is absent.

## Version pinning

The version scheme is `<terminal branch major>.<minor>.<yyMM><ddNNN>` — not semver. Only the
leading `1.<minor>` carries meaning: it names the `microsoft/terminal` branch the build came
from. `1.24.*` is the stable servicing branch; `1.25.*` is `main` and is published only as
`-preview`.

The trailing group is regrouped into the file version stamped in the binaries: package
`1.24.260710001` is file version `1.24.2607.10001`, i.e. `yyMM` = `2607` and `ddNNN` = `10001`.
`vendor.json` records both, so a shipped binary can be traced back to a package.

We pin `1.24`. The fix we depend on (#17741) is in `release-1.22` and later, so stable `1.24`
has it. The kitty keyboard protocol implementation ([#19817][kitty], Feb 2026) is on
`release-1.25` and `main` only — and we deliberately do not want it: it makes the console host
parse and re-encode kitty sequences itself rather than passing the terminal's bytes through
untouched.

Re-run the Windows keyboard QA matrix when bumping, especially across a `1.25` promotion to
stable.

## Updating

By hand. Each file's `from` field records where it came from, so the manifest tells you what to
fetch and where to put it.

For ConPTY, download the nupkg (it is a plain zip) from

```
https://api.nuget.org/v3-flatcontainer/microsoft.windows.console.conpty/<version>/microsoft.windows.console.conpty.<version>.nupkg
```

Extract each `from` path over the file of the same name in each target directory. Update
`version`, `file_version` and `nupkg_sha256` under `source`, and each file's `size` and `sha256`.
Then run `just verify-vendored` — it fails until every recorded hash matches the bytes on disk,
so a file you forgot to update, or a hash you forgot to change, does not get past you.

`conpty-LICENSE.txt` is not in the nupkg. It comes from the terminal repo, so check it by hand
when bumping across a licence change. MIT requires the notice to travel with the code, and it
ships in every artifact.

Run the Windows sanity test and the keyboard matrix afterwards.

## The list that is repeated

`cli/src/commands/common.rs` has its own copy of the Windows filenames. That is deliberate: it
answers a different question — what a runtime *tarball* must contain to be usable — and the CLI
can be pointed at a runtime it was not built beside. Everything inside this tree reads the
manifests.

[pr]: https://github.com/microsoft/terminal/pull/17741
[kitty]: https://github.com/microsoft/terminal/pull/19817
