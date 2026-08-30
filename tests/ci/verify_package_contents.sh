#!/bin/sh
# Verify a real built package payload, including executable modes after extraction.

set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "Usage: $0 FORMAT PACKAGE [SDK_APK]" >&2
    exit 2
fi

FORMAT="$1"
PACKAGE="$2"
SDK_APK="${3:-}"

[ -s "${PACKAGE}" ] || {
    echo "ERROR: package is missing or empty: ${PACKAGE}" >&2
    exit 1
}

TMP_DIR="$(mktemp -d)"
cleanup() {
    primary_rc=$?
    if ! rm -rf "${TMP_DIR}"; then
        echo "ERROR: failed to remove package-extraction directory ${TMP_DIR}" >&2
        [ "${primary_rc}" -ne 0 ] && return "${primary_rc}"
        return 1
    fi
    return "${primary_rc}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

case "${FORMAT}" in
    apk)
        [ -x "${SDK_APK}" ] || {
            echo "ERROR: SDK apk is required for APK extraction" >&2
            exit 1
        }
        "${SDK_APK}" --help
        "${SDK_APK}" extract --help
        "${SDK_APK}" --allow-untrusted extract --no-chown --destination "${TMP_DIR}" "${PACKAGE}"
        ;;
    ipk)
        command -v ar >/dev/null 2>&1 || {
            echo "ERROR: ar is required for IPK extraction" >&2
            exit 1
        }
        ar t "${PACKAGE}" | grep -Eq '^data\.tar\.(gz|zst|xz)$' || {
            echo "ERROR: IPK has no supported data archive: ${PACKAGE}" >&2
            exit 1
        }
        DATA_MEMBER="$(ar t "${PACKAGE}" | sed -n '/^data\.tar\./p' | head -n 1)"
        ar p "${PACKAGE}" "${DATA_MEMBER}" > "${TMP_DIR}/${DATA_MEMBER}"
        case "${DATA_MEMBER}" in
            *.gz) tar -C "${TMP_DIR}" -xzf "${TMP_DIR}/${DATA_MEMBER}" ;;
            *.zst) tar -C "${TMP_DIR}" --zstd -xf "${TMP_DIR}/${DATA_MEMBER}" ;;
            *.xz) tar -C "${TMP_DIR}" -xJf "${TMP_DIR}/${DATA_MEMBER}" ;;
        esac
        ;;
    *)
        echo "ERROR: unsupported package format: ${FORMAT}" >&2
        exit 1
        ;;
esac

case "$(basename "${PACKAGE}")" in
    luci-app-xray-status*)
        REQUIRED_PATHS="
            usr/share/luci/menu.d/luci-app-xray-status.json
            usr/share/rpcd/acl.d/luci-app-xray-status.json
            usr/share/xray/version.txt
            www/luci-static/resources/view/xray/status.js
        "
        ;;
    *)
        REQUIRED_PATHS="
            etc/init.d/xray_core
            etc/init.d/xray_profiles
            usr/libexec/rpcd/xray
            usr/libexec/rpcd/xray_profiles
            usr/share/luci/menu.d/luci-app-xray.json
            usr/share/rpcd/acl.d/luci-app-xray.json
            usr/share/xray/gen_config.uc
            usr/share/xray/gen_config.mjs
            usr/share/xray/common/config.mjs
            usr/share/xray/common/stream.mjs
            usr/share/xray/common/tls.mjs
            usr/share/xray/feature/bridge.mjs
            usr/share/xray/feature/dns.mjs
            usr/share/xray/feature/fake_dns.mjs
            usr/share/xray/feature/inbound.mjs
            usr/share/xray/feature/manual_tproxy.mjs
            usr/share/xray/feature/outbound.mjs
            usr/share/xray/feature/system.mjs
            usr/share/xray/protocol/http.mjs
            usr/share/xray/protocol/hysteria.mjs
            usr/share/xray/protocol/shadowsocks.mjs
            usr/share/xray/protocol/socks.mjs
            usr/share/xray/protocol/trojan.mjs
            usr/share/xray/protocol/vless.mjs
            usr/share/xray/protocol/vmess.mjs
            www/luci-static/resources/view/xray/core.js
            www/luci-static/resources/view/xray/profiles.js
        "
        ;;
esac

for required_path in ${REQUIRED_PATHS}; do
    [ -f "${TMP_DIR}/${required_path}" ] || [ -L "${TMP_DIR}/${required_path}" ] || {
        echo "ERROR: package payload is missing ${required_path}" >&2
        exit 1
    }
done

case "$(basename "${PACKAGE}")" in
    luci-app-xray-status*) ;;
    *)
        for executable_path in \
            etc/init.d/xray_core \
            etc/init.d/xray_profiles \
            usr/libexec/rpcd/xray \
            usr/libexec/rpcd/xray_profiles \
            usr/share/xray/gen_config.uc \
            usr/share/xray/default_gateway.uc \
            usr/share/xray/dnsmasq_include.ut \
            usr/share/xray/firewall_include.ut; do
            MODE="$(stat -c '%a' "${TMP_DIR}/${executable_path}")"
            [ "${MODE}" = "755" ] || {
                echo "ERROR: extracted mode for ${executable_path} is ${MODE}, expected 755" >&2
                exit 1
            }
        done
        ;;
esac

echo "PACKAGE_CONTENTS_AND_MODES_OK: $(basename "${PACKAGE}")"
