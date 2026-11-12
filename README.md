# ch32rv-toolchain

[日本語](README.ja.md)

A RISC-V-only clang + lld built from an upstream LLVM release, with a C
library (picolibc), a runtime (compiler-rt), a C++ library (libc++) and a
debugger (GDB), packed as one archive per host for the CH32 Arduino core
(ArduinoCore-CH32RV) to install through the Arduino Boards Manager.

## What is in an archive

`ch32rv-toolchain/` (one root directory, as arduino-cli requires):

- `bin/`: `clang`, `clang++`, `ld.lld` (lld), `llvm-ar`, `llvm-ranlib`,
  `llvm-objcopy`, `llvm-objdump`, `llvm-nm`, `llvm-size`, `llvm-readelf`,
  `llvm-strip`, `llvm-symbolizer`. On Linux and macOS they are one
  multicall binary with links; on Windows, separate executables.
  `riscv32-unknown-elf-gdb` (GDB).
- `lib/clang/<version>/include/`: clang's own headers.
- `lib/clang-runtimes/`: picolibc, compiler-rt's builtins, libc++ and
  libc++abi per instruction set (`multilib.yaml` and a directory each); the
  headers once, in `common/include`.
- `include/c++/v1/`: libc++'s headers.
- `share/gdb/`: GDB's data.
- `licenses/`: the licenses of picolibc, GDB, GMP, MPFR and Expat.
- `LICENSE.TXT` (LLVM: Apache License 2.0 with LLVM Exceptions),
  `VERSION.txt`, this README.

Only the RISCV backend is built. clang reads
`lib/clang-runtimes/multilib.yaml` and picks the libraries from `-march` /
`-mabi`, so no path needs naming.

| Library build | Instruction set | Series |
|---|---|---|
| `rv32ec/ilp32e`, `rv32ec_xwchc/ilp32e` | rv32ec | CH32V003, V00x, M007 |
| `rv32imc/ilp32`, `rv32imc_xwchc/ilp32` | rv32imc | CH32V205, M030 |
| `rv32imac/ilp32`, `rv32imac_xwchc/ilp32` | rv32imac | V103 (no XW), V20x, L103, X035, V407 |
| `rv32imafc/ilp32f`, `rv32imafc_xwchc/ilp32f` | rv32imafc | V30x, X315, H41x |

Each instruction set has a build with WCH's XW and one without: a
`-march` with `_xwchc` takes the first. Every QingKe core but the V3A
(CH32V103) has XW.

The libraries are built at `-Oz`. picolibc's printf / scanf default to the
integer-only variants (the floating-point ones are `__f_vfprintf`,
`__d_vfprintf` and so on). libc++ has no exceptions, RTTI or threads, and
leaves `new` / `delete` to the program.

clang carries WCH's `__attribute__((interrupt("WCH-Interrupt-fast")))`
(`patches/`): on a QingKe core with HPE (the hardware register save) on, the
handler does not save again what the hardware saved.

The WCH QingKe "XW" compressed instructions are LLVM's `Xwchc` extension
(`-march=..._xwchc`, LLVM 19 and later). Which cores have it is the core's
business (ch32-device-data's core table): using it on a core without XW
(QingKe V3A, V4A) stops the program at the first such instruction.

## Using it outside the Arduino core

The archive is a self-contained bare-metal toolchain; nothing in it is
specific to the Arduino core. Unpack it anywhere and call `bin/clang`:

```sh
TC=/path/to/ch32rv-toolchain
$TC/bin/clang --target=riscv32-unknown-elf -march=rv32ec_zicsr_xwchc -mabi=ilp32e \
  -Oz -ffunction-sections -fdata-sections -c main.c -o main.o
$TC/bin/clang --target=riscv32-unknown-elf -march=rv32ec_zicsr_xwchc -mabi=ilp32e \
  -nostdlib -nostartfiles -T your.ld -Wl,--gc-sections \
  startup.o main.o -lc -lclang_rt.builtins -o app.elf
$TC/bin/llvm-objcopy -O binary app.elf app.bin
```

- **`-march` picks the libraries.** clang reads
  `lib/clang-runtimes/multilib.yaml` and links the build for the
  instruction set, with XW when `-march` has `_xwchc` (table above).
  Extensions on top (`_zmmul`, `_zba_zbb_zbs`) are fine. lld is the default
  linker.
- **Libraries to name.** With `-nostdlib`: `-lc` (picolibc; `-lm` is an
  empty stub), `-lclang_rt.builtins` (soft float, 64-bit division,
  `__riscv_save_N` for `-msave-restore`), and for C++ `-lc++ -lc++abi` before
  them. Without `-nostdlib` clang adds them itself, but also expects a
  `crt0.o`, which is not shipped: the startup code is the program's.
- **What picolibc leaves to the program:** `stdin` / `stdout` / `stderr`
  (`FILE *const`, see picolibc's `FDEV_SETUP_STREAM`) if anything prints,
  `sbrk()` (or the linker symbols `__heap_start` / `__heap_end` for its
  fallback) if anything allocates, and `_exit()`. `time()` calls
  `gettimeofday()`, `clock()` calls `times()`.
- **printf / scanf:** `printf` and friends are picolibc's integer-only
  variants by default. Link `-Wl,--defsym=vfprintf=__d_vfprintf` (or
  `__f_vfprintf` for float only) for `%f %e %g`, and the same with
  `vfscanf` / `__d_vfscanf` for scanf.
- **C++:** libc++ without exceptions, RTTI or threads; compile with
  `-fno-exceptions -fno-rtti`. It defines no `operator new` / `delete`: the
  program does (over `malloc()`).
- **Interrupt handlers:** `__attribute__((interrupt("WCH-Interrupt-fast")))`
  as in WCH's EVT, when the startup code turns HPE on (INTSYSCR bit 0); keep
  the nesting within HPE's depth (2 levels, 3 on QingKe V4). Plain
  `__attribute__((interrupt))` otherwise.
- **Debugging:** `bin/riscv32-unknown-elf-gdb` against a GDB server for the
  probe (WCH's OpenOCD, or `ch32rv gdb`).

Projects written for GCC do not take it as a drop-in replacement. ch32fun
(cnlohr/ch32fun a800cbd, tried 2026-11-12), for one, calls `$(PREFIX)-gcc`,
passes GCC-only options (`-fno-tree-loop-distribute-patterns`) and has
naked functions with C statements in them, which clang rejects: it needs
support on its side.

## Hosts

| Target triple | Runner | Notes |
|---|---|---|
| x86_64-unknown-linux-gnu | ubuntu-22.04 | glibc 2.35 or later; libstdc++ linked in |
| aarch64-unknown-linux-gnu | ubuntu-22.04-arm | as above |
| x86_64-apple-darwin | macos-15-intel | macOS 11 or later |
| aarch64-apple-darwin | macos-15 | macOS 11 or later |
| x86_64-pc-windows-msvc | windows-2022 | MSVC runtime linked in |

## Versions

`<LLVM version>-<build>`, e.g. `23.1.5-1`: LLVM 23.1.5, first build of it.
A tag `v23.1.5-1` builds every host (.github/workflows/release.yml) and
publishes a release with each archive and its `.sha256`.

## Building by hand

```sh
scripts/build.sh 23.1.5 23.1.5-2 x86_64-unknown-linux-gnu   # clang, patches/ applied
scripts/build-runtimes.sh work/stage/ch32rv-toolchain work/llvm-project-23.1.5.src
tar -czf runtimes.tar.gz -C work/stage/ch32rv-toolchain lib/clang-runtimes include/c++ licenses
scripts/build-gdb.sh work/stage/ch32rv-toolchain
scripts/pack.sh 23.1.5-2 x86_64-unknown-linux-gnu runtimes.tar.gz
```

Needs cmake, ninja, meson, a C++ compiler (MSVC on Windows; GDB takes MSYS2's
MinGW), m4, curl, tar (7z on Windows). `JOBS` and `LINK_JOBS` limit
parallelism; the link of clang takes a few GB of memory per job. A release
builds the libraries once, with upstream's own release of the same LLVM, and
puts them in every host's archive: they are the same on every host.

## License

The build scripts in this repository: MIT. The archives contain LLVM (clang,
lld, compiler-rt, libc++) under the Apache License 2.0 with LLVM Exceptions
(LICENSE.TXT in each archive), picolibc under several BSD-style licenses,
GDB under GPL-3.0-or-later, GMP and MPFR under LGPL-3.0-or-later and Expat
under MIT (`licenses/`). The sources of GDB and its libraries go with each
release.
