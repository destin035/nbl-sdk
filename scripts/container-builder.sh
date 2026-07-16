#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# This program is the only place that downloads sources, compiles, validates,
# or creates archives.  It is invoked by the small host-side ./nbl-sdk wrapper
# from the pinned Ubuntu container image.
set -Eeuo pipefail

readonly SRC_ROOT=/src
readonly CACHE_ROOT=/cache
readonly OUT_ROOT=/out
readonly LOCK_FILE="$SRC_ROOT/source-lock.json"
readonly MCM_DIR="$SRC_ROOT/musl-cross-make"
readonly -a TARGETS=(
  aarch64-linux-musl
  loongarch64-linux-musl
  riscv64-linux-musl
  sw_64-linux-musl
  x86_64-linux-musl
)

WORK_DIR=
ARCHIVE_TMP=
JOBS=1
OFFLINE=0
SDK_VERSION=
TARGET_FILTER=
CHECKPOINT_KEY=
CHECKPOINT_ROOT=

readonly CHECKPOINT_SCHEMA=1
readonly RELEASE_PROFILE=debug-symbols-stripped-v2

log() {
  printf 'nbl-sdk-container: %s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

cleanup() {
  local status=$?
  if [[ -n ${ARCHIVE_TMP:-} ]]; then
    rm -f -- "$ARCHIVE_TMP" || true
  fi
  if [[ -n ${WORK_DIR:-} && -d ${WORK_DIR:-} ]]; then
    rm -rf -- "$WORK_DIR" || true
  fi
  exit "$status"
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage inside the builder image:
  nbl-sdk-builder fetch-sources [--offline]
  nbl-sdk-builder build --version VERSION --jobs N [--target TRIPLET] [--offline]
  nbl-sdk-builder toolchains --version VERSION --jobs N [--target TRIPLET] [--offline]
  nbl-sdk-builder libraries --version VERSION --jobs N [--target TRIPLET] [--offline]
  nbl-sdk-builder assemble --version VERSION [--offline]
  nbl-sdk-builder validate-sdk --version VERSION [--target TRIPLET] [--relocate] [--offline]
  nbl-sdk-builder package --version VERSION --jobs N [--offline]
  nbl-sdk-builder status --version VERSION [--target TRIPLET]
  nbl-sdk-builder verify-archive /input/nbl-sdk-<version>.tar.xz
  nbl-sdk-builder clean [--stages] [--all]
EOF
}

require_commands() {
  local command
  for command in ar file find git make python3 readelf rsync sha256sum stat strip tar xz; do
    command -v "$command" >/dev/null 2>&1 || die "required container command is missing: $command"
  done
}

lock_scalar() {
  local key=$1
  python3 - "$LOCK_FILE" "$key" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding='utf-8'))
value = data
for part in sys.argv[2].split('.'):
    value = value[part]
if isinstance(value, (dict, list)):
    raise SystemExit('lock scalar requested for a structured value')
print(value)
PY
}

source_version() {
  local name=$1
  python3 - "$LOCK_FILE" "$name" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding='utf-8'))
for source in data['sources']:
    if source['name'] == sys.argv[2]:
        print(source['version'])
        break
else:
    raise SystemExit('source not present in lock: ' + sys.argv[2])
PY
}

load_lock() {
  [[ -r "$LOCK_FILE" ]] || die "missing source lock: $LOCK_FILE"
  SOURCE_DATE_EPOCH=$(lock_scalar source_date_epoch)
  MCM_COMMIT=$(lock_scalar musl_cross_make.commit)
  MCM_ARCHIVE_SHA256=$(lock_scalar musl_cross_make.archive_sha256)
  PATCHSET_SHA256=$(python3 - "$LOCK_FILE" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
print(data['patches'][0]['sha256'])
PY
)
  export SOURCE_DATE_EPOCH TZ=UTC LC_ALL=C
  export PYTHONHASHSEED=0
}

is_known_target() {
  local candidate=$1 target
  for target in "${TARGETS[@]}"; do
    [[ "$candidate" == "$target" ]] && return 0
  done
  return 1
}

target_is_selected() {
  [[ -z "$TARGET_FILTER" || "$TARGET_FILTER" == "$1" ]]
}

ensure_work_dir() {
  if [[ -z "$WORK_DIR" ]]; then
    WORK_DIR=$(mktemp -d /work/nbl-sdk-work.XXXXXX)
  fi
}

init_checkpoint() {
  [[ -n "$SDK_VERSION" ]] || die 'a checkpointed command needs --version'

  local lock_sha builder_sha computed_key compatible_root
  lock_sha=$(sha256sum "$LOCK_FILE" | awk '{print $1}')
  builder_sha=$(sha256sum "$0" | awk '{print $1}')
  computed_key=$(printf '%s\n' \
    "schema=$CHECKPOINT_SCHEMA" \
    "source-lock=$lock_sha" \
    "mcm-commit=$MCM_COMMIT" \
    "mcm-archive=$MCM_ARCHIVE_SHA256" \
    "patchset=$PATCHSET_SHA256" | sha256sum | awk '{print $1}')
  if [[ ! -d "$CACHE_ROOT/checkpoints/$computed_key" ]]; then
    compatible_root=$(python3 - "$CACHE_ROOT/checkpoints" "$CHECKPOINT_SCHEMA" "$lock_sha" "$MCM_COMMIT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
if not root.is_dir():
    raise SystemExit
for state_path in sorted(root.glob('*/STATE.json')):
    try:
        state = json.loads(state_path.read_text(encoding='utf-8'))
    except (OSError, json.JSONDecodeError):
        continue
    if (state.get('schema') == int(sys.argv[2])
            and state.get('source_lock_sha256') == sys.argv[3]
            and state.get('musl_cross_make_commit') == sys.argv[4]):
        print(state_path.parent)
        break
PY
)
    if [[ -n "$compatible_root" && -d "$compatible_root" ]]; then
      mkdir -p "$CACHE_ROOT/checkpoints"
      mv -- "$compatible_root" "$CACHE_ROOT/checkpoints/$computed_key"
      log "migrated compatible checkpoint: $computed_key"
    fi
  fi
  CHECKPOINT_KEY=$computed_key
  CHECKPOINT_ROOT="$CACHE_ROOT/checkpoints/$CHECKPOINT_KEY"
  mkdir -p "$CHECKPOINT_ROOT" "$CHECKPOINT_ROOT/logs" "$CHECKPOINT_ROOT/.tmp"

  if [[ ! -f "$CHECKPOINT_ROOT/STATE.json" ]]; then
    python3 - "$CHECKPOINT_ROOT/STATE.json" "$CHECKPOINT_KEY" "$SDK_VERSION" "$lock_sha" "$builder_sha" "$MCM_COMMIT" <<'PY'
import json
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(json.dumps({
    'schema': 1,
    'checkpoint_key': sys.argv[2],
    'sdk_version': sys.argv[3],
    'source_lock_sha256': sys.argv[4],
    'builder_sha256': sys.argv[5],
    'musl_cross_make_commit': sys.argv[6],
}, indent=2, sort_keys=True) + '\n', encoding='utf-8')
PY
  fi
  log "checkpoint: $CHECKPOINT_ROOT (key $CHECKPOINT_KEY)"
}

prepare_pipeline() {
  load_lock
  validate_submodule
  fetch_sources
  init_checkpoint
}

prepare_status() {
  load_lock
  validate_submodule
  init_checkpoint
}

run_step() {
  local label=$1
  shift
  [[ -n "$CHECKPOINT_ROOT" ]] || die 'internal error: checkpoint is not initialized'
  local step_log="$CHECKPOINT_ROOT/logs/$label.log" status
  mkdir -p "$(dirname -- "$step_log")"
  log "step start: $label (log: $step_log)"
  if "$@" >"$step_log" 2>&1; then
    log "step passed: $label"
    return 0
  fi
  status=$?
  log "step failed: $label (exit $status; full log: $step_log)"
  tail -n 120 "$step_log" >&2 || true
  return "$status"
}

commit_checkpoint_dir() {
  local temporary=$1 destination=$2
  [[ -d "$temporary" ]] || die "internal error: checkpoint temporary directory is missing: $temporary"
  mkdir -p "$(dirname -- "$destination")"
  rm -rf -- "$destination"
  mv -- "$temporary" "$destination"
}

validate_submodule() {
  [[ -d "$MCM_DIR" ]] || die 'musl-cross-make submodule directory is missing'
  [[ -e "$MCM_DIR/.git" ]] || die 'musl-cross-make is not an initialized git submodule'

  local actual_commit actual_archive actual_patchset
  actual_commit=$(git -C "$MCM_DIR" rev-parse HEAD)
  [[ "$actual_commit" == "$MCM_COMMIT" ]] || die "musl-cross-make commit mismatch: expected $MCM_COMMIT, got $actual_commit"
  git -C "$MCM_DIR" diff --quiet || die 'musl-cross-make has unstaged changes'
  git -C "$MCM_DIR" diff --cached --quiet || die 'musl-cross-make has staged changes'
  [[ -z $(git -C "$MCM_DIR" status --porcelain --untracked-files=all) ]] || die 'musl-cross-make has untracked changes'

  actual_archive=$(git -C "$MCM_DIR" archive --format=tar "$MCM_COMMIT" | sha256sum | awk '{print $1}')
  [[ "$actual_archive" == "$MCM_ARCHIVE_SHA256" ]] || die 'musl-cross-make archive hash does not match source-lock.json'
  actual_patchset=$(git -C "$MCM_DIR" archive --format=tar "$MCM_COMMIT" patches | sha256sum | awk '{print $1}')
  [[ "$actual_patchset" == "$PATCHSET_SHA256" ]] || die 'musl-cross-make embedded patchset hash does not match source-lock.json'
}

fetch_sources() {
  local source_cache="$CACHE_ROOT/sources"
  mkdir -p "$source_cache"

  python3 - "$LOCK_FILE" "$source_cache" "$OFFLINE" <<'PY'
import hashlib
import json
import os
import pathlib
import subprocess
import sys

lock_path = pathlib.Path(sys.argv[1])
cache = pathlib.Path(sys.argv[2])
offline = sys.argv[3] == '1'
data = json.loads(lock_path.read_text(encoding='utf-8'))

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

for source in data['sources']:
    destination = cache / source['file']
    expected = source['sha256'].lower()
    if destination.is_file():
        actual = digest(destination)
        if actual == expected:
            destination.with_name(destination.name + '.part').unlink(missing_ok=True)
            print(f"using verified cache: {source['file']}", file=sys.stderr)
            continue
        if offline:
            raise SystemExit(
                f"offline cache hash mismatch for {source['file']}: expected {expected}, got {actual}"
            )
        print(f"discarding corrupt cache entry: {source['file']}", file=sys.stderr)
        destination.unlink()
    elif destination.exists():
        if offline:
            raise SystemExit(f"offline cache entry is not a regular file: {destination}")
        destination.unlink()

    if offline:
        raise SystemExit(
            f"offline cache miss: {source['file']} (expected SHA-256 {expected})"
        )

    failures = []
    for url in source['urls']:
        partial = destination.with_name(destination.name + '.part')
        partial.unlink(missing_ok=True)
        print(f"downloading {source['file']} from {url}", file=sys.stderr)
        command = [
            'curl', '--fail', '--location', '--silent', '--show-error',
            '--retry', '3', '--retry-all-errors', '--proto', '=https',
            '--output', str(partial), url,
        ]
        result = subprocess.run(command, check=False)
        if result.returncode != 0:
            failures.append(f'{url} (curl exit {result.returncode})')
            partial.unlink(missing_ok=True)
            continue
        if not partial.is_file():
            failures.append(f'{url} (curl reported success without an output file)')
            continue
        actual = digest(partial)
        if actual != expected:
            failures.append(f'{url} (SHA-256 {actual})')
            partial.unlink(missing_ok=True)
            continue
        os.replace(partial, destination)
        print(f"cached verified source: {source['file']}", file=sys.stderr)
        break
    else:
        joined = '; '.join(failures) or 'no URL attempted'
        raise SystemExit(
            f"could not obtain a verified copy of {source['file']}; attempts: {joined}"
        )
PY
}

append_mcm_common_config() {
  local config=$1 host_cc=$2 host_cxx=$3
  local libtool_wrapper
  libtool_wrapper="$(dirname -- "$config")/nbl-sdk-static-libtool"
  printf '%s\n' \
    '' \
    '# Added by nbl-sdk; this working copy is outside the read-only submodule.' \
    "SOURCES = $CACHE_ROOT/sources" \
    'GMP_VER = 6.3.0' \
    'MPC_VER = 1.3.1' \
    'MPFR_VER = 4.2.2' \
    'COMMON_CONFIG += --disable-nls' \
    'GCC_CONFIG += --disable-lto' \
    '# GNU libtool consumes -static; this wrapper maps program links to -all-static.' \
    "LIBTOOL = $libtool_wrapper" \
    'COMMON_CONFIG += LDFLAGS="-static"' \
    "COMMON_CONFIG += CC=\"$host_cc\" CXX=\"$host_cxx\"" \
    >>"$config"
}

write_mcm_config() {
  local work_mcm=$1 target=$2 host_cc=$3 host_cxx=$4 preset=${5:-}
  local config="$work_mcm/config.mak"

  if [[ -n "$preset" ]]; then
    [[ -r "$work_mcm/$preset" ]] || die "missing musl-cross-make preset: $preset"
    cp "$work_mcm/$preset" "$config"
  else
    printf '%s\n' \
      "TARGET = $target" \
      'BINUTILS_VER = 2.44' \
      'GCC_VER = 15.1.0' \
      'MUSL_VER = 1.2.6' \
      'LINUX_VER = 6.6' \
      >"$config"
  fi

  append_mcm_common_config "$config" "$host_cc" "$host_cxx"
}

assert_static_host_elf() {
  local executable=$1
  local description
  description=$(file -Lb "$executable")
  [[ "$description" == ELF* ]] || return 0
  log "host ELF: $executable: $description"
  if readelf -lW "$executable" | grep -Eq '(^|[[:space:]])INTERP([[:space:]]|$)|Requesting program interpreter'; then
    die "host SDK tool has a PT_INTERP segment: $executable"
  fi
  if readelf -dW "$executable" 2>/dev/null | grep -q '(NEEDED)'; then
    die "host SDK tool has a dynamic dependency: $executable"
  fi
}

assert_static_tool_tree() {
  local root=$1
  local candidate
  while IFS= read -r -d '' candidate; do
    assert_static_host_elf "$candidate"
  done < <(
    find "$root/bin" "$root/libexec" -type f -perm /111 -print0 2>/dev/null || true
  )
}

is_x86_64_host_elf() {
  local candidate=$1 machine
  readelf -h "$candidate" >/dev/null 2>&1 || return 1
  machine=$(readelf -h "$candidate" 2>/dev/null | awk -F: '
    $1 ~ /Machine/ {
      value = $2
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
    }
    END { print value }
  ')
  [[ "$machine" == *X86-64* ]]
}

release_strip_host_elf_debug_symbols() {
  local sdk_root=$1 target root record inode candidate canonical before after
  local stripped=0 saved=0 relinked=0
  local -A canonical_by_inode=()
  local -A stripped_by_inode=()

  for target in "${TARGETS[@]}"; do
    target_is_selected "$target" || continue
    root="$sdk_root/$target"
    [[ -d "$root/bin" || -d "$root/libexec" ]] || continue
    while IFS= read -r -d '' record; do
      inode=${record%%$'\t'*}
      candidate=${record#*$'\t'}
      if [[ -n ${canonical_by_inode[$inode]+present} ]]; then
        if [[ -n ${stripped_by_inode[$inode]+present} ]]; then
          canonical=${canonical_by_inode[$inode]}
          rm -f -- "$candidate"
          ln -- "$canonical" "$candidate"
          relinked=$((relinked + 1))
        fi
        continue
      fi
      canonical_by_inode[$inode]=$candidate
      is_x86_64_host_elf "$candidate" || continue
      before=$(stat -c %s "$candidate")
      strip --strip-debug "$candidate"
      after=$(stat -c %s "$candidate")
      (( after <= before )) || die "debug stripping unexpectedly grew host ELF: $candidate"
      saved=$((saved + before - after))
      stripped=$((stripped + 1))
      stripped_by_inode[$inode]=1
    done < <(
      find "$root/bin" "$root/libexec" -type f -printf '%D:%i\t%p\0' 2>/dev/null || true
    )
  done
  log "release profile $RELEASE_PROFILE: stripped $stripped host ELF files ($saved bytes; restored $relinked hard links)"
}

release_strip_target_static_archives() {
  local sdk_root=$1 target=$2 target_root target_strip target_ranlib
  local record inode candidate canonical before after strip_tool ranlib_tool
  local stripped=0 saved=0 relinked=0 host_archives=0
  local -A canonical_by_inode=()
  local -A stripped_by_inode=()

  target_root="$sdk_root/$target"
  target_strip="$target_root/bin/$target-strip"
  target_ranlib="$target_root/bin/$target-ranlib"
  [[ -x "$target_strip" ]] || die "release profile is missing $target-strip"
  [[ -x "$target_ranlib" ]] || die "release profile is missing $target-ranlib"

  while IFS= read -r -d '' record; do
    inode=${record%%$'\t'*}
    candidate=${record#*$'\t'}
    if [[ -n ${canonical_by_inode[$inode]+present} ]]; then
      if [[ -n ${stripped_by_inode[$inode]+present} ]]; then
        canonical=${canonical_by_inode[$inode]}
        rm -f -- "$candidate"
        ln -- "$canonical" "$candidate"
        relinked=$((relinked + 1))
      fi
      continue
    fi
    canonical_by_inode[$inode]=$candidate
    before=$(stat -c %s "$candidate")
    strip_tool=$target_strip
    ranlib_tool=$target_ranlib
    # Binutils installs a small x86_64 host BFD plugin archive below every
    # cross-toolchain prefix.  A target strip silently leaves it untouched;
    # detect it from all archive members and use the host binutils instead.
    if readelf -h "$candidate" 2>/dev/null | awk -F: '
      $1 ~ /Machine/ {
        value = $2
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        seen = 1
        if (value !~ /X86-64/) other = 1
      }
      END { exit (seen && !other) ? 0 : 1 }
    '; then
      strip_tool=strip
      ranlib_tool=ranlib
      host_archives=$((host_archives + 1))
    fi
    "$strip_tool" --strip-debug "$candidate"
    "$ranlib_tool" "$candidate"
    after=$(stat -c %s "$candidate")
    (( after <= before )) || die "debug stripping unexpectedly grew static archive: $candidate"
    saved=$((saved + before - after))
    stripped=$((stripped + 1))
    stripped_by_inode[$inode]=1
  done < <(find "$target_root" -type f -name '*.a' -printf '%D:%i\t%p\0')
  log "release profile $RELEASE_PROFILE: stripped $stripped static archives for $target ($saved bytes; $host_archives x86_64-handled archives; restored $relinked hard links)"
}

apply_release_profile() {
  local sdk_root=$1 target
  release_strip_host_elf_debug_symbols "$sdk_root"
  for target in "${TARGETS[@]}"; do
    target_is_selected "$target" || continue
    release_strip_target_static_archives "$sdk_root" "$target"
  done
}

assert_no_debug_sections() {
  local reader=$1 candidate=$2
  "$reader" -SW "$candidate" >/dev/null 2>&1 || die "cannot inspect release artifact for debug sections: $candidate"
  if "$reader" -SW "$candidate" 2>/dev/null | awk '
    $2 ~ /^\.(debug|zdebug)/ || $3 ~ /^\.(debug|zdebug)/ { found = 1 }
    END { exit found ? 0 : 1 }
  '; then
    die "release profile left debug sections in: $candidate"
  fi
}

assert_toolchain_release_profile() {
  local toolchain_root=$1 target=$2 candidate reader
  while IFS= read -r -d '' candidate; do
    is_x86_64_host_elf "$candidate" || continue
    assert_no_debug_sections readelf "$candidate"
  done < <(
    find "$toolchain_root/bin" "$toolchain_root/libexec" -type f -print0 2>/dev/null || true
  )

  reader="$toolchain_root/bin/$target-readelf"
  [[ -x "$reader" ]] || die "release profile is missing $target-readelf"
  while IFS= read -r -d '' candidate; do
    assert_no_debug_sections "$reader" "$candidate"
  done < <(find "$toolchain_root" -type f -name '*.a' -print0)
}

assert_release_profile() {
  local sdk_root=$1 target
  for target in "${TARGETS[@]}"; do
    target_is_selected "$target" || continue
    assert_toolchain_release_profile "$sdk_root/$target" "$target"
  done
}

build_mcm_toolchain() {
  local work_mcm=$1 target=$2 output=$3 host_cc=$4 host_cxx=$5 preset=${6:-}
  write_mcm_config "$work_mcm" "$target" "$host_cc" "$host_cxx" "$preset"
  rm -rf -- "$output"
  mkdir -p "$output"
  log "building musl-cross-make toolchain: $target"
  make -C "$work_mcm" "-j$JOBS" "OUTPUT=$output" install
}

prepare_mcm_worktree() {
  local destination=$1
  rsync -a --delete --exclude='.git' "$MCM_DIR/" "$destination/"
  printf '%s\n' \
    '#!/bin/sh' \
    '# Force static host programs without changing the source submodule.' \
    'set -eu' \
    'real_libtool=' \
    'for candidate in ./libtool ../libtool ../../libtool; do' \
    '  if [ -f "$candidate" ]; then' \
    '    real_libtool=$candidate' \
    '    break' \
    '  fi' \
    'done' \
    '[ -n "$real_libtool" ] || {' \
    '  printf "%s\\n" "nbl-sdk static libtool wrapper: generated libtool was not found" >&2' \
    '  exit 127' \
    '}' \
    'mode_link=0' \
    'output=' \
    'expect_output=0' \
    'for argument in "$@"; do' \
    '  if [ "$expect_output" -eq 1 ]; then' \
    '    output=$argument' \
    '    expect_output=0' \
    '    continue' \
    '  fi' \
    '  case "$argument" in' \
    '    --mode=link) mode_link=1 ;;' \
    '    -o) expect_output=1 ;;' \
    '  esac' \
    'done' \
    'if [ "$mode_link" -eq 1 ]; then' \
    '  case "$output" in' \
    '    *.a|*.la|*.so|*.so.*) exec "$real_libtool" "$@" ;;' \
    '    *) exec "$real_libtool" "$@" -all-static ;;' \
    '  esac' \
    'fi' \
    'exec "$real_libtool" "$@"' \
    >"$destination/nbl-sdk-static-libtool"
  chmod 0755 "$destination/nbl-sdk-static-libtool"
}

build_stage_one() {
  local work_mcm=$1 stage_one=$2
  build_mcm_toolchain "$work_mcm" x86_64-linux-musl "$stage_one" 'gcc -static' 'g++ -static'
  [[ -x "$stage_one/bin/x86_64-linux-musl-gcc" ]] || die 'stage-one GCC was not installed'
  [[ -x "$stage_one/bin/x86_64-linux-musl-g++" ]] || die 'stage-one G++ was not installed'
  assert_static_tool_tree "$stage_one"
}

preset_for_target() {
  case "$1" in
    loongarch64-linux-musl) printf '%s\n' 'presets/loongarch64-linux-musl' ;;
    sw_64-linux-musl) printf '%s\n' 'presets/sw_64-linux-musl' ;;
    *) printf '%s\n' '' ;;
  esac
}

openssl_target_for() {
  case "$1" in
    aarch64-linux-musl) printf '%s\n' linux-aarch64 ;;
    loongarch64-linux-musl) printf '%s\n' linux64-loongarch64 ;;
    riscv64-linux-musl) printf '%s\n' linux64-riscv64 ;;
    sw_64-linux-musl) printf '%s\n' linux-generic64 ;;
    x86_64-linux-musl) printf '%s\n' linux-x86_64 ;;
    *) die "unknown OpenSSL target: $1" ;;
  esac
}

write_openssl_pc_files() {
  local sysroot=$1 version=$2 pcdir
  pcdir="$sysroot/lib/pkgconfig"
  mkdir -p "$pcdir"
  printf '%s\n' \
    'prefix=/' \
    'exec_prefix=${prefix}' \
    'libdir=${exec_prefix}lib' \
    'includedir=${prefix}include' \
    '' \
    'Name: libcrypto' \
    'Description: OpenSSL cryptography library (static)' \
    "Version: $version" \
    'Libs: -L${libdir} -lcrypto' \
    'Libs.private: -ldl -pthread' \
    'Cflags: -I${includedir}' \
    >"$pcdir/libcrypto.pc"
  printf '%s\n' \
    'prefix=/' \
    'exec_prefix=${prefix}' \
    'libdir=${exec_prefix}lib' \
    'includedir=${prefix}include' \
    '' \
    'Name: libssl' \
    'Description: OpenSSL TLS library (static)' \
    "Version: $version" \
    'Requires.private: libcrypto' \
    'Libs: -L${libdir} -lssl' \
    'Cflags: -I${includedir}' \
    >"$pcdir/libssl.pc"
  printf '%s\n' \
    'prefix=/' \
    'exec_prefix=${prefix}' \
    'libdir=${exec_prefix}lib' \
    'includedir=${prefix}include' \
    '' \
    'Name: OpenSSL' \
    'Description: Secure Sockets Layer and cryptography libraries' \
    "Version: $version" \
    'Requires: libssl libcrypto' \
    'Cflags: -I${includedir}' \
    >"$pcdir/openssl.pc"
}

build_openssl() {
  local workspace=$1 sdk_root=$2 target=$3
  local sysroot="$sdk_root/$target/$target"
  local source_root="$workspace/openssl-$target"
  local config openssl_version
  config=$(openssl_target_for "$target")
  openssl_version=$(source_version openssl)

  rm -rf -- "$source_root"
  tar -xzf "$CACHE_ROOT/sources/openssl-$openssl_version.tar.gz" -C "$workspace"
  mv "$workspace/openssl-$openssl_version" "$source_root"

  local -a options=(no-apps no-asm no-dso no-module no-shared no-tests no-zlib)
  # SW64 intentionally stays on OpenSSL's generic C/no-asm implementation.
  # no-asm is also used for the other targets to keep the SDK's CPU baseline
  # entirely under musl-cross-make/GCC rather than OpenSSL per-CPU assembly.
  log "building static OpenSSL for $target ($config)"
  (
    cd "$source_root"
    export PATH="$sdk_root/$target/bin:$PATH"
    env \
      AR=ar \
      CC=gcc \
      CXX=g++ \
      CROSS_COMPILE="$target-" \
      RANLIB=ranlib \
      ./Configure "$config" --cross-compile-prefix="$target-" \
      "${options[@]}" --prefix=/ --libdir=lib
    make "-j$JOBS" build_sw
    make DESTDIR="$sysroot" install_sw
  )

  [[ -f "$sysroot/include/openssl/evp.h" ]] || die "OpenSSL headers missing for $target"
  [[ -f "$sysroot/lib/libssl.a" ]] || die "libssl.a missing for $target"
  [[ -f "$sysroot/lib/libcrypto.a" ]] || die "libcrypto.a missing for $target"
  if find "$sysroot/lib" -maxdepth 1 -type f \( -name 'libssl.so*' -o -name 'libcrypto.so*' \) -print -quit | grep -q .; then
    die "OpenSSL installed a shared library for $target"
  fi
  write_openssl_pc_files "$sysroot" "$openssl_version"
}

build_pciutils() {
  local workspace=$1 sdk_root=$2 target=$3
  local sysroot="$sdk_root/$target/$target"
  local source_root="$workspace/pciutils-$target"
  local pciutils_version pci_host
  pciutils_version=$(source_version pciutils)
  # pciutils wants CPU-OS here, not the complete GNU-style target triplet.
  # Supplying x86_64-linux-musl would make it treat "musl" as the OS.
  pci_host=${target%-musl}

  rm -rf -- "$source_root"
  tar -xJf "$CACHE_ROOT/sources/pciutils-$pciutils_version.tar.xz" -C "$workspace"
  mv "$workspace/pciutils-$pciutils_version" "$source_root"

  # Explicitly disable every optional backend that would pull a target-side
  # runtime dependency into libpci.  Zlib is therefore not a dependency of
  # this SDK's libpci configuration and is intentionally not shipped.
  log "building static pciutils libpci for $target"
  (
    export PATH="$sdk_root/$target/bin:$PATH"
    make -C "$source_root" "-j$JOBS" \
      "CROSS_COMPILE=$target-" \
      "HOST=$pci_host" \
      DNS=no HWDB=no LIBKMOD=no SHARED=no ZLIB=no \
      PREFIX=/ INCDIR=/include LIBDIR=/lib PKGCFDIR=/lib/pkgconfig \
      lib/libpci.a
    make -C "$source_root" \
      "CROSS_COMPILE=$target-" \
      "HOST=$pci_host" \
      DNS=no HWDB=no LIBKMOD=no SHARED=no ZLIB=no \
      PREFIX=/ INCDIR=/include LIBDIR=/lib PKGCFDIR=/lib/pkgconfig \
      "DESTDIR=$sysroot" install-lib
  )

  [[ -f "$sysroot/include/pci/pci.h" ]] || die "libpci headers missing for $target"
  [[ -f "$sysroot/lib/libpci.a" ]] || die "libpci.a missing for $target"
  [[ -f "$sysroot/lib/pkgconfig/libpci.pc" ]] || die "libpci.pc missing for $target"
  if grep -Eq -- '(^|[[:space:]])-l(z|resolv|kmod|udev)([[:space:]]|$)' "$sysroot/lib/pkgconfig/libpci.pc"; then
    die "libpci.pc unexpectedly records a disabled runtime dependency for $target"
  fi
}

build_pkgconf() {
  local workspace=$1 output_root=$2 stage_one=$3
  local pkgconf_version source_root install_root cc
  pkgconf_version=$(source_version pkgconf)
  source_root="$workspace/pkgconf-host-build"
  install_root="$workspace/pkgconf-install"
  cc="$stage_one/bin/x86_64-linux-musl-gcc"

  rm -rf -- "$source_root" "$install_root"
  tar -xJf "$CACHE_ROOT/sources/pkgconf-$pkgconf_version.tar.xz" -C "$workspace"
  mv "$workspace/pkgconf-$pkgconf_version" "$source_root"

  log 'building static host-side pkgconf'
  (
    cd "$source_root"
    env CC="$cc -static --static" LDFLAGS=-static \
      ./configure \
        --build=x86_64-linux-musl \
        --host=x86_64-linux-musl \
        --prefix=/ \
        --disable-shared \
        --enable-static
    make "-j$JOBS"
    make "DESTDIR=$install_root" install
  )

  mkdir -p "$output_root"
  install -m 0755 "$install_root/bin/pkgconf" "$output_root/pkgconf"
  assert_static_host_elf "$output_root/pkgconf"
}

install_toolchain_pkgconf() {
  local source=$1 toolchain_root=$2 destination
  destination="$toolchain_root/libexec/pkgconf"
  [[ -x "$source" ]] || die "static pkgconf is missing: $source"
  mkdir -p "$toolchain_root/libexec"
  # Use a real copy so a target directory remains complete when copied out of
  # the SDK or extracted alone.
  install -m 0755 "$source" "$destination"
  [[ -x "$destination" ]] || die "failed to install toolchain-local pkgconf: $destination"
}

write_pkg_config_wrapper() {
  local sdk_root=$1 target=$2 wrapper
  wrapper="$sdk_root/$target/bin/$target-pkg-config"
  printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    'self=$0' \
    'case "$self" in' \
    '  /*) ;;' \
    '  *) self=$(command -v -- "$self") ;;' \
    'esac' \
    'bindir=$(CDPATH= cd -- "$(dirname -- "$self")" && pwd -P)' \
    'toolchain_root=$(CDPATH= cd -- "$bindir/.." && pwd -P)' \
    'wrapper_name=$(basename -- "$self")' \
    'triplet=${wrapper_name%-pkg-config}' \
    '[ "$triplet" != "$wrapper_name" ] || {' \
    '  printf "%s\\n" "nbl-sdk pkg-config wrapper: unexpected wrapper name: $wrapper_name" >&2' \
    '  exit 127' \
    '}' \
    'sysroot="$toolchain_root/$triplet"' \
    'pkgconf="$toolchain_root/libexec/pkgconf"' \
    '[ -x "$pkgconf" ] || {' \
    '  printf "%s\\n" "nbl-sdk pkg-config wrapper: bundled pkgconf is missing: $pkgconf" >&2' \
    '  exit 127' \
    '}' \
    'unset PKG_CONFIG_PATH' \
    'export PKG_CONFIG_SYSROOT_DIR="$sysroot"' \
    'export PKG_CONFIG_LIBDIR="$sysroot/lib/pkgconfig:$sysroot/share/pkgconfig"' \
    'exec "$pkgconf" --static "$@"' \
    >"$wrapper"
  chmod 0755 "$wrapper"
}

cached_stage_one_is_valid() {
  local directory=$1
  [[ -x "$directory/bin/x86_64-linux-musl-gcc" ]] &&
    [[ -x "$directory/bin/x86_64-linux-musl-g++" ]]
}

cached_toolchain_is_valid() {
  local directory=$1 target=$2
  [[ -x "$directory/bin/$target-gcc" ]] &&
    [[ -x "$directory/bin/$target-g++" ]] &&
    [[ -x "$directory/bin/$target-ar" ]] &&
    [[ -x "$directory/bin/$target-ld" ]] &&
    [[ -d "$directory/$target/include" ]] &&
    [[ -d "$directory/$target/lib" ]]
}

cached_openssl_overlay_is_valid() {
  local directory=$1
  [[ -f "$directory/include/openssl/evp.h" ]] &&
    [[ -f "$directory/lib/libssl.a" ]] &&
    [[ -f "$directory/lib/libcrypto.a" ]] &&
    [[ -f "$directory/lib/pkgconfig/openssl.pc" ]] &&
    [[ -f "$directory/lib/pkgconfig/libssl.pc" ]] &&
    [[ -f "$directory/lib/pkgconfig/libcrypto.pc" ]]
}

cached_pciutils_overlay_is_valid() {
  local directory=$1
  [[ -f "$directory/include/pci/pci.h" ]] &&
    [[ -f "$directory/lib/libpci.a" ]] &&
    [[ -f "$directory/lib/pkgconfig/libpci.pc" ]]
}

build_final_toolchain_once() {
  local work_mcm=$1 target=$2 output=$3 stage_one=$4 preset
  preset=$(preset_for_target "$target")
  build_mcm_toolchain "$work_mcm" "$target" "$output" \
    "$stage_one/bin/x86_64-linux-musl-gcc -static --static" \
    "$stage_one/bin/x86_64-linux-musl-g++ -static --static" \
    "$preset"
  assert_static_tool_tree "$output"
}

ensure_stage_one_checkpoint() {
  local destination="$CHECKPOINT_ROOT/stage-one"
  if cached_stage_one_is_valid "$destination"; then
    log "checkpoint reuse: stage-one toolchain"
    return
  fi

  ensure_work_dir
  local work_mcm="$WORK_DIR/musl-cross-make-stage-one"
  local temporary="$CHECKPOINT_ROOT/.tmp/stage-one.$$"
  rm -rf -- "$work_mcm" "$temporary"
  mkdir -p "$temporary"
  prepare_mcm_worktree "$work_mcm"
  run_step 'toolchains/stage-one' build_stage_one "$work_mcm" "$temporary"
  commit_checkpoint_dir "$temporary" "$destination"
}

ensure_toolchain_checkpoint() {
  local target=$1 destination
  destination="$CHECKPOINT_ROOT/toolchains/$target"
  if cached_toolchain_is_valid "$destination" "$target"; then
    log "checkpoint reuse: toolchain $target"
    return
  fi

  ensure_stage_one_checkpoint
  ensure_work_dir
  local work_mcm="$WORK_DIR/musl-cross-make-$target"
  local temporary="$CHECKPOINT_ROOT/.tmp/toolchain-$target.$$"
  rm -rf -- "$work_mcm" "$temporary"
  mkdir -p "$temporary"
  prepare_mcm_worktree "$work_mcm"
  run_step "toolchains/$target" build_final_toolchain_once \
    "$work_mcm" "$target" "$temporary" "$CHECKPOINT_ROOT/stage-one"
  commit_checkpoint_dir "$temporary" "$destination"
}

build_pkgconf_checkpoint_once() {
  local temporary=$1
  local scratch="$WORK_DIR/pkgconf-sdk"
  rm -rf -- "$scratch" "$WORK_DIR/pkgconf-work"
  mkdir -p "$scratch" "$WORK_DIR/pkgconf-work" "$temporary"
  build_pkgconf "$WORK_DIR/pkgconf-work" "$scratch" "$CHECKPOINT_ROOT/stage-one"
  install -m 0755 "$scratch/pkgconf" "$temporary/pkgconf"
  assert_static_host_elf "$temporary/pkgconf"
}

ensure_pkgconf_checkpoint() {
  local destination="$CHECKPOINT_ROOT/host/pkgconf"
  if [[ -x "$destination" ]]; then
    log 'checkpoint reuse: static host pkgconf'
    return
  fi

  ensure_stage_one_checkpoint
  ensure_work_dir
  local temporary="$CHECKPOINT_ROOT/.tmp/pkgconf.$$"
  rm -rf -- "$temporary"
  mkdir -p "$temporary"
  run_step 'host/pkgconf' build_pkgconf_checkpoint_once "$temporary"
  mkdir -p "$(dirname -- "$destination")"
  rm -f -- "$destination"
  mv -- "$temporary/pkgconf" "$destination"
  rmdir "$temporary"
}

capture_openssl_overlay() {
  local sysroot=$1 overlay=$2
  mkdir -p "$overlay/include" "$overlay/lib/pkgconfig"
  cp -a "$sysroot/include/openssl" "$overlay/include/"
  cp -a "$sysroot/lib/libssl.a" "$sysroot/lib/libcrypto.a" "$overlay/lib/"
  cp -a "$sysroot/lib/pkgconfig/libcrypto.pc" \
    "$sysroot/lib/pkgconfig/libssl.pc" \
    "$sysroot/lib/pkgconfig/openssl.pc" \
    "$overlay/lib/pkgconfig/"
}

capture_pciutils_overlay() {
  local sysroot=$1 overlay=$2
  mkdir -p "$overlay/include" "$overlay/lib/pkgconfig"
  cp -a "$sysroot/include/pci" "$overlay/include/"
  cp -a "$sysroot/lib/libpci.a" "$overlay/lib/"
  cp -a "$sysroot/lib/pkgconfig/libpci.pc" "$overlay/lib/pkgconfig/"
}

build_openssl_overlay_once() {
  local target=$1 overlay=$2 scratch
  local sysroot
  scratch="$WORK_DIR/openssl-$target-sdk"
  rm -rf -- "$scratch" "$overlay"
  mkdir -p "$scratch/work" "$overlay"
  cp -a "$CHECKPOINT_ROOT/toolchains/$target" "$scratch/$target"
  build_openssl "$scratch/work" "$scratch" "$target"
  sysroot="$scratch/$target/$target"
  capture_openssl_overlay "$sysroot" "$overlay"
  cached_openssl_overlay_is_valid "$overlay" || die "OpenSSL checkpoint is incomplete for $target"
}

build_pciutils_overlay_once() {
  local target=$1 overlay=$2 scratch
  local sysroot
  scratch="$WORK_DIR/pciutils-$target-sdk"
  rm -rf -- "$scratch" "$overlay"
  mkdir -p "$scratch/work" "$overlay"
  cp -a "$CHECKPOINT_ROOT/toolchains/$target" "$scratch/$target"
  build_pciutils "$scratch/work" "$scratch" "$target"
  sysroot="$scratch/$target/$target"
  capture_pciutils_overlay "$sysroot" "$overlay"
  cached_pciutils_overlay_is_valid "$overlay" || die "pciutils checkpoint is incomplete for $target"
}

ensure_openssl_checkpoint() {
  local target=$1 destination
  destination="$CHECKPOINT_ROOT/integrations/$target/openssl"
  if cached_openssl_overlay_is_valid "$destination"; then
    log "checkpoint reuse: OpenSSL $target"
    return
  fi

  ensure_toolchain_checkpoint "$target"
  ensure_work_dir
  local temporary="$CHECKPOINT_ROOT/.tmp/openssl-$target.$$"
  rm -rf -- "$temporary"
  mkdir -p "$temporary"
  run_step "libraries/$target/openssl" build_openssl_overlay_once "$target" "$temporary"
  mkdir -p "$(dirname -- "$destination")"
  commit_checkpoint_dir "$temporary" "$destination"
}

ensure_pciutils_checkpoint() {
  local target=$1 destination
  destination="$CHECKPOINT_ROOT/integrations/$target/pciutils"
  if cached_pciutils_overlay_is_valid "$destination"; then
    log "checkpoint reuse: pciutils $target"
    return
  fi

  ensure_toolchain_checkpoint "$target"
  ensure_work_dir
  local temporary="$CHECKPOINT_ROOT/.tmp/pciutils-$target.$$"
  rm -rf -- "$temporary"
  mkdir -p "$temporary"
  run_step "libraries/$target/pciutils" build_pciutils_overlay_once "$target" "$temporary"
  mkdir -p "$(dirname -- "$destination")"
  commit_checkpoint_dir "$temporary" "$destination"
}

build_toolchain_stage() {
  local target
  for target in "${TARGETS[@]}"; do
    target_is_selected "$target" || continue
    ensure_toolchain_checkpoint "$target"
  done
}

build_library_stage() {
  local target
  ensure_pkgconf_checkpoint
  for target in "${TARGETS[@]}"; do
    target_is_selected "$target" || continue
    ensure_openssl_checkpoint "$target"
    ensure_pciutils_checkpoint "$target"
  done
}

ensure_all_checkpoints() {
  local saved_filter=$TARGET_FILTER target
  TARGET_FILTER=
  for target in "${TARGETS[@]}"; do
    ensure_toolchain_checkpoint "$target"
  done
  ensure_pkgconf_checkpoint
  for target in "${TARGETS[@]}"; do
    ensure_openssl_checkpoint "$target"
    ensure_pciutils_checkpoint "$target"
  done
  TARGET_FILTER=$saved_filter
}

cached_sdk_is_valid() {
  local directory=$1 target sysroot
  [[ ! -e "$directory/.host" && ! -L "$directory/.host" ]] || return 1
  [[ -r "$directory/BUILD-MANIFEST.json" ]] || return 1
  python3 - "$directory/BUILD-MANIFEST.json" "$RELEASE_PROFILE" <<'PY' || return 1
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))
release = manifest.get('release_optimization', {})
standalone = manifest.get('standalone_toolchains', {})
raise SystemExit(0 if (
    release.get('profile') == sys.argv[2]
    and standalone.get('directory_copy_supported') is True
    and standalone.get('local_pkgconf') == 'libexec/pkgconf'
    and standalone.get('root_host_directory_present') is False
) else 1)
PY
  for target in "${TARGETS[@]}"; do
    sysroot="$directory/$target/$target"
    [[ -x "$directory/$target/bin/$target-gcc" ]] || return 1
    [[ -x "$directory/$target/bin/$target-g++" ]] || return 1
    [[ -x "$directory/$target/bin/$target-pkg-config" ]] || return 1
    [[ ! -e "$directory/$target/bin/pkgconf" && ! -L "$directory/$target/bin/pkgconf" ]] || return 1
    [[ -x "$directory/$target/libexec/pkgconf" ]] || return 1
    [[ -f "$sysroot/lib/libssl.a" ]] || return 1
    [[ -f "$sysroot/lib/libcrypto.a" ]] || return 1
    [[ -f "$sysroot/lib/libpci.a" ]] || return 1
  done
  return 0
}

build_assembled_sdk_once() {
  local temporary=$1 target sysroot saved_filter=$TARGET_FILTER
  TARGET_FILTER=
  rm -rf -- "$temporary"
  mkdir -p "$temporary"
  for target in "${TARGETS[@]}"; do
    cp -a "$CHECKPOINT_ROOT/toolchains/$target" "$temporary/$target"
    sysroot="$temporary/$target/$target"
    cp -a "$CHECKPOINT_ROOT/integrations/$target/openssl/." "$sysroot/"
    cp -a "$CHECKPOINT_ROOT/integrations/$target/pciutils/." "$sysroot/"
    install_toolchain_pkgconf "$CHECKPOINT_ROOT/host/pkgconf" "$temporary/$target"
    write_pkg_config_wrapper "$temporary" "$target"
    write_toolchain_readme "$temporary/$target" "$target" "$SDK_VERSION"
  done
  # Checkpoints contain pristine toolchains.  Strip only this materialized
  # release tree, so retries and targeted diagnostics keep their symbols.
  apply_release_profile "$temporary"
  write_sdk_readme "$temporary" "$SDK_VERSION"
  write_build_manifest "$temporary" "$SDK_VERSION"
  check_required_layout "$temporary"
  TARGET_FILTER=$saved_filter
}

assemble_sdk_checkpoint() {
  local destination="$CHECKPOINT_ROOT/sdk/nbl-sdk-$SDK_VERSION"
  if cached_sdk_is_valid "$destination"; then
    log "checkpoint reuse: assembled SDK $SDK_VERSION"
    printf '%s\n' "$destination"
    return
  fi

  ensure_all_checkpoints
  local temporary="$CHECKPOINT_ROOT/.tmp/sdk-$SDK_VERSION.$$"
  mkdir -p "$temporary"
  run_step 'assemble/sdk' build_assembled_sdk_once "$temporary"
  mkdir -p "$(dirname -- "$destination")"
  commit_checkpoint_dir "$temporary" "$destination"
  printf '%s\n' "$destination"
}

write_toolchain_readme() {
  local toolchain_root=$1 target=$2 version=$3
  printf '%s\n' \
    "# NBL SDK $version: $target toolchain" \
    '' \
    'This directory is a complete, relocatable cross-toolchain unit. Copy the' \
    'entire directory anywhere on an x86_64 Linux host; it may also be renamed.' \
    'Keep `bin/`, `libexec/`, and the nested target sysroot together.' \
    '' \
    'It contains the prefixed compiler/binutils, C/C++ runtime and sysroot, the' \
    'static OpenSSL and libpci integrations, and a static `libexec/pkgconf` used by' \
    'the `<triplet>-pkg-config` wrapper. No file outside this directory is' \
    'required at compile or pkg-config runtime.' \
    '' \
    '## Example' \
    '' \
    '```sh' \
    "TOOLCHAIN=/opt/toolchains/$target" \
    "CC=\$TOOLCHAIN/bin/$target-gcc" \
    "PKG=\$TOOLCHAIN/bin/$target-pkg-config" \
    '"$CC" -static hello.c -o hello' \
    '"$CC" -static tls.c -o tls $($PKG --cflags --libs openssl)' \
    '```' \
    >"$toolchain_root/README.md"
}

write_sdk_readme() {
  local sdk_root=$1 version=$2
  printf '%s\n' \
    "# NBL SDK $version" \
    '' \
    'NBL SDK is a relocatable, static-linking cross SDK. It runs on an x86_64' \
    'Linux host and generates Linux/musl programs for these targets:' \
    '' \
    '- `aarch64-linux-musl`' \
    '- `loongarch64-linux-musl`' \
    '- `riscv64-linux-musl`' \
    '- `sw_64-linux-musl`' \
    '- `x86_64-linux-musl`' \
    '' \
    'No environment-activation script is required. Every `<triplet>/` directory' \
    'is a complete standalone toolchain: copy the entire directory (not only' \
    '`bin/`) anywhere, optionally rename it, and use it without the rest of' \
    'this SDK. Its `bin/` contains prefixed tools and its `libexec/pkgconf` is' \
    'a toolchain-local static executable; nested `<triplet>/include`, `<triplet>/lib`, and' \
    '`<triplet>/lib/pkgconfig` form the target sysroot.' \
    '' \
    'The SDK root deliberately contains no `.host/` directory.' \
    '' \
    'Every `<triplet>-pkg-config` wrapper finds its own toolchain directory,' \
    'selects only that target sysroot, and always enables static dependency' \
    'expansion. It has no runtime dependency outside that toolchain directory.' \
    '' \
    '## Static C example' \
    '' \
    '```sh' \
    "nbl-sdk-$version/x86_64-linux-musl/bin/x86_64-linux-musl-gcc -static hello.c -o hello" \
    '```' \
    '' \
    '## OpenSSL and libpci example' \
    '' \
    '```sh' \
    "SDK=nbl-sdk-$version" \
    'CC=$SDK/x86_64-linux-musl/bin/x86_64-linux-musl-gcc' \
    'PKG=$SDK/x86_64-linux-musl/bin/x86_64-linux-musl-pkg-config' \
    '$PKG --cflags --libs openssl' \
    '$CC -static tls.c -o tls $($PKG --cflags --libs openssl)' \
    '$CC -static pci.c -o pci $($PKG --cflags --libs libpci)' \
    '```' \
    '' \
    '## Copy one toolchain' \
    '' \
    '```sh' \
    "cp -a nbl-sdk-$version/aarch64-linux-musl /opt/toolchains/aarch64" \
    'CC=/opt/toolchains/aarch64/bin/aarch64-linux-musl-gcc' \
    'PKG=/opt/toolchains/aarch64/bin/aarch64-linux-musl-pkg-config' \
    '$CC -static hello.c -o hello' \
    '$CC -static tls.c -o tls $($PKG --cflags --libs openssl)' \
    '```' \
    '' \
    'OpenSSL ships only `libssl.a` and `libcrypto.a`. libpci is built with DNS,' \
    'zlib, libkmod, and HWDB backends disabled, so this SDK does not need to' \
    'ship zlib as a private libpci dependency.' \
    '' \
    'Release packaging removes DWARF debug sections from host-side SDK tools' \
    'and target static archives. This preserves normal compiler and linker' \
    'functionality while keeping the delivered SDK compact.' \
    '' \
    'See `BUILD-MANIFEST.json` and `SOURCE-LOCK.json` for exact source,' \
    'patchset, submodule, and container-image provenance.' \
    >"$sdk_root/README.md"
}

write_build_manifest() {
  local sdk_root=$1 version=$2
  python3 - "$LOCK_FILE" "$sdk_root/BUILD-MANIFEST.json" "$version" "${NBL_SDK_BUILDER_IMAGE:-unknown}" "$RELEASE_PROFILE" <<'PY'
import hashlib
import json
import pathlib
import sys

lock_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
lock = json.loads(lock_path.read_text(encoding='utf-8'))
manifest = {
    'schema': 5,
    'sdk_version': sys.argv[3],
    'source_date_epoch': lock['source_date_epoch'],
    'targets': [
        'aarch64-linux-musl',
        'loongarch64-linux-musl',
        'riscv64-linux-musl',
        'sw_64-linux-musl',
        'x86_64-linux-musl',
    ],
    'musl_cross_make': lock['musl_cross_make'],
    'sources': lock['sources'],
    'patches': lock['patches'],
    'container_image': {
        **lock['container'],
        'builder_image_reference': sys.argv[4],
    },
    'integrations': {
        'openssl': {
            'static_only': True,
            'assembly': 'disabled; SW64 uses the generic C path',
        },
        'pciutils': {
            'library': 'libpci.a',
            'dns': False,
            'hwdb': False,
            'libkmod': False,
            'zlib': False,
        },
        'pkgconf': {
            'host_static': True,
            'wrapper_default': '--static',
        },
    },
    'standalone_toolchains': {
        'directory_copy_supported': True,
        'copy_unit': '<triplet>/',
        'local_pkgconf': 'libexec/pkgconf',
        'pkg_config_wrapper': 'bin/<triplet>-pkg-config',
        'root_host_directory_present': False,
    },
    'release_optimization': {
        'profile': sys.argv[5],
        'host_elf_debug_sections': 'stripped',
        'target_static_archive_debug_sections': 'stripped',
    },
    'source_lock_sha256': hashlib.sha256(lock_path.read_bytes()).hexdigest(),
}
output_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n', encoding='utf-8')
PY
  cp "$LOCK_FILE" "$sdk_root/SOURCE-LOCK.json"
}

check_required_toolchain_layout() {
  local toolchain_root=$1 target=$2 sysroot tool
  [[ -d "$toolchain_root" ]] || die "toolchain directory is missing: $toolchain_root"
  [[ -r "$toolchain_root/README.md" ]] || die "toolchain README is missing: $toolchain_root/README.md"
  [[ ! -e "$toolchain_root/bin/pkgconf" && ! -L "$toolchain_root/bin/pkgconf" ]] || die "pkgconf must reside in libexec for $target"
  [[ -x "$toolchain_root/libexec/pkgconf" ]] || die "toolchain-local static pkgconf is missing for $target"
  sysroot="$toolchain_root/$target"
  for tool in gcc g++ ar ld pkg-config; do
    [[ -x "$toolchain_root/bin/$target-$tool" ]] || die "missing $target-$tool"
  done
  [[ -d "$sysroot/include" ]] || die "missing sysroot includes for $target"
  [[ -d "$sysroot/lib" ]] || die "missing sysroot libraries for $target"
  [[ -d "$sysroot/lib/pkgconfig" ]] || die "missing pkg-config directory for $target"
  [[ -f "$sysroot/lib/libssl.a" ]] || die "missing libssl.a for $target"
  [[ -f "$sysroot/lib/libcrypto.a" ]] || die "missing libcrypto.a for $target"
  [[ -f "$sysroot/lib/libpci.a" ]] || die "missing libpci.a for $target"
  [[ -f "$sysroot/include/openssl/evp.h" ]] || die "missing OpenSSL headers for $target"
  [[ -f "$sysroot/include/pci/pci.h" ]] || die "missing pciutils headers for $target"
  [[ -f "$sysroot/lib/pkgconfig/openssl.pc" ]] || die "missing openssl.pc for $target"
  [[ -f "$sysroot/lib/pkgconfig/libpci.pc" ]] || die "missing libpci.pc for $target"
}

check_required_layout() {
  local sdk_root=$1 target
  [[ ! -e "$sdk_root/.host" && ! -L "$sdk_root/.host" ]] || die 'delivered SDK must not contain .host'
  for target in "${TARGETS[@]}"; do
    target_is_selected "$target" || continue
    check_required_toolchain_layout "$sdk_root/$target" "$target"
  done
}

machine_pattern_for() {
  case "$1" in
    aarch64-linux-musl) printf '%s\n' 'AArch64' ;;
    loongarch64-linux-musl) printf '%s\n' 'LoongArch' ;;
    riscv64-linux-musl) printf '%s\n' 'RISC-V' ;;
    sw_64-linux-musl) printf '%s\n' 'Sw_64' ;;
    x86_64-linux-musl) printf '%s\n' 'X86-64' ;;
    *) die "unknown ELF target: $1" ;;
  esac
}

verify_target_elf() {
  local target=$1 binary=$2 readelf_tool=$3 pattern description
  pattern=$(machine_pattern_for "$target")
  description=$(file -Lb "$binary")
  log "target ELF: $binary: $description"
  [[ "$description" != *dynamically\ linked* ]] || die "target binary is dynamically linked: $binary"
  "$readelf_tool" -h "$binary" | grep -Eq "Machine:.*$pattern" || die "wrong ELF architecture for $binary (expected $pattern)"
  if "$readelf_tool" -lW "$binary" | grep -Eq '(^|[[:space:]])INTERP([[:space:]]|$)|Requesting program interpreter'; then
    die "static target binary has PT_INTERP: $binary"
  fi
  if "$readelf_tool" -dW "$binary" 2>/dev/null | grep -q '(NEEDED)'; then
    die "static target binary has DT_NEEDED entries: $binary"
  fi
}

write_validation_sources() {
  local directory=$1
  mkdir -p "$directory"
  printf '%s\n' \
    '#include <stdio.h>' \
    'int main(void) { puts("nbl-sdk"); return 0; }' \
    >"$directory/hello.c"
  printf '%s\n' \
    '#include <iostream>' \
    'int main() { std::cout << "nbl-sdk" << std::endl; return 0; }' \
    >"$directory/hello.cc"
  printf '%s\n' \
    '#include <openssl/evp.h>' \
    'int main(void) { return EVP_sha256() == 0; }' \
    >"$directory/openssl.c"
  printf '%s\n' \
    '#include <pci/pci.h>' \
    'int main(void) {' \
    '  struct pci_access *access = pci_alloc();' \
    '  if (!access) return 1;' \
    '  pci_cleanup(access);' \
    '  return 0;' \
    '}' \
    >"$directory/pci.c"
}

validate_toolchain_compilation() {
  local toolchain_root=$1 target=$2 validation_root=$3 label=$4
  local cc cxx pkg readelf_tool openssl_flags pci_flags
  log "validating toolchain compilation ($label): $toolchain_root"
  rm -rf -- "$validation_root"
  mkdir -p "$validation_root"
  cc="$toolchain_root/bin/$target-gcc"
  cxx="$toolchain_root/bin/$target-g++"
  pkg="$toolchain_root/bin/$target-pkg-config"
  readelf_tool="$toolchain_root/bin/$target-readelf"
  write_validation_sources "$validation_root"

  "$cc" -static "$validation_root/hello.c" -o "$validation_root/hello-c"
  "$cxx" -static "$validation_root/hello.cc" -o "$validation_root/hello-cxx"

  openssl_flags=$("$pkg" --cflags --libs openssl)
  pci_flags=$("$pkg" --cflags --libs libpci)
  [[ "$openssl_flags" == *-lssl* && "$openssl_flags" == *-lcrypto* ]] || die "OpenSSL pkg-config flags are incomplete for $target: $openssl_flags"
  [[ "$pci_flags" == *-lpci* ]] || die "libpci pkg-config flags are incomplete for $target: $pci_flags"
  [[ "$openssl_flags" != *"/usr/include"* && "$pci_flags" != *"/usr/include"* ]] || die "pkg-config leaked host include paths for $target"

  # The .pc files are generated by this SDK and use paths without spaces.
  # Deliberate word splitting converts pkgconf's flags into compiler args.
  # shellcheck disable=SC2086
  "$cc" -static "$validation_root/openssl.c" -o "$validation_root/openssl" $openssl_flags
  # shellcheck disable=SC2086
  "$cc" -static "$validation_root/pci.c" -o "$validation_root/pci" $pci_flags

  verify_target_elf "$target" "$validation_root/hello-c" "$readelf_tool"
  verify_target_elf "$target" "$validation_root/hello-cxx" "$readelf_tool"
  verify_target_elf "$target" "$validation_root/openssl" "$readelf_tool"
  verify_target_elf "$target" "$validation_root/pci" "$readelf_tool"
}

validate_standalone_toolchain() {
  local toolchain_root=$1 target=$2 validation_root=$3 label=$4
  log "validating standalone toolchain ($label): $toolchain_root"
  check_required_toolchain_layout "$toolchain_root" "$target"
  assert_static_tool_tree "$toolchain_root"
  assert_toolchain_release_profile "$toolchain_root" "$target"
  validate_toolchain_compilation "$toolchain_root" "$target" "$validation_root" "$label"
}

validate_independent_toolchain_copy() {
  local sdk_root=$1 target=$2 validation_root=$3 label=$4
  local copied_toolchain copied_validation
  copied_toolchain="$validation_root/${target}-toolchain-copy"
  copied_validation="$validation_root/${target}-validation"
  rm -rf -- "$copied_toolchain" "$copied_validation"
  mkdir -p "$validation_root"
  # Deliberately rename the copied directory.  This catches wrapper paths that
  # accidentally depend on either the SDK root or the original directory name.
  cp -a "$sdk_root/$target" "$copied_toolchain"
  validate_standalone_toolchain "$copied_toolchain" "$target" "$copied_validation" \
    "independently copied $target from $label"
  rm -rf -- "$copied_toolchain"
}

validate_sdk() {
  local sdk_root=$1 validation_root=$2 label=$3 validate_standalone=${4:-0}
  local target
  log "validating SDK ($label): $sdk_root"
  check_required_layout "$sdk_root"
  for target in "${TARGETS[@]}"; do
    target_is_selected "$target" || continue
    assert_static_tool_tree "$sdk_root/$target"
  done
  assert_release_profile "$sdk_root"

  rm -rf -- "$validation_root"
  mkdir -p "$validation_root"
  for target in "${TARGETS[@]}"; do
    target_is_selected "$target" || continue
    validate_toolchain_compilation "$sdk_root/$target" "$target" \
      "$validation_root/$target" "$label"
  done

  if (( validate_standalone )); then
    for target in "${TARGETS[@]}"; do
      target_is_selected "$target" || continue
      validate_independent_toolchain_copy "$sdk_root" "$target" \
        "$validation_root/standalone-copies" "$label"
    done
  fi
}

verify_archive_layout() {
  local archive=$1
  local top
  # Consume the complete tar listing.  With pipefail enabled, exiting awk at
  # the first entry would otherwise make tar report SIGPIPE (status 141).
  top=$(tar -tJf "$archive" | awk -F/ 'NF && !seen { top=$1; seen=1 } END { if (seen) print top }')
  [[ "$top" == nbl-sdk-* ]] || die "archive root is not nbl-sdk-<version>: $top"
  if tar -tJf "$archive" | grep -Eq '/(stage1|sources|source-cache|\.nbl-sdk-cache)(/|$)'; then
    die 'archive contains a stage-one toolchain, source cache, or build cache'
  fi
  if tar -tJf "$archive" | grep -Eq '^nbl-sdk-[^/]+/\.host(/|$)'; then
    die 'archive contains the removed SDK-root .host directory'
  fi
}

verify_archive() {
  local archive=$1
  local verify_work saved_filter=$TARGET_FILTER
  [[ -f "$archive" ]] || die "archive does not exist: $archive"
  verify_archive_layout "$archive"
  if [[ -n ${WORK_DIR:-} ]]; then
    verify_work=$(mktemp -d "$WORK_DIR/archive-verify.XXXXXX")
  else
    WORK_DIR=$(mktemp -d /work/nbl-sdk-verify.XXXXXX)
    verify_work=$WORK_DIR
  fi
  tar -xJf "$archive" -C "$verify_work"
  local root
  root=$(find "$verify_work" -mindepth 1 -maxdepth 1 -type d -name 'nbl-sdk-*' -print -quit)
  [[ -n "$root" && -f "$root/README.md" && -f "$root/BUILD-MANIFEST.json" && -f "$root/SOURCE-LOCK.json" ]] || die 'archive is missing required SDK root files'
  TARGET_FILTER=
  validate_sdk "$root" "$verify_work/validation" 'clean archive extraction' 1
  TARGET_FILTER=$saved_filter
  log "archive verification passed: $archive"
}

make_archive() {
  local sdk_root=$1 output_archive=$2 stage_root
  stage_root="$WORK_DIR/archive-root"
  rm -rf -- "$stage_root"
  mkdir -p "$stage_root"
  cp -a "$sdk_root" "$stage_root/"
  # Fixed single-thread xz keeps output reproducible while level 3 avoids
  # making a debugging/package iteration dominated by compression time.
  export XZ_OPT='--threads=1 -3'
  (
    cd "$stage_root"
    tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner \
      -cJf "$output_archive" "$(basename -- "$sdk_root")"
  )
}

materialize_selected_sdk() {
  local destination=$1 target sysroot
  rm -rf -- "$destination"
  mkdir -p "$destination"
  ensure_pkgconf_checkpoint
  for target in "${TARGETS[@]}"; do
    target_is_selected "$target" || continue
    ensure_toolchain_checkpoint "$target"
    ensure_openssl_checkpoint "$target"
    ensure_pciutils_checkpoint "$target"
    cp -a "$CHECKPOINT_ROOT/toolchains/$target" "$destination/$target"
    sysroot="$destination/$target/$target"
    cp -a "$CHECKPOINT_ROOT/integrations/$target/openssl/." "$sysroot/"
    cp -a "$CHECKPOINT_ROOT/integrations/$target/pciutils/." "$sysroot/"
    install_toolchain_pkgconf "$CHECKPOINT_ROOT/host/pkgconf" "$destination/$target"
    write_pkg_config_wrapper "$destination" "$target"
    write_toolchain_readme "$destination/$target" "$target" "$SDK_VERSION"
  done
  apply_release_profile "$destination"
}

validate_sdk_stage() {
  local relocate=$1 sdk_root relocated label
  ensure_work_dir
  if [[ -z "$TARGET_FILTER" ]]; then
    sdk_root=$(assemble_sdk_checkpoint)
    label='assembled SDK checkpoint'
  else
    sdk_root="$WORK_DIR/debug-sdk/nbl-sdk-$SDK_VERSION-$TARGET_FILTER"
    materialize_selected_sdk "$sdk_root"
    label="debug SDK checkpoint for $TARGET_FILTER"
  fi

  run_step "validation/${TARGET_FILTER:-all}/original" \
    validate_sdk "$sdk_root" "$WORK_DIR/validation-original" "$label" 1
  if (( relocate )); then
    relocated="$WORK_DIR/relocated/$(basename -- "$sdk_root")"
    rm -rf -- "$relocated"
    mkdir -p "$(dirname -- "$relocated")"
    cp -a "$sdk_root" "$relocated"
    run_step "validation/${TARGET_FILTER:-all}/relocated" \
      validate_sdk "$relocated" "$WORK_DIR/validation-relocated" "relocated $label"
  fi
}

make_and_verify_archive() {
  local sdk_root=$1 archive=$2
  make_archive "$sdk_root" "$archive"
  verify_archive_layout "$archive"
  verify_archive "$archive"
}

package_sdk() {
  [[ -z "$TARGET_FILTER" ]] || die 'package does not accept --target; use validate-sdk --target for focused checks'
  ensure_work_dir
  local sdk_root relocated final_archive
  sdk_root=$(assemble_sdk_checkpoint)

  run_step 'validation/all/original' \
    validate_sdk "$sdk_root" "$WORK_DIR/validation-original" 'assembled SDK checkpoint'
  relocated="$WORK_DIR/relocated/nbl-sdk-$SDK_VERSION"
  mkdir -p "$(dirname -- "$relocated")"
  cp -a "$sdk_root" "$relocated"
  run_step 'validation/all/relocated' \
    validate_sdk "$relocated" "$WORK_DIR/validation-relocated" 'relocated assembled SDK checkpoint'

  ARCHIVE_TMP="$OUT_ROOT/.nbl-sdk-$SDK_VERSION.$$.tar.xz"
  find "$OUT_ROOT" -maxdepth 1 -type f -name ".nbl-sdk-$SDK_VERSION.*.tar.xz" -delete
  run_step 'package/archive-and-clean-extraction' make_and_verify_archive "$sdk_root" "$ARCHIVE_TMP"

  final_archive="$OUT_ROOT/nbl-sdk-$SDK_VERSION.tar.xz"
  mv -f -- "$ARCHIVE_TMP" "$final_archive"
  ARCHIVE_TMP=
  sha256sum "$final_archive" >"$OUT_ROOT/nbl-sdk-$SDK_VERSION.tar.xz.sha256"
  log "package and complete verification passed: $final_archive"
}

build_sdk() {
  build_toolchain_stage
  build_library_stage
  if [[ -n "$TARGET_FILTER" ]]; then
    log "target checkpoint build passed: $TARGET_FILTER (no archive was created)"
    return
  fi
  package_sdk
}

checkpoint_status() {
  local target sdk_root
  printf 'checkpoint_key=%s\n' "$CHECKPOINT_KEY"
  printf 'checkpoint_root=%s\n' "$CHECKPOINT_ROOT"
  printf 'log_root=%s\n' "$CHECKPOINT_ROOT/logs"
  if cached_stage_one_is_valid "$CHECKPOINT_ROOT/stage-one"; then
    printf 'stage_one=ready\n'
  else
    printf 'stage_one=missing\n'
  fi
  if [[ -x "$CHECKPOINT_ROOT/host/pkgconf" ]]; then
    printf 'host_pkgconf=ready\n'
  else
    printf 'host_pkgconf=missing\n'
  fi
  for target in "${TARGETS[@]}"; do
    target_is_selected "$target" || continue
    if cached_toolchain_is_valid "$CHECKPOINT_ROOT/toolchains/$target" "$target"; then
      printf 'toolchain[%s]=ready\n' "$target"
    else
      printf 'toolchain[%s]=missing\n' "$target"
    fi
    if cached_openssl_overlay_is_valid "$CHECKPOINT_ROOT/integrations/$target/openssl"; then
      printf 'openssl[%s]=ready\n' "$target"
    else
      printf 'openssl[%s]=missing\n' "$target"
    fi
    if cached_pciutils_overlay_is_valid "$CHECKPOINT_ROOT/integrations/$target/pciutils"; then
      printf 'pciutils[%s]=ready\n' "$target"
    else
      printf 'pciutils[%s]=missing\n' "$target"
    fi
  done
  sdk_root="$CHECKPOINT_ROOT/sdk/nbl-sdk-$SDK_VERSION"
  if cached_sdk_is_valid "$sdk_root"; then
    printf 'assembled_sdk=ready (%s)\n' "$sdk_root"
  else
    printf 'assembled_sdk=missing\n'
  fi
}

clean_outputs() {
  local remove_sources=$1 remove_stages=$2
  find "$OUT_ROOT" -maxdepth 1 -type f \( -name 'nbl-sdk-*.tar.xz' -o -name 'nbl-sdk-*.tar.xz.sha256' \) -delete
  if (( remove_stages )); then
    rm -rf -- "$CACHE_ROOT/checkpoints"
  fi
  if (( remove_sources )); then
    rm -rf -- "$CACHE_ROOT/sources"
  fi
  if (( remove_sources && remove_stages )); then
    log 'removed output artifacts, verified source cache, and reusable checkpoints'
  elif (( remove_stages )); then
    log 'removed output artifacts and reusable checkpoints; verified source cache was retained'
  else
    log 'removed output artifacts; verified source cache and reusable checkpoints were retained'
  fi
}

parse_pipeline_args() {
  local allow_target=$1 allow_relocate=$2
  shift 2
  VALIDATE_RELOCATE=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [[ $# -ge 2 ]] || die '--version needs an argument'
        SDK_VERSION=$2
        shift 2
        ;;
      --jobs)
        [[ $# -ge 2 ]] || die '--jobs needs an argument'
        JOBS=$2
        shift 2
        ;;
      --target)
        (( allow_target )) || die '--target is not valid for this command'
        [[ $# -ge 2 ]] || die '--target needs an argument'
        TARGET_FILTER=$2
        shift 2
        ;;
      --relocate)
        (( allow_relocate )) || die '--relocate is only valid for validate-sdk'
        VALIDATE_RELOCATE=1
        shift
        ;;
      --offline)
        OFFLINE=1
        shift
        ;;
      *) die "unknown command argument: $1" ;;
    esac
  done
  [[ "$SDK_VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid SDK version: $SDK_VERSION"
  [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "invalid job count: $JOBS"
  if [[ -n "$TARGET_FILTER" ]] && ! is_known_target "$TARGET_FILTER"; then
    die "unknown target: $TARGET_FILTER"
  fi
}

main() {
  require_commands
  local command=${1:-help}
  if [[ $# -gt 0 ]]; then
    shift
  fi

  case "$command" in
    help|-h|--help)
      usage
      ;;
    fetch-sources)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --offline) OFFLINE=1 ;;
          *) die "unknown fetch-sources argument: $1" ;;
        esac
        shift
      done
      load_lock
      validate_submodule
      fetch_sources
      ;;
    build)
      parse_pipeline_args 1 0 "$@"
      prepare_pipeline
      build_sdk
      ;;
    toolchains)
      parse_pipeline_args 1 0 "$@"
      prepare_pipeline
      build_toolchain_stage
      ;;
    libraries)
      parse_pipeline_args 1 0 "$@"
      prepare_pipeline
      build_library_stage
      ;;
    assemble)
      parse_pipeline_args 0 0 "$@"
      prepare_pipeline
      assemble_sdk_checkpoint >/dev/null
      ;;
    validate-sdk)
      parse_pipeline_args 1 1 "$@"
      prepare_pipeline
      validate_sdk_stage "$VALIDATE_RELOCATE"
      ;;
    package)
      parse_pipeline_args 0 0 "$@"
      prepare_pipeline
      package_sdk
      ;;
    status)
      parse_pipeline_args 1 0 "$@"
      prepare_status
      checkpoint_status
      ;;
    verify-archive)
      [[ $# -eq 1 ]] || die 'verify-archive needs exactly one archive path'
      load_lock
      verify_archive "$1"
      ;;
    clean)
      local remove_sources=0 remove_stages=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --all)
            remove_sources=1
            remove_stages=1
            ;;
          --stages) remove_stages=1 ;;
          *) die "unknown clean argument: $1" ;;
        esac
        shift
      done
      clean_outputs "$remove_sources" "$remove_stages"
      ;;
    *)
      usage >&2
      die "unknown builder command: $command"
      ;;
  esac
}

main "$@"
