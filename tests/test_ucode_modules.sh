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
printf '%s\n' "${ROOT_DIR}/core/root/usr/libexec/rpcd/xray_profiles" >> "${MODULE_LIST}"
sort -o "${MODULE_LIST}" "${MODULE_LIST}"
trap 'rm -rf "${TMP_ROOT}"' EXIT INT TERM

while IFS= read -r module; do
    compile_source="${module}"
    case "${module}" in
        *.mjs)
            escaped_module="$(printf '%s' "${module}" | sed 's/[\\"]/\\&/g')"
            printf 'import * as module_under_test from "%s";\n' "${escaped_module}" > "${IMPORT_WRAPPER}"
            compile_source="${IMPORT_WRAPPER}"
            ;;
    esac
    "${UCODE_BIN}" -cdynlink=ubus -o /dev/null "${compile_source}" >/dev/null 2> "${TMP_ROOT}/compile.err" || {
        echo "FAIL: installed ucode source did not compile: ${module}" >&2
        cat "${TMP_ROOT}/compile.err" >&2
        exit 1
    }
done < "${MODULE_LIST}"

echo "PASS: every installed ucode source and the rpcd backend parsed successfully."
