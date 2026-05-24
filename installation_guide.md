# Installation Guide

This repo builds two bare-metal RISC-V GCC cross-toolchains from upstream GNU sources, side-by-side under a single prefix, so both `riscv32-unknown-elf-*` and `riscv64-unknown-elf-*` command sets coexist.

## Components

| Component | Version | Source |
|---|---|---|
| binutils  | 2.42   | https://ftp.gnu.org/gnu/binutils/ |
| gcc       | 13.3.0 | https://ftp.gnu.org/gnu/gcc/      |
| newlib    | 3.1.0  | https://sourceware.org/pub/newlib/ |
| gcc prereqs | bundled | `gcc/contrib/download_prerequisites` (gmp/mpfr/mpc/isl) |

Versions are overridable via `GCC_VER`, `BINUTILS_VER`, `NEWLIB_VER` env vars. The defaults are pinned to a known-good triple; binutils ≥ 2.41 is required for GCC 13 because the assembler/linker must understand the newer RISC-V relocations and instructions GCC emits.

## Host requirements

- Linux (tested on Ubuntu 22.04) or macOS (Intel/Apple Silicon).
- Tools on PATH: `bash`, `gcc`/`g++`, `make`, `tar`, `python3`, `wget` or `curl`.
- On macOS: Xcode Command Line Tools + Homebrew. The script sets `SDKROOT` and demotes C23-incompatible diagnostics so vintage GNU sources compile under modern Clang.
- ~20 GB free disk for build dirs + ~2 GB for the install. The build is RAM-hungry; an 8-core / 16 GB box is comfortable.

## Quick start

```bash
git clone <this repo>
cd build-riscv
./build.sh
```

The script downloads tarballs (cached in `src/`), extracts, runs gcc's prereq fetcher, then for each target builds binutils → gcc stage 1 → newlib → gcc final, ending with smoke tests for both targets.

Wall time on 24 cores: roughly 30–40 min for the first run (both toolchains); subsequent runs short-circuit on stamps.

## Configuration knobs (override via environment)

| Variable | Default | Purpose |
|---|---|---|
| `PREFIX`   | `$(pwd)/temp`           | Install root. Per-target paths land under `$PREFIX/bin`, `$PREFIX/lib/gcc/<target>/…`, `$PREFIX/<target>/lib/…`. |
| `JOBS`     | `nproc` (or `4`)        | `make -j` parallelism. |
| `GCC_VER`, `BINUTILS_VER`, `NEWLIB_VER` | as above | Pin component versions. URLs are derived. |
| `TARGETS`  | array, see below        | Target specs to build. |

`TARGETS` is a bash array; each entry is pipe-separated: `TARGET|ARCH|ABI|MULTILIB_GEN`. The defaults are:

```bash
TARGETS=(
  "riscv64-unknown-elf|rv64gc|lp64d|rv32imac-ilp32--;rv32imafdc-ilp32d--;rv64imac-lp64--;rv64imafdc-lp64d--"
  "riscv32-unknown-elf|rv32gc|ilp32d|rv32imac-ilp32--;rv32imafc-ilp32f--;rv32imafdc-ilp32d--"
)
```

`MULTILIB_GEN` syntax is what `gcc/config/riscv/multilib-generator` consumes: `<arch>-<abi>--[;...]` with a trailing `--` meaning no extra flags. To build only one target or change variants, export your own array before invoking the script:

```bash
TARGETS=( "riscv32-unknown-elf|rv32imac|ilp32|rv32imac-ilp32--" ) ./build.sh
```

## Layout produced

```
build-riscv/
├── src/                  # downloaded tarballs + extracted trees
├── build/                # per-phase, per-target build dirs (large; safe to delete)
│   ├── binutils-riscv64-unknown-elf/
│   ├── gcc-stage1-riscv64-unknown-elf/
│   ├── newlib-riscv64-unknown-elf/
│   ├── gcc-final-riscv64-unknown-elf/
│   └── …-riscv32-unknown-elf/
├── .stamps/              # one file per completed phase; delete a stamp to re-run that phase
├── log/                  # reserved (unused by the current driver)
└── temp/                 # install PREFIX
    ├── bin/              # riscv32-unknown-elf-* and riscv64-unknown-elf-* (27 each)
    ├── lib/gcc/<target>/9.2.0/…   # libgcc + multilib subdirs per target
    └── <target>/lib/…    # newlib + libstdc++ per multilib
```

## Adding the toolchain to PATH

```bash
export PATH="$(pwd)/temp/bin:$PATH"
riscv32-unknown-elf-gcc --version
riscv64-unknown-elf-gcc --version
```

For a permanent setup, drop that `export` into your shell rc, or use absolute paths in your Makefiles.

## Verification

After a successful build the script runs these smoke tests itself; you can re-run them manually:

```bash
echo 'int main(void){return 0;}' > /tmp/t.c
temp/bin/riscv32-unknown-elf-gcc -O2 /tmp/t.c -o /tmp/t32 && file /tmp/t32   # → ELF 32-bit, ilp32d
temp/bin/riscv64-unknown-elf-gcc -O2 /tmp/t.c -o /tmp/t64 && file /tmp/t64   # → ELF 64-bit, lp64d
temp/bin/riscv32-unknown-elf-gcc -print-multi-lib
temp/bin/riscv64-unknown-elf-gcc -print-multi-lib
```

## Incremental rebuilds

Each phase writes a stamp under `.stamps/`. To force re-running a phase, delete its stamp:

```bash
rm .stamps/gcc_final-riscv32-unknown-elf
./build.sh
```

To start a target from scratch, remove all four of its stamps (`binutils-`, `gcc_stage1-`, `newlib-`, `gcc_final-` with the target suffix). The script's `rm -rf` on the target's build dirs takes care of stale make state.

## How multilib variants are actually controlled

`build.sh` regenerates `gcc/config/riscv/t-elf-multilib` in the per-target src tree from each target's `MULTILIB_GEN` spec before configure. This is the workaround for an old gcc-9.2.0 quirk where `--with-multilib-generator` was silently ignored; it still works on gcc-13 (the file and `multilib-generator` script are in the same path) but is no longer strictly required — gcc-10+ accepts the configure flag natively. Keeping the regeneration approach avoids touching the multilib logic when bumping GCC versions.

If you want to retire the regeneration, replace `write_multilib_config` calls with `--with-multilib-generator="$multilib"` on the gcc configure lines.

## Known quirks

- `shell-init: error retrieving current directory: getcwd: cannot access parent directories` lines during the build are harmless. They come from sub-bash invocations whose parent's CWD was deleted; they don't affect correctness.
- `src/gcc-9.2.0/gcc/config/riscv/t-elf-multilib` is mutated by the build. If you want a pristine src tree, restore it from `t-elf-multilib.orig` (or re-extract the gcc tarball).
- The smoke test exercises the canonical arch/abi for each target via the target prefix alone (no `-march`/`-mabi`). Non-default multilibs are exercised by passing `-march`/`-mabi`.

## Uninstall

```bash
rm -rf temp build .stamps log
```

`src/` keeps the downloaded tarballs and extracted trees — delete it too for a full reset.
