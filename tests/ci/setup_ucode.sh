#!/bin/sh
# Builds the host test runtime from the exact source revisions selected by the
# active OpenWrt SDK, with UCI support for generator entrypoint tests.

set -ex

echo "=== Building host ucode from source ==="
SDK_HOME="${1:-${SDK_HOME:-}}"
[ -n "${SDK_HOME}" ] && [ -d "${SDK_HOME}" ] || {
    echo "::error::setup_ucode.sh requires the extracted OpenWrt SDK path"
    exit 1
}
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

export CMAKE_PREFIX_PATH="/opt/ucode-pinned:/usr:/usr/local:${CMAKE_PREFIX_PATH}"
export PKG_CONFIG_PATH="/opt/ucode-pinned/lib/pkgconfig:/usr/lib/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig:/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="/opt/ucode-pinned/lib:/usr/lib:/usr/lib64:/usr/local/lib:${LD_LIBRARY_PATH}"

source_revision() {
    local makefile="$1"
    local revision
    [ -f "${makefile}" ] || {
        echo "::error::OpenWrt source Makefile is missing: ${makefile}" >&2
        return 1
    }
    revision="$(sed -n 's/^PKG_SOURCE_VERSION:=//p' "${makefile}" | head -n 1)"
    echo "${revision}" | grep -Eq '^[0-9a-f]{40}$' || {
        echo "::error::Unable to derive a full source revision from ${makefile}: ${revision}" >&2
        return 1
    }
    printf '%s\n' "${revision}"
}

LIBUBOX_REF="$(source_revision "${SDK_HOME}/package/libs/libubox/Makefile")"
UCI_REF="$(source_revision "${SDK_HOME}/package/system/uci/Makefile")"
UCODE_REF="$(source_revision "${SDK_HOME}/package/utils/ucode/Makefile")"

echo "SDK-selected libubox revision: ${LIBUBOX_REF}"
echo "SDK-selected uci revision: ${UCI_REF}"
echo "SDK-selected ucode revision: ${UCODE_REF}"

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
    -DCMAKE_INSTALL_PREFIX=/opt/ucode-pinned \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_LUA=OFF \
    -DBUILD_EXAMPLES=OFF
cmake --build "${TMP_BUILD_DIR}/libubox/build" -j"${NPROC}"
${SUDO} cmake --install "${TMP_BUILD_DIR}/libubox/build"

echo "=== Building and installing libuci ==="
fetch_pinned_repo "uci" "https://github.com/openwrt/uci.git" "${UCI_REF}" "${TMP_BUILD_DIR}/uci"
cmake -S "${TMP_BUILD_DIR}/uci" -B "${TMP_BUILD_DIR}/uci/build" \
    -DCMAKE_INSTALL_PREFIX=/opt/ucode-pinned \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_LUA=OFF
cmake --build "${TMP_BUILD_DIR}/uci/build" -j"${NPROC}"
${SUDO} cmake --install "${TMP_BUILD_DIR}/uci/build"

echo "=== Building and installing ucode with UCI support ==="
fetch_pinned_repo "ucode" "https://github.com/jow-/ucode.git" "${UCODE_REF}" "${TMP_BUILD_DIR}/ucode"
cmake -S "${TMP_BUILD_DIR}/ucode" -B "${TMP_BUILD_DIR}/ucode/build" \
    -DCMAKE_INSTALL_PREFIX=/opt/ucode-pinned \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_BUILD_TYPE=Release \
    -DUCI_SUPPORT=ON \
    -DUBUS_SUPPORT=OFF \
    -DULOOP_SUPPORT=OFF \
    -DNL80211_SUPPORT=OFF \
    -DRESOLV_SUPPORT=OFF \
    -DEXT_ROOT=/opt/ucode-pinned/lib/ucode
cmake --build "${TMP_BUILD_DIR}/ucode/build" -j"${NPROC}"
${SUDO} cmake --install "${TMP_BUILD_DIR}/ucode/build"
${SUDO} ln -sfn /opt/ucode-pinned/bin/ucode /usr/bin/ucode

echo "=== Verifying ucode and uci module ==="
/opt/ucode-pinned/bin/ucode -v
/opt/ucode-pinned/bin/ucode -e 'import { cursor } from "uci"; print("UCI module loaded successfully\n");'
[ "$(readlink -f /usr/bin/ucode)" = "/opt/ucode-pinned/bin/ucode" ] || {
    echo "::error::The rpcd shebang does not resolve to the SDK-pinned ucode binary" >&2
    exit 1
}

echo "=== Host ucode bootstrap completed successfully ==="
exit 0
