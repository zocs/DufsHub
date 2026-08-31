# linux-compat.Dockerfile
# Ubuntu 18.04 (glibc 2.27) 构建环境，产物兼容 glibc 2.27+。
# 实验已验证：Flutter 3.47 引擎只需 GLIBC_2.18，此环境下链接的
# 主程序只需 GLIBC_2.2.5，完全兼容 Ubuntu 18.04 及更老发行版。
# 唯一需要外部升级的是 cmake（18.04 自带 3.10，Flutter 3.47 需 ≥ 3.14）。

FROM ubuntu:18.04

# 基础工具
# 注意：dufs 的 C 依赖（aws-lc-sys 等）使用 -Wno-deprecated-literal-operator
# 标志，这是 GCC 标志，clang 6/10 都不支持。必须用 gcc 编译。
RUN apt-get update && \
    apt-get install -y \
      curl git xz-utils unzip \
      ninja-build pkg-config \
      libgtk-3-dev libsecret-1-dev \
      libayatana-appindicator3-dev \
      build-essential ca-certificates \
      libfuse2 && \
    rm -rf /var/lib/apt/lists/*
# 确保 Rust 的 cc crate 使用 gcc（不是 clang）
ENV CC=gcc
ENV CXX=g++

# cmake 3.28（官方预编译二进制，静态）
RUN curl -sL -o /tmp/cmake.tar.gz \
      'https://github.com/Kitware/CMake/releases/download/v3.28.6/cmake-3.28.6-linux-x86_64.tar.gz' && \
    tar xzf /tmp/cmake.tar.gz -C /opt/ && \
    rm /tmp/cmake.tar.gz
ENV PATH="/opt/cmake-3.28.6-linux-x86_64/bin:${PATH}"

# Flutter 3.47.0
RUN curl -sL -o /tmp/flutter.tar.xz \
      'https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.0-stable.tar.xz' && \
    tar xf /tmp/flutter.tar.xz -C /opt/ && \
    rm /tmp/flutter.tar.xz && \
    git config --global --add safe.directory /opt/flutter
ENV PATH="/opt/flutter/bin:${PATH}"

# Rust 1.98（与 CI 主构建对齐）
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --default-toolchain 1.98.0 --profile minimal --no-modify-path
ENV PATH="/root/.cargo/bin:${PATH}"

# 预 cache flutter linux 引擎（避免构建时下载）
RUN flutter precache --linux --no-version-check 2>/dev/null; true

WORKDIR /src