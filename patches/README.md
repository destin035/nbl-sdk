# nbl-sdk source patches

This directory holds patches for source trees that `nbl-sdk` itself unpacks
and builds. Keep a patch beneath a descriptive, versioned path such as
`patches/openssl/3.5.7/0001-example.patch`, then register it in the
`source_patches` array in [`source-lock.json`](../source-lock.json).

Entries are applied in array order after the locked archive has been unpacked
and before that component is configured or compiled:

```json
{
  "source": "openssl",
  "path": "patches/openssl/3.5.7/0001-example.patch",
  "sha256": "<sha256sum of the patch file>",
  "strip": 1
}
```

`source` is the component name in `sources`; `path` is relative to the SDK
root and must stay below `patches/`; `sha256` is required; and `strip` is
optional (it defaults to `1`). Patch files must be regular files, not
symlinks. The current directly built components are `ncurses`, `openssl`,
`pciutils`, `pkgconf`, and `readline`. Adding another directly built component
should reuse the builder's `unpack_source` helper and add its source name to
`DIRECT_PATCH_SOURCES`.

Patch hashes are checked before a build uses its checkpoints. Since the lock
file is part of the checkpoint key, adding, removing, reordering, or updating
a patch together with its registered digest automatically selects a fresh
checkpoint. Patch application uses `patch --force --fuzz=0`, so a patch that
no longer matches fails instead of being applied fuzzily.

Do not use this directory for `musl-cross-make` or any source it manages
(GCC, binutils, musl, and related toolchain inputs). Those continue to use the
submodule's existing `musl-cross-make/patches/<upstream-source-version>/`
mechanism and its separately locked embedded patchset.
