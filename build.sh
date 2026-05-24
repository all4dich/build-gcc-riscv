#!/usr/bin/env bash
# Build bare-metal RISC-V GCC cross-toolchains from GNU mainline sources.
# Default components: binutils-2.42, gcc-13.3.0, newlib-3.1.0
# (override via BINUTILS_VER / GCC_VER / NEWLIB_VER env vars)
# Supported hosts: Linux, macOS (Intel or Apple Silicon).
# Builds one or more target triples (e.g. riscv64-unknown-elf, riscv32-unknown-elf)
# into a shared PREFIX so both `riscv32-*` and `riscv64-*` command sets coexist.
set -euo pipefail

# ---- Host detection ----
UNAME_S="$(uname -s)"
IS_MAC=0
[ "$UNAME_S" = "Darwin" ] && IS_MAC=1

detect_jobs() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif [ "$IS_MAC" -eq 1 ]; then
    sysctl -n hw.ncpu
  else
    echo 4
  fi
}

# ---- Layout (computed early so PREFIX can default to a project-local path) ----
WORK="$(cd "$(dirname "$0")" && pwd)"

# ---- Configurable knobs (override via env) ----
PREFIX="${PREFIX:-$WORK/temp}"
JOBS="${JOBS:-$(detect_jobs)}"

GCC_VER="${GCC_VER:-13.3.0}"
BINUTILS_VER="${BINUTILS_VER:-2.42}"
NEWLIB_VER="${NEWLIB_VER:-3.1.0}"

# Target specs: each entry is "TARGET|ARCH|ABI|MULTILIB_GEN".
# MULTILIB_GEN syntax: "<arch>-<abi>--;..." (trailing "--" = no extra flags).
# Override by exporting TARGETS as a bash array before running.
if [ -z "${TARGETS+x}" ]; then
  TARGETS=(
    "riscv64-unknown-elf|rv64gc|lp64d|rv32imac-ilp32--;rv32imafdc-ilp32d--;rv64imac-lp64--;rv64imafdc-lp64d--"
    "riscv32-unknown-elf|rv32gc|ilp32d|rv32imac-ilp32--;rv32imafc-ilp32f--;rv32imafdc-ilp32d--"
  )
fi

# ---- macOS host setup ----
# GCC 9.2 predates Apple Silicon / modern Xcode SDKs. Point the build at the
# active SDK and pin a deployment target so configure tests don't pick up
# host-only headers. The user is expected to have Xcode CLT + Homebrew.
if [ "$IS_MAC" -eq 1 ]; then
  if command -v xcrun >/dev/null 2>&1; then
    export SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path)}"
  fi
  export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
  # Clang 17 defaults to C23, which rejects K&R prototypes and implicit ints
  # used by the vintage sources in binutils-2.32 / gcc-9.2 / newlib-3.1.
  # Demote those to warnings so the host-side build can complete.
  HOST_C_COMPAT="-Wno-implicit-function-declaration -Wno-implicit-int -Wno-deprecated-non-prototype -Wno-incompatible-function-pointer-types"
  export CFLAGS="${CFLAGS:-} $HOST_C_COMPAT"
  export CXXFLAGS="${CXXFLAGS:-} $HOST_C_COMPAT"
fi

# ---- Layout (cont.) ----
SRC="$WORK/src"
BUILD="$WORK/build"
LOG="$WORK/log"
STAMP="$WORK/.stamps"
mkdir -p "$SRC" "$BUILD" "$LOG" "$STAMP" "$PREFIX"

# ---- URLs ----
GCC_URL="https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VER}/gcc-${GCC_VER}.tar.xz"
BINUTILS_URL="https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VER}.tar.xz"
NEWLIB_URL="https://sourceware.org/pub/newlib/newlib-${NEWLIB_VER}.tar.gz"

# ---- Helpers ----
log() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
have_stamp() { [ -f "$STAMP/$1" ]; }
mark() { touch "$STAMP/$1"; }

# Per-target gcc src tree path. Targets build in parallel, and each gcc
# configure mutates gcc/config/riscv/t-elf-multilib (see write_multilib_config
# below), so the trees must be separate to avoid a race.
target_src() { echo "$SRC/gcc-${GCC_VER}-$1"; }

# Hardlink-copy the shared gcc src tree to a per-target tree.
# Hardlinks are cheap (sub-second, ~no extra disk); we only de-hardlink the
# files we will overwrite (currently just t-elf-multilib).
setup_target_src() {
  local target="$1"
  local src_dir; src_dir="$(target_src "$target")"
  local shared="$SRC/gcc-${GCC_VER}"
  if [ ! -d "$src_dir" ]; then
    log "preparing per-target gcc src tree for $target"
    cp -al "$shared" "$src_dir"
    # Break the hardlink for t-elf-multilib so a per-target rewrite doesn't
    # clobber the other target's tree.
    local mf="$src_dir/gcc/config/riscv/t-elf-multilib"
    cp --remove-destination "$shared/gcc/config/riscv/t-elf-multilib" "$mf"
  fi
}

# gcc-9.2.0 does NOT honor --with-multilib-generator at configure time.
# To set the multilib set, regenerate gcc/config/riscv/t-elf-multilib in the
# (per-target) src tree before configuring. The stock file ships with both
# rv32 and rv64 variants, which breaks a riscv32-* toolchain (libstdc++
# install fails when building for rv64 multilibs under a riscv32 default).
write_multilib_config() {
  local target="$1" multilib_gen="$2"
  local src_dir; src_dir="$(target_src "$target")"
  local generator="$src_dir/gcc/config/riscv/multilib-generator"
  local out="$src_dir/gcc/config/riscv/t-elf-multilib"
  local -a args
  IFS=';' read -ra args <<<"$multilib_gen"
  python3 "$generator" "${args[@]}" > "$out"
}

# ---- Phase 1: download sources in parallel ----
fetch() {
  local url="$1" dest="$2"
  if command -v wget >/dev/null 2>&1; then
    wget --no-verbose -O "$dest" "$url"
  elif command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 2 -o "$dest" "$url"
  else
    echo "ERROR: need wget or curl to download $url" >&2
    return 1
  fi
}

download() {
  local url="$1" out="$SRC/$(basename "$1")"
  if [ -s "$out" ]; then echo "have $(basename "$out")"; return 0; fi
  echo "fetch $url"
  fetch "$url" "$out.part"
  mv "$out.part" "$out"
}

phase_download() {
  if have_stamp download; then log "download: cached"; return 0; fi
  log "downloading sources"
  download "$GCC_URL" &
  local p1=$!
  download "$BINUTILS_URL" &
  local p2=$!
  download "$NEWLIB_URL" &
  local p3=$!
  wait $p1 $p2 $p3
  mark download
}

# ---- Phase 2: extract ----
extract_one() {
  local tarball="$1" dir="$2"
  if [ -d "$SRC/$dir" ]; then echo "have $dir"; return 0; fi
  echo "extract $tarball"
  tar -C "$SRC" -xf "$SRC/$tarball"
}

phase_extract() {
  if have_stamp extract; then log "extract: cached"; return 0; fi
  log "extracting sources"
  extract_one "gcc-${GCC_VER}.tar.xz"           "gcc-${GCC_VER}"
  extract_one "binutils-${BINUTILS_VER}.tar.xz" "binutils-${BINUTILS_VER}"
  extract_one "newlib-${NEWLIB_VER}.tar.gz"     "newlib-${NEWLIB_VER}"
  mark extract
}

# ---- Phase 3: gcc prerequisites (gmp/mpfr/mpc/isl) ----
phase_prereqs() {
  if have_stamp prereqs; then log "prereqs: cached"; return 0; fi
  log "gcc contrib/download_prerequisites"
  ( cd "$SRC/gcc-${GCC_VER}" && ./contrib/download_prerequisites )
  mark prereqs
}

export PATH="$PREFIX/bin:$PATH"

# ---- Phase 4: binutils (per target) ----
phase_binutils() {
  local target="$1"
  local stamp="binutils-$target"
  if have_stamp "$stamp"; then log "binutils ($target): cached"; return 0; fi
  log "configure + build binutils-${BINUTILS_VER} for $target"
  rm -rf "$BUILD/binutils-$target"
  mkdir -p "$BUILD/binutils-$target"
  cd "$BUILD/binutils-$target"
  "$SRC/binutils-${BINUTILS_VER}/configure" \
      --target="$target" \
      --prefix="$PREFIX" \
      --with-sysroot \
      --with-system-zlib \
      --disable-nls \
      --disable-werror \
      --enable-multilib
  make -j"$JOBS"
  make install
  mark "$stamp"
}

# ---- Phase 5: gcc stage 1 (compiler only, no libc) ----
phase_gcc_stage1() {
  local target="$1" arch="$2" abi="$3" multilib="$4"
  local stamp="gcc_stage1-$target"
  if have_stamp "$stamp"; then log "gcc stage1 ($target): cached"; return 0; fi
  log "configure + build gcc-${GCC_VER} stage 1 for $target"
  setup_target_src "$target"
  write_multilib_config "$target" "$multilib"
  local src_dir; src_dir="$(target_src "$target")"
  rm -rf "$BUILD/gcc-stage1-$target"
  mkdir -p "$BUILD/gcc-stage1-$target"
  cd "$BUILD/gcc-stage1-$target"
  "$src_dir/configure" \
      --target="$target" \
      --prefix="$PREFIX" \
      --with-arch="$arch" \
      --with-abi="$abi" \
      --without-headers \
      --with-newlib \
      --with-system-zlib \
      --enable-languages=c \
      --disable-shared \
      --disable-threads \
      --disable-libssp \
      --disable-libgomp \
      --disable-libmudflap \
      --disable-libquadmath \
      --disable-libatomic \
      --disable-decimal-float \
      --disable-nls \
      --disable-bootstrap \
      --enable-multilib
  make -j"$JOBS" all-gcc
  make install-gcc
  make -j"$JOBS" all-target-libgcc
  make install-target-libgcc
  mark "$stamp"
}

# ---- Phase 6: newlib (per target) ----
phase_newlib() {
  local target="$1"
  local stamp="newlib-$target"
  if have_stamp "$stamp"; then log "newlib ($target): cached"; return 0; fi
  log "configure + build newlib-${NEWLIB_VER} for $target"
  rm -rf "$BUILD/newlib-$target"
  mkdir -p "$BUILD/newlib-$target"
  cd "$BUILD/newlib-$target"
  "$SRC/newlib-${NEWLIB_VER}/configure" \
      --target="$target" \
      --prefix="$PREFIX" \
      --disable-newlib-supplied-syscalls \
      --enable-newlib-reent-small \
      --disable-newlib-fvwrite-in-streamio \
      --disable-newlib-fseek-optimization \
      --disable-newlib-wide-orient \
      --enable-newlib-nano-malloc \
      --disable-newlib-unbuf-stream-opt \
      --enable-lite-exit \
      --enable-newlib-global-atexit \
      --enable-newlib-nano-formatted-io \
      --enable-multilib \
      --disable-nls
  make -j"$JOBS"
  make install
  mark "$stamp"
}

# ---- Phase 7: gcc final (C + C++ with newlib) ----
phase_gcc_final() {
  local target="$1" arch="$2" abi="$3" multilib="$4"
  local stamp="gcc_final-$target"
  if have_stamp "$stamp"; then log "gcc final ($target): cached"; return 0; fi
  log "configure + build gcc-${GCC_VER} final for $target"
  setup_target_src "$target"
  write_multilib_config "$target" "$multilib"
  local src_dir; src_dir="$(target_src "$target")"
  rm -rf "$BUILD/gcc-final-$target"
  mkdir -p "$BUILD/gcc-final-$target"
  cd "$BUILD/gcc-final-$target"
  "$src_dir/configure" \
      --target="$target" \
      --prefix="$PREFIX" \
      --with-arch="$arch" \
      --with-abi="$abi" \
      --with-newlib \
      --with-system-zlib \
      --enable-languages=c,c++ \
      --disable-shared \
      --disable-threads \
      --disable-libssp \
      --disable-libgomp \
      --disable-nls \
      --disable-bootstrap \
      --enable-multilib
  make -j"$JOBS"
  make install
  mark "$stamp"
}

# ---- Phase 8: smoke test (per target, using its default arch/abi) ----
phase_smoke() {
  log "smoke test"
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/hello.c" <<'EOF'
#include <stdio.h>
int main(void) { printf("hello, riscv\n"); return 0; }
EOF
  cat > "$tmp/hello.cpp" <<'EOF'
#include <cstdio>
int main() { std::printf("hello, riscv c++\n"); return 0; }
EOF
  local spec target arch abi
  for spec in "${TARGETS[@]}"; do
    IFS='|' read -r target arch abi _ <<<"$spec"
    log "smoke test: ${target} default (${arch}/${abi}) — no -march/-mabi"
    "$PREFIX/bin/${target}-gcc" -O2 "$tmp/hello.c" -o "$tmp/hello-${target}.elf"
    file "$tmp/hello-${target}.elf"
    "$PREFIX/bin/${target}-g++" -O2 "$tmp/hello.cpp" -o "$tmp/hello-cpp-${target}.elf"
    file "$tmp/hello-cpp-${target}.elf"
    log "available multilibs (${target})"
    "$PREFIX/bin/${target}-gcc" -print-multi-lib
  done
  rm -rf "$tmp"
}

# Build the four target-specific phases for one TARGETS spec.
# Used by main() under `&` to run targets in parallel.
build_target() {
  local spec="$1"
  local target arch abi multilib
  IFS='|' read -r target arch abi multilib <<<"$spec"
  phase_binutils  "$target"
  phase_gcc_stage1 "$target" "$arch" "$abi" "$multilib"
  phase_newlib    "$target"
  phase_gcc_final  "$target" "$arch" "$abi" "$multilib"
}

# ---- Driver ----
main() {
  log "PREFIX=$PREFIX  JOBS=$JOBS  TARGETS=${TARGETS[*]}"

  # Surface where build/ lives. tmpfs is dramatically faster for the many-
  # small-files I/O of gcc/libstdc++ builds.
  if mount | grep -qE " on $BUILD type tmpfs"; then
    log "build/ is on tmpfs (fast)"
  else
    log "build/ is on disk; for ~2-4 min faster builds, mount tmpfs:
       sudo mount -t tmpfs -o size=20G tmpfs $BUILD"
  fi

  phase_download
  phase_extract
  phase_prereqs

  # Per-target builds run in parallel. Each writes to its own per-target
  # gcc src tree (see setup_target_src) so configure's t-elf-multilib
  # mutation doesn't race. Install paths are per-target inside $PREFIX,
  # so make-install doesn't conflict either.
  local spec pids=() targets=()
  for spec in "${TARGETS[@]}"; do
    local target
    IFS='|' read -r target _ _ _ <<<"$spec"
    targets+=("$target")
    local log_file="$LOG/build-$target.log"
    log "[parallel] $target -> $log_file"
    ( build_target "$spec" ) >"$log_file" 2>&1 &
    pids+=($!)
  done

  # Wait on each, accumulate failures, print log tail for any that failed.
  local fail=0 i=0 pid
  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      echo "FAILED: ${targets[$i]} (see $LOG/build-${targets[$i]}.log; tail below)" >&2
      tail -40 "$LOG/build-${targets[$i]}.log" >&2 || true
      fail=1
    else
      log "[parallel] ${targets[$i]} done"
    fi
    i=$((i+1))
  done
  [ "$fail" -eq 0 ] || exit 1

  phase_smoke
  log "DONE: toolchain(s) installed in $PREFIX"
  for spec in "${TARGETS[@]}"; do
    local target
    IFS='|' read -r target _ _ _ <<<"$spec"
    ls "$PREFIX/bin" | grep "^${target}" | head
  done
}

main "$@"
