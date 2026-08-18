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
    CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup \
    PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:/usr/local/cargo/bin:$PATH

RUN apt-get update && apt-get install -y \
    bash \
    ca-certificates \
    clang \
    cmake \
    curl \
    dpkg-dev \
    file \
    git \
    libayatana-appindicator3-dev \
    libfuse2 \
    libgtk-3-dev \
    libsecret-1-dev \
    lld \
    llvm \
    ninja-build \
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
    && flutter precache --linux \
    && chmod -R a+rX /opt/flutter \
    && find /opt/flutter -type d -name .dart_tool -exec chmod -R a+rwX {} +

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --no-modify-path \
    && rustup target add x86_64-unknown-linux-gnu \
    && chmod -R a+rX /usr/local/cargo /usr/local/rustup

WORKDIR /work
