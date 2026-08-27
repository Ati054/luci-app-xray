#!/bin/sh
# Master test runner for luci-app-xray ucode and lifecycle tests

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Running local syntax and structure checks..."
if command -v node >/dev/null 2>&1; then
    node "${SCRIPT_DIR}/local_check.js"
fi

echo "\nRunning package metadata and standalone alignment tests..."
sh "${SCRIPT_DIR}/test_package_metadata.sh"

echo "\nRunning ucode unit tests..."
if command -v ucode >/dev/null 2>&1; then
    ucode "${SCRIPT_DIR}/test_vless_reverse.uc"
    ucode "${SCRIPT_DIR}/test_reverse_only_generator.uc"
else
    if [ "${CI}" = "true" ] || [ "${GITHUB_ACTIONS}" = "true" ]; then
        echo "::error::ucode CLI is required in CI mode."
        exit 1
    fi
    echo "  [SKIP] ucode CLI not available in current environment."
fi

echo "\nRunning init lifecycle and state transition tests..."
sh "${SCRIPT_DIR}/test_init_lifecycle.sh"

echo "\nRunning Xray semantic validation..."
sh "${SCRIPT_DIR}/test_xray_validation.sh" "${XRAY_BIN:-xray}"

echo "\nAll executable tests completed successfully."
exit 0
