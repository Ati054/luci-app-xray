#!/bin/sh
set -eu

echo "=== OpenWrt 25.12 ucode module parse sweep ==="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
UCODE_BIN="${UCODE_BIN:-ucode}"

if ! command -v "${UCODE_BIN}" >/dev/null 2>&1 && [ ! -x "${UCODE_BIN}" ]; then
    echo "FAIL: exact OpenWrt 25.12 ucode runtime is required"
    exit 1
fi

TMP_ROOT="$(mktemp -d)"
MODULE_LIST="${TMP_ROOT}/modules.list"
IMPORT_WRAPPER="${TMP_ROOT}/import-wrapper.uc"
find "${ROOT_DIR}/core/root/usr/share/xray" -type f \( -name '*.uc' -o -name '*.mjs' \) -print | sort > "${MODULE_LIST}"
trap 'rm -rf "${TMP_ROOT}"' EXIT INT TERM

while IFS= read -r module; do
    escaped_module="$(printf '%s' "${module}" | sed 's/[\\"]/\\&/g')"
    printf 'import * as module_under_test from "%s";\n' "${escaped_module}" > "${IMPORT_WRAPPER}"
    "${UCODE_BIN}" -c -o /dev/null "${IMPORT_WRAPPER}" >/dev/null 2> "${TMP_ROOT}/compile.err" || {
        echo "FAIL: ucode module did not compile through an import: ${module}" >&2
        cat "${TMP_ROOT}/compile.err" >&2
        exit 1
    }
done < "${MODULE_LIST}"

echo "PASS: every installed ucode module parsed successfully."
