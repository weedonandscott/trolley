# Dist listing snapshots

One file per target: the exact, complete, `LC_ALL=C`-sorted listing of the
`dist/` directory that `trolley package` (default formats) must produce. The
sanity test (`just sanity-test --target <target>`) diffs the real listing
against these files; the filename structure is a released contract, so any
mismatch is a breaking change.

These files are generated — do not hand-edit. To accept an intentional
change, run `just sanity-test --target <target> --bless`, then review the
git diff.

## Why the pacman tarball is producer-named

Every other artifact's filename is composed by trolley from config
(`config/src/lib.rs`, `PlannedFormat::artifact_name`). The pacman tarball
alone keeps whatever name cargo-packager gave it
(`{main_binary_name}_{version}_{arch}`, which resolves to the slug because
the Linux main binary is the slug-named wrapper script): the generated
PKGBUILD's `source=()` references that tarball byte-for-byte, so renaming
it would break `makepkg`. The pair is pinned instead, and the sanity test
greps the PKGBUILD to prove the cross-reference holds.
