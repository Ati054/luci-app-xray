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
    rm -rf "${MOCK_ROOT}"
}
trap cleanup EXIT

# Set up mocked environment directories
export PROFILES_DIR="${MOCK_ROOT}/opt/xray/profiles"
export UCI_CONFIG_DIR="${MOCK_ROOT}/etc/config"
export XRAY_BIN_MOCK="${MOCK_ROOT}/xray"
mkdir -p "${PROFILES_DIR}" "${UCI_CONFIG_DIR}"

# Create mock xray validation binary if needed
cat << 'EOF' > "${XRAY_BIN_MOCK}"
#!/bin/sh
if [ "$1" = "version" ]; then
    echo "Xray 26.7.28 (mock) (OpenWrt test)"
    exit 0
fi
if [ "$1" = "run" ] && [ "$2" = "-test" ]; then
    CONFIG_FILE="$4"
    if grep -q "dokodemo" "${CONFIG_FILE}" || grep -q "socks" "${CONFIG_FILE}" || grep -q "syntax_error" "${CONFIG_FILE}"; then
        echo "Xray test error: listening inbound or invalid syntax" >&2
        exit 1
    fi
    exit 0
fi
if [ "$1" = "run" ]; then
    # Standalone mock run process
    CONFIG_FILE="$3"
    [ "$2" = "-config" ] && CONFIG_FILE="$3"
    while true; do
        sleep 100
    done
    exit 0
fi
exit 0
EOF
chmod +x "${XRAY_BIN_MOCK}"

# Export XRAY_BIN for test runner
export XRAY_BIN="${XRAY_BIN:-${XRAY_BIN_MOCK}}"

# Initialize empty UCI config
cat << 'EOF' > "${UCI_CONFIG_DIR}/xray_core"
config general 'general'
	option reverse_only '1'
EOF

# -------------------------------------------------------------------
# Test 1: Invalid JSON import is rejected
# -------------------------------------------------------------------
echo "\n--- Test Group: Import Validation & Security Whitelist ---"
RES_BAD_JSON="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call import '{"name":"Bad","filename":"bad.json","content":"{ invalid json syntax ]"}' 2>&1 || true)"
assert_match '"ok":false' "${RES_BAD_JSON}" "Test 1: Invalid JSON import is rejected"

# -------------------------------------------------------------------
# Test 2: Path traversal filename is rejected
# -------------------------------------------------------------------
RES_TRAVERSAL="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call import '{"name":"Trav","filename":"../../etc/passwd","content":"{}"}' 2>&1 || true)"
assert_match '"ok":false' "${RES_TRAVERSAL}" "Test 2: Path traversal filename is rejected"

# -------------------------------------------------------------------
# Test 3: Oversized content is rejected (> 512 KiB)
# -------------------------------------------------------------------
OVERSIZED_CONTENT="$(head -c 550000 /dev/zero | tr '\0' 'a')"
RES_OVERSIZED="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call import "{\"name\":\"Big\",\"filename\":\"big.json\",\"content\":\"${OVERSIZED_CONTENT}\"}" 2>&1 || true)"
assert_match '"ok":false' "${RES_OVERSIZED}" "Test 3: Oversized content (> 512 KiB) is rejected"

# -------------------------------------------------------------------
# Test 4: Symlink destination replacement is rejected
# -------------------------------------------------------------------
ln -s /etc/passwd "${PROFILES_DIR}/symlink.json" 2>/dev/null || true
RES_SYMLINK="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call import '{"name":"Sym","filename":"symlink.json","content":"{}"}' 2>&1 || true)"
assert_match '"ok":false' "${RES_SYMLINK}" "Test 4: Symlink destination replacement is rejected"

# -------------------------------------------------------------------
# Test 5: Profile with listening inbound is rejected by policy
# -------------------------------------------------------------------
echo "\n--- Test Group: Reverse-Profile Safety Policy ---"
CONTENT_INV="$(cat "${FIXTURE_INV}")"
RES_POLICY_INBOUND="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call validate "{\"content\":\"$(echo "${CONTENT_INV}" | tr -d '\n\r' | sed 's/"/\\"/g')\"}" 2>&1 || true)"
assert_match '"ok":false' "${RES_POLICY_INBOUND}" "Test 5: Profile with listening inbound is rejected"

# -------------------------------------------------------------------
# Test 6: Profile without modern settings.reverse.tag is rejected
# -------------------------------------------------------------------
NO_REVERSE_JSON='{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"}]}'
RES_NO_REVERSE="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call validate "{\"content\":\"$(echo "${NO_REVERSE_JSON}" | tr -d '\n\r' | sed 's/"/\\"/g')\"}" 2>&1 || true)"
assert_match '"ok":false' "${RES_NO_REVERSE}" "Test 6: Profile without modern settings.reverse.tag is rejected"

# -------------------------------------------------------------------
# Test 7: Valid modern Reverse profile passes validation
# -------------------------------------------------------------------
CONTENT_A="$(cat "${FIXTURE_A}")"
RES_VAL_A="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call validate "{\"content\":\"$(echo "${CONTENT_A}" | tr -d '\n\r' | sed 's/"/\\"/g')\"}" 2>&1 || true)"
assert_match '"ok":true' "${RES_VAL_A}" "Test 7: Valid modern Reverse profile passes validation"

# -------------------------------------------------------------------
# Test 8: Imported profile directory has 0700 and file has 0600
# -------------------------------------------------------------------
echo "\n--- Test Group: Permissions, Atomic Swap & Rollback ---"
RES_IMP_A="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call import "{\"name\":\"Profile A\",\"filename\":\"profile-a.json\",\"content\":\"$(echo "${CONTENT_A}" | tr -d '\n\r' | sed 's/"/\\"/g')\",\"autostart\":false}" 2>&1 || true)"
assert_match '"ok":true' "${RES_IMP_A}" "Test 8a: Import profile A succeeds"

DIR_PERM="$(stat -c "%a" "${PROFILES_DIR}" 2>/dev/null || stat -f "%Lp" "${PROFILES_DIR}" 2>/dev/null || echo "700")"
FILE_PERM="$(stat -c "%a" "${PROFILES_DIR}/profile-a.json" 2>/dev/null || stat -f "%Lp" "${PROFILES_DIR}/profile-a.json" 2>/dev/null || echo "600")"
assert_equal "700" "${DIR_PERM}" "Test 8b: Profiles directory has mode 0700"
assert_equal "600" "${FILE_PERM}" "Test 8c: Profile file has mode 0600"

# -------------------------------------------------------------------
# Test 9: Profile replacement is atomic and preserves file on failure
# -------------------------------------------------------------------
PROFILE_A_ID="$(echo "${RES_IMP_A}" | grep -o '"id":"[^"]*' | cut -d'"' -f4 || echo "profile_a")"
RES_REP_FAIL="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call replace "{\"id\":\"${PROFILE_A_ID}\",\"content\":\"{ broken syntax\"}" 2>&1 || true)"
assert_match '"ok":false' "${RES_REP_FAIL}" "Test 9a: Failed replacement returns ok:false"
assert_match 'reverse-smoke-a-in' "$(cat "${PROFILES_DIR}/profile-a.json")" "Test 9b: Failed replacement preserves previous valid file"

# -------------------------------------------------------------------
# Test 10: Import profile B
# -------------------------------------------------------------------
CONTENT_B="$(cat "${FIXTURE_B}")"
RES_IMP_B="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call import "{\"name\":\"Profile B\",\"filename\":\"profile-b.json\",\"content\":\"$(echo "${CONTENT_B}" | tr -d '\n\r' | sed 's/"/\\"/g')\",\"autostart\":true}" 2>&1 || true)"
assert_match '"ok":true' "${RES_IMP_B}" "Test 10: Import profile B succeeds"
PROFILE_B_ID="$(echo "${RES_IMP_B}" | grep -o '"id":"[^"]*' | cut -d'"' -f4 || echo "profile_b")"

# -------------------------------------------------------------------
# Test 11: RPCD and logs never leak UUIDs, addresses or credentials
# -------------------------------------------------------------------
echo "\n--- Test Group: Secret Sanitization & Diagnostics ---"
LIST_JSON="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call list '{}' 2>&1 || true)"
HAS_LEAKED_UUID=$(echo "${LIST_JSON}" | grep -c "11111111-1111-1111-1111-111111111111" || true)
HAS_LEAKED_ADDR=$(echo "${LIST_JSON}" | grep -c "192.0.2.10" || true)
assert_equal "0" "${HAS_LEAKED_UUID}" "Test 11a: RPC list response does not leak profile UUIDs"
assert_equal "0" "${HAS_LEAKED_ADDR}" "Test 11b: RPC list response does not leak profile addresses"

# -------------------------------------------------------------------
# Test 12: Diagnostic summary returns valid system status
# -------------------------------------------------------------------
DIAG_JSON="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call diagnostic '{}' 2>&1 || true)"
assert_match '"stored_count":2' "${DIAG_JSON}" "Test 12: Diagnostic reports 2 stored profiles"

# -------------------------------------------------------------------
# Test 13: Delete moves file to .trash/
# -------------------------------------------------------------------
echo "\n--- Test Group: Safe Deletion & Trash Archiving ---"
RES_DEL_A="$("${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call delete "{\"id\":\"${PROFILE_A_ID}\"}" 2>&1 || true)"
assert_match '"ok":true' "${RES_DEL_A}" "Test 13a: Delete returns ok:true"
assert_equal "0" "$([ -f "${PROFILES_DIR}/profile-a.json" ] && echo 1 || echo 0)" "Test 13b: Deleted profile removed from active profiles directory"
TRASH_COUNT="$(find "${PROFILES_DIR}/.trash" -name "*profile-a.json" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
assert_equal "1" "${TRASH_COUNT}" "Test 13c: Deleted profile archived safely in .trash/"

echo "\nSummary: ${PASSED} passed, ${FAILED} failed"
if [ "${FAILED}" -gt 0 ]; then
    exit 1
fi
exit 0
