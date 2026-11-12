#!/usr/bin/env bash
# Build GDB for RISC-V bare-metal targets and install it into a staged
# package: <prefix>/bin/riscv32-unknown-elf-gdb (the Arduino IDE's debugger
# runs it; platform.txt debug.toolchain.prefix). GMP, MPFR and Expat are built
# from source and linked in statically, so the binary needs only the host's
# own C library. No Python, TUI, NLS or debuginfod.
#
#   scripts/build-gdb.sh <prefix> [host triple]
#
# Only bin/riscv32-unknown-elf-gdb, share/gdb and licenses/ are written there.
# On Windows it runs in an MSYS2 MinGW shell (release.yml) with the host
# triple x86_64-w64-mingw32.
#
# Environment: WORK (scratch, default work/), JOBS.
set -euo pipefail

GDB_VERSION=18.1
GMP_VERSION=6.3.0
MPFR_VERSION=4.2.2
EXPAT_VERSION=2.7.3
SOURCES=(
  "https://ftp.gnu.org/gnu/gdb/gdb-$GDB_VERSION.tar.xz"
  "https://ftp.gnu.org/gnu/gmp/gmp-$GMP_VERSION.tar.xz"
  "https://ftp.gnu.org/gnu/mpfr/mpfr-$MPFR_VERSION.tar.xz"
  "https://github.com/libexpat/libexpat/releases/download/R_${EXPAT_VERSION//./_}/expat-$EXPAT_VERSION.tar.xz"
)
# --sources: the source archives this builds, one URL a line (release.yml
# publishes them with the binaries, as the GPL and LGPL ask).
if [ "${1:-}" = "--sources" ]; then
  printf '%s\n' "${SOURCES[@]}"
  exit 0
fi

PREFIX=${1:?install prefix (the staged package directory)}
HOST=${2:-}
mkdir -p "$PREFIX"
PREFIX=$(cd "$PREFIX" && pwd)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$ROOT/work}/gdb
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}

mkdir -p "$WORK"
cd "$WORK"
for url in "${SOURCES[@]}"; do
  file=${url##*/}
  [ -d "${file%.tar.xz}" ] && continue
  curl -fsSL -o "$file" "$url"
  tar -xJf "$file"
  rm -f "$file"
done

host_args=()
[ -n "$HOST" ] && host_args=(--host="$HOST" --build="$HOST")
DEPS=$WORK/deps
rm -rf "$DEPS" build-gmp build-mpfr build-expat build-gdb
mkdir -p build-gmp build-mpfr build-expat build-gdb

# GMP's C code only (--disable-assembly): nothing in it is hot for GDB, and
# it is the same code on every host. Its configure still wants an m4 (M4= to
# name one). gnu17: GMP 6.3.0's configure tests are not valid C23, GCC 15's
# default.
( cd build-gmp && "../gmp-$GMP_VERSION/configure" "${host_args[@]}" --prefix="$DEPS" \
    --disable-shared --enable-static --disable-assembly CFLAGS="-O2 -std=gnu17" \
  && make -j "$JOBS" && make install )
( cd build-mpfr && "../mpfr-$MPFR_VERSION/configure" "${host_args[@]}" --prefix="$DEPS" \
    --with-gmp="$DEPS" --disable-shared --enable-static \
  && make -j "$JOBS" && make install )
( cd build-expat && "../expat-$EXPAT_VERSION/configure" "${host_args[@]}" --prefix="$DEPS" \
    --disable-shared --enable-static --without-docbook --without-examples --without-tests \
  && make -j "$JOBS" && make install )

extra=()
case "$(uname -s)" in
  Darwin) ;;
  # MinGW: everything static, winpthread included - no DLL beside the exe.
  MINGW*|MSYS*) extra+=(--with-static-standard-libraries LDFLAGS=-static) ;;
  # libstdc++ and libgcc go in; glibc stays dynamic.
  *) extra+=(--with-static-standard-libraries) ;;
esac
# Installed apart first: <prefix> is a package that already holds other
# things under lib/ and include/.
GDB_INST=$WORK/inst
rm -rf "$GDB_INST"
( cd build-gdb && "../gdb-$GDB_VERSION/configure" "${host_args[@]}" \
    --target=riscv32-unknown-elf --prefix="$GDB_INST" \
    --disable-nls --disable-werror --disable-sim --disable-gprofng \
    --disable-binutils --disable-ld --disable-gas --disable-gold --disable-gprof \
    --disable-tui --disable-source-highlight \
    --without-python --without-guile --without-debuginfod --without-babeltrace \
    --without-lzma --without-zstd --without-xxhash --without-intel-pt \
    --with-gmp="$DEPS" --with-mpfr="$DEPS" --with-expat --with-libexpat-prefix="$DEPS" \
    "${extra[@]}" \
  && make -j "$JOBS" all-gdb && make install-strip-gdb )
# Only the program and its data directory: no manuals, and not the
# gdb-add-index / gstack shell scripts (they drive a native gdb).
mkdir -p "$PREFIX/bin" "$PREFIX/share"
cp "$GDB_INST"/bin/riscv32-unknown-elf-gdb* "$PREFIX/bin/"
rm -f "$PREFIX"/bin/riscv32-unknown-elf-gdb-add-index*
rm -rf "$PREFIX/share/gdb"
cp -R "$GDB_INST/share/gdb" "$PREFIX/share/gdb"
# Their licenses: GDB GPL-3.0-or-later, GMP and MPFR LGPL-3.0-or-later,
# Expat MIT. The release carries the exact source archives (release.yml).
mkdir -p "$PREFIX/licenses/gdb" "$PREFIX/licenses/gmp" "$PREFIX/licenses/mpfr" "$PREFIX/licenses/expat"
cp "gdb-$GDB_VERSION/COPYING3" "$PREFIX/licenses/gdb/COPYING3"
cp "gmp-$GMP_VERSION/COPYING.LESSERv3" "gmp-$GMP_VERSION/COPYINGv3" "$PREFIX/licenses/gmp/"
cp "mpfr-$MPFR_VERSION/COPYING.LESSER" "mpfr-$MPFR_VERSION/COPYING" "$PREFIX/licenses/mpfr/"
cp "expat-$EXPAT_VERSION/COPYING" "$PREFIX/licenses/expat/COPYING"
echo "gdb $GDB_VERSION (GMP $GMP_VERSION, MPFR $MPFR_VERSION, Expat $EXPAT_VERSION)" > "$PREFIX/licenses/gdb/VERSION"
echo "gdb in $PREFIX/bin"
