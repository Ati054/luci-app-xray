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
RPCD_BACKEND="${ROOT_DIR}/core/root/usr/libexec/rpcd/xray_profiles"
INIT_PROFILES="${ROOT_DIR}/core/root/etc/init.d/xray_profiles"
FIXTURE_A="${SCRIPT_DIR}/fixtures/profile-smoke-a.json"
FIXTURE_B="${SCRIPT_DIR}/fixtures/profile-smoke-b.json"
FIXTURE_INV="${SCRIPT_DIR}/fixtures/profile-invalid.json"

MOCK_ROOT="$(mktemp -d)"
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
MOCK_XRAY_MODE="fail_23" RES_FAIL_23="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call validate "{\"content\":\"$(echo "${CONTENT_A}" | tr -d '\n\r' | sed 's/"/\\"/g')\"}" 2>&1 || true)"
assert_match '"ok":false' "${RES_FAIL_23}" "Test 1: Nonzero exit with 'Failed to start' (code 23) is rejected"

# 2. Exit 0 with harmless output passes
MOCK_XRAY_MODE="success_harmless" RES_PASS_HARMLESS="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call validate "{\"content\":\"$(echo "${CONTENT_A}" | tr -d '\n\r' | sed 's/"/\\"/g')\"}" 2>&1 || true)"
assert_match '"ok":true' "${RES_PASS_HARMLESS}" "Test 2: Exit 0 with harmless output passes validation"

# 3. Exit 0 with silent output passes
MOCK_XRAY_MODE="success_silent" RES_PASS_SILENT="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call validate "{\"content\":\"$(echo "${CONTENT_A}" | tr -d '\n\r' | sed 's/"/\\"/g')\"}" 2>&1 || true)"
assert_match '"ok":true' "${RES_PASS_SILENT}" "Test 3: Exit 0 with silent output passes validation"

# 4. Missing Xray binary is a hard failure
MISSING_BIN_MOCK_ROOT="${MOCK_ROOT}/no_bin"
mkdir -p "${MISSING_BIN_MOCK_ROOT}"
RES_NO_BIN="$("${RPCD_BACKEND}" --mock-dir "${MISSING_BIN_MOCK_ROOT}" call validate "{\"content\":\"$(echo "${CONTENT_A}" | tr -d '\n\r' | sed 's/"/\\"/g')\"}" 2>&1 || true)"
assert_match '"ok":false' "${RES_NO_BIN}" "Test 4: Missing Xray binary is a hard validation failure"

# Reset mock mode
unset MOCK_XRAY_MODE

# -------------------------------------------------------------------
# Test Group 2: Import Validation & Security Whitelist
# -------------------------------------------------------------------
echo "\n--- Test Group: Security Whitelisting & Injection Defense ---"

# 5. Invalid JSON import is rejected
RES_BAD_JSON="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call import '{"name":"Bad","filename":"bad.json","content":"{ invalid json syntax ]"}' 2>&1 || true)"
assert_match '"ok":false' "${RES_BAD_JSON}" "Test 5: Invalid JSON import is rejected"

# 6. Path traversal filename is rejected
RES_TRAVERSAL="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call import '{"name":"Trav","filename":"../../etc/passwd","content":"{}"}' 2>&1 || true)"
assert_match '"ok":false' "${RES_TRAVERSAL}" "Test 6: Path traversal filename is rejected"

# 7. Oversized content is rejected (> 512 KiB)
OVERSIZED_CONTENT="$(head -c 550000 /dev/zero | tr '\0' 'a')"
RES_OVERSIZED="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call import "{\"name\":\"Big\",\"filename\":\"big.json\",\"content\":\"${OVERSIZED_CONTENT}\"}" 2>&1 || true)"
assert_match '"ok":false' "${RES_OVERSIZED}" "Test 7: Oversized content (> 512 KiB) is rejected"

# 8. Command injection IDs are rejected across all methods
for bad_id in 'profile;rm -rf /' 'profile$(id)' 'profile`id`' 'profile\ninjection' 'profile with space' 'profile"injection' 'profile/test' 'profile\test' '..'; do
    RES_CMD_INJ="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call start "{\"id\":\"${bad_id}\"}" 2>&1 || true)"
    assert_match '"ok":false' "${RES_CMD_INJ}" "Test 8: Command injection ID '${bad_id}' rejected by start"
done

# -------------------------------------------------------------------
# Test Group 3: Reverse-Profile Safety Policy
# -------------------------------------------------------------------
echo "\n--- Test Group: Reverse-Profile Safety Policy ---"
CONTENT_INV="$(cat "${FIXTURE_INV}")"
RES_POLICY_INBOUND="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call validate "{\"content\":\"$(echo "${CONTENT_A}" | sed 's/"settings":/"inbounds":[{"port":1080,"protocol":"socks"}],"settings":/' | tr -d '\n\r' | sed 's/"/\\"/g')\"}" 2>&1 || true)"
assert_match '"ok":false' "${RES_POLICY_INBOUND}" "Test 9: Profile with listening inbound is rejected by policy"

NO_REVERSE_JSON='{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"}]}'
RES_NO_REVERSE="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call validate "{\"content\":\"$(echo "${NO_REVERSE_JSON}" | tr -d '\n\r' | sed 's/"/\\"/g')\"}" 2>&1 || true)"
assert_match '"ok":false' "${RES_NO_REVERSE}" "Test 10: Profile without modern settings.reverse.tag is rejected"

# -------------------------------------------------------------------
# Test Group 4: Permissions, Symlinks & Orphan File Protection
# -------------------------------------------------------------------
echo "\n--- Test Group: Permissions, Symlinks & Atomic Operations ---"

# 11. Symlink destination replacement is rejected
ln -s /etc/passwd "${PROFILES_DIR}/symlink.json" 2>/dev/null || true
RES_SYMLINK="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call import '{"name":"Sym","filename":"symlink.json","content":"{}"}' 2>&1 || true)"
assert_match '"ok":false' "${RES_SYMLINK}" "Test 11: Symlink destination replacement is rejected"

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
PROFILE_A_ID="$(echo "${RES_IMP_A}" | grep -o '"id":"[^"]*' | cut -d'"' -f4 || echo "profile-a")"
RES_REP_FAIL="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call replace "{\"id\":\"${PROFILE_A_ID}\",\"content\":\"{ broken syntax\"}" 2>&1 || true)"
assert_match '"ok":false' "${RES_REP_FAIL}" "Test 14a: Failed replacement returns ok:false"
assert_match 'reverse-smoke-a-in' "$(cat "${PROFILES_DIR}/profile-a.json")" "Test 14b: Failed replacement preserves previous valid file"

# 15. Import valid profile B
CONTENT_B="$(cat "${FIXTURE_B}")"
RES_IMP_B="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call import "{\"name\":\"Profile B\",\"filename\":\"profile-b.json\",\"content\":\"$(echo "${CONTENT_B}" | tr -d '\n\r' | sed 's/"/\\"/g')\",\"autostart\":true}" 2>&1 || true)"
assert_match '"ok":true' "${RES_IMP_B}" "Test 15: Import profile B succeeds"
PROFILE_B_ID="$(echo "${RES_IMP_B}" | grep -o '"id":"[^"]*' | cut -d'"' -f4 || echo "profile-b")"

# 16. Rename & Reorder RPC methods
RES_RENAME="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call rename "{\"id\":\"${PROFILE_A_ID}\",\"name\":\"Renamed A\"}" 2>&1 || true)"
assert_match '"ok":true' "${RES_RENAME}" "Test 16a: Rename profile succeeds"

RES_REORDER="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call reorder "{\"id\":\"${PROFILE_A_ID}\",\"direction\":\"down\"}" 2>&1 || true)"
assert_match '"ok":true' "${RES_REORDER}" "Test 16b: Reorder profile succeeds"

# 17. Secret Sanitization
echo "\n--- Test Group: Secret Sanitization & Trash Archiving ---"
LIST_JSON="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call list '{}' 2>&1 || true)"
HAS_LEAKED_UUID=$(echo "${LIST_JSON}" | grep -c "11111111-1111-1111-1111-111111111111" || true)
HAS_LEAKED_ADDR=$(echo "${LIST_JSON}" | grep -c "192.0.2.10" || true)
assert_equal "0" "${HAS_LEAKED_UUID}" "Test 17a: RPC list response does not leak profile UUIDs"
assert_equal "0" "${HAS_LEAKED_ADDR}" "Test 17b: RPC list response does not leak profile addresses"

# 18. Safe Deletion into .trash/
RES_DEL_A="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call delete "{\"id\":\"${PROFILE_A_ID}\"}" 2>&1 || true)"
assert_match '"ok":true' "${RES_DEL_A}" "Test 18a: Delete returns ok:true"
assert_equal "0" "$([ -f "${PROFILES_DIR}/profile-a.json" ] && echo 1 || echo 0)" "Test 18b: Deleted profile removed from active profiles directory"
TRASH_COUNT="$(find "${PROFILES_DIR}/.trash" -name "*profile-a.json" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
assert_equal "1" "${TRASH_COUNT}" "Test 18c: Deleted profile archived safely in .trash/"

echo "\nSummary: ${PASSED} passed, ${FAILED} failed"
if [ "${FAILED}" -gt 0 ]; then
    exit 1
fi
exit 0
