#!/bin/bash
# build_macos.sh - Build FileInfra for macOS
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCH=${1:-aarch64}
VERSION=$(grep '^version:' pubspec.yaml | head -1 | awk '{print $2}' | awk -F'+' '{print $1}')
APP_NAME="FileInfra"

# Architecture mapping
DARWIN_ARCH=$([ "$ARCH" = "aarch64" ] && echo "aarch64-apple-darwin" || echo "x86_64-apple-darwin")
DISPLAY_ARCH=$([ "$ARCH" = "aarch64" ] && echo "arm64" || echo "x64")
ARCHIVE_NAME="${APP_NAME}-${VERSION}-macos-${DISPLAY_ARCH}"

echo "Building FileInfra ${VERSION} for macOS ${DISPLAY_ARCH}..."

# Build dufs shared library (or skip if already present in assets/dufs/)
DUFS_LIB="assets/dufs/libdufs-macos-${DISPLAY_ARCH}.dylib"
if [ -f "$DUFS_LIB" ]; then
  echo "Existing dufs library found: $DUFS_LIB (delete to rebuild from source)"
else
  DUFS_PLATFORM=$([ "$ARCH" = "aarch64" ] && echo "macos-arm64" || echo "macos-x86_64")
  echo "Compiling dufs shared library for ${DUFS_PLATFORM}..."
  bash "${SCRIPT_DIR}/build_dufs.sh" "$DUFS_PLATFORM"
fi

# Build Flutter macOS
flutter build macos --release

BUILD_DIR="build/macos/Build/Products/Release"
OUTPUT_DIR="build/macos/output"
mkdir -p "$OUTPUT_DIR"

# Copy .app bundle (Flutter outputs based on PRODUCT_NAME = FileInfra)
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
if [ ! -d "$APP_BUNDLE" ]; then
  echo "ERROR: ${APP_BUNDLE} not found"
  ls "$BUILD_DIR/" 2>/dev/null
  exit 1
fi
cp -r "$APP_BUNDLE" "${OUTPUT_DIR}/${APP_NAME}.app"

# Include dufs shared library in the app bundle
APP_CONTENTS="${OUTPUT_DIR}/${APP_NAME}.app/Contents/MacOS"
cp "assets/dufs/libdufs-macos-${DISPLAY_ARCH}.dylib" "${APP_CONTENTS}/libdufs.dylib"

echo "App contents:"
ls -la "${APP_CONTENTS}/"

# Create DMG-like zip (simpler for distribution)
echo "Creating zip archive..."
cd "${OUTPUT_DIR}"
zip -r -y "${ARCHIVE_NAME}.zip" "${APP_NAME}.app"
cd -

echo "Created: ${OUTPUT_DIR}/${ARCHIVE_NAME}.zip"
ls -la "${OUTPUT_DIR}/${ARCHIVE_NAME}.zip"
