#!/usr/bin/env bash
# Build the target libraries for the CH32 cores with a built clang, into its
# lib/clang-runtimes: compiler-rt's builtins, picolibc and libc++ (with
# libc++abi), one set per variant in multilib.yaml, and the headers once. clang's BareMetal driver
# reads lib/clang-runtimes/multilib.yaml next to its bin/ by itself and picks
# the variant from -march / -mabi, so a build passes no sysroot or paths.
#
#   scripts/build-runtimes.sh <clang install dir> <llvm source dir>
#
# The libraries are the same for every host; release.yml builds them once and
# puts the same tree in every host's archive.
#
# Environment: WORK (scratch, default work/), PICOLIBC_VERSION, JOBS.
set -euo pipefail

INSTALL=$(cd "${1:?clang install dir (with bin/clang)}" && pwd)
SRC=$(cd "${2:?llvm-project source dir}" && pwd)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$ROOT/work}
PICOLIBC_VERSION=${PICOLIBC_VERSION:-1.8.12}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
BIN=$INSTALL/bin
RUNTIMES=$INSTALL/lib/clang-runtimes
TRIPLE=riscv32-unknown-elf

# <dir> <march> <mabi>: the multilib's directory under clang-runtimes and the
# flags it is built with. One per base ISA and float ABI the CH32 cores have,
# with WCH's XW compressed instructions (Xwchc): every QingKe core but the
# V3A has them, so CH32V103 alone gets a plain rv32imac. XW shortens byte and
# halfword loads and stores: memcpy / strcmp and the like lose 9-18%, strtol /
# strtod 1-3%, float and math routines nothing. A board's other extras
# (zmmul, zba/zbb/zbs) map onto these in multilib.yaml.
VARIANTS=(
  "rv32ec_xwchc/ilp32e rv32ec_zicsr_xwchc ilp32e"
  "rv32imc_xwchc/ilp32 rv32imc_zicsr_xwchc ilp32"
  "rv32imac/ilp32 rv32imac_zicsr ilp32"
  "rv32imac_xwchc/ilp32 rv32imac_zicsr_xwchc ilp32"
  "rv32imafc_xwchc/ilp32f rv32imafc_zicsr_xwchc ilp32f"
)
# Size first, as the sketches are built.
OPT="-Oz -ffunction-sections -fdata-sections"

mkdir -p "$WORK" "$RUNTIMES"

# picolibc: the release's own source tarball.
PICO_SRC=$WORK/picolibc-$PICOLIBC_VERSION
if [ ! -d "$PICO_SRC" ]; then
  curl -fsSL -o "$WORK/picolibc.tar.xz" \
    "https://github.com/picolibc/picolibc/releases/download/$PICOLIBC_VERSION/picolibc-$PICOLIBC_VERSION.tar.xz"
  tar -xJf "$WORK/picolibc.tar.xz" -C "$WORK"
  rm -f "$WORK/picolibc.tar.xz"
fi

cp "$ROOT/scripts/multilib.yaml" "$RUNTIMES/multilib.yaml"

for v in "${VARIANTS[@]}"; do
  read -r dir march mabi <<<"$v"
  tag=${dir//\//-}
  out=$RUNTIMES/$dir
  flags="--target=$TRIPLE -march=$march -mabi=$mabi $OPT"
  mkdir -p "$out/lib" "$out/include"

  # 1. compiler-rt's builtins: the runtime routines (soft float, 64-bit
  #    division, __riscv_save_N for -msave-restore) that libgcc gave.
  b=$WORK/rt-$tag
  rm -rf "$b"
  cmake -G Ninja -S "$SRC/runtimes" -B "$b" \
    -DLLVM_ENABLE_RUNTIMES=compiler-rt \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Generic \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_C_COMPILER="$BIN/clang" -DCMAKE_CXX_COMPILER="$BIN/clang++" \
    -DCMAKE_ASM_COMPILER="$BIN/clang" \
    -DCMAKE_AR="$BIN/llvm-ar" -DCMAKE_RANLIB="$BIN/llvm-ranlib" -DCMAKE_NM="$BIN/llvm-nm" \
    -DCMAKE_C_COMPILER_TARGET=$TRIPLE -DCMAKE_CXX_COMPILER_TARGET=$TRIPLE \
    -DCMAKE_ASM_COMPILER_TARGET=$TRIPLE \
    -DCMAKE_C_FLAGS="$flags" -DCMAKE_CXX_FLAGS="$flags" -DCMAKE_ASM_FLAGS="$flags" \
    -DCMAKE_C_FLAGS_RELEASE= -DCMAKE_CXX_FLAGS_RELEASE= -DCMAKE_ASM_FLAGS_RELEASE= \
    -DLLVM_DEFAULT_TARGET_TRIPLE=$TRIPLE \
    -DCOMPILER_RT_BAREMETAL_BUILD=ON \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    -DCOMPILER_RT_BUILD_BUILTINS=ON \
    -DCOMPILER_RT_BUILD_CRT=OFF \
    -DCOMPILER_RT_BUILD_LIBFUZZER=OFF -DCOMPILER_RT_BUILD_MEMPROF=OFF \
    -DCOMPILER_RT_BUILD_PROFILE=OFF -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
    -DCOMPILER_RT_BUILD_XRAY=OFF -DCOMPILER_RT_BUILD_ORC=OFF \
    -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF \
    -DCOMPILER_RT_BUILTINS_ENABLE_PIC=OFF \
    -DCOMPILER_RT_EXCLUDE_ATOMIC_BUILTIN=ON
  ninja -C "$b" -j "$JOBS" builtins
  cp "$(find "$b" -name 'libclang_rt.builtins*.a' | head -n 1)" "$out/lib/libclang_rt.builtins.a"

  # 2. picolibc.
  b=$WORK/pico-$tag
  rm -rf "$b"
  cross=$WORK/cross-$tag.txt
  cat >"$cross" <<EOF
[binaries]
c = ['$BIN/clang', '--target=$TRIPLE', '-march=$march', '-mabi=$mabi', '-nostdlib']
c_ld = 'lld'
ar = '$BIN/llvm-ar'
nm = '$BIN/llvm-nm'
strip = '$BIN/llvm-strip'

[host_machine]
system = 'none'
cpu_family = 'riscv32'
cpu = 'riscv'
endian = 'little'

[built-in options]
c_args = [$(printf "'%s', " $OPT)]

[properties]
skip_sanity_check = true
EOF
  #    No thread-local storage: errno and the rest are plain variables (the
  #    cores run one thread and set no thread pointer).
  #    printf / scanf: the integer-only variants are the default, so a
  #    program that never formats a float links no floating point; the
  #    float and double ones (__f_vfprintf, __d_vfprintf, ...) are there to
  #    be chosen.
  meson setup "$b" "$PICO_SRC" --cross-file "$cross" \
    --prefix="$out" --includedir=include --libdir=lib \
    --buildtype=plain -Dmultilib=false -Dtests=false \
    -Dpicocrt=false -Dsemihost=false -Dspecsdir=none \
    -Dlibgccdir= -Dsingle-thread=true -Dthread-local-storage=false \
    -Dformat-default=integer
  ninja -C "$b" -j "$JOBS" install

  # 3. libc++ and libc++abi over that picolibc: no exceptions, no RTTI, no
  #    threads, no locale or wide characters - as the sketches are compiled
  #    (-fno-exceptions -fno-rtti). new / delete stay with the program
  #    (the Arduino core defines them over malloc).
  b=$WORK/cxx-$tag
  rm -rf "$b"
  cmake -G Ninja -S "$SRC/runtimes" -B "$b" \
    -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$out" \
    -DCMAKE_SYSTEM_NAME=Generic \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_C_COMPILER="$BIN/clang" -DCMAKE_CXX_COMPILER="$BIN/clang++" \
    -DCMAKE_ASM_COMPILER="$BIN/clang" \
    -DCMAKE_AR="$BIN/llvm-ar" -DCMAKE_RANLIB="$BIN/llvm-ranlib" -DCMAKE_NM="$BIN/llvm-nm" \
    -DCMAKE_C_COMPILER_TARGET=$TRIPLE -DCMAKE_CXX_COMPILER_TARGET=$TRIPLE \
    -DCMAKE_ASM_COMPILER_TARGET=$TRIPLE \
    -DCMAKE_C_FLAGS="$flags" -DCMAKE_CXX_FLAGS="$flags" -DCMAKE_ASM_FLAGS="$flags" \
    -DCMAKE_C_FLAGS_RELEASE= -DCMAKE_CXX_FLAGS_RELEASE= -DCMAKE_ASM_FLAGS_RELEASE= \
    -DLLVM_DEFAULT_TARGET_TRIPLE=$TRIPLE \
    -DLIBCXX_ENABLE_SHARED=OFF -DLIBCXX_ENABLE_STATIC=ON \
    -DLIBCXX_SHARED_OUTPUT_NAME=c++-shared \
    -DLIBCXX_ENABLE_EXCEPTIONS=OFF -DLIBCXX_ENABLE_RTTI=OFF \
    -DLIBCXX_ENABLE_THREADS=OFF -DLIBCXX_ENABLE_MONOTONIC_CLOCK=OFF \
    -DLIBCXX_ENABLE_FILESYSTEM=OFF -DLIBCXX_ENABLE_RANDOM_DEVICE=OFF \
    -DLIBCXX_ENABLE_LOCALIZATION=OFF -DLIBCXX_ENABLE_WIDE_CHARACTERS=OFF \
    -DLIBCXX_ENABLE_TIME_ZONE_DATABASE=OFF \
    -DLIBCXX_ENABLE_NEW_DELETE_DEFINITIONS=OFF \
    -DLIBCXX_INCLUDE_BENCHMARKS=OFF -DLIBCXX_INCLUDE_TESTS=OFF \
    -DLIBCXX_USE_COMPILER_RT=ON \
    -DLIBCXX_CXX_ABI=libcxxabi \
    -DLIBCXX_INSTALL_INCLUDE_TARGET_DIR="$out/include/c++/v1" \
    -DLIBCXX_INSTALL_LIBRARY_DIR="$out/lib" \
    -DLIBCXXABI_ENABLE_SHARED=OFF -DLIBCXXABI_ENABLE_STATIC=ON \
    -DLIBCXXABI_SHARED_OUTPUT_NAME=c++abi-shared \
    -DLIBCXXABI_BAREMETAL=ON \
    -DLIBCXXABI_ENABLE_EXCEPTIONS=OFF -DLIBCXXABI_ENABLE_THREADS=OFF \
    -DLIBCXXABI_ENABLE_NEW_DELETE_DEFINITIONS=OFF \
    -DLIBCXXABI_USE_COMPILER_RT=ON -DLIBCXXABI_USE_LLVM_UNWINDER=OFF \
    -DLIBCXXABI_INCLUDE_TESTS=OFF \
    -DLIBCXXABI_INSTALL_LIBRARY_DIR="$out/lib"
  ninja -C "$b" -j "$JOBS" install-cxx install-cxxabi install-cxx-headers

  # Only what a sketch links: picolibc's libm.a is an empty stub kept so a
  # library's -lm still resolves; its linker scripts, libnosys, libg and
  # libdummyhost and libc++'s experimental part and module list are unused.
  ( cd "$out/lib" && rm -f libc++experimental.a libc++.modules.json libdummyhost.a \
      libg.a libnosys.a picolibc*.ld picolibcpp*.ld )
done

# The headers come out the same for every variant (checked here): one copy.
# picolibc's go to the "common" multilib, which matches every target
# (multilib.yaml), and libc++'s to include/c++/v1 next to bin/, where the
# driver looks for them before the libc's.
first=${VARIANTS[0]%% *}
rm -rf "$RUNTIMES/common" "$INSTALL/include/c++"
mkdir -p "$RUNTIMES/common" "$INSTALL/include"
for v in "${VARIANTS[@]}"; do
  dir=${v%% *}
  diff -r "$RUNTIMES/$first/include" "$RUNTIMES/$dir/include" >/dev/null || {
    echo "$dir: headers differ from $first's" >&2; exit 1; }
done
mv "$RUNTIMES/$first/include/c++" "$INSTALL/include/c++"
mv "$RUNTIMES/$first/include" "$RUNTIMES/common/include"
for v in "${VARIANTS[@]}"; do
  rm -rf "$RUNTIMES/${v%% *}/include"
done

# picolibc's license (BSD-style, the file lists each part's); compiler-rt
# and libc++ are LLVM's, under its LICENSE.TXT.
mkdir -p "$INSTALL/licenses/picolibc"
cp "$PICO_SRC/COPYING.picolibc" "$INSTALL/licenses/picolibc/COPYING.picolibc"
echo "picolibc $PICOLIBC_VERSION" > "$INSTALL/licenses/picolibc/VERSION"

echo "runtimes in $RUNTIMES"
