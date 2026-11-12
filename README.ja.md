# ch32rv-toolchain

[English](README.md)

LLVM の正式リリースから RISC-V だけを入れた clang と lld をビルドし、
C ライブラリ（picolibc）、ランタイム（compiler-rt）、C++ ライブラリ（libc++）、
デバッガー（GDB）と一緒に、ホストごとに 1 つのアーカイブにまとめたものです。
CH32 の Arduino コア（ArduinoCore-CH32RV）が Arduino のボードマネージャーから
入れて使います。

## アーカイブの中身

`ch32rv-toolchain/`（arduino-cli の決まりで、最上位のディレクトリは 1 つ）:

- `bin/`: `clang`、`clang++`、`ld.lld`（lld）、`llvm-ar`、`llvm-ranlib`、
  `llvm-objcopy`、`llvm-objdump`、`llvm-nm`、`llvm-size`、`llvm-readelf`、
  `llvm-strip`、`llvm-symbolizer`。Linux と macOS では 1 つのマルチコール
  バイナリとリンク、Windows では別々の実行ファイルです。
  `riscv32-unknown-elf-gdb`（GDB）。
- `lib/clang/<版>/include/`: clang 自身のヘッダー。
- `lib/clang-runtimes/`: 命令セットの組み合わせごとの picolibc、compiler-rt の
  builtins、libc++ と libc++abi（`multilib.yaml` と、種類ごとのディレクトリ）。
  ヘッダーは `common/include` に 1 組。
- `include/c++/v1/`: libc++ のヘッダー。
- `share/gdb/`: GDB のデータ。
- `licenses/`: picolibc、GDB、GMP、MPFR、Expat のライセンス。
- `LICENSE.TXT`（LLVM: Apache License 2.0 with LLVM Exceptions）、
  `VERSION.txt`、README。

バックエンドは RISCV だけです。clang は `-march` / `-mabi` から
`lib/clang-runtimes/multilib.yaml` を読んで合うライブラリを選ぶので、
パスを指定する必要はありません。

| ライブラリの種類 | 命令セット | 使う系列 |
|---|---|---|
| `rv32ec_xwchc/ilp32e` | rv32ec + XW | CH32V003、V00x |
| `rv32imc_xwchc/ilp32` | rv32imc + XW | CH32V205、M030 |
| `rv32imac/ilp32` | rv32imac | CH32V103（XW が無い） |
| `rv32imac_xwchc/ilp32` | rv32imac + XW | V20x、L103、X035、V407 |
| `rv32imafc_xwchc/ilp32f` | rv32imafc + XW | V30x、X315、H41x |

ライブラリは `-Oz` でビルドします。picolibc の printf / scanf は、整数だけの版を
既定にしています（浮動小数の版は `__f_vfprintf`、`__d_vfprintf` などで選べます）。
例外、RTTI、スレッドの無い libc++ で、`new` / `delete` は持ちません
（プログラム側で定義します）。

clang には WCH の `__attribute__((interrupt("WCH-Interrupt-fast")))` を足して
あります（`patches/`）。HPE（ハードウェアのレジスタ退避）を有効にした QingKe の
コアで、割り込みの関数がハードウェアの退避したレジスタを退避し直しません。

WCH QingKe の「XW」圧縮命令は LLVM の `Xwchc` 拡張です
（`-march=..._xwchc`、LLVM 19 以降）。どのコアにあるかはコア側
（ch32-device-data のコア表）で決めます。XW のないコア（QingKe V3A、V4A）で
使うと、最初の XW 命令でプログラムが止まります。

## ホスト

| ターゲット | ランナー | 備考 |
|---|---|---|
| x86_64-unknown-linux-gnu | ubuntu-22.04 | glibc 2.35 以降。libstdc++ は静的リンク |
| aarch64-unknown-linux-gnu | ubuntu-22.04-arm | 同上 |
| x86_64-apple-darwin | macos-15-intel | macOS 11 以降 |
| aarch64-apple-darwin | macos-15 | macOS 11 以降 |
| x86_64-pc-windows-msvc | windows-2022 | MSVC ランタイムは静的リンク |

## 版

`<LLVM の版>-<ビルド番号>`。例: `23.1.5-1` は LLVM 23.1.5 の 1 回目のビルド。
タグ `v23.1.5-1` を push すると全ホストをビルドし
（.github/workflows/release.yml）、各アーカイブと `.sha256` をリリースに
載せます。

## 手元でのビルド

```sh
scripts/build.sh 23.1.5 23.1.5-2 x86_64-unknown-linux-gnu   # clang（patches/ を当てる）
scripts/build-runtimes.sh work/stage/ch32rv-toolchain work/llvm-project-23.1.5.src
tar -czf runtimes.tar.gz -C work/stage/ch32rv-toolchain lib/clang-runtimes include/c++ licenses
scripts/build-gdb.sh work/stage/ch32rv-toolchain
scripts/pack.sh 23.1.5-2 x86_64-unknown-linux-gnu runtimes.tar.gz
```

cmake、ninja、meson、C++ コンパイラ（Windows は MSVC、GDB は MSYS2 の MinGW）、
m4、curl、tar（Windows は 7z）が要ります。並列数は `JOBS` と `LINK_JOBS` で
絞れます。clang のリンクは 1 ジョブあたり数 GB のメモリを使います。
リリースでは、ライブラリは LLVM の正式リリースの同じ版の clang で 1 回だけ作り、
各ホストのアーカイブに入れます（どのホストでも同じものになるため）。

## ライセンス

このリポジトリのビルドスクリプトは MIT です。アーカイブに入る LLVM
（clang、lld、compiler-rt、libc++）は Apache License 2.0 with LLVM Exceptions
です（各アーカイブの LICENSE.TXT）。picolibc は BSD 系の複数のライセンス、
GDB は GPL-3.0-or-later、GMP と MPFR は LGPL-3.0-or-later、Expat は MIT です
（`licenses/`）。GDB とその依存のソースは、リリースに一緒に載せます。
