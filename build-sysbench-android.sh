#!/usr/bin/env bash
set -euo pipefail

JOBS="${JOBS:-$(nproc)}"
OUT_DIR="${OUT_DIR:-/out}"
SRC_DIR="${SRC_DIR:-/work/sysbench}"
NDK_DIR="${ANDROID_NDK_HOME:-/opt/android-ndk-r10e}"
TOOLCHAIN_ROOT="${TOOLCHAIN_ROOT:-/work/toolchains}"
BUILD_ROOT="${BUILD_ROOT:-/work/build}"
# Comma-separated list of target names to build. Defaults to all targets.
BUILD_TARGETS="${BUILD_TARGETS:-}"

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
  local use_pie="${7:-yes}"
  local use_static="${8:-no}"

  local tc_dir="${TOOLCHAIN_ROOT}/${name}"
  local bdir="${BUILD_ROOT}/${name}"
  local extra_cflags=""
  local ck_configure_flags=""

  if [[ "${host}" == "aarch64-linux-android" ]]; then
    ck_configure_flags="--profile=aarch64"
  elif [[ "${host}" == "x86_64-linux-android" ]]; then
    ck_configure_flags="--profile=x86_64"
  elif [[ "${host}" == "i686-linux-android" ]]; then
    ck_configure_flags="--profile=x86"
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
  else
    ck_configure_flags="--profile=arm"
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
  # For 32-bit targets, force a 32-bit HOST_CC.
  if [[ "${host}" == "arm-linux-androideabi" || "${host}" == "i686-linux-android" ]]; then
    export HOST_CC="gcc -m32"
  else
    export HOST_CC="gcc"
  fi

  pushd "${bdir}" >/dev/null

  local pie_cflags="" pie_ldflags="" static_ldflags=""
  if [[ "${use_pie}" == "yes" ]]; then
    pie_cflags="-fPIE"
    pie_ldflags="-fPIE -pie"
  fi
  # static linking via -all-static requires post-Makefile patching; skip for now

  if ! "${SRC_DIR}/configure" \
    --host="${host}" \
    --without-mysql \
    --without-pgsql \
    CK_CONFIGURE_FLAGS="${ck_configure_flags}" \
      CFLAGS="${cflags} ${extra_cflags} -Os -fdata-sections -ffunction-sections ${pie_cflags}" \
    LDFLAGS="-Wl,--gc-sections ${pie_ldflags} ${static_ldflags}"; then
    echo "configure failed for ${name}; tail of config.log:" >&2
    tail -n 120 config.log >&2 || true
    exit 1
  fi

  # Android < 4.1: bionic does not initialize the PT_TLS segment for non-PIE
  # executables, so _Thread_local variables crash on first access. Strip the
  # keyword so TLS vars become regular globals (safe: old device is single-core).
  if [[ "${use_static}" == "yes" ]] && [[ -f config/config.h ]]; then
    sed -i 's/^#define TLS .*/#define TLS /' config/config.h
    echo "==> Patched config/config.h: TLS disabled for old-Android (${name})"
  fi

  local ck_tmp_dir="${bdir}/third_party/concurrency_kit/tmp"
  rm -rf "${ck_tmp_dir}"
  mkdir -p "${ck_tmp_dir}"
  tar -C "${SRC_DIR}/third_party/concurrency_kit" -cf - ck | tar -xf - -C "${ck_tmp_dir}"
  chmod -R u+w "${ck_tmp_dir}"
  (cd "${ck_tmp_dir}/ck" && \
    CC="${CC}" \
    CFLAGS="${cflags} ${extra_cflags} -Os -fdata-sections -ffunction-sections -D_GNU_SOURCE" \
    LDFLAGS="-static -Wl,--gc-sections" \
    ./configure ${ck_configure_flags} --prefix="${bdir}/third_party/concurrency_kit" && \
    make)
  mkdir -p "${bdir}/third_party/concurrency_kit/lib" "${bdir}/third_party/concurrency_kit/include"
  cp "${ck_tmp_dir}/ck/src/libck.a" "${bdir}/third_party/concurrency_kit/lib/libck.a"
  cp "${ck_tmp_dir}/ck/include"/*.h "${bdir}/third_party/concurrency_kit/include"
  cp -r "${ck_tmp_dir}/ck/include/gcc" "${bdir}/third_party/concurrency_kit/include/"
  cp -r "${ck_tmp_dir}/ck/include/spinlock" "${bdir}/third_party/concurrency_kit/include/"
  cat > "${bdir}/third_party/concurrency_kit/Makefile" <<'EOF'
all:
	@true

install:
	@true

clean:
	@true
EOF

  if [[ "${host}" == "aarch64-linux-android" ]]; then
    python3 /work/src/patch_ck_aarch64.py
  fi

  python3 /work/src/patch_ck_libck_so.py

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
    XCFLAGS="-DLUAJIT_DISABLE_JIT -DLUAJIT_USE_SYSMALLOC" \
    TARGET_SYS=Linux \
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

  make -j"${JOBS:-1}"

  cp -f src/sysbench "${OUT_DIR}/sysbench-${name}"
  "${STRIP}" "${OUT_DIR}/sysbench-${name}" || true

  popd >/dev/null

  file "${OUT_DIR}/sysbench-${name}"
}

_build_one() {
  local name="$1"
  # Skip if BUILD_TARGETS is set and this target is not in the list.
  if [[ -n "${BUILD_TARGETS}" ]]; then
    local t
    for t in ${BUILD_TARGETS//,/ }; do
      [[ "${t}" == "${name}" ]] && { build_one "$@"; return; }
    done
    echo "==> Skipping ${name} (not in BUILD_TARGETS)"
    return
  fi
  build_one "$@"
}

# armv5 (armeabi legacy) — no -mthumb: LuaJIT assembly is ARM-mode only
_build_one \
  "armv5" \
  "arm" \
  "android-16" \
  "arm-linux-androideabi-4.9" \
  "arm-linux-androideabi" \
  "-march=armv5te -msoft-float"

# armv6
_build_one \
  "armv6" \
  "arm" \
  "android-16" \
  "arm-linux-androideabi-4.9" \
  "arm-linux-androideabi" \
  "-march=armv6 -mfpu=vfp -mfloat-abi=softfp"

# armv7
_build_one \
  "armv7" \
  "arm" \
  "android-16" \
  "arm-linux-androideabi-4.9" \
  "arm-linux-androideabi" \
  "-march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=softfp"

# armv7-nopie: for Android < 4.1 (API < 16) — no PIE, statically linked
# so it works regardless of the old device's shared library versions.
_build_one \
  "armv7-nopie" \
  "arm" \
  "android-14" \
  "arm-linux-androideabi-4.9" \
  "arm-linux-androideabi" \
  "-march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=softfp" \
  "no" \
  "yes"

# x86
_build_one \
  "x86" \
  "x86" \
  "android-16" \
  "x86-4.9" \
  "i686-linux-android" \
  "-march=i686 -mtune=intel -mssse3 -mfpmath=sse"

# aarch64
_build_one \
  "aarch64" \
  "arm64" \
  "android-21" \
  "aarch64-linux-android-4.9" \
  "aarch64-linux-android" \
  "-march=armv8-a"

# x86_64
_build_one \
  "x86_64" \
  "x86_64" \
  "android-21" \
  "x86_64-4.9" \
  "x86_64-linux-android" \
  "-march=x86-64"

echo ""
echo "Artifacts in ${OUT_DIR}:"
ls -lh "${OUT_DIR}"/sysbench-*
