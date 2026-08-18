FROM ubuntu:24.04

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG ALL_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG all_proxy
ARG no_proxy

ENV DEBIAN_FRONTEND=noninteractive \
    FLUTTER_HOME=/opt/flutter \
    FLUTTER_VERSION=3.47.0 \
    FLUTTER_TAR=flutter_linux_3.41.5-stable.tar.xz \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
    CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup \
    PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:/usr/local/cargo/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/usr/lib/jvm/java-17-openjdk-amd64/bin:$PATH

RUN apt-get update && apt-get install -y \
    bash \
    ca-certificates \
    clang \
    cmake \
    curl \
    file \
    git \
    libglu1-mesa \
    libstdc++6 \
    ninja-build \
    openjdk-17-jdk \
    pkg-config \
    tar \
    unzip \
    xz-utils \
    zip \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/${FLUTTER_TAR}" -o /tmp/flutter.tar.xz \
    && mkdir -p /opt \
    && tar -xJf /tmp/flutter.tar.xz -C /opt \
    && rm -f /tmp/flutter.tar.xz \
    && git config --global --add safe.directory /opt/flutter \
    && flutter config --no-analytics \
    && flutter precache --android \
    && chmod -R a+rX /opt/flutter \
    && find /opt/flutter -type d -name .dart_tool -exec chmod -R a+rwX {} +

RUN unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy \
    && mkdir -p "$ANDROID_HOME/cmdline-tools" \
    && curl -fsSL https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip -o /tmp/cmdline-tools.zip \
    && unzip -q /tmp/cmdline-tools.zip -d "$ANDROID_HOME/cmdline-tools" \
    && mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest" \
    && yes | sdkmanager --licenses \
    && sdkmanager \
      "platform-tools" \
      "platforms;android-35" \
      "platforms;android-36" \
      "build-tools;35.0.0" \
      "build-tools;36.0.0" \
      "ndk;28.2.13676358" \
    && rm -f /tmp/cmdline-tools.zip \
    && chmod -R a+rwX "$ANDROID_HOME"

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --no-modify-path \
    && rustup target add aarch64-linux-android \
    && chmod -R a+rX /usr/local/cargo /usr/local/rustup

WORKDIR /work
