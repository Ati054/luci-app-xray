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

TMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

# Test 1: Module import produces zero stdout and zero stderr with exit code 0
IMPORT_ERR="${TMP_DIR}/import_err.log"
IMPORT_OUT="${TMP_DIR}/import_out.log"

ucode -e '
    import { gen_config_from_data } from "'"${GEN_CONFIG_PATH}"'";
' > "${IMPORT_OUT}" 2> "${IMPORT_ERR}"
IMPORT_STATUS=$?

assert_equal "0" "${IMPORT_STATUS}" "Importing gen_config.uc exits with 0"
assert_equal "" "$(cat "${IMPORT_OUT}")" "Importing gen_config.uc produces no stdout output"
assert_equal "" "$(cat "${IMPORT_ERR}")" "Importing gen_config.uc produces no stderr output"

# Test 2: Direct CLI execution with deterministic UCI configuration
UCI_DIR="${TMP_DIR}/etc/config"
mkdir -p "${UCI_DIR}"

cat << 'EOF' > "${UCI_DIR}/xray_core"
config general 'general'
	option reverse_only '1'
	option loglevel 'warning'

config servers 's1'
	option protocol 'vless'
	option vless_reverse '1'
	option server '198.51.100.1'
	option server_port '443'
	option password '00000000-0000-0000-0000-000000000001'
EOF

CLI_OUT="${TMP_DIR}/cli_out.json"
CLI_ERR="${TMP_DIR}/cli_err.log"

export UCI_CONFIG_DIR="${UCI_DIR}"
ucode "${GEN_CONFIG_PATH}" > "${CLI_OUT}" 2> "${CLI_ERR}"
CLI_STATUS=$?

assert_equal "0" "${CLI_STATUS}" "Direct execution of gen_config.uc exits with 0"
assert_equal "" "$(cat "${CLI_ERR}")" "Direct execution of gen_config.uc produces no stderr error"

# Verify that stdout contains valid Reverse-only JSON structure
JSON_CHECK_STATUS=0
if command -v node >/dev/null 2>&1; then
    node -e '
        const fs = require("fs");
        const json = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        if (!Array.isArray(json.inbounds) || json.inbounds.length !== 0) process.exit(1);
        if (!Array.isArray(json.outbounds) || json.outbounds.length < 2) process.exit(2);
        if (json.outbounds[1].tag !== "reverse-egress") process.exit(3);
        if (!json.routing || !Array.isArray(json.routing.rules)) process.exit(4);
    ' "${CLI_OUT}" || JSON_CHECK_STATUS=$?
else
    grep -q '"reverse-egress"' "${CLI_OUT}" || JSON_CHECK_STATUS=1
fi

assert_equal "0" "${JSON_CHECK_STATUS}" "Direct execution produces valid reverse-only JSON structure"

echo "\nSummary: ${PASSED} passed, ${FAILED} failed"
if [ "${FAILED}" -gt 0 ]; then
    exit 1
fi
exit 0
