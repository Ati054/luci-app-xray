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

export CMAKE_PREFIX_PATH="/usr:/usr/local:${CMAKE_PREFIX_PATH}"
export PKG_CONFIG_PATH="/usr/lib/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig:/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="/usr/lib:/usr/lib64:/usr/local/lib:${LD_LIBRARY_PATH}"

LIBUBOX_REF="e7608b69283d919d031d13cc8e21692503f5dbea"
UCI_REF="74f6277aabffc943d026f406df57c22595134c42"
UCODE_REF="fa2c1bc01420f656b1997cad6829b91f81161895"

fetch_pinned_repo() {
    local name="$1"
    local repo_url="$2"
    local commit_ref="$3"
    local dest_dir="$4"

    echo "Fetching pinned ${name} @ ${commit_ref}..."
    mkdir -p "${dest_dir}"
    (
        cd "${dest_dir}"
        git init -q
        git remote add origin "${repo_url}" 2>/dev/null || git remote set-url origin "${repo_url}"
        git fetch -q --depth=1 origin "${commit_ref}"
        git checkout -q --detach "${commit_ref}"
        local actual_head
        actual_head="$(git rev-parse HEAD)"
        if [ "${actual_head}" != "${commit_ref}" ]; then
            echo "::error::Commit verification failed for ${name}: expected ${commit_ref}, got ${actual_head}"
            exit 1
        fi
        echo "  [VERIFIED] ${name}: ${actual_head}"
    )
}

echo "=== Building and installing libubox ==="
fetch_pinned_repo "libubox" "https://github.com/openwrt/libubox.git" "${LIBUBOX_REF}" "${TMP_BUILD_DIR}/libubox"
cmake -S "${TMP_BUILD_DIR}/libubox" -B "${TMP_BUILD_DIR}/libubox/build" \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_LUA=OFF \
    -DBUILD_EXAMPLES=OFF
cmake --build "${TMP_BUILD_DIR}/libubox/build" -j"${NPROC}"
${SUDO} cmake --install "${TMP_BUILD_DIR}/libubox/build"

echo "=== Building and installing libuci ==="
fetch_pinned_repo "uci" "https://github.com/openwrt/uci.git" "${UCI_REF}" "${TMP_BUILD_DIR}/uci"
cmake -S "${TMP_BUILD_DIR}/uci" -B "${TMP_BUILD_DIR}/uci/build" \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_LUA=OFF
cmake --build "${TMP_BUILD_DIR}/uci/build" -j"${NPROC}"
${SUDO} cmake --install "${TMP_BUILD_DIR}/uci/build"

if command -v ldconfig >/dev/null 2>&1; then
    ${SUDO} ldconfig || true
fi

echo "=== Building and installing ucode with UCI support ==="
fetch_pinned_repo "ucode" "https://github.com/jow-/ucode.git" "${UCODE_REF}" "${TMP_BUILD_DIR}/ucode"
cmake -S "${TMP_BUILD_DIR}/ucode" -B "${TMP_BUILD_DIR}/ucode/build" \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_BUILD_TYPE=Release \
    -DUCI_SUPPORT=ON \
    -DUBUS_SUPPORT=OFF \
    -DULOOP_SUPPORT=OFF \
    -DNL80211_SUPPORT=OFF \
    -DRESOLV_SUPPORT=OFF \
    -DEXT_ROOT=/usr/lib/ucode
cmake --build "${TMP_BUILD_DIR}/ucode/build" -j"${NPROC}"
${SUDO} cmake --install "${TMP_BUILD_DIR}/ucode/build"

if command -v ldconfig >/dev/null 2>&1; then
    ${SUDO} ldconfig || true
fi

echo "=== Verifying ucode and uci module ==="
ucode -v
ucode -e 'import { cursor } from "uci"; print("UCI module loaded successfully\n");'

echo "=== Host ucode bootstrap completed successfully ==="
exit 0
