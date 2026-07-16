# NBL SDK builder

`./nbl-sdk` produces a relocatable, static-linking Linux/musl SDK for an
x86_64 Linux host. The delivered SDK contains cross toolchains for:

- `aarch64-linux-musl`
- `loongarch64-linux-musl`
- `riscv64-linux-musl`
- `sw_64-linux-musl`
- `x86_64-linux-musl`

Each `<triplet>/` directory is a complete standalone toolchain unit. Copy the
whole directory—rather than only `bin/`—to any location on an x86_64 Linux
host (and optionally rename it); its compiler, sysroot, OpenSSL/libpci
integration, and static `libexec/pkgconf` remain usable without the rest of
the SDK.

The delivered SDK root has no `.host/` directory: each target owns its static
`pkgconf` at `<triplet>/libexec/pkgconf`.

The host entrypoint only checks arguments and rootless Podman, builds or uses
the pinned builder image, and mounts the cache and artifact directories. Every
source download, compilation, validation step, and archive operation happens
inside Podman. The existing `musl-cross-make` submodule is mounted read-only;
the container copies it into its temporary work area and verifies its locked
commit and patchset before use.

## Commands

```sh
# Build the pinned Ubuntu 24.04 builder image.
./nbl-sdk image

# Download each locked source into .nbl-sdk-cache/sources and verify SHA-256.
./nbl-sdk sources

# Build, validate, relocate-check, package, unpack, and validate again.
./nbl-sdk build

# Run only the reusable toolchain checkpoint for one target.
./nbl-sdk toolchains --target aarch64-linux-musl

# Build/retry only static OpenSSL and libpci for that target.
./nbl-sdk libraries --target aarch64-linux-musl

# Materialize the cached complete SDK without creating an archive.
./nbl-sdk assemble

# Compile/link checks for one cached target, including a renamed standalone copy.
# Add --relocate for an additional complete-SDK move check.
./nbl-sdk validate-sdk --target aarch64-linux-musl --relocate

# Package and run the full all-target archive validation from checkpoints.
./nbl-sdk package

# Inspect checkpoint availability and exact container-side log locations.
./nbl-sdk status

# Recheck an existing package in a clean container temporary directory.
./nbl-sdk verify

# Remove generated archives while retaining the verified source cache.
./nbl-sdk clean

# Drop reusable checkpoints but retain verified source downloads.
./nbl-sdk clean --stages

# Explicitly remove both generated archives and the verified source cache.
./nbl-sdk clean --all
```

`VERSION` supplies the default SDK version. `--version`, `--jobs`, `--cache`,
`--output`, and `--image` override the corresponding defaults; run
`./nbl-sdk --help` for the full interface. `--offline` requires an existing
builder image and refuses to download: a missing or corrupted cache entry is a
hard error naming the expected SHA-256.

## Checkpoints and failure isolation

The cache contains three distinct classes of data:

- `sources/`: verified upstream downloads;
- `checkpoints/<key>/`: static stage-one host tools, each final toolchain,
  static `pkgconf`, and separate OpenSSL/libpci overlays per target;
- `checkpoints/<key>/logs/`: one log per stage, such as
  `toolchains/sw_64-linux-musl.log` or
  `libraries/aarch64-linux-musl/openssl.log`.

The key covers the source lock, locked submodule/patch hashes, and an explicit
checkpoint compatibility version. A failed target does not publish its checkpoint; successful prior
targets and libraries are reused on the next invocation. `build --target
<triplet>` intentionally stops after making that target reusable, so it cannot
publish a partial SDK archive. `build` without `--target` orchestrates all
checkpoints and the complete packaging verification.

Checkpoints are mounted only inside Podman and are never copied into the SDK
tree or archive. `clean` retains both source and checkpoint caches; use
`clean --stages` to remove checkpoints or `clean --all` to remove both them and
the verified source cache.

The output is `dist/nbl-sdk-<version>.tar.xz` by default. It contains only the
toolchain payload; no SDK-specific README, manifest, or source-lock files are
added. No activation script is needed. The package verifier extracts the
archive, copies each target directory alone to a renamed location, and verifies
static C/C++/OpenSSL/libpci links from that isolated copy.
Release materialization strips only DWARF debug sections from host-side SDK
ELF tools and target static archives. Pristine reusable checkpoints retain
their symbols, while the delivered toolchains, headers, static libraries, and
pkg-config metadata remain intact. The package verification checks both that
these sections are absent and that every required static C/C++/OpenSSL/libpci
link still succeeds.

## Provenance and reproducibility

[`source-lock.json`](source-lock.json) is machine readable and locks the
container base digest, `musl-cross-make` commit and embedded patchset, every
source URL/version/SHA-256, and the archive timestamp. It is a build-time
input and is not copied into the generated SDK.

The SW64 target uses the existing submodule preset, including its SW8A CPU
constraint. The builder adds no `-march=native`, host tuning, external RPM,
precompiled toolchain, or target execution. OpenSSL is static-only; libpci is
built with DNS, zlib, libkmod, and HWDB backends disabled, so no zlib private
dependency is needed.
