#!/bin/sh
# Builds and installs real OpenWrt ucode with UCI support for CI runners

set -ex

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

export CMAKE_PREFIX_PATH="/usr/local:/usr:${CMAKE_PREFIX_PATH}"
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig:${PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib64:${LD_LIBRARY_PATH}"

echo "=== Building and installing libubox ==="
git clone --depth=1 https://github.com/openwrt/libubox.git "${TMP_BUILD_DIR}/libubox"
cmake -S "${TMP_BUILD_DIR}/libubox" -B "${TMP_BUILD_DIR}/libubox/build" \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_PREFIX_PATH=/usr/local \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_LUA=OFF \
    -DBUILD_EXAMPLES=OFF
cmake --build "${TMP_BUILD_DIR}/libubox/build" -j"${NPROC}"
${SUDO} cmake --install "${TMP_BUILD_DIR}/libubox/build"

echo "=== Building and installing libuci ==="
git clone --depth=1 https://github.com/openwrt/uci.git "${TMP_BUILD_DIR}/uci"
cmake -S "${TMP_BUILD_DIR}/uci" -B "${TMP_BUILD_DIR}/uci/build" \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_PREFIX_PATH=/usr/local \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_LUA=OFF
cmake --build "${TMP_BUILD_DIR}/uci/build" -j"${NPROC}"
${SUDO} cmake --install "${TMP_BUILD_DIR}/uci/build"

echo "/usr/local/lib" | ${SUDO} tee /etc/ld.so.conf.d/99-local.conf >/dev/null 2>&1 || true
if command -v ldconfig >/dev/null 2>&1; then
    ${SUDO} ldconfig || true
fi

echo "=== Building and installing ucode with UCI support ==="
git clone --depth=1 https://github.com/jow-/ucode.git "${TMP_BUILD_DIR}/ucode"
cmake -S "${TMP_BUILD_DIR}/ucode" -B "${TMP_BUILD_DIR}/ucode/build" \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_PREFIX_PATH=/usr/local \
    -DCMAKE_BUILD_TYPE=Release \
    -DUCI_SUPPORT=ON \
    -DUBUS_SUPPORT=OFF \
    -DULOOP_SUPPORT=OFF \
    -DNL80211_SUPPORT=OFF \
    -DRESOLV_SUPPORT=OFF
cmake --build "${TMP_BUILD_DIR}/ucode/build" -j"${NPROC}"
${SUDO} cmake --install "${TMP_BUILD_DIR}/ucode/build"

if command -v ldconfig >/dev/null 2>&1; then
    ${SUDO} ldconfig || true
fi

echo "=== Verifying ucode and uci module ==="
/usr/local/bin/ucode -v
/usr/local/bin/ucode -e 'import { cursor } from "uci"; print("UCI module loaded successfully\n");'

echo "=== Host ucode bootstrap completed successfully ==="
exit 0
