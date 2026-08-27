#!/bin/sh
# Test suite for xray_core init.d lifecycle isolation, state transitions, and migration

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
mkdir -p "${MOCK_DIR}/bin" "${MOCK_DIR}/etc/init.d" "${MOCK_DIR}/etc/nftables.d" "${MOCK_DIR}/var/run" "${MOCK_DIR}/var/etc/xray" "${MOCK_DIR}/tmp/dnsmasq.d" "${MOCK_DIR}/opt/xray/current"

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

# Mock IP binary safely referencing MOCK_DIR
cat << EOF > "${MOCK_DIR}/bin/ip"
#!/bin/sh
echo "ip \$*" >> "${MOCK_DIR}/commands.log"
if [ "\$1" = "rule" ] && [ "\$2" = "show" ]; then
    cat "${MOCK_DIR}/ip_rules.txt" 2>/dev/null || true
elif [ "\$1" = "-6" ] && [ "\$2" = "rule" ] && [ "\$3" = "show" ]; then
    cat "${MOCK_DIR}/ip6_rules.txt" 2>/dev/null || true
fi
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
export XRAY_RUNTIME_DIR="${MOCK_DIR}/var/etc/xray"
export XRAY_RUN_DIR="${MOCK_DIR}/var/run"
export XRAY_NFTABLES_DIR="${MOCK_DIR}/etc/nftables.d"
export DNSMASQ_RUNTIME_ROOT="${MOCK_DIR}/tmp"
export FIREWALL_INIT="${MOCK_DIR}/etc/init.d/firewall"
export DNSMASQ_INIT="${MOCK_DIR}/etc/init.d/dnsmasq"
export IP_BIN="${MOCK_DIR}/bin/ip"
export UCODE_BIN="${MOCK_DIR}/bin/ucode"
export UTPL_BIN="${MOCK_DIR}/bin/utpl"
export TPROXY_MARKER="${MOCK_DIR}/var/run/xray_tproxy.active"

# Helper to source init script and then override framework wrappers
run_init_lifecycle() {
    (
        . "${MOCK_DIR}/procd_mock.sh"
        . "${INIT_SCRIPT}"
        # Override service framework wrappers after sourcing production script
        service_framework_stop() { echo "framework_stop" >> "${LOG_FILE}"; stop_service; }
        service_framework_start() { echo "framework_start" >> "${LOG_FILE}"; start_service; }
        "$@"
    )
}

# Test case 1: Fresh Reverse-only mode (start_service, stop_service, reload_service, service_triggers)
{
    echo "\nTest Case 1: Fresh reverse-only lifecycle execution"
    cat << EOF > "${MOCK_DIR}/bin/uci"
#!/bin/sh
case "\$*" in
    *"reverse_only"*) echo "1" ;;
    *"transparent_proxy_enable"*) echo "0" ;;
    *"custom_config"*) echo "" ;;
    *"xray_bin"*) echo "${MOCK_DIR}/opt/xray/current/xray" ;;
    *"xray_location_asset"*) echo "${MOCK_DIR}/opt/xray/current" ;;
    *) echo "" ;;
esac
exit 0
EOF
    chmod +x "${MOCK_DIR}/bin/uci"

    rm -f "${LOG_FILE}" "${TPROXY_MARKER}" "${MOCK_DIR}/ip_rules.txt" "${MOCK_DIR}/ip6_rules.txt"

    START_EXIT_CODE=0
    run_init_lifecycle start_service || START_EXIT_CODE=$?
    assert_equal "0" "${START_EXIT_CODE}" "start_service with empty custom_config must succeed (exit 0)"

    run_init_lifecycle reload_service
    run_init_lifecycle service_triggers
    run_init_lifecycle stop_service

    FIREWALL_CALLS=$(grep -c "firewall" "${LOG_FILE}" 2>/dev/null || true)
    DNSMASQ_CALLS=$(grep -c "dnsmasq" "${LOG_FILE}" 2>/dev/null || true)
    IP_MUTATIONS=$(grep -E -c "ip (-6 )?(rule|route) (add|del)" "${LOG_FILE}" 2>/dev/null || true)
    DHCP_TRIGGERS=$(grep -c "trigger: xray_core dhcp" "${LOG_FILE}" 2>/dev/null || true)

    assert_equal "0" "${FIREWALL_CALLS:-0}" "Fresh reverse-only mode must not call firewall"
    assert_equal "0" "${DNSMASQ_CALLS:-0}" "Fresh reverse-only mode must not call dnsmasq"
    assert_equal "0" "${IP_MUTATIONS:-0}" "Fresh reverse-only mode must not mutate ip rules or routes"
    assert_equal "0" "${DHCP_TRIGGERS:-0}" "Reverse-only mode must not register dhcp reload trigger"
}

# Test case 2: Legacy transparent proxy mode lifecycle
{
    echo "\nTest Case 2: Legacy transparent proxy mode creates marker and calls setup"
    cat << EOF > "${MOCK_DIR}/bin/uci"
#!/bin/sh
case "\$*" in
    *"reverse_only"*) echo "0" ;;
    *"transparent_proxy_enable"*) echo "1" ;;
    *"xray_bin"*) echo "${MOCK_DIR}/opt/xray/current/xray" ;;
    *) echo "" ;;
esac
exit 0
EOF
    chmod +x "${MOCK_DIR}/bin/uci"

    rm -f "${LOG_FILE}" "${TPROXY_MARKER}"
    run_init_lifecycle start_service
    run_init_lifecycle service_triggers

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
    # Create active marker and dummy artifacts under mock root
    touch "${TPROXY_MARKER}"
    touch "${MOCK_DIR}/tmp/dnsmasq.d/xray.conf"
    touch "${MOCK_DIR}/var/etc/xray/01_firewall_include.nft"

    # Switch UCI to reverse_only=1
    cat << EOF > "${MOCK_DIR}/bin/uci"
#!/bin/sh
case "\$*" in
    *"reverse_only"*) echo "1" ;;
    *"transparent_proxy_enable"*) echo "0" ;;
    *"xray_bin"*) echo "${MOCK_DIR}/opt/xray/current/xray" ;;
    *) echo "" ;;
esac
exit 0
EOF
    chmod +x "${MOCK_DIR}/bin/uci"

    rm -f "${LOG_FILE}"
    run_init_lifecycle start_service

    # First execution should have cleaned up the legacy artifacts once
    CLEANUP_FIREWALL=$(grep -c "firewall" "${LOG_FILE}" 2>/dev/null || true)
    CLEANUP_DNSMASQ=$(grep -c "dnsmasq" "${LOG_FILE}" 2>/dev/null || true)
    assert_equal "1" "$((CLEANUP_FIREWALL > 0))" "Transition must flush firewall once"
    assert_equal "1" "$((CLEANUP_DNSMASQ > 0))" "Transition must flush dnsmasq once"
    assert_equal "0" "$([ -f "${TPROXY_MARKER}" ] && echo 1 || echo 0)" "Transition must remove active marker file"

    # Subsequent stop/reload in reverse-only mode must NOT call firewall or dnsmasq
    rm -f "${LOG_FILE}"
    run_init_lifecycle stop_service
    run_init_lifecycle reload_service
    LATER_FIREWALL=$(grep -c "firewall" "${LOG_FILE}" 2>/dev/null || true)
    LATER_DNSMASQ=$(grep -c "dnsmasq" "${LOG_FILE}" 2>/dev/null || true)
    assert_equal "0" "${LATER_FIREWALL:-0}" "Subsequent reverse-only stop/reload must not call firewall"
    assert_equal "0" "${LATER_DNSMASQ:-0}" "Subsequent reverse-only stop/reload must not call dnsmasq"
}

# Test case 4A: Unrelated lookup 251 rule does NOT trigger cleanup
{
    echo "\nTest Case 4A: Unrelated lookup 251 rule does not trigger cleanup"
    rm -f "${TPROXY_MARKER}" "${LOG_FILE}"
    rm -f "${MOCK_DIR}/tmp/dnsmasq.d/xray.conf" "${MOCK_DIR}/var/etc/xray/01_firewall_include.nft"

    # Set up unrelated rule in ip_rules.txt without Xray fwmark
    echo "100: from all to 10.0.0.0/8 lookup 251" > "${MOCK_DIR}/ip_rules.txt"

    cat << EOF > "${MOCK_DIR}/bin/uci"
#!/bin/sh
case "\$*" in
    *"reverse_only"*) echo "1" ;;
    *"transparent_proxy_enable"*) echo "0" ;;
    *"xray_bin"*) echo "${MOCK_DIR}/opt/xray/current/xray" ;;
    *) echo "" ;;
esac
exit 0
EOF
    chmod +x "${MOCK_DIR}/bin/uci"

    run_init_lifecycle start_service
    CLEANUP_FIREWALL=$(grep -c "firewall" "${LOG_FILE}" 2>/dev/null || true)
    CLEANUP_DNSMASQ=$(grep -c "dnsmasq" "${LOG_FILE}" 2>/dev/null || true)
    assert_equal "0" "${CLEANUP_FIREWALL:-0}" "Unrelated table 251 rule must not trigger firewall flush"
    assert_equal "0" "${DNSMASQ_CALLS:-0}" "Unrelated table 251 rule must not trigger dnsmasq flush"
}

# Test case 4B: Exact Xray signature triggers migration cleanup
{
    echo "\nTest Case 4B: Exact Xray fwmark signature triggers migration cleanup once"
    rm -f "${TPROXY_MARKER}" "${LOG_FILE}"
    rm -f "${MOCK_DIR}/tmp/dnsmasq.d/xray.conf" "${MOCK_DIR}/var/etc/xray/01_firewall_include.nft"

    # Set up exact Xray rule in ip_rules.txt
    echo "100: from all fwmark 0xfb lookup 251" > "${MOCK_DIR}/ip_rules.txt"

    cat << EOF > "${MOCK_DIR}/bin/uci"
#!/bin/sh
case "\$*" in
    *"reverse_only"*) echo "1" ;;
    *"transparent_proxy_enable"*) echo "0" ;;
    *"xray_bin"*) echo "${MOCK_DIR}/opt/xray/current/xray" ;;
    *) echo "" ;;
esac
exit 0
EOF
    chmod +x "${MOCK_DIR}/bin/uci"

    run_init_lifecycle start_service
    CLEANUP_FIREWALL=$(grep -c "firewall" "${LOG_FILE}" 2>/dev/null || true)
    CLEANUP_DNSMASQ=$(grep -c "dnsmasq" "${LOG_FILE}" 2>/dev/null || true)
    assert_equal "1" "$((CLEANUP_FIREWALL > 0))" "Exact Xray signature must trigger firewall cleanup"
    assert_equal "1" "$((CLEANUP_DNSMASQ > 0))" "Exact Xray signature must trigger dnsmasq cleanup"
}

echo "\nSummary: ${PASSED} passed, ${FAILED} failed"
if [ "${FAILED}" -gt 0 ]; then
    exit 1
fi
exit 0
