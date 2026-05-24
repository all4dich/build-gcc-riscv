# Getting Started

A practical walkthrough: why this repo exists, what it gives you, and how to use it for real RISC-V bare-metal work.

## The scenario

You're building firmware for a heterogeneous RISC-V system:

- A small **MCU core** (rv32, no FPU on the cheap parts, hardware double on the higher SKUs) running a control loop in C and a thin RTOS.
- A bigger **application core** (rv64gc) running a small ELF that boots from ROM, sets up memory, and hands off to a payload.

The host is Ubuntu. There's no distro package that ships both `riscv32-unknown-elf-gcc` and `riscv64-unknown-elf-gcc` together with newlib + libstdc++ and the multilib variants you actually need (`rv32imac/ilp32` for the integer-only MCU SKU, `rv32imafdc/ilp32d` for the FPU SKU, `rv64gc/lp64d` for the app core). The riscv-gnu-toolchain meta-repo can build all of that, but it's heavy and version-pins things you don't always want.

This repo's `build.sh` is the minimal alternative: pure upstream GNU tarballs (binutils-2.32, gcc-9.2.0, newlib-3.1.0), one shell script, two target triples, custom multilib lists per target, project-local install.

End result:

```
temp/bin/
├── riscv32-unknown-elf-gcc   →  defaults to rv32gc/ilp32d, plus multilibs for rv32imac, rv32imafc, rv32imafdc
└── riscv64-unknown-elf-gcc   →  defaults to rv64gc/lp64d, plus multilibs for rv32* and rv64imac
```

No `-march`/`-mabi` needed for the default case — the target triple in the command name picks the bit-width.

## Step 1 — Build

From the repo root:

```bash
./build.sh
```

First run takes 30–40 minutes on a 24-core box (less than 10 GB peak RAM). The script caches downloads, source extraction, and each build phase via stamp files in `.stamps/`. Re-running after a successful build is near-instant (every phase short-circuits).

See [installation_guide.md](installation_guide.md) for prerequisites and configuration knobs.

## Step 2 — Put the toolchain on PATH

```bash
export PATH="$(pwd)/temp/bin:$PATH"
```

Confirm:

```bash
riscv32-unknown-elf-gcc --version    # gcc (GCC) 9.2.0
riscv64-unknown-elf-gcc --version    # gcc (GCC) 9.2.0
```

## Step 3 — Write something for the MCU core (rv32)

Save as `mcu.c`:

```c
#include <stdio.h>

volatile int counter;

int main(void) {
    for (int i = 0; i < 10; i++) {
        counter += i;
    }
    printf("counter=%d\n", counter);
    return 0;
}
```

Compile with the rv32 default arch/abi (rv32gc/ilp32d, hardware double-float):

```bash
riscv32-unknown-elf-gcc -O2 -g mcu.c -o mcu.elf
file mcu.elf
# mcu.elf: ELF 32-bit LSB executable, UCB RISC-V, RVC, double-float ABI
```

If your MCU SKU has no FPU, pick the integer-only multilib instead — same compiler, just override the arch/abi:

```bash
riscv32-unknown-elf-gcc -O2 -g -march=rv32imac -mabi=ilp32 mcu.c -o mcu-soft.elf
file mcu-soft.elf
# mcu-soft.elf: ELF 32-bit LSB executable, UCB RISC-V, RVC, soft-float ABI
```

Check which multilibs are available:

```bash
riscv32-unknown-elf-gcc -print-multi-lib
# .;
# rv32imac/ilp32;@march=rv32imac@mabi=ilp32
# rv32imafc/ilp32f;@march=rv32imafc@mabi=ilp32f
# rv32imafdc/ilp32d;@march=rv32imafdc@mabi=ilp32d
```

The first `.;` is the default; the others are picked by matching `-march`/`-mabi`. Newlib and libstdc++ are pre-built for each.

## Step 4 — Write something for the app core (rv64)

Save as `app.cpp`:

```cpp
#include <cstdio>
#include <array>

int main() {
    std::array<int, 5> xs{1, 2, 3, 4, 5};
    int sum = 0;
    for (auto x : xs) sum += x;
    std::printf("sum=%d\n", sum);
    return 0;
}
```

Compile with the rv64 default (rv64gc/lp64d):

```bash
riscv64-unknown-elf-g++ -O2 -g app.cpp -o app.elf
file app.elf
# app.elf: ELF 64-bit LSB executable, UCB RISC-V, RVC, double-float ABI
```

The rv64 toolchain is also multilib — it can target rv32 variants too, which is handy for sharing one toolchain across both cores if you don't want to install both:

```bash
riscv64-unknown-elf-gcc -print-multi-lib
# .;
# rv32i/ilp32;@march=rv32i@mabi=ilp32
# rv32im/ilp32;@march=rv32im@mabi=ilp32
# rv32iac/ilp32;@march=rv32iac@mabi=ilp32
# rv32imac/ilp32;@march=rv32imac@mabi=ilp32
# rv32imafc/ilp32f;@march=rv32imafc@mabi=ilp32f
# rv64imac/lp64;@march=rv64imac@mabi=lp64
# rv64imafdc/lp64d;@march=rv64imafdc@mabi=lp64d
```

That said, using the matching target prefix (`riscv32-` for MCU code) is the cleaner habit: it surfaces typos like accidentally building a 64-bit object for an rv32 target.

## Step 5 — Run under an ISS (optional)

The toolchain ships `riscv{32,64}-unknown-elf-{objdump,readelf,nm,size}` etc. for inspection. To actually execute the ELFs, plug in qemu-system-riscv32 / qemu-riscv32 (user mode) or Spike — those are out of scope for this repo. The smoke test in `build.sh` only confirms compile + link work; it doesn't run the binaries.

```bash
riscv32-unknown-elf-objdump -d mcu.elf | head -30
riscv32-unknown-elf-size mcu.elf
```

## Why both toolchains instead of one multilib?

You could use only `riscv64-unknown-elf-gcc -march=rv32... -mabi=ilp32...` for MCU code; the multilib build supports it. Reasons to keep `riscv32-unknown-elf-*` available as a first-class command set:

- **Makefiles stay readable.** `CC = riscv32-unknown-elf-gcc` is clearer than `CC = riscv64-unknown-elf-gcc` with hidden `-march`/`-mabi` flags pulled in via CFLAGS.
- **The target prefix is a sanity rail.** If you accidentally point your MCU build at the rv64 driver, the linker won't pick up a 32-bit `crt0.o` for you. A wrong target prefix fails loudly.
- **Cross-project ergonomics.** Third-party RISC-V Makefiles and SDK templates expect `riscv32-unknown-elf-*` for 32-bit cores. Matching that convention saves you a patch.

## When you change the build

- **Change a target's multilib set:** edit the `TARGETS` array near the top of `build.sh`, delete that target's stamps (`.stamps/{binutils,gcc_stage1,newlib,gcc_final}-<target>`), and re-run. The script rewrites `src/gcc-9.2.0/gcc/config/riscv/t-elf-multilib` per target before each gcc configure (see the note in installation_guide.md about gcc-9.2.0's `--with-multilib-generator` being a no-op).
- **Add a third target** (e.g., `riscv64-elf` without `-unknown-`): just append another `"target|arch|abi|multilibs"` entry to the array.
- **Use a different install root:** `PREFIX=/opt/riscv ./build.sh`. By default it's the project-local `temp/` so the repo is self-contained and your home dir stays untouched.

## When the build breaks

- `installation_guide.md` has the troubleshooting notes (shell-init noise, mutated src tree, etc.).
- For a clean slate without re-downloading: `rm -rf build temp .stamps && ./build.sh` keeps `src/`.
- For a full reset including sources: `rm -rf build temp .stamps src && ./build.sh`.
