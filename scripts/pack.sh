#!/usr/bin/env bash
# Check and pack a staged package: clang (build.sh), the target libraries
# (build-runtimes.sh's tree, given as an archive) and GDB (build-gdb.sh).
#
#   scripts/pack.sh <package version> <target triple> <runtimes.tar.gz>
#
# Out: dist/ch32rv-toolchain-<package version>-<target>.tar.gz (.zip on Windows)
#      and <archive>.sha256.
set -euo pipefail

PKG_VERSION=${1:?package version, e.g. 23.1.5-1}
TARGET=${2:?host target triple}
RUNTIMES_ARCHIVE=${3:?runtimes archive (lib/clang-runtimes, include/c++, licenses/)}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$ROOT/work}
DIST=$ROOT/dist
NAME=ch32rv-toolchain
PKG=$NAME-$PKG_VERSION-$TARGET
STAGE=$WORK/stage/$NAME
mkdir -p "$DIST"

ext=""
case "$TARGET" in *windows*) ext=".exe" ;; esac

# 1. The target libraries, the same tree on every host.
rm -rf "$STAGE/lib/clang-runtimes" "$STAGE/include/c++" "$STAGE/licenses/picolibc"
tar -xzf "$RUNTIMES_ARCHIVE" -C "$STAGE"
for f in "lib/clang-runtimes/multilib.yaml" "include/c++/v1/__config_site" \
         "bin/riscv32-unknown-elf-gdb$ext" "licenses/picolibc/VERSION" "licenses/gdb/VERSION"; do
  [ -e "$STAGE/$f" ] || { echo "missing in the stage: $f" >&2; exit 1; }
done
{
  cat "$STAGE/licenses/picolibc/VERSION"
  echo "compiler-rt builtins, libc++ and libc++abi from the same LLVM"
  cat "$STAGE/licenses/gdb/VERSION"
} >> "$STAGE/VERSION.txt"

# 2. Smoke test, for every variant multilib.yaml has: C and C++ against
#    picolibc, libc++ and compiler-rt, linked by lld; and GDB starts.
cat > "$WORK/smoke.cpp" <<'EOF'
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <functional>
#include <new>
static std::function<float(float)> f;
void *operator new(std::size_t n) { return std::malloc(n ? n : 1); }
void operator delete(void *p) noexcept { std::free(p); }
void operator delete(void *p, std::size_t) noexcept { std::free(p); }
int main() {
  f = [](float x) { return std::sqrt(x) * 2.0f; };
  long long q = std::strtoll("123456789012", nullptr, 10) / 7;
  std::printf("%g %lld\n", (double)f(2.0f), q);
  return 0;
}
extern "C" void _start(void) { std::exit(main()); }
EOF
# What picolibc leaves to the program: stdout / stderr (libc++'s abort
# message), _exit() and the heap's sbrk().
cat > "$WORK/smoke-glue.c" <<'EOF'
#include <stdio.h>
#include <stddef.h>
static int put(char c, FILE *f) { (void)f; return (unsigned char)c; }
static FILE out = FDEV_SETUP_STREAM(put, NULL, NULL, _FDEV_SETUP_WRITE);
FILE *const stdout = &out;
FILE *const stderr = &out;
void _exit(int code) { (void)code; for (;;) { } }
void *sbrk(ptrdiff_t n) {
  static char heap[4096];
  static size_t used;
  if (n < 0 || used + (size_t)n > sizeof heap) return (void *)-1;
  void *p = heap + used;
  used += (size_t)n;
  return p;
}
EOF
for m in "rv32ec_zicsr_xwchc ilp32e" "rv32ec_zmmul_zicsr_xwchc ilp32e" "rv32imc_zicsr_xwchc ilp32" \
         "rv32imac_zicsr ilp32" "rv32imac_zicsr_xwchc ilp32" "rv32imafc_zicsr_xwchc ilp32f"; do
  set -- $m
  "$STAGE/bin/clang++$ext" --target=riscv32-unknown-elf -march="$1" -mabi="$2" -Oz \
    -fno-exceptions -fno-rtti -nostartfiles -fuse-ld=lld \
    -x c++ "$WORK/smoke.cpp" -x c "$WORK/smoke-glue.c" -o "$WORK/smoke-$1.elf" \
    -nostdlib -lc++ -lc -lclang_rt.builtins
  "$STAGE/bin/llvm-size$ext" "$WORK/smoke-$1.elf" | tail -n 1
done
"$STAGE/bin/riscv32-unknown-elf-gdb$ext" -batch -nx -ex "info line main" "$WORK/smoke-rv32imac_zicsr.elf"

# 3. Pack.
cd "$WORK/stage"
case "$TARGET" in
  *windows*)
    archive=$DIST/$PKG.zip
    rm -f "$archive"
    7z a -tzip -mx=9 "$archive" "$NAME" > /dev/null ;;
  *)
    archive=$DIST/$PKG.tar.gz
    tar -czf "$archive" "$NAME" ;;
esac
cd "$DIST"
if command -v sha256sum > /dev/null; then
  sha256sum "$(basename "$archive")" > "$(basename "$archive").sha256"
else
  shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256"
fi
ls -l "$archive"
