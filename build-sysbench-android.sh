#!/usr/bin/env bash
set -euo pipefail

JOBS="${JOBS:-$(nproc)}"
OUT_DIR="${OUT_DIR:-/out}"
SRC_DIR="${SRC_DIR:-/work/sysbench}"
NDK_DIR="${ANDROID_NDK_HOME:-/opt/android-ndk-r10e}"
TOOLCHAIN_ROOT="${TOOLCHAIN_ROOT:-/work/toolchains}"
BUILD_ROOT="${BUILD_ROOT:-/work/build}"

if [[ ! -x "${NDK_DIR}/build/tools/make-standalone-toolchain.sh" ]]; then
  echo "NDK toolchain helper not found at ${NDK_DIR}" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}" "${TOOLCHAIN_ROOT}" "${BUILD_ROOT}"

cd "${SRC_DIR}"

# Concurrency Kit's custom configure expects CC to be an executable path.
# Sysbench's autoconf may set CC to "<compiler> -std=gnu11", which makes CK
# fall back to host gcc. Strip any appended flags in CK's Makefile recipe.
sed -i 's|CC="$(CC)"|CC="$(firstword $(CC))"|' third_party/concurrency_kit/Makefile.am

# CK's configure script tries to execute a probe binary, which fails for
# cross-compilation. Force a gcc-like compiler classification instead.
sed -i '/^\$CC -o \.1 \.1\.c$/,/^fi$/c\
$CC -o .1 .1.c 2>/dev/null || true\
COMPILER="${COMPILER:-gcc}"\
r=0\
rm -f .1.c .1\
echo "success [$CC]"' third_party/concurrency_kit/ck/configure

# CK's configure --use-cc-builtins adds -DCK_CC_BUILTINS to CFLAGS, but
# ck_pr.h guards the platform-specific (ldrex/strex) header with
# CK_USE_CC_BUILTINS — a different macro. Fix the guard to match.
sed -i 's/CK_USE_CC_BUILTINS/CK_CC_BUILTINS/g' third_party/concurrency_kit/ck/include/ck_pr.h

# Out-of-tree builds pass absolute paths to the .lua -> .lua.h rule. Ensure the
# generated C symbol replaces both dots and path separators.
sed -i "s|sed 's/\\\./_/g'|sed 's#[./]#_#g'|" src/lua/internal/Makefile.am
# Derive symbol name from filename only so sb_lua.c sees canonical names like
# sysbench_lua, sysbench_rand_lua, etc.
sed -i 's|echo \$< |basename \$< |' src/lua/internal/Makefile.am

# CK configure detects the x86_64 build host and prepends -m64 to LDFLAGS
# via: LDFLAGS="-m64 $LDFLAGS". This breaks ARM cross-linking. Strip it.
sed -i 's/LDFLAGS="-m64 /LDFLAGS="/g' third_party/concurrency_kit/ck/configure
# CK's Makefile.in builds libck.so AND libck.a. Building libck.so fails when
# -static is in LDFLAGS (contradicts -shared -fPIC). Since sysbench only needs
# the static archive, skip the shared library target entirely.
sed -i 's/^all: \$(ALL_LIBS)$/all: libck.a/' third_party/concurrency_kit/ck/src/Makefile.in
./autogen.sh

build_one() {
  local name="$1"
  local arch="$2"
  local platform="$3"
  local toolchain_name="$4"
  local host="$5"
  local cflags="$6"

  local tc_dir="${TOOLCHAIN_ROOT}/${name}"
  local bdir="${BUILD_ROOT}/${name}"
  local extra_cflags=""
  local ck_configure_flags="--profile=arm"

  if [[ "${host}" == "aarch64-linux-android" ]]; then
    ck_configure_flags="--profile=aarch64"
  elif [[ "${name}" == "armv5" ]]; then
    # armv5te lacks ldrex/strex (ARMv6+ only); combine arm profile (avoids host
    # x86_64 profile and its -m64 flag) with --use-cc-builtins (uses GCC
    # __atomic_* intrinsics instead of ARMv6+ inline assembly).
    ck_configure_flags="--profile=arm --use-cc-builtins"
    extra_cflags="-DCK_CC_BUILTINS"
  elif [[ "${name}" == "aarch64" ]]; then
    # Force CK to aarch64 so it does not auto-detect host x86_64 and inject
    # -m64 / -D__x86_64__ into target compilation.
    ck_configure_flags="--profile=aarch64"
  fi

  # CK static-only build avoids install-so/libck.so failures while sysbench
  # links against libck.a. CK's custom configure script uses --without-pic
  # (it ignores --disable-shared for compatibility).
  ck_configure_flags="${ck_configure_flags} --without-pic"

  echo "==> Building ${name}"

  if [[ ! -x "${tc_dir}/bin/${host}-gcc" ]]; then
    rm -rf "${tc_dir}"
    "${NDK_DIR}/build/tools/make-standalone-toolchain.sh" \
      --platform="${platform}" \
      --toolchain="${toolchain_name}" \
      --arch="${arch}" \
      --install-dir="${tc_dir}" >/dev/null
  fi

  rm -rf "${bdir}"
  mkdir -p "${bdir}"

  export PATH="${tc_dir}/bin:${PATH}"
  export CC="${tc_dir}/bin/${host}-gcc"
  export CXX="${tc_dir}/bin/${host}-g++"
  export AR="${tc_dir}/bin/${host}-ar"
  export RANLIB="${tc_dir}/bin/${host}-ranlib"
  export STRIP="${tc_dir}/bin/${host}-strip"

  # LuaJIT's host tools (buildvm/minilua) must match the target pointer size.
  # For 32-bit ARM targets, force a 32-bit HOST_CC.
  if [[ "${host}" == "arm-linux-androideabi" ]]; then
    export HOST_CC="gcc -m32"
  else
    export HOST_CC="gcc"
  fi

  pushd "${bdir}" >/dev/null

  if ! "${SRC_DIR}/configure" \
    --host="${host}" \
    --without-mysql \
    --without-pgsql \
    CK_CONFIGURE_FLAGS="${ck_configure_flags}" \
      CFLAGS="${cflags} ${extra_cflags} -Os -fdata-sections -ffunction-sections" \
    LDFLAGS="-static -Wl,--gc-sections"; then
    echo "configure failed for ${name}; tail of config.log:" >&2
    tail -n 120 config.log >&2 || true
    exit 1
  fi

  if [[ "${host}" == "aarch64-linux-android" ]]; then
    python3 - <<'PY'
from pathlib import Path
import re

path = Path("third_party/concurrency_kit/Makefile")
text = path.read_text()

# Prefer rewriting CK_CONFIGURE_FLAGS directly when the assignment is present.
text, assigned = re.subn(
    r'(?m)^CK_CONFIGURE_FLAGS\s*=.*$',
    'CK_CONFIGURE_FLAGS = --profile=aarch64 --without-pic',
    text,
    count=1,
)

# Fallback for Makefiles that inline ./configure without CK_CONFIGURE_FLAGS.
if assigned == 0 and "--profile=aarch64" not in text:
    text, inserted = re.subn(
        r'(?m)^(\s*\.\/configure)(\s*\\)$',
        r'\1 --profile=aarch64 --without-pic\2',
        text,
        count=1,
    )
else:
    inserted = 0

# If arm profile leaked in, rewrite it for aarch64.
text = text.replace("--profile=arm", "--profile=aarch64")
path.write_text(text)

if assigned or inserted:
    print("patched CK configure recipe with aarch64 profile")
PY
  fi

  # Build LuaJIT manually in the build tree, then replace the recursive
  # subdir Makefile with a trivial one so the top-level make does not recurse
  # into the broken wrapper recipe.
  local luajit_tmp_dir="${bdir}/third_party/luajit/tmp"
  rm -rf "${luajit_tmp_dir}"
  mkdir -p "${luajit_tmp_dir}"
  tar -C "${SRC_DIR}/third_party/luajit" -cf - luajit | tar -xf - -C "${luajit_tmp_dir}"
  chmod -R u+w "${luajit_tmp_dir}"
  make -C "${luajit_tmp_dir}/luajit/src" \
    HOST_CC="${HOST_CC}" \
    CROSS="${host}-" \
    TARGET_SYS=Other \
    TARGET_CFLAGS="${cflags}" \
    TARGET_LDFLAGS="-static -Wl,--gc-sections" \
    libluajit.a
  mkdir -p "${bdir}/third_party/luajit/lib" "${bdir}/third_party/luajit/inc"
  cp "${luajit_tmp_dir}/luajit/src/libluajit.a" "${bdir}/third_party/luajit/lib/libluajit-5.1.a"
  cp "${luajit_tmp_dir}/luajit/src/lua.h" "${luajit_tmp_dir}/luajit/src/lualib.h" "${luajit_tmp_dir}/luajit/src/lauxlib.h" "${luajit_tmp_dir}/luajit/src/luaconf.h" "${luajit_tmp_dir}/luajit/src/lua.hpp" "${luajit_tmp_dir}/luajit/src/luajit.h" "${bdir}/third_party/luajit/inc"
  cat > "${bdir}/third_party/luajit/Makefile" <<'EOF'
all:
	@true

install:
	@true

clean:
	@true
EOF

  make -j"${JOBS}"

  cp -f src/sysbench "${OUT_DIR}/sysbench-${name}"
  "${STRIP}" "${OUT_DIR}/sysbench-${name}" || true

  popd >/dev/null

  file "${OUT_DIR}/sysbench-${name}"
}

# armv5 (armeabi legacy)
build_one \
  "armv5" \
  "arm" \
  "android-16" \
  "arm-linux-androideabi-4.9" \
  "arm-linux-androideabi" \
  "-march=armv5te -mthumb -msoft-float"

# armv6
build_one \
  "armv6" \
  "arm" \
  "android-16" \
  "arm-linux-androideabi-4.9" \
  "arm-linux-androideabi" \
  "-march=armv6 -mfpu=vfp -mfloat-abi=softfp"

# armv7
build_one \
  "armv7" \
  "arm" \
  "android-16" \
  "arm-linux-androideabi-4.9" \
  "arm-linux-androideabi" \
  "-march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=softfp"

# aarch64
build_one \
  "aarch64" \
  "arm64" \
  "android-21" \
  "aarch64-linux-android-4.9" \
  "aarch64-linux-android" \
  "-march=armv8-a"

echo "\nArtifacts in ${OUT_DIR}:"
ls -lh "${OUT_DIR}"/sysbench-*
