#!/bin/sh
# Builds and installs real OpenWrt ucode with UCI support for CI runners

set -e

echo "=== Checking host ucode availability ==="
if command -v ucode >/dev/null 2>&1; then
    if ucode -e 'import { cursor } from "uci";' >/dev/null 2>&1; then
        echo "ucode with UCI module is already installed and functional."
        ucode -v
        exit 0
    fi
fi

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

TMP_BUILD_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "${TMP_BUILD_DIR}"
}
trap cleanup EXIT

NPROC=$(nproc 2>/dev/null || echo 2)

echo "=== Building and installing libubox ==="
git clone --depth=1 https://github.com/openwrt/libubox.git "${TMP_BUILD_DIR}/libubox"
cmake -S "${TMP_BUILD_DIR}/libubox" -B "${TMP_BUILD_DIR}/libubox/build" \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_LUA=OFF
cmake --build "${TMP_BUILD_DIR}/libubox/build" -j"${NPROC}"
${SUDO} cmake --install "${TMP_BUILD_DIR}/libubox/build"

echo "=== Building and installing libuci ==="
git clone --depth=1 https://github.com/openwrt/uci.git "${TMP_BUILD_DIR}/uci"
cmake -S "${TMP_BUILD_DIR}/uci" -B "${TMP_BUILD_DIR}/uci/build" \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_LUA=OFF
cmake --build "${TMP_BUILD_DIR}/uci/build" -j"${NPROC}"
${SUDO} cmake --install "${TMP_BUILD_DIR}/uci/build"

echo "=== Building and installing ucode with UCI support ==="
git clone --depth=1 https://github.com/jow-/ucode.git "${TMP_BUILD_DIR}/ucode"
cmake -S "${TMP_BUILD_DIR}/ucode" -B "${TMP_BUILD_DIR}/ucode/build" \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DCMAKE_BUILD_TYPE=Release \
    -DUCI_SUPPORT=ON \
    -DUBUS_SUPPORT=OFF \
    -DULOOP_SUPPORT=OFF \
    -DNL80211_SUPPORT=OFF
cmake --build "${TMP_BUILD_DIR}/ucode/build" -j"${NPROC}"
${SUDO} cmake --install "${TMP_BUILD_DIR}/ucode/build"

if command -v ldconfig >/dev/null 2>&1; then
    ${SUDO} ldconfig /usr/local/lib || true
fi

echo "=== Verifying ucode and uci module ==="
/usr/local/bin/ucode -v
/usr/local/bin/ucode -e 'import { cursor } from "uci"; print("UCI module loaded successfully\n");'

echo "=== Host ucode bootstrap completed successfully ==="
exit 0
