#!/usr/bin/env bash
# Publish a release from the packed archives in <dist>: add the sources of
# GDB and its libraries (GDB is GPL, GMP and MPFR LGPL: their exact sources go
# with the binaries), then create the GitHub release v<package version>, or
# upload into it when it exists already.
#
#   scripts/publish.sh <package version> <dist dir>     (GH_TOKEN, GITHUB_REPOSITORY)
set -euo pipefail

PKG_VERSION=${1:?package version, e.g. 23.1.5-2}
DIST=${2:?directory with the archives}
LLVM_VERSION=${PKG_VERSION%-*}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO=${GITHUB_REPOSITORY:?owner/name}

"$ROOT/scripts/build-gdb.sh" --sources | while read -r url; do
  curl -fsSL -o "$DIST/${url##*/}" "$url"
done
files=()
for f in "$DIST"/*; do
  [ -f "$f" ] && files+=("$f")
done
ls -l "${files[@]}"
tag="v$PKG_VERSION"
gh release create "$tag" "${files[@]}" --repo "$REPO" \
  --title "ch32rv-toolchain $PKG_VERSION (LLVM $LLVM_VERSION)" \
  --notes "RISC-V-only clang + lld from LLVM $LLVM_VERSION with picolibc, compiler-rt, libc++ and GDB, for the CH32 Arduino core. See README. The gdb, gmp, mpfr and expat archives are the sources of the GDB in the packages." \
  || gh release upload "$tag" "${files[@]}" --repo "$REPO" --clobber
