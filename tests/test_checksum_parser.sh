#!/bin/sh
# Unit tests for the production shell checksum parser library (checksum_lib.sh)

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

echo "=== Test Suite: Shell Checksum Parser Unit Tests ==="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/ci/checksum_lib.sh"

TMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

VALID_HASH="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

# Test 1: SHA256= <64 hex>
cat << EOF > "${TMP_DIR}/test1.dgst"
MD5= dummy
SHA256= ${VALID_HASH}
SHA512= other
EOF
RES1=$(parse_sha256_digest "${TMP_DIR}/test1.dgst" 2>/dev/null || true)
assert_equal "${VALID_HASH}" "${RES1}" "Parses SHA256= <64 hex>"

# Test 2: SHA2-256= <64 hex>
cat << EOF > "${TMP_DIR}/test2.dgst"
SHA2-256= ${VALID_HASH}
EOF
RES2=$(parse_sha256_digest "${TMP_DIR}/test2.dgst" 2>/dev/null || true)
assert_equal "${VALID_HASH}" "${RES2}" "Parses SHA2-256= <64 hex>"

# Test 3: BSD style SHA256 (filename) = <64 hex>
cat << EOF > "${TMP_DIR}/test3.dgst"
SHA256 (Xray-linux-64.zip) = ${VALID_HASH}
EOF
RES3=$(parse_sha256_digest "${TMP_DIR}/test3.dgst" 2>/dev/null || true)
assert_equal "${VALID_HASH}" "${RES3}" "Parses BSD SHA256 (filename) = <64 hex>"

# Test 4: Missing SHA-256 line
cat << EOF > "${TMP_DIR}/test4.dgst"
MD5= 0123456789abcdef
SHA512= 0123456789abcdef
EOF
RES4_STATUS=0
parse_sha256_digest "${TMP_DIR}/test4.dgst" >/dev/null 2>&1 || RES4_STATUS=$?
assert_equal "1" "$((RES4_STATUS != 0))" "Rejects digest with missing SHA-256"

# Test 5: Malformed SHA-256 (too short or invalid chars)
cat << EOF > "${TMP_DIR}/test5.dgst"
SHA256= 0123456789abcdef_too_short
EOF
RES5_STATUS=0
parse_sha256_digest "${TMP_DIR}/test5.dgst" >/dev/null 2>&1 || RES5_STATUS=$?
assert_equal "1" "$((RES5_STATUS != 0))" "Rejects malformed non-64-hex SHA-256"

# Test 6: Duplicate identical SHA-256 lines
cat << EOF > "${TMP_DIR}/test6.dgst"
SHA256= ${VALID_HASH}
SHA256= ${VALID_HASH}
EOF
RES6_STATUS=0
parse_sha256_digest "${TMP_DIR}/test6.dgst" >/dev/null 2>&1 || RES6_STATUS=$?
assert_equal "1" "$((RES6_STATUS != 0))" "Rejects duplicate identical SHA-256 lines"

# Test 7: Conflicting multiple SHA-256 lines
cat << EOF > "${TMP_DIR}/test7.dgst"
SHA256= ${VALID_HASH}
SHA2-256= ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
EOF
RES7_STATUS=0
parse_sha256_digest "${TMP_DIR}/test7.dgst" >/dev/null 2>&1 || RES7_STATUS=$?
assert_equal "1" "$((RES7_STATUS != 0))" "Rejects conflicting SHA-256 lines"

# Test 8: Extra unexpected SHA-256 records (A/B/A)
cat << EOF > "${TMP_DIR}/test8.dgst"
SHA256= ${VALID_HASH}
SHA2-256= ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
SHA256= ${VALID_HASH}
EOF
RES8_STATUS=0
parse_sha256_digest "${TMP_DIR}/test8.dgst" >/dev/null 2>&1 || RES8_STATUS=$?
assert_equal "1" "$((RES8_STATUS != 0))" "Rejects multiple alternating SHA-256 lines"

echo "\nSummary: ${PASSED} passed, ${FAILED} failed"
if [ "${FAILED}" -gt 0 ]; then
    exit 1
fi
exit 0
