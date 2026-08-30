#!/bin/sh
# Validates generated and fixture configurations using Xray binary

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE_FILE="${SCRIPT_DIR}/fixtures/dual_reverse_fixture.json"
XRAY_BIN="${1:-xray}"

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

if ! check_tool "${XRAY_BIN}"; then
    if [ "${CI}" = "true" ] || [ "${GITHUB_ACTIONS}" = "true" ]; then
        echo "::error::Xray binary '${XRAY_BIN}' required in CI mode."
        exit 1
    fi
    echo "  [SKIP] Xray binary '${XRAY_BIN}' not found in PATH or arguments."
    exit 0
fi

echo "Testing reference dual_reverse_fixture.json with ${XRAY_BIN}..."
"${XRAY_BIN}" run -test -config "${FIXTURE_FILE}"
echo "  [PASS] Reference dual_reverse_fixture.json passed Xray semantic test."

echo "Testing empty/default reverse-only configuration with ${XRAY_BIN}..."
"${XRAY_BIN}" run -test -config "${SCRIPT_DIR}/fixtures/empty-reverse.json"
echo "  [PASS] Empty/default reverse-only configuration passed Xray semantic test."

echo "Testing smoke fixtures with ${XRAY_BIN}..."
"${XRAY_BIN}" run -test -config "${SCRIPT_DIR}/fixtures/profile-smoke-a.json"
"${XRAY_BIN}" run -test -config "${SCRIPT_DIR}/fixtures/profile-smoke-b.json"
echo "  [PASS] Reference smoke fixtures passed Xray semantic test."

if command -v ucode >/dev/null 2>&1; then
    echo "Generating dynamic reverse-only config from ucode..."
    TMP_DYNAMIC_DIR="$(mktemp -d)"
    TMP_JSON="${TMP_DYNAMIC_DIR}/config.json"
    trap 'rm -rf "${TMP_DYNAMIC_DIR}"' EXIT INT TERM
    ucode -e '
        import { gen_config_from_data } from "'"${SCRIPT_DIR}"'/../core/root/usr/share/xray/gen_config.mjs";
        import { get_dual_reverse_config } from "'"${SCRIPT_DIR}"'/fixtures/sample_configs.uc";
        print(sprintf("%.4J\n", gen_config_from_data(get_dual_reverse_config())));
    ' > "${TMP_JSON}"

    echo "Testing dynamically generated reverse config with ${XRAY_BIN}..."
    "${XRAY_BIN}" run -test -config "${TMP_JSON}"
    rm -rf "${TMP_DYNAMIC_DIR}"
    trap - EXIT INT TERM
    echo "  [PASS] Dynamically generated reverse-only config passed Xray semantic test."
else
    if [ "${CI}" = "true" ] || [ "${GITHUB_ACTIONS}" = "true" ]; then
        echo "::error::ucode CLI required in CI mode for dynamic generator validation."
        exit 1
    fi
    echo "  [SKIP] ucode CLI not available for dynamic config generation."
fi

exit 0
