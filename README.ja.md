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

| ライブラリの種類 | 命令セット | 系列 |
|---|---|---|
| `rv32ec/ilp32e`、`rv32ec_xwchc/ilp32e` | rv32ec | CH32V003、V00x、M007 |
| `rv32imc/ilp32`、`rv32imc_xwchc/ilp32` | rv32imc | CH32V205、M030 |
| `rv32imac/ilp32`、`rv32imac_xwchc/ilp32` | rv32imac | V103（XW が無い）、V20x、L103、X035、V407 |
| `rv32imafc/ilp32f`、`rv32imafc_xwchc/ilp32f` | rv32imafc | V30x、X315、H41x |

どの命令セットにも、WCH の XW 付きの版と XW 無しの版があります。`-march` に `_xwchc` が
あれば XW 付きの版が選ばれます。XW を持たないのは QingKe V3A（CH32V103）だけです。

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

## Arduino コアの外で使う

アーカイブは、それだけで完結したベアメタル用のツールチェーンです。Arduino コアに
依存するものは入っていません。好きな場所に展開して `bin/clang` を呼びます。

```sh
TC=/path/to/ch32rv-toolchain
$TC/bin/clang --target=riscv32-unknown-elf -march=rv32ec_zicsr_xwchc -mabi=ilp32e \
  -Oz -ffunction-sections -fdata-sections -c main.c -o main.o
$TC/bin/clang --target=riscv32-unknown-elf -march=rv32ec_zicsr_xwchc -mabi=ilp32e \
  -nostdlib -nostartfiles -T your.ld -Wl,--gc-sections \
  startup.o main.o -lc -lclang_rt.builtins -o app.elf
$TC/bin/llvm-objcopy -O binary app.elf app.bin
```

- **ライブラリは `-march` で選ばれます。** clang が `lib/clang-runtimes/multilib.yaml` を
  読み、命令セットに合う版をリンクします。`-march` に `_xwchc` があれば XW 付きの版です
  （上の表）。`_zmmul` や `_zba_zbb_zbs` を足すのはかまいません。リンカーは既定で lld です。
- **リンクで名前を挙げるライブラリ。** `-nostdlib` のときは `-lc`（picolibc。`-lm` は空）、
  `-lclang_rt.builtins`（ソフトウェアの浮動小数点、64 bit の割り算、`-msave-restore` の
  `__riscv_save_N`）、C++ ならその前に `-lc++ -lc++abi`。`-nostdlib` を付けなければ clang が
  自分で足しますが、`crt0.o` も探します。`crt0.o` は入っていないので、起動のコードは
  プログラム側で用意します。
- **picolibc がプログラムに任せるもの:** 何かを表示するなら `stdin` / `stdout` / `stderr`
  （`FILE *const`。picolibc の `FDEV_SETUP_STREAM`）、メモリを確保するなら `sbrk()`（または、
  picolibc の代わりの版が使うリンカーのシンボル `__heap_start` / `__heap_end`）、それに
  `_exit()`。`time()` は `gettimeofday()` を、`clock()` は `times()` を呼びます。
- **printf / scanf:** 既定は picolibc の整数だけの版です。`%f %e %g` を使うときは
  `-Wl,--defsym=vfprintf=__d_vfprintf`（float だけなら `__f_vfprintf`）を、scanf は同じく
  `vfscanf` / `__d_vfscanf` を指定します。
- **C++:** 例外、RTTI、スレッドの無い libc++ です。`-fno-exceptions -fno-rtti` で
  コンパイルします。`operator new` / `delete` は定義していないので、プログラム側で
  （`malloc()` の上に）定義します。
- **割り込みの関数:** 起動のコードで HPE を有効にしたなら（INTSYSCR の bit 0）、WCH の EVT と
  同じく `__attribute__((interrupt("WCH-Interrupt-fast")))` が使えます。入れ子の深さは HPE の
  段数（2 段、QingKe V4 は 3 段）以内にします。HPE を使わないなら、普通の
  `__attribute__((interrupt))` です。
- **デバッグ:** `bin/riscv32-unknown-elf-gdb` を、プローブの GDB サーバー（WCH の OpenOCD、
  または `ch32rv gdb`）につなぎます。

GCC 向けに書かれたプロジェクトは、置き換えるだけでは動きません。たとえば ch32fun
（cnlohr/ch32fun a800cbd、2026-11-12 に試した）は、`$(PREFIX)-gcc` を呼び、GCC だけの
オプション（`-fno-tree-loop-distribute-patterns`）を渡し、C の文を含む naked 関数を
持つので、clang はそこで止まります。ch32fun 側での対応が要ります。

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
