#!/usr/bin/env bash
# Build a RISC-V-only clang + lld (+ the binutils-like LLVM tools an Arduino
# build calls) and stage it in work/stage/ch32rv-clang. The target libraries
# (build-runtimes.sh) and GDB (build-gdb.sh) go into the same directory, and
# pack.sh checks and packs it.
#
#   scripts/build.sh <llvm version> <package version> <target triple>
#   scripts/build.sh 23.1.5 23.1.5-1 x86_64-unknown-linux-gnu
#
# Environment: JOBS (parallel compile jobs, default: all CPUs), LINK_JOBS
# (parallel link jobs, default 2), CCACHE=1 to compile through ccache,
# CONFIGURE_ONLY=1 to stop after cmake (a quick check of the source and flags).
set -euo pipefail

LLVM_VERSION=${1:?llvm version, e.g. 23.1.5}
PKG_VERSION=${2:?package version, e.g. 23.1.5-1}
TARGET=${3:?host target triple, e.g. x86_64-unknown-linux-gnu}

case "$LLVM_VERSION" in
  *[!0-9.]*|"") echo "llvm version must look like 23.1.5: got '$LLVM_VERSION'" >&2; exit 2 ;;
esac

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$ROOT/work}
DIST=$ROOT/dist
NAME=ch32rv-clang
PKG=$NAME-$PKG_VERSION-$TARGET
SRC=$WORK/llvm-project-$LLVM_VERSION.src
BUILD=$WORK/build-$TARGET
STAGE=$WORK/stage/$NAME

mkdir -p "$WORK" "$DIST"

case "$TARGET" in
  *windows*) WINDOWS=1 ;;
  *) WINDOWS=0 ;;
esac
case "$TARGET" in
  *darwin*) DARWIN=1 ;;
  *) DARWIN=0 ;;
esac

# 1. Source: the release's own source tarball.
if [ ! -d "$SRC" ]; then
  url=https://github.com/llvm/llvm-project/releases/download/llvmorg-$LLVM_VERSION/llvm-project-$LLVM_VERSION.src.tar.xz
  curl -fsSL -o "$WORK/src.tar.xz" "$url"
  # The test trees and lldb are not built (LLVM_INCLUDE_TESTS=OFF) and hold
  # symlinks that Git for Windows' tar cannot create (it gives up on the
  # archive); leave them out on every host. llvm/utils/mlgo-utils is
  # configured, so only its three symlinked scripts go.
  top=llvm-project-$LLVM_VERSION.src
  mlgo=$top/llvm/utils/mlgo-utils
  tar -xJf "$WORK/src.tar.xz" -C "$WORK" \
    --exclude="$top/llvm/test" --exclude="$top/clang/test" --exclude="$top/lld/test" \
    --exclude="$top/lldb" --exclude="$mlgo/combine_training_corpus.py" \
    --exclude="$mlgo/extract_ir.py" --exclude="$mlgo/make_corpus.py"
  rm -f "$WORK/src.tar.xz"
  # Our changes to LLVM (patches/, applied in order).
  for p in "$ROOT"/patches/*.patch; do
    [ -e "$p" ] || continue
    patch -d "$SRC" -p1 --forward < "$p"
  done
fi

# 2. Configure. Only the RISCV backend; clang and lld; no tests, examples,
#    docs or bindings; everything static where the host allows it, so the
#    archive runs on a bare machine. On Linux and macOS the tools are one
#    multicall binary (llvm-driver) with symlinks; on Windows, where symlinks
#    do not survive a zip and the Arduino IDE's unpacking, each tool is its
#    own executable.
TOOLS="llvm-ar;llvm-ranlib;llvm-objcopy;llvm-objdump;llvm-nm;llvm-size;llvm-readelf;llvm-strip;llvm-symbolizer"
COMPONENTS="clang;clang-resource-headers;lld;$TOOLS"

cmake_args=(
  -G Ninja
  -S "$SRC/llvm"
  -B "$BUILD"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$STAGE"
  -DLLVM_ENABLE_PROJECTS="clang;lld"
  -DLLVM_TARGETS_TO_BUILD=RISCV
  -DLLVM_DEFAULT_TARGET_TRIPLE=riscv32-unknown-elf
  -DLLVM_DISTRIBUTION_COMPONENTS="$COMPONENTS"
  -DLLVM_PARALLEL_LINK_JOBS="${LINK_JOBS:-2}"
  -DLLVM_INCLUDE_TESTS=OFF
  -DLLVM_INCLUDE_EXAMPLES=OFF
  -DLLVM_INCLUDE_BENCHMARKS=OFF
  -DLLVM_INCLUDE_DOCS=OFF
  -DLLVM_ENABLE_BINDINGS=OFF
  -DLLVM_ENABLE_LIBXML2=OFF
  -DLLVM_ENABLE_ZLIB=OFF
  -DLLVM_ENABLE_ZSTD=OFF
  -DLLVM_ENABLE_TERMINFO=OFF
  -DLLVM_ENABLE_LIBEDIT=OFF
  -DLLVM_ENABLE_LIBPFM=OFF
  -DLLVM_ENABLE_ASSERTIONS=OFF
  -DCLANG_ENABLE_STATIC_ANALYZER=OFF
  -DCLANG_PLUGIN_SUPPORT=OFF
  -DLLVM_BUILD_LLVM_DYLIB=OFF
  -DLLVM_LINK_LLVM_DYLIB=OFF
)
if [ "$WINDOWS" = 0 ]; then
  cmake_args+=(-DLLVM_TOOL_LLVM_DRIVER_BUILD=ON)
fi
if [ "$WINDOWS" = 1 ]; then
  # MSVC, with its runtime linked in: no VC++ redistributable needed.
  cmake_args+=(-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl)
elif [ "$DARWIN" = 1 ]; then
  cmake_args+=(-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0)
else
  # glibc stays dynamic (the runner's, Ubuntu 22.04: 2.35); libstdc++ and libgcc go in.
  cmake_args+=(-DCMAKE_EXE_LINKER_FLAGS="-static-libstdc++ -static-libgcc")
fi
if [ "${CCACHE:-0}" = 1 ]; then
  cmake_args+=(-DLLVM_CCACHE_BUILD=ON)
fi

cmake "${cmake_args[@]}"
[ "${CONFIGURE_ONLY:-0}" = 1 ] && exit 0

# 3. Build and install only the distribution, stripped.
rm -rf "$STAGE"
ninja -C "$BUILD" ${JOBS:+-j "$JOBS"} install-distribution-stripped

# 4. Licenses and a version note in the archive.
cp "$SRC/llvm/LICENSE.TXT" "$STAGE/LICENSE.TXT"
{
  echo "$NAME $PKG_VERSION"
  echo "LLVM $LLVM_VERSION (https://github.com/llvm/llvm-project/releases/tag/llvmorg-$LLVM_VERSION)"
  echo "targets: RISCV only; projects: clang, lld"
  echo "host: $TARGET"
} > "$STAGE/VERSION.txt"
cp "$ROOT/README.md" "$STAGE/README.md"

# 5. Smoke test: compile and link a bare rv32 program, the WCH XW extension included.
ext=""; [ "$WINDOWS" = 1 ] && ext=".exe"
cat > "$WORK/smoke.c" <<'EOF'
unsigned char b[8];
int f(unsigned char *p) { return p[3] + p[7]; }
void _start(void) { b[5] = (unsigned char)f(b); for (;;) { } }
EOF
# (lld's default layout: -Ttext=0 would put .text under its 0x10000 image base, which it refuses.)
"$STAGE/bin/clang$ext" --target=riscv32-unknown-elf -march=rv32ec_zicsr_xwchc -mabi=ilp32e -Oz \
  -nostdlib -fuse-ld=lld "$WORK/smoke.c" -o "$WORK/smoke.elf"
"$STAGE/bin/llvm-size$ext" "$WORK/smoke.elf"
