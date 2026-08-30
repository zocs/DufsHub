#!/bin/bash
# build_dufs.sh - Compile dufs from source for a given platform
# Usage: bash scripts/build_dufs.sh <platform>
#   platform: android-arm64 | android-arm | android-x86_64 | linux-x86_64 | linux-arm64 | windows-x86_64 | macos-arm64 | macos-x86_64 | ios-arm64
#
# Builds dufs as a cdylib (shared library) for FFI embedding in Flutter.
# The output is a .so / .dll / .dylib that exposes dufs_start / dufs_stop / dufs_is_running.
set -euo pipefail

DUFS_VERSION="v0.46.0-fix5"
DUFS_REPO="https://github.com/zocs/dufs.git"
PLATFORM=${1:?Usage: $0 <platform>}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 确保 $RUST_TARGET 已安装。原来各处写的是
#   command -v rustup >/dev/null 2>&1 && rustup target add "$RUST_TARGET"
# ——rustup 不在 PATH（发行版自包的 rust）时会被静默跳过，然后在 cargo 深处
# 炸出「can't find crate for `core`」，报错完全指不到根因（本地实测踩过）。
ensure_rust_target() {
  command -v rustup >/dev/null 2>&1 && rustup target add "$RUST_TARGET"
  local sysroot
  sysroot=$(rustc --print sysroot)
  if [ ! -d "$sysroot/lib/rustlib/$RUST_TARGET/lib" ]; then
    echo "ERROR: Rust target '$RUST_TARGET' is not installed." >&2
    echo "       rustc sysroot: $sysroot" >&2
    if command -v rustup >/dev/null 2>&1; then
      echo "       Fix: rustup target add $RUST_TARGET" >&2
    else
      echo "       rustup is not on PATH: install rustup (https://rustup.rs), or" >&2
      echo "       your distro's rust-std package for $RUST_TARGET." >&2
    fi
    exit 1
  fi
}
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${PROJECT_DIR}/assets/dufs"

mkdir -p "$OUTPUT_DIR"

# Ensure Rust is available
if ! command -v cargo &> /dev/null; then
  echo "Installing Rust..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  source "$HOME/.cargo/env"
fi

# Clone dufs source
DUFS_SRC="/tmp/dufs-src-${DUFS_VERSION}"
# Reuse a cached checkout only if it's a complete clone of the pinned ref. A
# partial tree from an interrupted run (or a corrupt one) must be re-cloned,
# otherwise it gets silently reused and the build fails in confusing ways.
if [ -d "$DUFS_SRC/.git" ] \
   && git -C "$DUFS_SRC" rev-parse --verify -q HEAD >/dev/null 2>&1 \
   && [ -f "$DUFS_SRC/Cargo.toml" ]; then
  # 复用时也强制对齐 pin 的 tag：个人 fork 存在同名 re-tag 的可能，且树
  # 会被下面的 FFI shim 拷贝弄脏——fetch（--force 覆盖本地 tag）+ checkout
  # -f 一并处理。fetch 失败（网络）则整树重克隆。
  echo "Refreshing cached dufs checkout to $DUFS_VERSION: $DUFS_SRC"
  if ! git -C "$DUFS_SRC" fetch --depth 1 --force origin \
        "refs/tags/${DUFS_VERSION}:refs/tags/${DUFS_VERSION}" 2>/dev/null \
     || ! git -C "$DUFS_SRC" checkout -f "$DUFS_VERSION" >/dev/null 2>&1; then
    rm -rf "$DUFS_SRC"
    git clone --depth 1 --branch "$DUFS_VERSION" "$DUFS_REPO" "$DUFS_SRC"
  fi
else
  rm -rf "$DUFS_SRC"
  git clone --depth 1 --branch "$DUFS_VERSION" "$DUFS_REPO" "$DUFS_SRC"
fi

# Apply FileInfra's FFI modifications (lib.rs + Cargo.toml [lib] section)
DUFS_FFI_DIR="${SCRIPT_DIR}/dufs-ffi"
if [ -d "$DUFS_FFI_DIR" ]; then
  echo "Applying FFI modifications..."
  cp "${DUFS_FFI_DIR}/lib.rs" "${DUFS_SRC}/src/lib.rs"
  # Ensure Cargo.toml has [lib] section (BSD/GNU sed compatible)
  if ! grep -q '^\[lib\]' "${DUFS_SRC}/Cargo.toml"; then
    TMPFILE="${DUFS_SRC}/Cargo.toml.tmp"
    printf '%s\n\n%s\n' '[lib]
name = "dufs"
crate-type = ["cdylib", "rlib"]' "$(cat "${DUFS_SRC}/Cargo.toml")" > "$TMPFILE"
    mv "$TMPFILE" "${DUFS_SRC}/Cargo.toml"
  fi
fi

cd "$DUFS_SRC"

if command -v rustup >/dev/null 2>&1; then
  rustup show active-toolchain >/dev/null 2>&1 || rustup default stable
fi

case "$PLATFORM" in
  android-arm64|android-arm|android-x86_64)
    # 三个 ABI 共用同一套交叉编译配置。Flutter 的 `flutter build apk` 默认出
    # universal APK（armeabi-v7a + arm64-v8a + x86_64），只编 arm64 的话另外
    # 两个 ABI 的 libdufs.so 是缺的：应用装得上、界面也跑，但一点启动就报
    # 「dufs 服务组件缺失」。32 位老设备（Kirin 65x 这类只跑 32 位用户空间
    # 的华为平板）和 x86_64 模拟器都踩这条。
    case "$PLATFORM" in
      android-arm64)
        RUST_TARGET="aarch64-linux-android"; ABI_DIR="arm64-v8a"
        CLANG_PREFIX="aarch64-linux-android" ;;
      android-arm)
        RUST_TARGET="armv7-linux-androideabi"; ABI_DIR="armeabi-v7a"
        CLANG_PREFIX="armv7a-linux-androideabi" ;;
      android-x86_64)
        RUST_TARGET="x86_64-linux-android"; ABI_DIR="x86_64"
        CLANG_PREFIX="x86_64-linux-android" ;;
    esac

    ensure_rust_target

    if [ -n "${ANDROID_NDK_HOME:-}" ]; then
      NDK="$ANDROID_NDK_HOME"
    elif [ -n "${ANDROID_HOME:-}" ]; then
      NDK=$(find "$ANDROID_HOME/ndk" -maxdepth 1 -type d | sort -V | tail -1)
    else
      echo "ERROR: ANDROID_NDK_HOME or ANDROID_NDK_HOME must be set"
      exit 1
    fi

    TOOLCHAIN="${NDK}/toolchains/llvm/prebuilt"
    case "$(uname -s)" in
      Linux*)  HOST_TAG="linux-x86_64" ;;
      Darwin*) HOST_TAG="darwin-x86_64" ;;
      *)       echo "Unsupported host"; exit 1 ;;
    esac
    # IMPORTANT: link against a low API level (matches AndroidManifest minSdk=24).
    # If we let `sort -V | tail -1` pick the highest clang wrapper (e.g. API 35 in
    # NDK r27), lld emits DT_RELR packed relocations — the Android dynamic linker
    # only understands those from API 30+. On older devices (tested API 26) the
    # linker logs "unused DT entry: type 0x6fffe000/01/03" then the binary
    # segfaults at SEGV_MAPERR on its first PLT call. Pinning to API 24 keeps lld
    # on the legacy relocation format that works everywhere from minSdk up.
    ANDROID_API="${ANDROID_API:-24}"
    LINKER="${TOOLCHAIN}/${HOST_TAG}/bin/${CLANG_PREFIX}${ANDROID_API}-clang"
    if [ ! -x "$LINKER" ]; then
      echo "ERROR: Missing ${LINKER}. Available ${CLANG_PREFIX} clang wrappers:"
      ls "${TOOLCHAIN}/${HOST_TAG}/bin/" 2>/dev/null | grep "${CLANG_PREFIX}.*-clang$" | head -20
      exit 1
    fi

    mkdir -p .cargo
    cat > .cargo/config.toml << EOF
[target.${RUST_TARGET}]
linker = "${LINKER}"
# Three belt-and-suspenders linker flags for Android compat with NDK r28+:
# 1. --pack-dyn-relocs=none: forbid DT_RELR packed relocations (only API 30+
#    linkers understand them; older devices crash SEGV_MAPERR on first PLT
#    call).
# 2/3. -z max-page-size=0x1000 + -z common-page-size=0x1000: force 4KB page
#    alignment. NDK r28 changed the default to 16KB (0x4000) for Android 15+
#    page-size readiness; on devices < API 35 a 16KB-aligned binary loads via
#    a compat path but networking syscalls misbehave (process stays alive but
#    never bind()s a port) — observed as "dufs did not start listening on
#    port N" with empty stderr.
rustflags = [
  "-C", "link-arg=-Wl,--pack-dyn-relocs=none",
  "-C", "link-arg=-Wl,-z,max-page-size=0x1000",
  "-C", "link-arg=-Wl,-z,common-page-size=0x1000",
]
EOF

    export CC="${LINKER}"
    export AR="${TOOLCHAIN}/${HOST_TAG}/bin/llvm-ar"
    export RANLIB="${TOOLCHAIN}/${HOST_TAG}/bin/llvm-ranlib"

    cargo build --release --target "$RUST_TARGET"

    LIB_OUTPUT="${PROJECT_DIR}/android/app/src/main/jniLibs/${ABI_DIR}/libdufs.so"
    mkdir -p "$(dirname "$LIB_OUTPUT")"
    cp "target/${RUST_TARGET}/release/dufs" "$LIB_OUTPUT"
    echo "Built: $LIB_OUTPUT ($(du -h "$LIB_OUTPUT" | cut -f1))"
    ;;

  linux-x86_64)
    RUST_TARGET="x86_64-unknown-linux-gnu"

    ensure_rust_target
    cargo build --lib --release --target "$RUST_TARGET"

    cp "target/${RUST_TARGET}/release/libdufs.so" "${OUTPUT_DIR}/libdufs-linux-x86_64.so"
    echo "Built: ${OUTPUT_DIR}/libdufs-linux-x86_64.so ($(du -h "${OUTPUT_DIR}/libdufs-linux-x86_64.so" | cut -f1))"
    ;;

  linux-arm64)
    RUST_TARGET="aarch64-unknown-linux-gnu"

    ensure_rust_target
    sudo apt-get update && sudo apt-get install -y gcc-aarch64-linux-gnu

    mkdir -p .cargo
    cat > .cargo/config.toml << EOF
[target.aarch64-unknown-linux-gnu]
linker = "aarch64-linux-gnu-gcc"
EOF

    export CC="aarch64-linux-gnu-gcc"
    cargo build --lib --release --target "$RUST_TARGET"

    cp "target/${RUST_TARGET}/release/libdufs.so" "${OUTPUT_DIR}/libdufs-linux-aarch64.so"
    echo "Built: ${OUTPUT_DIR}/libdufs-linux-aarch64.so ($(du -h "${OUTPUT_DIR}/libdufs-linux-aarch64.so" | cut -f1))"
    ;;

  windows-x86_64)
    mkdir -p .cargo
    if [ "$(uname -s | cut -c1-6)" = "MINGW" ] || [ "$(uname -s | cut -c1-5)" = "MSYS" ]; then
      # Native Windows build (CI runs on windows-latest)
      RUST_TARGET="x86_64-pc-windows-msvc"
      cargo build --lib --release --target "$RUST_TARGET"
      cp "target/${RUST_TARGET}/release/dufs.dll" "${OUTPUT_DIR}/dufs-windows-x86_64.dll"
    else
      # Cross-compile from Linux
      RUST_TARGET="x86_64-pc-windows-gnu"
      ensure_rust_target
      sudo apt-get update && sudo apt-get install -y gcc-mingw-w64-x86-64
      cat > .cargo/config.toml <<XEOF
[target.x86_64-pc-windows-gnu]
linker = "x86_64-w64-mingw32-gcc"
XEOF
      export CC="x86_64-w64-mingw32-gcc"
      cargo build --lib --release --target "$RUST_TARGET"
      cp "target/${RUST_TARGET}/release/dufs.dll" "${OUTPUT_DIR}/dufs-windows-x86_64.dll"
    fi
    echo "Built: ${OUTPUT_DIR}/dufs-windows-x86_64.dll"
    ;;

  macos-arm64)
    RUST_TARGET="aarch64-apple-darwin"

    ensure_rust_target
    cargo build --lib --release --target "$RUST_TARGET"

    cp "target/${RUST_TARGET}/release/libdufs.dylib" "${OUTPUT_DIR}/libdufs-macos-arm64.dylib"
    echo "Built: ${OUTPUT_DIR}/libdufs-macos-arm64.dylib ($(du -h "${OUTPUT_DIR}/libdufs-macos-arm64.dylib" | cut -f1))"
    ;;

  macos-x86_64)
    RUST_TARGET="x86_64-apple-darwin"

    ensure_rust_target
    cargo build --lib --release --target "$RUST_TARGET"

    cp "target/${RUST_TARGET}/release/libdufs.dylib" "${OUTPUT_DIR}/libdufs-macos-x86_64.dylib"
    echo "Built: ${OUTPUT_DIR}/libdufs-macos-x86_64.dylib ($(du -h "${OUTPUT_DIR}/libdufs-macos-x86_64.dylib" | cut -f1))"
    ;;

  ios-arm64)
    # iOS doesn't support cdylib — build as binary (subprocess approach)
    RUST_TARGET="aarch64-apple-ios"
    FRAMEWORKS_DIR="${PROJECT_DIR}/ios/Frameworks"

    ensure_rust_target
    # --no-default-features drops dufs's only default feature: tls.
    # Since dufs v0.46.0, tls pulls rustls's aws-lc-rs provider (aws-lc-sys C
    # objects), whose cmake build targets the host SDK's min iOS (26.5) while
    # rustc links for arm64-apple-ios10.0.0 — the mix fails with undefined
    # arm64 symbols. FileInfra never passes --tls-cert/--tls-key, so nothing is
    # lost. Revisit if the HTTPS roadmap item lands (fix aws-lc's
    # IPHONEOS_DEPLOYMENT_TARGET, or pin the ring provider in the fork).
    cargo build --release --no-default-features --target "$RUST_TARGET"

    mkdir -p "$FRAMEWORKS_DIR"
    cp "target/${RUST_TARGET}/release/dufs" "${FRAMEWORKS_DIR}/dufs"
    echo "Built: ${FRAMEWORKS_DIR}/dufs"
    ;;

  *)
    echo "Unknown platform: $PLATFORM"
    echo "Supported: android-arm64, android-arm, android-x86_64, linux-x86_64, linux-arm64, windows-x86_64, macos-arm64, macos-x86_64, ios-arm64"
    exit 1
    ;;
esac
