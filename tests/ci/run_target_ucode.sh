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
CORE_PAYLOAD="${TMP_DIR}/core-payload"
mkdir -p "${ROOT}/etc/apk" "${ROOT}/lib/apk/db" "${ROOT}/var/cache/apk" "${ROOT}/tmp" "${REPO}" "${CORE_PAYLOAD}"
printf 'aarch64_cortex-a53\nall\n' > "${ROOT}/etc/apk/arch"
: > "${ROOT}/etc/apk/world"
find "${BUNDLE_DIR}" -maxdepth 1 -type f -name '*.apk' -exec cp -p '{}' "${REPO}/" ';'
(
    cd "${REPO}"
    "${SDK_APK}" --allow-untrusted mkndx --output packages.adb ./*.apk
)

"${SDK_APK}" \
    --usermode \
    --root "${ROOT}" \
    --arch aarch64_cortex-a53 \
    --allow-untrusted \
    --repositories-file /dev/null \
    --repository "file://${REPO}/packages.adb" \
    add --initdb --no-cache --no-network --no-scripts ucode ucode-mod-fs ucode-mod-uci

"${SDK_APK}" --allow-untrusted extract --no-chown --destination "${CORE_PAYLOAD}" "${CORE_APK}"
cp -a "${CORE_PAYLOAD}/." "${ROOT}/"
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

MODULE_LIST="${TMP_DIR}/modules.list"
IMPORT_WRAPPER="${ROOT}/tmp/import-wrapper.uc"
find "${ROOT}/usr/share/xray" -type f \( -name '*.uc' -o -name '*.mjs' \) -print | sort > "${MODULE_LIST}"
printf '%s\n' "${ROOT}/usr/libexec/rpcd/xray_profiles" >> "${MODULE_LIST}"
sort -o "${MODULE_LIST}" "${MODULE_LIST}"
while IFS= read -r host_module; do
    target_module="${host_module#${ROOT}}"
    compile_source="${target_module}"
    case "${target_module}" in
        *.mjs)
            escaped_module="$(printf '%s' "${target_module}" | sed 's/[\\"]/\\&/g')"
            printf 'import * as module_under_test from "%s";\n' "${escaped_module}" > "${IMPORT_WRAPPER}"
            compile_source="/tmp/import-wrapper.uc"
            ;;
    esac
    : > "${TMP_DIR}/parse.stderr"
    if ! sudo chroot "${ROOT}" /usr/bin/qemu-aarch64-static /usr/bin/ucode \
        -cdynlink=ubus -o /dev/null "${compile_source}" \
        > /dev/null 2> "${TMP_DIR}/parse.stderr"; then
        echo "ERROR: exact target ucode rejected installed module ${target_module}" >&2
        cat "${TMP_DIR}/parse.stderr" >&2
        exit 1
    fi
done < "${MODULE_LIST}"

if ! sudo chroot "${ROOT}" /usr/bin/qemu-aarch64-static /usr/bin/ucode \
    /usr/share/xray/gen_config.uc \
    > "${TMP_DIR}/generated.json" 2> "${TMP_DIR}/entrypoint.stderr"; then
    echo "ERROR: target gen_config.uc execution failed" >&2
    cat "${TMP_DIR}/entrypoint.stderr" >&2
    exit 1
fi
[ ! -s "${TMP_DIR}/entrypoint.stderr" ] || {
    echo "ERROR: target gen_config.uc wrote to stderr" >&2
    cat "${TMP_DIR}/entrypoint.stderr" >&2
    exit 1
}

"${XRAY_BIN}" run -test -config "${TMP_DIR}/generated.json"
echo "OPENWRT_25_12_TARGET_UCODE_OK"
