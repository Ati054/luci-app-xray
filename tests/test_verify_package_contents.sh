#!/bin/sh
# Exercise both IPK container layouts accepted by OpenWrt package tooling.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
TMP_ROOT="$(mktemp -d)"

cleanup() {
    primary_rc=$?
    rm -rf "${TMP_ROOT}"
    return "${primary_rc}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

PAYLOAD="${TMP_ROOT}/payload"
COMPONENTS="${TMP_ROOT}/components"
mkdir -p \
    "${PAYLOAD}/usr/share/luci/menu.d" \
    "${PAYLOAD}/usr/share/rpcd/acl.d" \
    "${PAYLOAD}/usr/share/xray" \
    "${PAYLOAD}/www/luci-static/resources/view/xray" \
    "${COMPONENTS}/empty-control"

printf '{}\n' > "${PAYLOAD}/usr/share/luci/menu.d/luci-app-xray-status.json"
printf '{}\n' > "${PAYLOAD}/usr/share/rpcd/acl.d/luci-app-xray-status.json"
printf 'test\n' > "${PAYLOAD}/usr/share/xray/version.txt"
printf "'use strict';\n" > "${PAYLOAD}/www/luci-static/resources/view/xray/status.js"
printf '2.0\n' > "${COMPONENTS}/debian-binary"
tar -C "${PAYLOAD}" -czf "${COMPONENTS}/data.tar.gz" .
tar -C "${COMPONENTS}/empty-control" -czf "${COMPONENTS}/control.tar.gz" .

TAR_IPK="${TMP_ROOT}/luci-app-xray-status-tar.ipk"
tar -C "${COMPONENTS}" -czf "${TAR_IPK}" \
    ./debian-binary ./control.tar.gz ./data.tar.gz
sh "${SCRIPT_DIR}/ci/verify_package_contents.sh" ipk "${TAR_IPK}"

if command -v ar >/dev/null 2>&1; then
    AR_IPK="${TMP_ROOT}/luci-app-xray-status-ar.ipk"
    (
        cd "${COMPONENTS}"
        ar r "${AR_IPK}" debian-binary control.tar.gz data.tar.gz >/dev/null
    )
    sh "${SCRIPT_DIR}/ci/verify_package_contents.sh" ipk "${AR_IPK}"
    echo "PASS: Debian ar IPK container is verified."
fi

echo "PASS: OpenWrt tar IPK container is verified."
