# ch32rv-clang

[日本語](README.ja.md)

A RISC-V-only clang + lld built from an upstream LLVM release, with a C
library (picolibc), a runtime (compiler-rt), a C++ library (libc++) and a
debugger (GDB), packed as one archive per host for the CH32 Arduino core
(ArduinoCore-CH32RV) to install through the Arduino Boards Manager.

## What is in an archive

`ch32rv-clang/` (one root directory, as arduino-cli requires):

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
| `rv32ec_xwchc/ilp32e` | rv32ec + XW | CH32V003, V00x |
| `rv32imc_xwchc/ilp32` | rv32imc + XW | CH32V205, M030 |
| `rv32imac/ilp32` | rv32imac | CH32V103 (no XW) |
| `rv32imac_xwchc/ilp32` | rv32imac + XW | V20x, L103, X035, V407 |
| `rv32imafc_xwchc/ilp32f` | rv32imafc + XW | V30x, X315, H41x |

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
scripts/build-runtimes.sh work/stage/ch32rv-clang work/llvm-project-23.1.5.src
tar -czf runtimes.tar.gz -C work/stage/ch32rv-clang lib/clang-runtimes include/c++ licenses
scripts/build-gdb.sh work/stage/ch32rv-clang
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
