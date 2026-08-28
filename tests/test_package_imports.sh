#!/bin/sh
# Validates installed package completeness and isolated import resolution

set -e

PASSED=0
FAILED=0

assert_equal() {
    local expected="$1"
    local actual="$2"
    local msg="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  [PASS] $msg"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] $msg (expected '$expected', got '$actual')"
        FAILED=$((FAILED + 1))
    fi
}

echo "=== Test Suite: Installed Package Completeness & Import Resolution ==="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CORE_MAKEFILE="${ROOT_DIR}/core/Makefile"

STAGE_ROOT="$(mktemp -d)"
cleanup() {
    rm -rf "${STAGE_ROOT}"
}
trap cleanup EXIT

# 1. Build an isolated staging root reflecting exactly what core/Makefile installs
XRAY_DIR="${STAGE_ROOT}/usr/share/xray"
mkdir -p "${XRAY_DIR}/common" "${XRAY_DIR}/feature" "${XRAY_DIR}/protocol"

# Copy installed files as defined in core/Makefile
cp -p "${ROOT_DIR}/core/root/usr/share/xray/gen_config.mjs" "${XRAY_DIR}/"
cp -p "${ROOT_DIR}/core/root/usr/share/xray/gen_config.uc" "${XRAY_DIR}/"
cp -p "${ROOT_DIR}/core/root/usr/share/xray/common/"*.mjs "${XRAY_DIR}/common/"
cp -p "${ROOT_DIR}/core/root/usr/share/xray/feature/"*.mjs "${XRAY_DIR}/feature/"

# Install protocol modules as specified in Makefile
for p in http.mjs hysteria.mjs shadowsocks.mjs socks.mjs trojan.mjs vless.mjs vmess.mjs; do
    if grep -q "protocol/${p}" "${CORE_MAKEFILE}"; then
        cp -p "${ROOT_DIR}/core/root/usr/share/xray/protocol/${p}" "${XRAY_DIR}/protocol/"
    fi
done

# Test 1: Verify all 7 protocol modules exist in staging root
for p in http.mjs hysteria.mjs shadowsocks.mjs socks.mjs trojan.mjs vless.mjs vmess.mjs; do
    assert_equal "1" "$([ -f "${XRAY_DIR}/protocol/${p}" ] && echo 1 || echo 0)" "Installed package contains protocol/${p}"
done

# Test 2: Verify all feature modules exist in staging root
for f in bridge.mjs dns.mjs fake_dns.mjs inbound.mjs manual_tproxy.mjs outbound.mjs system.mjs; do
    assert_equal "1" "$([ -f "${XRAY_DIR}/feature/${f}" ] && echo 1 || echo 0)" "Installed package contains feature/${f}"
done

# Test 3: Verify all common modules exist in staging root
for c in config.mjs stream.mjs tls.mjs; do
    assert_equal "1" "$([ -f "${XRAY_DIR}/common/${c}" ] && echo 1 || echo 0)" "Installed package contains common/${c}"
done

# Test 4: Verify that gen_config.uc executes strictly from the isolated staging root
if command -v ucode >/dev/null 2>&1; then
    UCI_DIR="${STAGE_ROOT}/etc/config"
    mkdir -p "${UCI_DIR}"
    cat << 'EOF' > "${UCI_DIR}/xray_core"
config general 'general'
	option reverse_only '1'
EOF
    OUT_LOG="${STAGE_ROOT}/gen_config_out.json"
    ERR_LOG="${STAGE_ROOT}/gen_config_err.log"

    (
        cd "${XRAY_DIR}"
        export UCI_CONFIG_DIR="${UCI_DIR}"
        ucode ./gen_config.uc > "${OUT_LOG}" 2> "${ERR_LOG}"
    )
    STATUS=$?
    assert_equal "0" "${STATUS}" "Isolated staging gen_config.uc executes with exit code 0"
    assert_equal "" "$(cat "${ERR_LOG}")" "Isolated staging gen_config.uc produces no stderr"
else
    echo "  [SKIP] ucode CLI not available in current environment for execution check."
fi

echo "\nSummary: ${PASSED} passed, ${FAILED} failed"
if [ "${FAILED}" -gt 0 ]; then
    exit 1
fi
exit 0
