#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE_NAME="dufshub-linux-builder"
ARCH="${1:-x86_64}"
DOCKER_BUILD_ARGS=()
DOCKER_ENV=()
DOCKER_CPUS="${DOCKER_CPUS:-12}"
CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-12}"
DOCKER_BUILD_ROOT="${DOCKER_BUILD_ROOT:-$PROJECT_DIR/docker_build}"
PLATFORM_ROOT="$DOCKER_BUILD_ROOT/linux/$ARCH"
CACHE_ROOT="$PLATFORM_ROOT/cache"
WORK_ROOT="$PLATFORM_ROOT/work"
OUTPUT_ROOT="$PLATFORM_ROOT/outputs"
PACKAGE_OUTPUT_ROOT="$OUTPUT_ROOT/packages"
LOG_ROOT="$OUTPUT_ROOT/logs"
STAGE_ROOT="$PLATFORM_ROOT/stage"
STAGE_PROJECT_ROOT="$STAGE_ROOT/project"

for proxy_var in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy; do
  proxy_value="${!proxy_var:-}"
  if [ -n "$proxy_value" ]; then
    DOCKER_BUILD_ARGS+=( --build-arg "$proxy_var=$proxy_value" )
    DOCKER_ENV+=( -e "$proxy_var=$proxy_value" )
  fi
done

if [ "$ARCH" != "x86_64" ]; then
  echo "Only x86_64 is supported by the local Docker workflow for now."
  exit 1
fi

mkdir -p "$CACHE_ROOT/pub" "$CACHE_ROOT/cargo" "$CACHE_ROOT/rustup" "$PACKAGE_OUTPUT_ROOT" "$LOG_ROOT" "$STAGE_ROOT"
docker run --rm --network=host -v "$CACHE_ROOT:/target" ubuntu:24.04 \
  chown -R "$(id -u):$(id -g)" /target >/dev/null 2>&1 || true
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

docker build --network=host "${DOCKER_BUILD_ARGS[@]}" -f "$PROJECT_DIR/docker/linux.Dockerfile" -t "$IMAGE_NAME" "$DOCKER_CONTEXT_ROOT"

docker run --rm \
  --network=host \
  --cpus "$DOCKER_CPUS" \
  --user "$(id -u):$(id -g)" \
  -v "$WORK_ROOT:/work" \
  -v "$CACHE_ROOT/pub:/cache/pub" \
  -v "$CACHE_ROOT/cargo:/cache/cargo" \
  -v "$CACHE_ROOT/rustup:/cache/rustup" \
  -v "$PACKAGE_OUTPUT_ROOT:/outputs/packages" \
  -e HOME=/tmp \
  -e PUB_CACHE=/cache/pub \
  -e CARGO_HOME=/cache/cargo \
  -e RUSTUP_HOME=/cache/rustup \
  -e CARGO_BUILD_JOBS="$CARGO_BUILD_JOBS" \
  -e DUFSHUB_BUILD_ROOT=build \
  -e DUFSHUB_OUTPUT_DIR=/outputs/packages \
  "${DOCKER_ENV[@]}" \
  "$IMAGE_NAME" \
  bash -lc "
    set -euo pipefail
    flutter pub get
    bash scripts/build_linux.sh $ARCH
  "

printf 'Linux Docker outputs: %s\n' "$PACKAGE_OUTPUT_ROOT"
