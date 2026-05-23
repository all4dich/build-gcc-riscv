#!/usr/bin/env bash
# Build a bare-metal RISC-V GCC cross-toolchain from GNU mainline sources.
# Components: binutils-2.32, gcc-9.2.0, newlib-3.1.0
# Supported hosts: Linux, macOS (Intel or Apple Silicon).
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

# ---- Configurable knobs (override via env) ----
PREFIX="${PREFIX:-$HOME/.local/gcc-9.2.0-riscv}"
TARGET="${TARGET:-riscv64-unknown-elf}"
ARCH="${ARCH:-rv64gc}"
ABI="${ABI:-lp64d}"
JOBS="${JOBS:-$(detect_jobs)}"

GCC_VER="${GCC_VER:-9.2.0}"
BINUTILS_VER="${BINUTILS_VER:-2.32}"
NEWLIB_VER="${NEWLIB_VER:-3.1.0}"

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

# ---- Layout ----
WORK="$(cd "$(dirname "$0")" && pwd)"
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

run() {
  local name="$1"; shift
  log "$name"
  if "$@" 2>&1 | tee "$LOG/$name.log"; then
    return 0
  else
    echo "FAILED: $name. See $LOG/$name.log"
    return 1
  fi
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

# ---- Phase 4: binutils ----
phase_binutils() {
  if have_stamp binutils; then log "binutils: cached"; return 0; fi
  log "configure + build binutils-${BINUTILS_VER}"
  rm -rf "$BUILD/binutils"
  mkdir -p "$BUILD/binutils"
  cd "$BUILD/binutils"
  "$SRC/binutils-${BINUTILS_VER}/configure" \
      --target="$TARGET" \
      --prefix="$PREFIX" \
      --with-sysroot \
      --with-system-zlib \
      --disable-nls \
      --disable-werror \
      --disable-multilib
  make -j"$JOBS"
  make install
  mark binutils
}

# ---- Phase 5: gcc stage 1 (compiler only, no libc) ----
phase_gcc_stage1() {
  if have_stamp gcc_stage1; then log "gcc stage1: cached"; return 0; fi
  log "configure + build gcc-${GCC_VER} stage 1"
  rm -rf "$BUILD/gcc-stage1"
  mkdir -p "$BUILD/gcc-stage1"
  cd "$BUILD/gcc-stage1"
  "$SRC/gcc-${GCC_VER}/configure" \
      --target="$TARGET" \
      --prefix="$PREFIX" \
      --with-arch="$ARCH" \
      --with-abi="$ABI" \
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
      --disable-multilib
  make -j"$JOBS" all-gcc
  make install-gcc
  make -j"$JOBS" all-target-libgcc
  make install-target-libgcc
  mark gcc_stage1
}

# ---- Phase 6: newlib ----
phase_newlib() {
  if have_stamp newlib; then log "newlib: cached"; return 0; fi
  log "configure + build newlib-${NEWLIB_VER}"
  rm -rf "$BUILD/newlib"
  mkdir -p "$BUILD/newlib"
  cd "$BUILD/newlib"
  "$SRC/newlib-${NEWLIB_VER}/configure" \
      --target="$TARGET" \
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
      --disable-nls
  make -j"$JOBS"
  make install
  mark newlib
}

# ---- Phase 7: gcc final (C + C++ with newlib) ----
phase_gcc_final() {
  if have_stamp gcc_final; then log "gcc final: cached"; return 0; fi
  log "configure + build gcc-${GCC_VER} final"
  rm -rf "$BUILD/gcc-final"
  mkdir -p "$BUILD/gcc-final"
  cd "$BUILD/gcc-final"
  "$SRC/gcc-${GCC_VER}/configure" \
      --target="$TARGET" \
      --prefix="$PREFIX" \
      --with-arch="$ARCH" \
      --with-abi="$ABI" \
      --with-newlib \
      --with-system-zlib \
      --enable-languages=c,c++ \
      --disable-shared \
      --disable-threads \
      --disable-libssp \
      --disable-libgomp \
      --disable-nls \
      --disable-bootstrap \
      --disable-multilib
  make -j"$JOBS"
  make install
  mark gcc_final
}

# ---- Phase 8: smoke test ----
phase_smoke() {
  log "smoke test"
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/hello.c" <<'EOF'
#include <stdio.h>
int main(void) { printf("hello, riscv\n"); return 0; }
EOF
  "$PREFIX/bin/${TARGET}-gcc" -O2 -march="$ARCH" -mabi="$ABI" \
      "$tmp/hello.c" -o "$tmp/hello.elf"
  file "$tmp/hello.elf"
  "$PREFIX/bin/${TARGET}-objdump" -d "$tmp/hello.elf" 2>&1 | sed -n '1,20p'
  cat > "$tmp/hello.cpp" <<'EOF'
#include <cstdio>
int main() { std::printf("hello, riscv c++\n"); return 0; }
EOF
  "$PREFIX/bin/${TARGET}-g++" -O2 -march="$ARCH" -mabi="$ABI" \
      "$tmp/hello.cpp" -o "$tmp/hello-cpp.elf"
  file "$tmp/hello-cpp.elf"
  rm -rf "$tmp"
}

# ---- Driver ----
main() {
set -x
  log "PREFIX=$PREFIX  TARGET=$TARGET  ARCH=$ARCH  ABI=$ABI  JOBS=$JOBS"
  phase_download
  phase_extract
  phase_prereqs
  phase_binutils
  phase_gcc_stage1
  phase_newlib
  phase_gcc_final
  phase_smoke
  log "DONE: toolchain installed in $PREFIX"
  ls "$PREFIX/bin" | grep "^${TARGET}" | head
set +x
}

main "$@"
