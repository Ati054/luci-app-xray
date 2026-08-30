#!/bin/sh
# Master test runner for luci-app-xray ucode and lifecycle tests

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UCODE_BIN="${UCODE_BIN:-ucode}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
REQUIRED_SUITE_BLOCKED=0

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
    for tool in node "${PYTHON_BIN}" "${UCODE_BIN}" "${XRAY_BIN:-xray}" sha256sum unzip; do
        if ! check_tool "${tool}"; then
            echo "::error::Mandatory CI tool '${tool}' is missing."
            exit 1
        fi
    done
    echo "  [PASS] All mandatory CI tools are present."
fi

echo "\n--- 1. Running local syntax, UI runtime, and structure checks ---"
if command -v node >/dev/null 2>&1; then
    node "${SCRIPT_DIR}/local_check.js"
    node "${SCRIPT_DIR}/test_rule_encoding.js"
    node "${SCRIPT_DIR}/test_profiles_view.js"
else
    if [ "${CI}" = "true" ] || [ "${GITHUB_ACTIONS}" = "true" ]; then
        echo "::error::node runtime is required in CI mode."
        exit 1
    fi
    echo "  [BLOCKED] node runtime is required for the UI test suites."
    REQUIRED_SUITE_BLOCKED=1
fi

echo "\n--- 2. Running shell checksum parser, package metadata, and import graph tests ---"
sh "${SCRIPT_DIR}/test_checksum_parser.sh"
sh "${SCRIPT_DIR}/test_package_metadata.sh"
sh "${SCRIPT_DIR}/test_package_import_failure_reporting.sh"
sh "${SCRIPT_DIR}/test_package_imports.sh"
PYTHONDONTWRITEBYTECODE=1 "${PYTHON_BIN}" "${SCRIPT_DIR}/test_r9_contracts.py"
PYTHONDONTWRITEBYTECODE=1 "${PYTHON_BIN}" "${SCRIPT_DIR}/test_r9_manifest.py"
PYTHONDONTWRITEBYTECODE=1 "${PYTHON_BIN}" "${SCRIPT_DIR}/test_workflow_shell.py"
sh "${SCRIPT_DIR}/test_installer_r9.sh"
sh "${SCRIPT_DIR}/test_setup_ucode_discovery.sh"

echo "\n--- 3. Running ucode unit tests and tag invariant contracts ---"
if check_tool "${UCODE_BIN}"; then
    UCODE_BIN="${UCODE_BIN}" sh "${SCRIPT_DIR}/test_ucode_modules.sh"
    "${UCODE_BIN}" "${SCRIPT_DIR}/test_vless_reverse.uc"
    "${UCODE_BIN}" "${SCRIPT_DIR}/test_reverse_only_generator.uc"
    UCODE_BIN="${UCODE_BIN}" sh "${SCRIPT_DIR}/test_ucode_entrypoint.sh"
    UCODE_BIN="${UCODE_BIN}" sh "${SCRIPT_DIR}/test_gen_config_import.sh"
    UCODE_BIN="${UCODE_BIN}" sh "${SCRIPT_DIR}/test_rpcd_stdin.sh"
    UCODE_BIN="${UCODE_BIN}" sh "${SCRIPT_DIR}/test_tmp_cleanup.sh"
else
    if [ "${CI}" = "true" ] || [ "${GITHUB_ACTIONS}" = "true" ]; then
        echo "::error::ucode CLI is required in CI mode."
        exit 1
    fi
    echo "  [BLOCKED] target-compatible ucode is required for the generator and rpcd suites."
    REQUIRED_SUITE_BLOCKED=1
fi

echo "\n--- 4. Running init lifecycle and state transition tests ---"
sh "${SCRIPT_DIR}/test_executable_modes.sh"
sh "${SCRIPT_DIR}/test_init_lifecycle.sh"
sh "${SCRIPT_DIR}/test_rand_removal.sh"

echo "\n--- 5. Running JSON profile manager and process isolation tests ---"
if check_tool "${UCODE_BIN}"; then
    UCODE_BIN="${UCODE_BIN}" sh "${SCRIPT_DIR}/test_profile_manager.sh"
else
    if [ "${CI}" = "true" ] || [ "${GITHUB_ACTIONS}" = "true" ]; then
        echo "::error::ucode CLI is required in CI mode."
        exit 1
    fi
    echo "  [BLOCKED] target-compatible ucode is required for the profile-manager suite."
    REQUIRED_SUITE_BLOCKED=1
fi

echo "\n--- 6. Running Xray semantic validation ---"
sh "${SCRIPT_DIR}/test_xray_validation.sh" "${XRAY_BIN:-xray}"

if [ "${REQUIRED_SUITE_BLOCKED}" -ne 0 ]; then
    echo "\nRequired test suites were blocked by missing local target tooling."
    exit 2
fi

echo "\nAll required test suites completed successfully."
exit 0
