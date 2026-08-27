#!/bin/sh
# Test suite for xray_core init.d lifecycle isolation

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

echo "=== Test Suite: Init Script Lifecycle Isolation ==="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INIT_SCRIPT="${SCRIPT_DIR}/../core/root/etc/init.d/xray_core"
MOCK_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "${MOCK_DIR}"
}
trap cleanup EXIT

# Create mocks for logger, procd, ucode, utpl, ip, iptables, nft, dnsmasq, firewall
cat << 'EOF' > "${MOCK_DIR}/logger"
#!/bin/sh
exit 0
EOF
chmod +x "${MOCK_DIR}/logger"

cat << 'EOF' > "${MOCK_DIR}/service"
#!/bin/sh
echo "service $*" >> "${LOG_FILE}"
exit 0
EOF
chmod +x "${MOCK_DIR}/service"

mkdir -p "${MOCK_DIR}/etc/init.d"

cat << 'EOF' > "${MOCK_DIR}/etc/init.d/firewall"
#!/bin/sh
echo "firewall $*" >> "${LOG_FILE}"
exit 0
EOF
chmod +x "${MOCK_DIR}/etc/init.d/firewall"

cat << 'EOF' > "${MOCK_DIR}/etc/init.d/dnsmasq"
#!/bin/sh
echo "dnsmasq $*" >> "${LOG_FILE}"
exit 0
EOF
chmod +x "${MOCK_DIR}/etc/init.d/dnsmasq"

cat << 'EOF' > "${MOCK_DIR}/ip"
#!/bin/sh
echo "ip $*" >> "${LOG_FILE}"
exit 0
EOF
chmod +x "${MOCK_DIR}/ip"

cat << 'EOF' > "${MOCK_DIR}/ip6"
#!/bin/sh
echo "ip6 $*" >> "${LOG_FILE}"
exit 0
EOF
chmod +x "${MOCK_DIR}/ip6"

cat << 'EOF' > "${MOCK_DIR}/utpl"
#!/bin/sh
exit 0
EOF
chmod +x "${MOCK_DIR}/utpl"

cat << 'EOF' > "${MOCK_DIR}/ucode"
#!/bin/sh
echo "{}"
exit 0
EOF
chmod +x "${MOCK_DIR}/ucode"

export PATH="${MOCK_DIR}:${PATH}"
export LOG_FILE="${MOCK_DIR}/commands.log"

# Test case 1: Reverse-only mode (reverse_only=1)
{
    echo "\nTest Case 1: Reverse-only mode lifecycle"
    cat << 'EOF' > "${MOCK_DIR}/uci"
#!/bin/sh
case "$*" in
    *"reverse_only"*) echo "1" ;;
    *"transparent_proxy_enable"*) echo "0" ;;
    *"xray_bin"*) echo "/opt/xray/current/xray" ;;
    *"xray_location_asset"*) echo "/opt/xray/current" ;;
    *) echo "" ;;
esac
exit 0
EOF
    chmod +x "${MOCK_DIR}/uci"

    mkdir -p "${MOCK_DIR}/opt/xray/current"
    cat << 'EOF' > "${MOCK_DIR}/opt/xray/current/xray"
#!/bin/sh
exit 0
EOF
    chmod +x "${MOCK_DIR}/opt/xray/current/xray"

    # Source functions and test start/stop/reload paths
    rm -f "${LOG_FILE}"
    (
        . "${INIT_SCRIPT}"
        # Execute lifecycle functions directly
        create_when_enable
        flush_when_disable
    )

    FIREWALL_CALLS=$(grep -c "firewall" "${LOG_FILE}" 2>/dev/null || true)
    DNSMASQ_CALLS=$(grep -c "dnsmasq" "${LOG_FILE}" 2>/dev/null || true)
    IP_CALLS=$(grep -c "ip " "${LOG_FILE}" 2>/dev/null || true)

    assert_equal "0" "${FIREWALL_CALLS:-0}" "Reverse-only mode must not call firewall on start or stop"
    assert_equal "0" "${DNSMASQ_CALLS:-0}" "Reverse-only mode must not call dnsmasq on start or stop"
    assert_equal "0" "${IP_CALLS:-0}" "Reverse-only mode must not invoke ip rules/routes"
}

# Test case 2: Legacy transparent proxy mode (reverse_only=0, transparent_proxy_enable=1)
{
    echo "\nTest Case 2: Legacy transparent proxy mode calls firewall and dnsmasq"
    cat << 'EOF' > "${MOCK_DIR}/uci"
#!/bin/sh
case "$*" in
    *"reverse_only"*) echo "0" ;;
    *"transparent_proxy_enable"*) echo "1" ;;
    *"xray_bin"*) echo "/usr/bin/xray" ;;
    *) echo "" ;;
esac
exit 0
EOF
    chmod +x "${MOCK_DIR}/uci"

    rm -f "${LOG_FILE}"
    (
        export PATH="${MOCK_DIR}/etc/init.d:${MOCK_DIR}:${PATH}"
        . "${INIT_SCRIPT}"
        create_when_enable
        flush_when_disable
    )

    FIREWALL_CALLS=$(grep -c "firewall" "${LOG_FILE}" 2>/dev/null || true)
    DNSMASQ_CALLS=$(grep -c "dnsmasq" "${LOG_FILE}" 2>/dev/null || true)

    assert_equal "1" "$((FIREWALL_CALLS > 0))" "Legacy transparent proxy mode must invoke firewall"
    assert_equal "1" "$((DNSMASQ_CALLS > 0))" "Legacy transparent proxy mode must invoke dnsmasq"
}

echo "\nSummary: ${PASSED} passed, ${FAILED} failed"
if [ "${FAILED}" -gt 0 ]; then
    exit 1
fi
exit 0
