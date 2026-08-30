#!/bin/sh
set -eu

echo "=== gen_config.uc import boundary ==="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
UCODE_BIN="${UCODE_BIN:-ucode}"
GEN_CONFIG_UC="${ROOT_DIR}/core/root/usr/share/xray/gen_config.uc"

if ! command -v "${UCODE_BIN}" >/dev/null 2>&1 && [ ! -x "${UCODE_BIN}" ]; then
    echo "FAIL: exact ucode runtime is required"
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT INT TERM

cat > "${TMP_DIR}/import.uc" <<EOF
import "${GEN_CONFIG_UC}";
print("IMPORT_OK\\n");
EOF

IMPORT_STATUS=0
"${UCODE_BIN}" -R "${TMP_DIR}/import.uc" > "${TMP_DIR}/stdout" 2> "${TMP_DIR}/stderr" || IMPORT_STATUS=$?
[ "${IMPORT_STATUS}" -eq 0 ] || {
    echo "FAIL: importing gen_config.uc exited with status ${IMPORT_STATUS}"
    cat "${TMP_DIR}/stderr"
    exit 1
}
test ! -s "${TMP_DIR}/stderr" || {
    echo "FAIL: importing gen_config.uc wrote to stderr"
    cat "${TMP_DIR}/stderr"
    exit 1
}
[ "$(cat "${TMP_DIR}/stdout")" = "IMPORT_OK" ] || {
    echo "FAIL: importing gen_config.uc executed the CLI entrypoint"
    cat "${TMP_DIR}/stdout"
    exit 1
}

echo "PASS: importing gen_config.uc has no CLI side effects."
