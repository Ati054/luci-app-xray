#!/bin/sh
# Validates core package Makefile metadata and symlinks for standalone Xray

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

echo "=== Test Suite: Package Metadata & Standalone Binary Alignment ==="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAKEFILE="${SCRIPT_DIR}/../core/Makefile"

# Test 1: core/Makefile must not have +xray-core in DEPENDS
DEPENDS_LINE=$(grep "^[[:space:]]*DEPENDS:=" "${MAKEFILE}")
HAS_XRAY_CORE_DEP=$(echo "${DEPENDS_LINE}" | grep -c "+xray-core" || true)
assert_equal "0" "${HAS_XRAY_CORE_DEP}" "core/Makefile must not depend on +xray-core"

# Test 2: core/Makefile must point symlink to /opt/xray/current/xray
HAS_OPT_SYMLINK=$(grep -c "LN.*opt/xray/current/xray" "${MAKEFILE}" || true)
assert_equal "1" "$((HAS_OPT_SYMLINK > 0))" "core/Makefile must install symlink pointing to /opt/xray/current/xray"

echo "\nSummary: ${PASSED} passed, ${FAILED} failed"
if [ "${FAILED}" -gt 0 ]; then
    exit 1
fi
exit 0
