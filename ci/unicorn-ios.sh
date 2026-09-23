#!/usr/bin/env bash
# Build libunicorn (x86_64 emulator core) as a static library for iOS.
# Unicorn 2 uses precompiled TCG — no JIT, no private entitlements needed.
set -euo pipefail

UNICORN_VERSION="2.1.3"
BUILD_DIR="$(pwd)/build/unicorn"
SRC_DIR="${BUILD_DIR}/src"
PREFIX_DEVICE="${BUILD_DIR}/iphoneos"
PREFIX_SIM="${BUILD_DIR}/iphonesimulator"

mkdir -p "${SRC_DIR}"

if [ ! -d "${SRC_DIR}/unicorn-${UNICORN_VERSION}" ]; then
  curl -sL "https://github.com/unicorn-engine/unicorn/archive/refs/tags/${UNICORN_VERSION}.tar.gz" \
    -o "${SRC_DIR}/unicorn.tar.gz"
  tar -xzf "${SRC_DIR}/unicorn.tar.gz" -C "${SRC_DIR}"
fi

build_for() {
  local sdk="$1" prefix="$2"
  local sysroot
  sysroot="$(xcrun --sdk "${sdk}" --show-sdk-path)"
  cmake -S "${SRC_DIR}/unicorn-${UNICORN_VERSION}" -B "${BUILD_DIR}/${sdk}" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="${sysroot}" \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DUNICORN_BUILD_SHARED=OFF \
    -DUNICORN_ARCH=x86 \
    -DCMAKE_BUILD_TYPE=Release
  cmake --build "${BUILD_DIR}/${sdk}" -j"$(sysctl -n hw.ncpu)"
  mkdir -p "${prefix}/lib" "${prefix}/include"
  cp "${BUILD_DIR}/${sdk}/libunicorn.a" "${prefix}/lib/"
  cp -R "${SRC_DIR}/unicorn-${UNICORN_VERSION}/include/unicorn" "${prefix}/include/"
}

build_for iphoneos "${PREFIX_DEVICE}"
build_for iphonesimulator "${PREFIX_SIM}"

# Host (macOS) build for running package tests on the runner.
PREFIX_MACOS="${BUILD_DIR}/macos"
cmake -S "${SRC_DIR}/unicorn-${UNICORN_VERSION}" -B "${BUILD_DIR}/macos"   -DUNICORN_BUILD_SHARED=OFF   -DUNICORN_ARCH=x86   -DCMAKE_BUILD_TYPE=Release
cmake --build "${BUILD_DIR}/macos" -j"$(sysctl -n hw.ncpu)"
mkdir -p "${PREFIX_MACOS}/lib" "${PREFIX_MACOS}/include"
cp "${BUILD_DIR}/macos/libunicorn.a" "${PREFIX_MACOS}/lib/"
cp -R "${SRC_DIR}/unicorn-${UNICORN_VERSION}/include/unicorn" "${PREFIX_MACOS}/include/"

echo "Built:"
ls -la "${PREFIX_DEVICE}/lib/libunicorn.a" "${PREFIX_SIM}/lib/libunicorn.a"
