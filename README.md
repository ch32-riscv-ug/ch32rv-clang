# ch32rv-clang

[日本語](README.ja.md)

A RISC-V-only clang + lld built from an upstream LLVM release, packed as
one archive per host for the CH32 Arduino core (ArduinoCore-CH32RV) to
install through the Arduino Boards Manager.

## What is in an archive

`ch32rv-clang/` (one root directory, as arduino-cli requires):

- `bin/`: `clang`, `clang++`, `ld.lld` (lld), `llvm-ar`, `llvm-ranlib`,
  `llvm-objcopy`, `llvm-objdump`, `llvm-nm`, `llvm-size`, `llvm-readelf`,
  `llvm-strip`, `llvm-symbolizer`. On Linux and macOS they are one
  multicall binary with links; on Windows, separate executables.
- `lib/clang/<version>/include/`: clang's own headers.
- `LICENSE.TXT` (LLVM: Apache License 2.0 with LLVM Exceptions),
  `VERSION.txt`, this README.

Only the RISCV backend is built. There is no C library and no compiler
runtime: the core links newlib-nano and libgcc from the xPack GNU RISC-V
Embedded GCC for now.

The WCH QingKe "XW" compressed instructions are LLVM's `Xwchc` extension
(`-march=..._xwchc`, LLVM 19 and later). Which cores have it is the core's
business (ch32-device-data's core table): using it on a core without XW
(QingKe V3A, V4A) stops the program at the first such instruction.

## Hosts

| Target triple | Runner | Notes |
|---|---|---|
| x86_64-unknown-linux-gnu | ubuntu-22.04 | glibc 2.35 or later; libstdc++ linked in |
| aarch64-unknown-linux-gnu | ubuntu-22.04-arm | as above |
| x86_64-apple-darwin | macos-13 | macOS 11 or later |
| aarch64-apple-darwin | macos-14 | macOS 11 or later |
| x86_64-pc-windows-msvc | windows-2022 | MSVC runtime linked in |

## Versions

`<LLVM version>-<build>`, e.g. `23.1.5-1`: LLVM 23.1.5, first build of it.
A tag `v23.1.5-1` builds every host (.github/workflows/release.yml) and
publishes a release with each archive and its `.sha256`.

## Building by hand

```sh
scripts/build.sh 23.1.5 23.1.5-1 x86_64-unknown-linux-gnu
```

Needs cmake, ninja, a C++ compiler (MSVC on Windows), curl, tar (7z on
Windows). `JOBS` and `LINK_JOBS` limit parallelism; the link of clang takes
a few GB of memory per job.

## License

The build scripts in this repository: MIT. The archives contain LLVM, under
the Apache License 2.0 with LLVM Exceptions (LICENSE.TXT in each archive).
