#!/bin/bash
# build_linux.sh - Build and package DufsHub for Linux
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCH=${1:-x86_64}
VERSION=$(grep '^version:' pubspec.yaml | head -1 | awk '{print $2}' | awk -F'+' '{print $1}')
APP_NAME="dufshub"
BUILD_ROOT="${DUFSHUB_BUILD_ROOT:-build}"
OUTPUT_DIR="${DUFSHUB_OUTPUT_DIR:-${BUILD_ROOT}/linux/output}"

# Architecture mapping
DEB_ARCH=$([ "$ARCH" = "aarch64" ] && echo "arm64" || echo "amd64")
ARCHIVE_NAME="${APP_NAME}-${VERSION}-linux-${ARCH}"

echo "Building DufsHub ${VERSION} for Linux ${ARCH}..."

# Build dufs shared library (or skip if already present in assets/dufs/)
DUFS_LIB="assets/dufs/libdufs-linux-${ARCH}.so"
if [ -f "$DUFS_LIB" ]; then
  echo "Existing dufs library found: $DUFS_LIB (delete to rebuild from source)"
else
  DUFS_PLATFORM=$([ "$ARCH" = "aarch64" ] && echo "linux-arm64" || echo "linux-x86_64")
  echo "Compiling dufs shared library for ${DUFS_PLATFORM}..."
  bash "${SCRIPT_DIR}/build_dufs.sh" "$DUFS_PLATFORM"
fi

# Build Flutter Linux
flutter build linux --release

# Flutter outputs to build/linux/{x64|arm64}/release/bundle
FLUTTER_ARCH=$([ "$ARCH" = "aarch64" ] && echo "arm64" || echo "x64")
BUILD_DIR="${BUILD_ROOT}/linux/${FLUTTER_ARCH}/release/bundle"
mkdir -p "$OUTPUT_DIR"

# Copy build output for packaging
PKG_DIR="${OUTPUT_DIR}/${APP_NAME}"
cp -r "$BUILD_DIR" "$PKG_DIR"

# Include dufs shared library in the bundle
cp "assets/dufs/libdufs-linux-${ARCH}.so" "${PKG_DIR}/libdufs.so"

# ==================== AppImage ====================
echo "Creating AppImage..."
APPDIR="${OUTPUT_DIR}/${APP_NAME}.AppDir"
rm -rf "${APPDIR}"
mkdir -p "${APPDIR}/usr/bin" "${APPDIR}/usr/share/applications" "${APPDIR}/usr/share/icons/hicolor/256x256/apps"

# Copy app files
cp -r "${PKG_DIR}/"* "${APPDIR}/usr/bin/"

# Create desktop entry
cat > "${APPDIR}/${APP_NAME}.desktop" << 'DESKTOP'
[Desktop Entry]
Name=DufsHub
Comment=The hub for dufs.
Exec=dufshub
Icon=dufshub
Type=Application
Categories=Utility;FileTransfer;
Terminal=false
DESKTOP

cp "${APPDIR}/${APP_NAME}.desktop" "${APPDIR}/usr/share/applications/${APP_NAME}.desktop"

# Copy icon
if [ -f "assets/icon/app_icon.png" ]; then
  cp "assets/icon/app_icon.png" "${APPDIR}/dufshub.png"
  cp "assets/icon/app_icon.png" "${APPDIR}/usr/share/icons/hicolor/256x256/apps/${APP_NAME}.png"
fi

# AppRun
cat > "${APPDIR}/AppRun" << 'APPRUN'
#!/bin/bash
SELF=$(readlink -f "$0")
HERE="${SELF%/*}"
export LD_LIBRARY_PATH="${HERE}/usr/lib:${HERE}/usr/bin/lib:${LD_LIBRARY_PATH}"
exec "${HERE}/usr/bin/dufshub" "$@"
APPRUN
chmod +x "${APPDIR}/AppRun"

# Download linuxdeploy (better architecture handling than appimagetool)
LINUXDEPLOY_ARCH=$([ "$ARCH" = "aarch64" ] && echo "aarch64" || echo "x86_64")
if [ ! -f /tmp/linuxdeploy ]; then
  curl -sL "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-${LINUXDEPLOY_ARCH}.AppImage" -o /tmp/linuxdeploy
  chmod +x /tmp/linuxdeploy
fi

# Use linuxdeploy for AppImage creation
export ARCH=${LINUXDEPLOY_ARCH}
export OUTPUT="${OUTPUT_DIR}/${ARCHIVE_NAME}.AppImage"
export NO_STRIP=true
export APPIMAGE_EXTRACT_AND_RUN=1
/tmp/linuxdeploy --appdir "${APPDIR}" --output appimage
echo "Created: ${OUTPUT}"

# ==================== .deb ====================
echo "Creating .deb package..."
DEB_DIR="${OUTPUT_DIR}/${APP_NAME}-deb"
rm -rf "${DEB_DIR}"
mkdir -p "${DEB_DIR}/DEBIAN" "${DEB_DIR}/opt/${APP_NAME}" "${DEB_DIR}/usr/share/applications" "${DEB_DIR}/usr/bin"

# Control file
cat > "${DEB_DIR}/DEBIAN/control" << CONTROL
Package: ${APP_NAME}
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${DEB_ARCH}
Depends: libgtk-3-0, libglib2.0-0
Maintainer: zocs <zocs@live.com>
Description: The hub for dufs.
 A Dufs-based, lightweight cross-platform file distribution GUI optimized
 for air-gapped LANs and restricted industrial environments.
CONTROL

# Copy files
cp -r "${PKG_DIR}/"* "${DEB_DIR}/opt/${APP_NAME}/"

# Symlink to /usr/bin
cat > "${DEB_DIR}/DEBIAN/postinst" << 'POSTINST'
#!/bin/bash
ln -sf /opt/dufshub/dufshub /usr/bin/dufshub
chmod +x /opt/dufshub/dufshub
POSTINST
chmod 755 "${DEB_DIR}/DEBIAN/postinst"

cat > "${DEB_DIR}/DEBIAN/prerm" << 'PRERM'
#!/bin/bash
rm -f /usr/bin/dufshub
PRERM
chmod 755 "${DEB_DIR}/DEBIAN/prerm"

# Desktop entry
cat > "${DEB_DIR}/usr/share/applications/${APP_NAME}.desktop" << 'DESKTOP'
[Desktop Entry]
Name=DufsHub
Comment=The hub for dufs.
Exec=/opt/dufshub/dufshub
Icon=utilities-terminal
Type=Application
Categories=Utility;FileTransfer;
Terminal=false
DESKTOP

dpkg-deb --build "${DEB_DIR}" "${OUTPUT_DIR}/${ARCHIVE_NAME}.deb"
echo "Created: ${OUTPUT_DIR}/${ARCHIVE_NAME}.deb"

# ==================== .rpm ====================
echo "Creating .rpm package..."
if command -v rpmbuild &> /dev/null; then
  RPM_DIR="${OUTPUT_DIR}/rpm-build"
  mkdir -p "${RPM_DIR}/BUILD" "${RPM_DIR}/RPMS" "${RPM_DIR}/SOURCES" "${RPM_DIR}/SPECS" "${RPM_DIR}/SRPMS"
  cp -r "${PKG_DIR}" "${RPM_DIR}/BUILD/${APP_NAME}"

  cat > "${RPM_DIR}/SPECS/${APP_NAME}.spec" << SPEC
Name: ${APP_NAME}
Version: ${VERSION}
Release: 1
Summary: The hub for dufs.
License: MIT
Requires: gtk3 glib2

%description
A Dufs-based, lightweight cross-platform file distribution GUI optimized
for air-gapped LANs and restricted industrial environments.

%install
mkdir -p %{buildroot}/opt/${APP_NAME}
cp -r ${APP_NAME}/* %{buildroot}/opt/${APP_NAME}/
mkdir -p %{buildroot}/usr/bin
ln -sf /opt/${APP_NAME}/${APP_NAME} %{buildroot}/usr/bin/${APP_NAME}

%files
/opt/${APP_NAME}/*
/usr/bin/${APP_NAME}
SPEC

  rpmbuild -bb --define "_topdir ${RPM_DIR}" --define "_builddir ${RPM_DIR}/BUILD" "${RPM_DIR}/SPECS/${APP_NAME}.spec" 2>&1 || echo "RPM build failed, continuing..."
  # Copy RPM if created
  RPM_FILE=$(find "${RPM_DIR}/RPMS" -name "*.rpm" 2>/dev/null | head -1)
  if [ -n "$RPM_FILE" ]; then
    cp "$RPM_FILE" "${OUTPUT_DIR}/${ARCHIVE_NAME}.rpm"
    echo "Created: ${OUTPUT_DIR}/${ARCHIVE_NAME}.rpm"
  else
    echo "RPM not created, skipping"
  fi
else
  echo "rpmbuild not found, skipping .rpm"
fi

# ==================== .tar.gz (for Arch/AUR) ====================
echo "Creating .tar.gz..."
tar -czf "${OUTPUT_DIR}/${ARCHIVE_NAME}.tar.gz" -C "${OUTPUT_DIR}" "${APP_NAME}"
echo "Created: ${OUTPUT_DIR}/${ARCHIVE_NAME}.tar.gz"

echo ""
echo "Build complete! Output files:"
ls -la "${OUTPUT_DIR}/"*.AppImage "${OUTPUT_DIR}/"*.deb "${OUTPUT_DIR}/"*.tar.gz 2>/dev/null || true
ls -la "${OUTPUT_DIR}/"*.rpm 2>/dev/null || true
