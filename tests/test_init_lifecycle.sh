#!/bin/sh
# Test suite for xray_core init.d lifecycle isolation and state transitions

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

echo "=== Test Suite: Init Script Lifecycle Isolation & State Transitions ==="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INIT_SCRIPT="${SCRIPT_DIR}/../core/root/etc/init.d/xray_core"
MOCK_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "${MOCK_DIR}"
}
trap cleanup EXIT

# Setup mock environment directories
mkdir -p "${MOCK_DIR}/bin" "${MOCK_DIR}/etc/init.d" "${MOCK_DIR}/var/run" "${MOCK_DIR}/var/etc/xray" "${MOCK_DIR}/tmp/dnsmasq.d" "${MOCK_DIR}/opt/xray/current"

# Mock logger
cat << 'EOF' > "${MOCK_DIR}/bin/logger"
#!/bin/sh
exit 0
EOF
chmod +x "${MOCK_DIR}/bin/logger"

# Mock procd functions
cat << 'EOF' > "${MOCK_DIR}/procd_mock.sh"
procd_open_instance() { :; }
procd_close_instance() { :; }
procd_set_param() { :; }
procd_append_param() { :; }
procd_add_reload_trigger() { echo "trigger: $*" >> "${LOG_FILE}"; }
config_load() { :; }
config_foreach() { :; }
EOF

# Mock firewall and dnsmasq init scripts
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

cat << 'EOF' > "${MOCK_DIR}/bin/ip"
#!/bin/sh
echo "ip $*" >> "${LOG_FILE}"
exit 0
EOF
chmod +x "${MOCK_DIR}/bin/ip"

cat << 'EOF' > "${MOCK_DIR}/bin/utpl"
#!/bin/sh
exit 0
EOF
chmod +x "${MOCK_DIR}/bin/utpl"

cat << 'EOF' > "${MOCK_DIR}/bin/ucode"
#!/bin/sh
echo "{}"
exit 0
EOF
chmod +x "${MOCK_DIR}/bin/ucode"

cat << 'EOF' > "${MOCK_DIR}/opt/xray/current/xray"
#!/bin/sh
exit 0
EOF
chmod +x "${MOCK_DIR}/opt/xray/current/xray"

export PATH="${MOCK_DIR}/bin:${MOCK_DIR}/etc/init.d:${PATH}"
export LOG_FILE="${MOCK_DIR}/commands.log"
export CMD_FIREWALL_RESTART="${MOCK_DIR}/etc/init.d/firewall restart"
export CMD_DNSMASQ_RESTART="${MOCK_DIR}/etc/init.d/dnsmasq restart"
export CMD_IP="${MOCK_DIR}/bin/ip"
export CMD_UTPL="${MOCK_DIR}/bin/utpl"
export CMD_UCODE="${MOCK_DIR}/bin/ucode"
export TPROXY_MARKER="${MOCK_DIR}/var/run/xray_tproxy.active"

# Test case 1: Fresh Reverse-only mode (start_service, stop_service, reload_service, service_triggers)
{
    echo "\nTest Case 1: Fresh reverse-only lifecycle execution"
    cat << 'EOF' > "${MOCK_DIR}/bin/uci"
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
    chmod +x "${MOCK_DIR}/bin/uci"

    rm -f "${LOG_FILE}" "${TPROXY_MARKER}"
    (
        . "${MOCK_DIR}/procd_mock.sh"
        . "${INIT_SCRIPT}"
        start_service
        reload_service
        service_triggers
        stop_service
    )

    FIREWALL_CALLS=$(grep -c "firewall" "${LOG_FILE}" 2>/dev/null || true)
    DNSMASQ_CALLS=$(grep -c "dnsmasq" "${LOG_FILE}" 2>/dev/null || true)
    IP_CALLS=$(grep -c "ip " "${LOG_FILE}" 2>/dev/null || true)
    DHCP_TRIGGERS=$(grep -c "trigger: xray_core dhcp" "${LOG_FILE}" 2>/dev/null || true)

    assert_equal "0" "${FIREWALL_CALLS:-0}" "Fresh reverse-only mode must not call firewall"
    assert_equal "0" "${DNSMASQ_CALLS:-0}" "Fresh reverse-only mode must not call dnsmasq"
    assert_equal "0" "${IP_CALLS:-0}" "Fresh reverse-only mode must not call ip rule/route"
    assert_equal "0" "${DHCP_TRIGGERS:-0}" "Reverse-only mode must not register dhcp reload trigger"
}

# Test case 2: Legacy transparent proxy mode lifecycle
{
    echo "\nTest Case 2: Legacy transparent proxy mode creates marker and calls setup"
    cat << 'EOF' > "${MOCK_DIR}/bin/uci"
#!/bin/sh
case "$*" in
    *"reverse_only"*) echo "0" ;;
    *"transparent_proxy_enable"*) echo "1" ;;
    *"xray_bin"*) echo "/opt/xray/current/xray" ;;
    *) echo "" ;;
esac
exit 0
EOF
    chmod +x "${MOCK_DIR}/bin/uci"

    rm -f "${LOG_FILE}" "${TPROXY_MARKER}"
    (
        . "${MOCK_DIR}/procd_mock.sh"
        . "${INIT_SCRIPT}"
        start_service
        service_triggers
    )

    FIREWALL_CALLS=$(grep -c "firewall" "${LOG_FILE}" 2>/dev/null || true)
    DNSMASQ_CALLS=$(grep -c "dnsmasq" "${LOG_FILE}" 2>/dev/null || true)
    DHCP_TRIGGERS=$(grep -c "trigger: xray_core dhcp" "${LOG_FILE}" 2>/dev/null || true)

    assert_equal "1" "$((FIREWALL_CALLS > 0))" "Legacy transparent proxy mode must invoke firewall"
    assert_equal "1" "$((DNSMASQ_CALLS > 0))" "Legacy transparent proxy mode must invoke dnsmasq"
    assert_equal "1" "$((DHCP_TRIGGERS > 0))" "Legacy transparent proxy mode must register dhcp trigger"
    assert_equal "1" "$([ -f "${TPROXY_MARKER}" ] && echo 1 || echo 0)" "Legacy transparent proxy mode must create active marker file"
}

# Test case 3: State transition from Active Legacy to Reverse-only
{
    echo "\nTest Case 3: Transition from active transparent proxy to reverse-only cleans artifacts once"
    # Create active marker and dummy artifacts
    touch "${TPROXY_MARKER}"
    touch "${MOCK_DIR}/tmp/dnsmasq.d/xray.conf"
    touch "${MOCK_DIR}/var/etc/xray/01_firewall_include.nft"

    # Switch UCI to reverse_only=1
    cat << 'EOF' > "${MOCK_DIR}/bin/uci"
#!/bin/sh
case "$*" in
    *"reverse_only"*) echo "1" ;;
    *"transparent_proxy_enable"*) echo "0" ;;
    *"xray_bin"*) echo "/opt/xray/current/xray" ;;
    *) echo "" ;;
esac
exit 0
EOF
    chmod +x "${MOCK_DIR}/bin/uci"

    rm -f "${LOG_FILE}"
    (
        . "${MOCK_DIR}/procd_mock.sh"
        . "${INIT_SCRIPT}"
        # Start service in reverse-only mode after switch
        start_service
    )

    # First execution should have cleaned up the legacy artifacts once
    CLEANUP_FIREWALL=$(grep -c "firewall" "${LOG_FILE}" 2>/dev/null || true)
    CLEANUP_DNSMASQ=$(grep -c "dnsmasq" "${LOG_FILE}" 2>/dev/null || true)
    assert_equal "1" "$((CLEANUP_FIREWALL > 0))" "Transition must flush firewall once"
    assert_equal "1" "$((CLEANUP_DNSMASQ > 0))" "Transition must flush dnsmasq once"
    assert_equal "0" "$([ -f "${TPROXY_MARKER}" ] && echo 1 || echo 0)" "Transition must remove active marker file"

    # Subsequent stop/reload in reverse-only mode must NOT call firewall or dnsmasq
    rm -f "${LOG_FILE}"
    (
        . "${MOCK_DIR}/procd_mock.sh"
        . "${INIT_SCRIPT}"
        stop_service
        reload_service
    )
    LATER_FIREWALL=$(grep -c "firewall" "${LOG_FILE}" 2>/dev/null || true)
    LATER_DNSMASQ=$(grep -c "dnsmasq" "${LOG_FILE}" 2>/dev/null || true)
    assert_equal "0" "${LATER_FIREWALL:-0}" "Subsequent reverse-only stop/reload must not call firewall"
    assert_equal "0" "${LATER_DNSMASQ:-0}" "Subsequent reverse-only stop/reload must not call dnsmasq"
}

# Test case 4: Migration cleanup of pre-marker legacy artifacts
{
    echo "\nTest Case 4: Migration cleans unmanaged legacy artifacts on reverse-only start"
    rm -f "${TPROXY_MARKER}"
    touch "${MOCK_DIR}/tmp/dnsmasq.d/xray.conf"

    cat << 'EOF' > "${MOCK_DIR}/bin/uci"
#!/bin/sh
case "$*" in
    *"reverse_only"*) echo "1" ;;
    *"transparent_proxy_enable"*) echo "0" ;;
    *"xray_bin"*) echo "/opt/xray/current/xray" ;;
    *) echo "" ;;
esac
exit 0
EOF
    chmod +x "${MOCK_DIR}/bin/uci"

    rm -f "${LOG_FILE}"
    (
        . "${MOCK_DIR}/procd_mock.sh"
        . "${INIT_SCRIPT}"
        start_service
    )

    MIGRATION_CLEANUP=$(grep -c "dnsmasq" "${LOG_FILE}" 2>/dev/null || true)
    assert_equal "1" "$((MIGRATION_CLEANUP > 0))" "Migration must detect unmanaged dnsmasq artifact and flush"
}

echo "\nSummary: ${PASSED} passed, ${FAILED} failed"
if [ "${FAILED}" -gt 0 ]; then
    exit 1
fi
exit 0
