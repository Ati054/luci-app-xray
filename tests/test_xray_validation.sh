#!/bin/sh
# Validates generated and fixture configurations using Xray binary

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE_FILE="${SCRIPT_DIR}/fixtures/dual_reverse_fixture.json"
XRAY_BIN="${1:-xray}"

echo "=== Test Suite: Xray-core 26.7.28 Semantic Validation ==="

if ! command -v "${XRAY_BIN}" >/dev/null 2>&1; then
    echo "  [SKIP] Xray binary '${XRAY_BIN}' not found in PATH or arguments."
    exit 0
fi

echo "Testing reference dual_reverse_fixture.json with ${XRAY_BIN}..."
"${XRAY_BIN}" -test -config "${FIXTURE_FILE}"
echo "  [PASS] Reference dual_reverse_fixture.json passed Xray configuration test."

if command -v ucode >/dev/null 2>&1; then
    echo "Generating dynamic reverse-only config from ucode..."
    TMP_JSON="$(mktemp)"
    ucode -e '
        import { gen_config_from_data } from "'"${SCRIPT_DIR}"'/../core/root/usr/share/xray/gen_config.uc";
        import { get_dual_reverse_config } from "'"${SCRIPT_DIR}"'/fixtures/sample_configs.uc";
        print(sprintf("%.4J\n", gen_config_from_data(get_dual_reverse_config())));
    ' > "${TMP_JSON}"

    echo "Testing dynamically generated reverse config with ${XRAY_BIN}..."
    "${XRAY_BIN}" -test -config "${TMP_JSON}"
    rm -f "${TMP_JSON}"
    echo "  [PASS] Dynamically generated reverse-only config passed Xray configuration test."
fi

exit 0
