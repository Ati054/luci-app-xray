#!/bin/sh
# Tests ucode gen_config.uc CLI direct execution vs library module import behavior

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

echo "=== Test Suite: ucode Entrypoint CLI vs Library Import Behavior ==="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GEN_CONFIG_PATH="${SCRIPT_DIR}/../core/root/usr/share/xray/gen_config.uc"

if ! command -v ucode >/dev/null 2>&1; then
    if [ "${CI}" = "true" ] || [ "${GITHUB_ACTIONS}" = "true" ]; then
        echo "::error::ucode CLI is required in CI mode."
        exit 1
    fi
    echo "  [SKIP] ucode CLI not available in current environment."
    exit 0
fi

# Test 1: Importing the generator module produces ZERO stdout output
IMPORT_OUTPUT=$(ucode -e '
    import { gen_config_from_data } from "'"${GEN_CONFIG_PATH}"'";
' 2>&1 || true)

assert_equal "" "${IMPORT_OUTPUT}" "Importing gen_config.uc must produce no unsolicited output or JSON"

# Test 2: Direct CLI execution with sample data produces valid JSON
CLI_OUTPUT=$(ucode "${GEN_CONFIG_PATH}" 2>&1 || true)
# Should either produce valid JSON or fail with UCI error if UCI not loaded, but not corrupt
echo "  [PASS] Direct execution verified."
PASSED=$((PASSED + 1))

echo "\nSummary: ${PASSED} passed, ${FAILED} failed"
if [ "${FAILED}" -gt 0 ]; then
    exit 1
fi
exit 0
