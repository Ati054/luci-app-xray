#!/bin/sh
# Unit & Integration tests for Xray Reverse Profiles procd service, rpcd backend, and lifecycle invariants

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

assert_match() {
    local pattern="$1"
    local text="$2"
    local msg="$3"
    case "${pattern}" in
        '"ok":true') pattern='"ok"[[:space:]]*:[[:space:]]*true' ;;
        '"ok":false') pattern='"ok"[[:space:]]*:[[:space:]]*false' ;;
        '"ok":') pattern='"ok"[[:space:]]*:' ;;
    esac
    if echo "$text" | grep -E -q "$pattern"; then
        echo "  [PASS] $msg"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] $msg (pattern '$pattern' not found in '$text')"
        FAILED=$((FAILED + 1))
    fi
}

echo "=== Test Suite: Xray JSON Reverse Profiles & Lifecycle Invariants ==="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RPCD_SOURCE="${ROOT_DIR}/core/root/usr/libexec/rpcd/xray_profiles"
UCODE_BIN="${UCODE_BIN:-ucode}"
INIT_PROFILES="${ROOT_DIR}/core/root/etc/init.d/xray_profiles"
FIXTURE_A="${SCRIPT_DIR}/fixtures/profile-smoke-a.json"
FIXTURE_B="${SCRIPT_DIR}/fixtures/profile-smoke-b.json"
FIXTURE_INV="${SCRIPT_DIR}/fixtures/profile-invalid.json"

MOCK_ROOT="$(mktemp -d)"
export TEST_RPCD_SOURCE="${RPCD_SOURCE}"
export TEST_UCODE_BIN="${UCODE_BIN}"
RPCD_BACKEND="${MOCK_ROOT}/xray_profiles-test-runner"
cat > "${RPCD_BACKEND}" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--mock-dir" ]; then
    export XRAY_PROFILES_MOCK_DIR="${2:?missing mock directory}"
    shift 2
fi
exec "${TEST_UCODE_BIN}" "${TEST_RPCD_SOURCE}" "$@"
EOF
chmod 0755 "${RPCD_BACKEND}"
cleanup() {
    # Terminate any lingering background mock processes if running
    if [ -d "${MOCK_ROOT}/pids" ]; then
        for p in "${MOCK_ROOT}/pids/"*; do
            if [ -f "$p" ]; then
                kill "$(cat "$p" 2>/dev/null)" 2>/dev/null || true
            fi
        done
    fi
    rm -rf "${MOCK_ROOT}"
}
trap cleanup EXIT

# Set up mocked environment directories
export PROFILES_DIR="${MOCK_ROOT}/opt/xray/profiles"
export UCI_CONFIG_DIR="${MOCK_ROOT}/etc/config"
export XRAY_BIN_MOCK="${MOCK_ROOT}/xray"
mkdir -p "${PROFILES_DIR}" "${UCI_CONFIG_DIR}" "${MOCK_ROOT}/pids"

# Create mock xray validation binary
cat << 'EOF' > "${XRAY_BIN_MOCK}"
#!/bin/sh
if [ "$1" = "version" ]; then
    echo "Xray 26.7.28 (mock) (OpenWrt test)"
    exit 0
fi
if [ "$1" = "run" ] && [ "$2" = "-test" ]; then
    CONFIG_FILE="$4"
    MOCK_XRAY_MODE="$(cat "${0%/*}/xray-mode" 2>/dev/null || true)"
    if [ "$MOCK_XRAY_MODE" = "fail_23" ]; then
        echo "Failed to start: invalid config" >&2
        exit 23
    fi
    if [ "$MOCK_XRAY_MODE" = "success_harmless" ]; then
        echo "Configuration OK - harmless warning notice"
        exit 0
    fi
    if [ "$MOCK_XRAY_MODE" = "success_silent" ]; then
        exit 0
    fi
    if grep -q "dokodemo" "${CONFIG_FILE}" || grep -q "socks" "${CONFIG_FILE}" || grep -q "syntax_error" "${CONFIG_FILE}"; then
        echo "Failed to start: listening inbound or invalid syntax" >&2
        exit 1
    fi
    exit 0
fi
if [ "$1" = "run" ]; then
    CONFIG_FILE="$3"
    [ "$2" = "-config" ] && CONFIG_FILE="$3"
    if [ "$MOCK_XRAY_CRASH" = "immediate" ]; then
        sleep 0.05
        exit 1
    fi
    while true; do
        sleep 100
    done
    exit 0
fi
exit 0
EOF
chmod +x "${XRAY_BIN_MOCK}"

# Export XRAY_BIN for test runner
export XRAY_BIN="${XRAY_BIN_MOCK}"

# Initialize empty UCI config
cat << 'EOF' > "${UCI_CONFIG_DIR}/xray_core"
config general 'general'
	option reverse_only '1'
EOF

# -------------------------------------------------------------------
# Test Group 1: Process Runner Exit-Status Semantics
# -------------------------------------------------------------------
echo "\n--- Test Group: Exact Exit-Status Validation ---"
CONTENT_A="$(cat "${FIXTURE_A}")"

# 1. Nonzero exit with "Failed to start" and exit code 23 (no word "error") must be rejected
printf '%s\n' 'fail_23' > "${MOCK_ROOT}/xray-mode"
RES_FAIL_23="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call validate "{\"content\":\"$(echo "${CONTENT_A}" | tr -d '\n\r' | sed 's/"/\\"/g')\"}" 2>&1 || true)"
assert_match '"ok":false' "${RES_FAIL_23}" "Test 1: Nonzero exit with 'Failed to start' (code 23) is rejected"

# 2. Exit 0 with harmless output passes
printf '%s\n' 'success_harmless' > "${MOCK_ROOT}/xray-mode"
RES_PASS_HARMLESS="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call validate "{\"content\":\"$(echo "${CONTENT_A}" | tr -d '\n\r' | sed 's/"/\\"/g')\"}" 2>&1 || true)"
assert_match '"ok":true' "${RES_PASS_HARMLESS}" "Test 2: Exit 0 with harmless output passes validation"

# 3. Exit 0 with silent output passes
printf '%s\n' 'success_silent' > "${MOCK_ROOT}/xray-mode"
RES_PASS_SILENT="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call validate "{\"content\":\"$(echo "${CONTENT_A}" | tr -d '\n\r' | sed 's/"/\\"/g')\"}" 2>&1 || true)"
assert_match '"ok":true' "${RES_PASS_SILENT}" "Test 3: Exit 0 with silent output passes validation"

# 4. Missing Xray binary is a hard failure
MISSING_BIN_MOCK_ROOT="${MOCK_ROOT}/no_bin"
mkdir -p "${MISSING_BIN_MOCK_ROOT}"
RES_NO_BIN="$(XRAY_BIN="${MISSING_BIN_MOCK_ROOT}/xray" "${RPCD_BACKEND}" --mock-dir "${MISSING_BIN_MOCK_ROOT}" call validate "{\"content\":\"$(echo "${CONTENT_A}" | tr -d '\n\r' | sed 's/"/\\"/g')\"}" 2>&1 || true)"
assert_match '"ok":false' "${RES_NO_BIN}" "Test 4: Missing Xray binary is a hard validation failure"

# Reset mock mode
rm -f "${MOCK_ROOT}/xray-mode"

# -------------------------------------------------------------------
# Test Group 2: Import Validation & Security Whitelist
# -------------------------------------------------------------------
echo "\n--- Test Group: Security Whitelisting & Injection Defense ---"

# 5. Invalid JSON import is rejected with exact syntax error
RES_BAD_JSON="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call import '{"name":"Bad","filename":"bad.json","content":"{ invalid json syntax ]"}' 2>&1 || true)"
assert_match '"ok":false' "${RES_BAD_JSON}" "Test 5a: Invalid JSON import is rejected"
assert_match 'Invalid JSON syntax' "${RES_BAD_JSON}" "Test 5b: Rejection error message explicitly identifies invalid JSON syntax"

# 6. Path traversal filename is rejected using 100% valid JSON payload
RES_TRAVERSAL="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call import "{\"name\":\"Trav\",\"filename\":\"../../etc/passwd\",\"content\":\"$(echo "${CONTENT_A}" | tr -d '\n\r' | sed 's/"/\\"/g')\"}" 2>&1 || true)"
assert_match '"ok":false' "${RES_TRAVERSAL}" "Test 6a: Path traversal filename is rejected using 100% valid JSON"
assert_match 'Invalid canonical filename' "${RES_TRAVERSAL}" "Test 6b: Rejection error message explicitly identifies canonical filename rule"

# 7. Oversized content is rejected (> 512 KiB) using 100% valid JSON structure
PADDING_STR="$(head -c 550000 /dev/zero | tr '\0' 'x')"
OVERSIZED_CONTENT="{\"outbounds\":[{\"protocol\":\"vless\",\"settings\":{\"reverse\":{\"tag\":\"rev-in\"}},\"tag\":\"${PADDING_STR}\"}]}"
OVERSIZED_ESCAPED="$(printf '%s' "${OVERSIZED_CONTENT}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
RES_OVERSIZED="$(printf '%s\n' "{\"name\":\"Big\",\"filename\":\"big.json\",\"content\":\"${OVERSIZED_ESCAPED}\"}" | "${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call import 2>&1 || true)"
assert_match '"ok":false' "${RES_OVERSIZED}" "Test 7a: Oversized content (> 512 KiB) is rejected using valid JSON structure"
assert_match 'size exceeds 512 KiB limit' "${RES_OVERSIZED}" "Test 7b: Rejection error message explicitly identifies size limit violation"

# 8. Command injection IDs are rejected across methods with exact error message
for bad_id in 'profile;rm -rf /' 'profile$(id)' 'profile`id`' 'profile\ninjection' 'profile with space' 'profile"injection' 'profile/test' 'profile\test' '..'; do
    RES_CMD_INJ="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call start "{\"id\":\"${bad_id}\"}" 2>&1 || true)"
    assert_match '"ok":false' "${RES_CMD_INJ}" "Test 8a: Command injection ID '${bad_id}' rejected by start"
    assert_match 'Invalid profile ID' "${RES_CMD_INJ}" "Test 8b: Error message explicitly rejects invalid ID '${bad_id}' before UCI lookup"
done

# -------------------------------------------------------------------
# Test Group 3: Reverse-Profile Safety Policy
# -------------------------------------------------------------------
echo "\n--- Test Group: Reverse-Profile Safety Policy ---"
CONTENT_INV="$(cat "${FIXTURE_INV}")"
RES_POLICY_INBOUND="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call validate "{\"content\":\"$(echo "${CONTENT_INV}" | tr -d '\n\r' | sed 's/"/\\"/g')\"}" 2>&1 || true)"
assert_match '"ok":false' "${RES_POLICY_INBOUND}" "Test 9a: Profile with listening inbound is rejected by policy"
assert_match 'listening inbounds are prohibited' "${RES_POLICY_INBOUND}" "Test 9b: Error message explicitly identifies forbidden listening inbounds"

NO_REVERSE_JSON='{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"}]}'
RES_NO_REVERSE="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call validate "{\"content\":\"$(echo "${NO_REVERSE_JSON}" | tr -d '\n\r' | sed 's/"/\\"/g')\"}" 2>&1 || true)"
assert_match '"ok":false' "${RES_NO_REVERSE}" "Test 10a: Profile without modern settings.reverse.tag is rejected"
assert_match 'at least one VLESS outbound must contain settings.reverse.tag' "${RES_NO_REVERSE}" "Test 10b: Error message explicitly identifies missing reverse tag"

# -------------------------------------------------------------------
# Test Group 4: Permissions, Symlinks & Orphan File Protection
# -------------------------------------------------------------------
echo "\n--- Test Group: Permissions, Symlinks & Atomic Operations ---"

# 11. Symlink destination replacement is rejected using 100% valid JSON
TARGET_SECRET_FILE="${MOCK_ROOT}/secret_target.txt"
echo "SECRET_ORIGINAL_TARGET_BYTES_UNCHANGED" > "${TARGET_SECRET_FILE}"
ln -s "${TARGET_SECRET_FILE}" "${PROFILES_DIR}/symlink.json" 2>/dev/null || true

RES_SYMLINK="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call import "{\"name\":\"Sym\",\"filename\":\"symlink.json\",\"content\":\"$(echo "${CONTENT_A}" | tr -d '\n\r' | sed 's/"/\\"/g')\"}" 2>&1 || true)"
assert_match '"ok":false' "${RES_SYMLINK}" "Test 11: Symlink destination rejection using 100% valid Reverse JSON (lstat check)"
assert_match 'symbolic link' "${RES_SYMLINK}" "Test 11b: Rejection error message explicitly identifies symbolic link"

# 11c. Assert symlink target contents are strictly unchanged
TARGET_AFTER="$(cat "${TARGET_SECRET_FILE}")"
assert_equal "SECRET_ORIGINAL_TARGET_BYTES_UNCHANGED" "${TARGET_AFTER}" "Test 11c: Symlink target contents strictly unchanged"
rm -f "${PROFILES_DIR}/symlink.json" "${TARGET_SECRET_FILE}"

# 12. Unmanaged orphan regular file rejection
echo "orphan content" > "${PROFILES_DIR}/orphan.json"
RES_ORPHAN="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call import "{\"name\":\"Orphan\",\"filename\":\"orphan.json\",\"content\":\"$(echo "${CONTENT_A}" | tr -d '\n\r' | sed 's/"/\\"/g')\"}" 2>&1 || true)"
assert_match '"ok":false' "${RES_ORPHAN}" "Test 12: Existing unmanaged orphan file is rejected from silent overwrite"
rm -f "${PROFILES_DIR}/orphan.json"

# 13. Import valid profile A
RES_IMP_A="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call import "{\"name\":\"Profile A\",\"filename\":\"profile-a.json\",\"content\":\"$(echo "${CONTENT_A}" | tr -d '\n\r' | sed 's/"/\\"/g')\",\"autostart\":false}" 2>&1 || true)"
assert_match '"ok":true' "${RES_IMP_A}" "Test 13a: Import profile A succeeds"

DIR_PERM="$(stat -c "%a" "${PROFILES_DIR}" 2>/dev/null || stat -f "%Lp" "${PROFILES_DIR}" 2>/dev/null || echo "700")"
FILE_PERM="$(stat -c "%a" "${PROFILES_DIR}/profile-a.json" 2>/dev/null || stat -f "%Lp" "${PROFILES_DIR}/profile-a.json" 2>/dev/null || echo "600")"
assert_equal "700" "${DIR_PERM}" "Test 13b: Profiles directory has mode 0700"
assert_equal "600" "${FILE_PERM}" "Test 13c: Profile file has mode 0600"

# 14. Atomic replacement failure rollback
PROFILE_A_ID="$(printf '%s\n' "${RES_IMP_A}" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
PROFILE_A_ID="${PROFILE_A_ID:-profile-a}"
RES_REP_FAIL="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call replace "{\"id\":\"${PROFILE_A_ID}\",\"content\":\"{ broken syntax\"}" 2>&1 || true)"
assert_match '"ok":false' "${RES_REP_FAIL}" "Test 14a: Failed replacement returns ok:false"
assert_match 'reverse-smoke-a-in' "$(cat "${PROFILES_DIR}/profile-a.json")" "Test 14b: Failed replacement preserves previous valid file"

# 15. Import valid profile B
# Real Reverse exports may use streamSettings.method instead of network.
CONTENT_B="$(sed 's/"network": "xhttp"/"method": "xhttp"/' "${FIXTURE_B}")"
RES_IMP_B="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call import "{\"name\":\"Profile B\",\"filename\":\"profile-b.json\",\"content\":\"$(echo "${CONTENT_B}" | tr -d '\n\r' | sed 's/"/\\"/g')\",\"autostart\":true}" 2>&1 || true)"
assert_match '"ok":true' "${RES_IMP_B}" "Test 15: Import profile B succeeds"
PROFILE_B_ID="$(printf '%s\n' "${RES_IMP_B}" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
PROFILE_B_ID="${PROFILE_B_ID:-profile-b}"

# 16. Rename & Reorder RPC methods
RES_RENAME="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call rename "{\"id\":\"${PROFILE_A_ID}\",\"name\":\"Renamed A\"}" 2>&1 || true)"
assert_match '"ok":true' "${RES_RENAME}" "Test 16a: Rename profile succeeds"

RES_REORDER="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call reorder "{\"id\":\"${PROFILE_A_ID}\",\"direction\":\"down\"}" 2>&1 || true)"
assert_match '"ok":true' "${RES_REORDER}" "Test 16b: Reorder profile succeeds"

# -------------------------------------------------------------------
# Test Group 5: Locking, Concurrency & Stale Lock Recovery
# -------------------------------------------------------------------
echo "\n--- Test Group: Locking, Concurrency & Stale Lock Recovery ---"

# 17. Stale lock recovery
LOCK_DIR="${PROFILES_DIR}/.lock.d"
mkdir -p "${LOCK_DIR}"
echo '{"pid": 999999, "ts": 1000000000}' > "${LOCK_DIR}/meta.json"
REPLACE_A_PAYLOAD="{\"id\":\"${PROFILE_A_ID}\",\"content\":\"$(echo "${CONTENT_A}" | tr -d '\n\r' | sed 's/"/\\"/g')\"}"
RES_STALE_REC="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call replace "${REPLACE_A_PAYLOAD}" 2>&1 || true)"
assert_match '"ok":true' "${RES_STALE_REC}" "Test 17: Stale lock belonging to dead PID / old timestamp is transparently recovered"

# 18. An old lock owned by a live process must not be stolen.
mkdir -p "${LOCK_DIR}"
printf '{"pid": %s, "ts": 1000000000}\n' "$$" > "${LOCK_DIR}/meta.json"
set +e
RES_LIVE_LOCK="$(timeout 40 "${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call replace "${REPLACE_A_PAYLOAD}" 2>&1)"
LIVE_LOCK_RC=$?
set -e
assert_equal "1" "${LIVE_LOCK_RC}" "Test 18a: Live lock rejects the concurrent replacement"
assert_match 'lock busy' "${RES_LIVE_LOCK}" "Test 18b: Live lock returns the explicit busy result"
if [ -d "${LOCK_DIR}" ]; then LIVE_LOCK_PRESENT=1; else LIVE_LOCK_PRESENT=0; fi
assert_equal "1" "${LIVE_LOCK_PRESENT}" "Test 18c: Live lock is not removed as stale"
rm -f "${LOCK_DIR}/meta.json"
rmdir "${LOCK_DIR}"

# 19. Secret Sanitization
echo "\n--- Test Group: Secret Sanitization & Trash Archiving ---"
cat > "${MOCK_ROOT}/instances.json" <<EOF
{"instances":{"profile_${PROFILE_A_ID}":{"running":true,"pid":4242,"respawn_count":3}}}
EOF
cat > "${MOCK_ROOT}/traffic.json" <<EOF
{"${PROFILE_A_ID}":{"available":true,"sample_time":100,"connections":2,"rx_bytes":1048576,"tx_bytes":524288,"rtt_ms":17,"uptime_seconds":3661}}
EOF
LIST_JSON="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call list '{}' 2>&1 || true)"
HAS_LEAKED_UUID=$(echo "${LIST_JSON}" | grep -c "11111111-1111-1111-1111-111111111111" || true)
HAS_LEAKED_ADDR=$(echo "${LIST_JSON}" | grep -c "192.0.2.10" || true)
assert_equal "0" "${HAS_LEAKED_UUID}" "Test 19a: RPC list response does not leak profile UUIDs"
assert_equal "0" "${HAS_LEAKED_ADDR}" "Test 19b: RPC list response does not leak profile addresses"
assert_match '"connections"[[:space:]]*:[[:space:]]*2' "${LIST_JSON}" "Test 19c: RPC list reports exact per-profile TCP connection count"
assert_match '"rx_bytes"[[:space:]]*:[[:space:]]*1048576' "${LIST_JSON}" "Test 19d: RPC list reports exact per-profile received bytes"
assert_match '"tx_bytes"[[:space:]]*:[[:space:]]*524288' "${LIST_JSON}" "Test 19e: RPC list reports exact per-profile transmitted bytes"
assert_match '"rtt_ms"[[:space:]]*:[[:space:]]*17' "${LIST_JSON}" "Test 19f: RPC list reports TCP_INFO RTT"
assert_match '"uptime_seconds"[[:space:]]*:[[:space:]]*3661' "${LIST_JSON}" "Test 19g: RPC list reports process uptime"
assert_match '"protocol_stack"[[:space:]]*:[[:space:]]*"VLESS \+ REALITY \+ Vision"' "${LIST_JSON}" "Test 19h: RPC list derives the safe protocol stack from profile JSON"
assert_match '"protocol_stack"[[:space:]]*:[[:space:]]*"VLESS \+ XHTTP \+ REALITY"' "${LIST_JSON}" "Test 19i: RPC list recognizes Reverse streamSettings.method transport"
HAS_OBSOLETE_FILE_METADATA=$(echo "${LIST_JSON}" | grep -E -c '"(size|sha256)"[[:space:]]*:' || true)
assert_equal "0" "${HAS_OBSOLETE_FILE_METADATA}" "Test 19j: RPC list omits removed size and SHA metadata"
rm -f "${MOCK_ROOT}/traffic.json"
mkdir -p "${MOCK_ROOT}/usr/sbin"
cat > "${MOCK_ROOT}/usr/sbin/ss" <<'EOF'
#!/bin/sh
cat <<'OUTPUT'
ESTAB 0 0 192.0.2.2:443 192.0.2.10:30443 users:(("xray",pid=4242,fd=7)) cubic wscale:7,7 rto:220 rtt:12.7/2.1 bytes_sent:123456 bytes_acked:123000 bytes_received:654321
ESTAB 0 0 192.0.2.2:444 192.0.2.11:30443 users:(("other",pid=9999,fd=8)) cubic wscale:7,7 rto:240 rtt:40.1/5.0 bytes_sent:999999 bytes_received:888888
OUTPUT
EOF
chmod 0755 "${MOCK_ROOT}/usr/sbin/ss"
LIST_SS_JSON="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call list '{}' 2>&1 || true)"
assert_match '"connections"[[:space:]]*:[[:space:]]*1' "${LIST_SS_JSON}" "Test 19k: one-line ss parser selects only sockets owned by the exact profile PID"
assert_match '"bytes_available"[[:space:]]*:[[:space:]]*true' "${LIST_SS_JSON}" "Test 19l: ss parser reports explicit byte-counter capability"
assert_match '"rx_bytes"[[:space:]]*:[[:space:]]*654321' "${LIST_SS_JSON}" "Test 19m: one-line ss parser reads bytes_received from TCP_INFO"
assert_match '"tx_bytes"[[:space:]]*:[[:space:]]*123456' "${LIST_SS_JSON}" "Test 19n: one-line ss parser reads bytes_sent from TCP_INFO"
assert_match '"rtt_ms"[[:space:]]*:[[:space:]]*12' "${LIST_SS_JSON}" "Test 19o: one-line ss parser reports integer TCP RTT milliseconds"

mkdir -p "${MOCK_ROOT}/usr/libexec"
cat > "${MOCK_ROOT}/usr/libexec/xray-sockstats" <<'EOF'
#!/bin/sh
printf '%s\n' '{"4242":{"available":true,"reason":null,"connections":3,"bytes_available":true,"rx_bytes":700000,"tx_bytes":800000,"rtt_available":true,"rtt_ms":9}}'
EOF
chmod 0755 "${MOCK_ROOT}/usr/libexec/xray-sockstats"
LIST_HELPER_JSON="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call list '{}' 2>&1 || true)"
assert_match '"source"[[:space:]]*:[[:space:]]*"pidfd_tcp_info"' "${LIST_HELPER_JSON}" "Test 19p: backend prefers the native read-only TCP_INFO collector"
assert_match '"connections"[[:space:]]*:[[:space:]]*3' "${LIST_HELPER_JSON}" "Test 19q: native collector metrics are mapped to the exact profile PID"
assert_match '"rx_bytes"[[:space:]]*:[[:space:]]*700000' "${LIST_HELPER_JSON}" "Test 19r: native collector receive bytes reach RPC output"
assert_match '"tx_bytes"[[:space:]]*:[[:space:]]*800000' "${LIST_HELPER_JSON}" "Test 19s: native collector transmit bytes reach RPC output"
rm -f "${MOCK_ROOT}/instances.json" "${MOCK_ROOT}/usr/sbin/ss" "${MOCK_ROOT}/usr/libexec/xray-sockstats"

# 20. Missing profile start/stop returns ok:false
RES_START_NONEXIST="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call start '{"id":"nonexistent_profile"}' 2>&1 || true)"
assert_match '"ok":false' "${RES_START_NONEXIST}" "Test 20a: Start on nonexistent profile returns ok:false"

RES_STOP_NONEXIST="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call stop '{"id":"nonexistent_profile"}' 2>&1 || true)"
# Stop on missing init returns ok:false if init missing or handles safely
assert_match '"ok":' "${RES_STOP_NONEXIST}" "Test 20b: Stop handler returns valid JSON result"

# 21. Safe Deletion into .trash/
RES_DEL_A="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call delete "{\"id\":\"${PROFILE_A_ID}\"}" 2>&1 || true)"
assert_match '"ok":true' "${RES_DEL_A}" "Test 21a: Delete returns ok:true"
assert_equal "0" "$([ -f "${PROFILES_DIR}/profile-a.json" ] && echo 1 || echo 0)" "Test 21b: Deleted profile removed from active profiles directory"
TRASH_COUNT="$(find "${PROFILES_DIR}/.trash" -name "*profile-a.json" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
assert_equal "1" "${TRASH_COUNT}" "Test 21c: Deleted profile archived safely in .trash/"

echo "\nSummary: ${PASSED} passed, ${FAILED} failed"
if [ "${FAILED}" -gt 0 ]; then
    exit 1
fi
exit 0
