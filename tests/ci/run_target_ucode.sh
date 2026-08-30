#!/bin/sh
# Execute installed modules under the official OpenWrt 25.12.5 aarch64 ucode.

set -eu

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 SDK_APK BUNDLE_DIR CORE_APK XRAY_BIN" >&2
    exit 2
fi

SDK_APK="$1"
BUNDLE_DIR="$2"
CORE_APK="$3"
XRAY_BIN="$4"
QEMU_BIN=""
if command -v qemu-aarch64-static >/dev/null 2>&1; then
    QEMU_BIN="$(command -v qemu-aarch64-static)"
fi

[ -x "${SDK_APK}" ] && [ -x "${QEMU_BIN}" ] && [ -x "${XRAY_BIN}" ] || {
    echo "ERROR: SDK apk, qemu-aarch64-static, and Xray are required" >&2
    exit 1
}

TMP_DIR="$(mktemp -d)"
cleanup() {
    primary_rc=$?
    if ! rm -rf "${TMP_DIR}"; then
        echo "ERROR: failed to remove target-ucode temporary root ${TMP_DIR}" >&2
        [ "${primary_rc}" -ne 0 ] && return "${primary_rc}"
        return 1
    fi
    return "${primary_rc}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ROOT="${TMP_DIR}/root"
REPO="${TMP_DIR}/repo"
mkdir -p "${ROOT}/etc/apk" "${ROOT}/lib/apk/db" "${ROOT}/var/cache/apk" "${ROOT}/tmp" "${REPO}"
printf 'aarch64_cortex-a53\nall\n' > "${ROOT}/etc/apk/arch"
: > "${ROOT}/etc/apk/world"
find "${BUNDLE_DIR}" -maxdepth 1 -type f -name '*.apk' -exec cp -p '{}' "${REPO}/" ';'
(
    cd "${REPO}"
    "${SDK_APK}" --allow-untrusted mkndx --output packages.adb ./*.apk
)

"${SDK_APK}" \
    --root "${ROOT}" \
    --arch aarch64_cortex-a53 \
    --allow-untrusted \
    --repositories-file /dev/null \
    --repository "file://${REPO}/packages.adb" \
    add --initdb --no-cache --no-network --no-scripts ucode ucode-mod-fs ucode-mod-uci

"${SDK_APK}" --allow-untrusted extract --no-chown --destination "${ROOT}" "${CORE_APK}"
mkdir -p "${ROOT}/usr/bin" "${ROOT}/proc" "${ROOT}/dev" "${ROOT}/etc/config"
cp -p "${QEMU_BIN}" "${ROOT}/usr/bin/qemu-aarch64-static"
sudo mknod "${ROOT}/dev/null" c 1 3
sudo chmod 0666 "${ROOT}/dev/null"
cat > "${ROOT}/etc/config/xray_core" <<'EOF'
config general 'general'
	option reverse_only '1'
	option transparent_proxy_enable '0'
	option xray_bin '/opt/xray/current/xray'
	option xray_location_asset '/opt/xray/current'
	option loglevel 'warning'
EOF

: > "${TMP_DIR}/parse.stderr"
find "${ROOT}/usr/share/xray" -type f \( -name '*.uc' -o -name '*.mjs' \) -print | sort | while IFS= read -r host_module; do
    target_module="${host_module#${ROOT}}"
    sudo chroot "${ROOT}" /usr/bin/qemu-aarch64-static /usr/bin/ucode -c "${target_module}" 2>> "${TMP_DIR}/parse.stderr"
done
sudo chroot "${ROOT}" /usr/bin/qemu-aarch64-static /usr/bin/ucode -c \
    /usr/libexec/rpcd/xray_profiles 2>> "${TMP_DIR}/parse.stderr"
[ ! -s "${TMP_DIR}/parse.stderr" ] || {
    echo "ERROR: exact target ucode rejected an installed module" >&2
    cat "${TMP_DIR}/parse.stderr" >&2
    exit 1
}

sudo chroot "${ROOT}" /usr/bin/qemu-aarch64-static /usr/bin/ucode /usr/share/xray/gen_config.uc \
    > "${TMP_DIR}/generated.json" 2> "${TMP_DIR}/entrypoint.stderr"
[ ! -s "${TMP_DIR}/entrypoint.stderr" ] || {
    echo "ERROR: target gen_config.uc wrote to stderr" >&2
    cat "${TMP_DIR}/entrypoint.stderr" >&2
    exit 1
}

"${XRAY_BIN}" run -test -config "${TMP_DIR}/generated.json"
echo "OPENWRT_25_12_TARGET_UCODE_OK"
