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

find "${ROOT_DIR}/core/root/usr/share/xray" -type f \( -name '*.uc' -o -name '*.mjs' \) -print | sort > "${TMPDIR:-/tmp}/r9-ucode-modules.$$"
trap 'rm -f "${TMPDIR:-/tmp}/r9-ucode-modules.$$"' EXIT INT TERM

while IFS= read -r module; do
    "${UCODE_BIN}" -c "${module}" >/dev/null
done < "${TMPDIR:-/tmp}/r9-ucode-modules.$$"

echo "PASS: every installed ucode module parsed successfully."
