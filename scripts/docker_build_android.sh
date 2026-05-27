#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE_NAME="dufshub-android-builder"
SDK_DIR_IN_CONTAINER="/opt/android-sdk"
FLUTTER_DIR_IN_CONTAINER="/opt/flutter"
KEYSTORE_MOUNT=()
DOCKER_BUILD_ARGS=()
DOCKER_CPUS="${DOCKER_CPUS:-12}"
CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-12}"
DOCKER_BUILD_ROOT="${DOCKER_BUILD_ROOT:-$PROJECT_DIR/docker_build}"
PLATFORM_ROOT="$DOCKER_BUILD_ROOT/android"
CACHE_ROOT="$PLATFORM_ROOT/cache"
WORK_ROOT="$PLATFORM_ROOT/work"
OUTPUT_ROOT="$PLATFORM_ROOT/outputs"
APK_OUTPUT_ROOT="$OUTPUT_ROOT/apk"
LOG_ROOT="$OUTPUT_ROOT/logs"
STAGE_ROOT="$PLATFORM_ROOT/stage"
STAGE_PROJECT_ROOT="$STAGE_ROOT/project"
DOCKER_ENV=(
  -e ANDROID_HOME="$SDK_DIR_IN_CONTAINER"
  -e ANDROID_SDK_ROOT="$SDK_DIR_IN_CONTAINER"
  -e ANDROID_NDK_HOME="$SDK_DIR_IN_CONTAINER/ndk/28.2.13676358"
  -e PUB_CACHE=/cache/pub
  -e GRADLE_USER_HOME=/cache/gradle
  -e CARGO_HOME=/cache/cargo
  -e RUSTUP_HOME=/cache/rustup
  -e CARGO_BUILD_JOBS="$CARGO_BUILD_JOBS"
  -e HOME=/tmp
  -e KOTLIN_USER_HOME=/cache/kotlin
)

for proxy_var in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy; do
  proxy_value="${!proxy_var:-}"
  if [ -n "$proxy_value" ]; then
    DOCKER_BUILD_ARGS+=( --build-arg "$proxy_var=$proxy_value" )
    DOCKER_ENV+=( -e "$proxy_var=$proxy_value" )
  fi
done

if [ -n "${KEYSTORE_FILE:-}" ]; then
  KEYSTORE_HOST_PATH="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$KEYSTORE_FILE")"
  KEYSTORE_MOUNT=(
    -v "$KEYSTORE_HOST_PATH:/tmp/dufshub-release.jks:ro"
    -e KEYSTORE_FILE=/tmp/dufshub-release.jks
  )
  [ -n "${KEYSTORE_PASSWORD:-}" ] && DOCKER_ENV+=( -e KEYSTORE_PASSWORD="$KEYSTORE_PASSWORD" )
  [ -n "${KEY_ALIAS:-}" ] && DOCKER_ENV+=( -e KEY_ALIAS="$KEY_ALIAS" )
  [ -n "${KEY_PASSWORD:-}" ] && DOCKER_ENV+=( -e KEY_PASSWORD="$KEY_PASSWORD" )
fi

mkdir -p "$CACHE_ROOT/pub" "$CACHE_ROOT/gradle" "$CACHE_ROOT/kotlin" "$CACHE_ROOT/cargo" "$CACHE_ROOT/rustup" "$APK_OUTPUT_ROOT" "$LOG_ROOT" "$STAGE_ROOT"
docker run --rm --network=host -v "$CACHE_ROOT:/target" ubuntu:24.04 \
  chown -R "$(id -u):$(id -g)" /target >/dev/null 2>&1 || true
if [ -e "$WORK_ROOT" ]; then
  chmod -R u+rwX "$WORK_ROOT" 2>/dev/null || true
  docker run --rm --network=host -v "$WORK_ROOT:/target" ubuntu:24.04 bash -lc 'rm -rf /target/* /target/.[!.]* /target/..?*' >/dev/null 2>&1 || true
  chmod -R u+rwX "$WORK_ROOT" 2>/dev/null || true
fi
rm -rf "$WORK_ROOT" "$STAGE_PROJECT_ROOT"
mkdir -p "$STAGE_PROJECT_ROOT"
rsync -a --delete \
  --exclude '.git/' \
  --exclude 'docker_build/' \
  --exclude '.dart_tool/' \
  --exclude 'build/' \
  --exclude 'android/.gradle/' \
  --exclude 'android/.kotlin/' \
  --exclude '.pub-cache/' \
  "$PROJECT_DIR/" "$STAGE_PROJECT_ROOT/"
mv "$STAGE_PROJECT_ROOT" "$WORK_ROOT"

DOCKER_CONTEXT_ROOT="$WORK_ROOT"

docker build --network=host "${DOCKER_BUILD_ARGS[@]}" -f "$PROJECT_DIR/docker/android.Dockerfile" -t "$IMAGE_NAME" "$DOCKER_CONTEXT_ROOT"

docker run --rm \
  --network=host \
  --cpus "$DOCKER_CPUS" \
  --user "$(id -u):$(id -g)" \
  -v "$WORK_ROOT:/work" \
  -v "$CACHE_ROOT/pub:/cache/pub" \
  -v "$CACHE_ROOT/gradle:/cache/gradle" \
  -v "$CACHE_ROOT/kotlin:/cache/kotlin" \
  -v "$CACHE_ROOT/cargo:/cache/cargo" \
  -v "$CACHE_ROOT/rustup:/cache/rustup" \
  -v "$APK_OUTPUT_ROOT:/outputs/apk" \
  "${KEYSTORE_MOUNT[@]}" \
  "${DOCKER_ENV[@]}" \
  "$IMAGE_NAME" \
  bash -lc '
    set -euo pipefail
    VERSION=$(grep "^version:" pubspec.yaml | awk "{print \$2}")
    VERSION_NAME=${VERSION%%+*}
    VERSION_CODE=${VERSION##*+}
    cat > android/local.properties <<EOF
flutter.sdk=/opt/flutter
sdk.dir=/opt/android-sdk
flutter.buildMode=release
flutter.versionName=${VERSION_NAME}
flutter.versionCode=${VERSION_CODE}
EOF
    ln -sfn /cache/gradle android/.gradle
    ln -sfn /cache/kotlin android/.kotlin
    flutter pub get
    bash scripts/build_dufs.sh android-arm64
    flutter build apk --release
    cp build/app/outputs/flutter-apk/*.apk /outputs/apk/
  '

printf 'Android Docker outputs: %s\n' "$APK_OUTPUT_ROOT"
