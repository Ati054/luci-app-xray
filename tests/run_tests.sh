#!/bin/sh
# Master test runner for luci-app-xray ucode and lifecycle tests

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== luci-app-xray Master Test Runner ==="

check_tool() {
    local t="$1"
    case "$t" in
        */*)
            [ -x "$t" ]
            ;;
        *)
            command -v "$t" >/dev/null 2>&1
            ;;
    esac
}

# Check mandatory tools in CI mode
if [ "${CI}" = "true" ] || [ "${GITHUB_ACTIONS}" = "true" ]; then
    echo "Verifying mandatory CI tools..."
    for tool in node ucode "${XRAY_BIN:-xray}" sha256sum unzip; do
        if ! check_tool "${tool}"; then
            echo "::error::Mandatory CI tool '${tool}' is missing."
            exit 1
        fi
    done
    echo "  [PASS] All mandatory CI tools are present."
fi

echo "\n--- 1. Running local syntax and structure checks ---"
if command -v node >/dev/null 2>&1; then
    node "${SCRIPT_DIR}/local_check.js"
    node "${SCRIPT_DIR}/test_rule_encoding.js"
else
    if [ "${CI}" = "true" ] || [ "${GITHUB_ACTIONS}" = "true" ]; then
        echo "::error::node runtime is required in CI mode."
        exit 1
    fi
    echo "  [SKIP] node runtime not available in current environment."
fi

echo "\n--- 2. Running shell checksum parser, package metadata, import graph, and APK extractor tests ---"
sh "${SCRIPT_DIR}/test_checksum_parser.sh"
sh "${SCRIPT_DIR}/test_package_metadata.sh"
sh "${SCRIPT_DIR}/test_package_imports.sh"
if python3 -c "import sys" >/dev/null 2>&1; then
    python3 "${SCRIPT_DIR}/test_extract_openwrt_apk.py"
elif python -c "import sys" >/dev/null 2>&1; then
    python "${SCRIPT_DIR}/test_extract_openwrt_apk.py"
fi

echo "\n--- 3. Running ucode unit tests and tag invariant contracts ---"
if command -v ucode >/dev/null 2>&1; then
    ucode "${SCRIPT_DIR}/test_vless_reverse.uc"
    ucode "${SCRIPT_DIR}/test_reverse_only_generator.uc"
    sh "${SCRIPT_DIR}/test_ucode_entrypoint.sh"
else
    if [ "${CI}" = "true" ] || [ "${GITHUB_ACTIONS}" = "true" ]; then
        echo "::error::ucode CLI is required in CI mode."
        exit 1
    fi
    echo "  [SKIP] ucode CLI not available in current environment."
fi

echo "\n--- 4. Running init lifecycle and state transition tests ---"
sh "${SCRIPT_DIR}/test_init_lifecycle.sh"

echo "\n--- 5. Running JSON profile manager and process isolation tests ---"
if command -v ucode >/dev/null 2>&1; then
    sh "${SCRIPT_DIR}/test_profile_manager.sh"
else
    if [ "${CI}" = "true" ] || [ "${GITHUB_ACTIONS}" = "true" ]; then
        echo "::error::ucode CLI is required in CI mode."
        exit 1
    fi
    echo "  [SKIP] ucode CLI not available in current environment."
fi

echo "\n--- 6. Running Xray semantic validation ---"
sh "${SCRIPT_DIR}/test_xray_validation.sh" "${XRAY_BIN:-xray}"

echo "\nAll test suites completed successfully."
exit 0
