# ch32rv-clang

[English](README.md)

LLVM の正式リリースから RISC-V だけを入れた clang と lld をビルドし、
ホストごとに 1 つのアーカイブにまとめたものです。CH32 の Arduino コア
（ArduinoCore-CH32RV）が Arduino のボードマネージャーから入れて使います。

## アーカイブの中身

`ch32rv-clang/`（arduino-cli の決まりで、最上位のディレクトリは 1 つ）:

- `bin/`: `clang`、`clang++`、`ld.lld`（lld）、`llvm-ar`、`llvm-ranlib`、
  `llvm-objcopy`、`llvm-objdump`、`llvm-nm`、`llvm-size`、`llvm-readelf`、
  `llvm-strip`、`llvm-symbolizer`。Linux と macOS では 1 つのマルチコール
  バイナリとリンク、Windows では別々の実行ファイルです。
- `lib/clang/<版>/include/`: clang 自身のヘッダー。
- `LICENSE.TXT`（LLVM: Apache License 2.0 with LLVM Exceptions）、
  `VERSION.txt`、README。

バックエンドは RISCV だけです。C ライブラリとコンパイラのランタイムは
入っていません。いまのところコアは xPack GNU RISC-V Embedded GCC の
newlib-nano と libgcc をリンクします。

WCH QingKe の「XW」圧縮命令は LLVM の `Xwchc` 拡張です
（`-march=..._xwchc`、LLVM 19 以降）。どのコアにあるかはコア側
（ch32-device-data のコア表）で決めます。XW のないコア（QingKe V3A、V4A）で
使うと、最初の XW 命令でプログラムが止まります。

## ホスト

| ターゲット | ランナー | 備考 |
|---|---|---|
| x86_64-unknown-linux-gnu | ubuntu-22.04 | glibc 2.35 以降。libstdc++ は静的リンク |
| aarch64-unknown-linux-gnu | ubuntu-22.04-arm | 同上 |
| x86_64-apple-darwin | macos-13 | macOS 11 以降 |
| aarch64-apple-darwin | macos-14 | macOS 11 以降 |
| x86_64-pc-windows-msvc | windows-2022 | MSVC ランタイムは静的リンク |

## 版

`<LLVM の版>-<ビルド番号>`。例: `23.1.5-1` は LLVM 23.1.5 の 1 回目のビルド。
タグ `v23.1.5-1` を push すると全ホストをビルドし
（.github/workflows/release.yml）、各アーカイブと `.sha256` をリリースに
載せます。

## 手元でのビルド

```sh
scripts/build.sh 23.1.5 23.1.5-1 x86_64-unknown-linux-gnu
```

cmake、ninja、C++ コンパイラ（Windows は MSVC）、curl、tar（Windows は 7z）が
要ります。並列数は `JOBS` と `LINK_JOBS` で絞れます。clang のリンクは
1 ジョブあたり数 GB のメモリを使います。

## ライセンス

このリポジトリのビルドスクリプトは MIT です。アーカイブに入る LLVM は
Apache License 2.0 with LLVM Exceptions です（各アーカイブの LICENSE.TXT）。
