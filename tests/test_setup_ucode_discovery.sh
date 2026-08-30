#!/bin/sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_SCRIPT="${SCRIPT_DIR}/ci/setup_ucode.sh"
TMP_ROOT="$(mktemp -d)"

cleanup() {
    rm -rf "${TMP_ROOT}"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

write_source_makefile() {
    path="$1"
    revision="$2"
    mkdir -p "$(dirname "${path}")"
    printf 'PKG_SOURCE_VERSION:=%s\n' "${revision}" > "${path}"
}

assert_layout() {
    sdk_root="$1"
    label="$2"
    output_file="${TMP_ROOT}/${label}.out"
    error_file="${TMP_ROOT}/${label}.err"

    SETUP_UCODE_DISCOVERY_ONLY=1 sh "${SETUP_SCRIPT}" "${sdk_root}" \
        > "${output_file}" 2> "${error_file}" || {
        cat "${error_file}" >&2
        fail "${label} layout was rejected"
    }
    grep -q 'SDK-selected libubox revision: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "${output_file}" ||
        fail "${label} did not resolve libubox"
    grep -q 'SDK-selected uci revision: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "${output_file}" ||
        fail "${label} did not resolve uci"
    grep -q 'SDK-selected ucode revision: cccccccccccccccccccccccccccccccccccccccc' "${output_file}" ||
        fail "${label} did not resolve ucode"
    echo "PASS: setup_ucode discovers ${label} SDK source layout"
}

SDK_OLD="${TMP_ROOT}/sdk-old"
write_source_makefile "${SDK_OLD}/package/libs/libubox/Makefile" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
write_source_makefile "${SDK_OLD}/package/system/uci/Makefile" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
write_source_makefile "${SDK_OLD}/package/utils/ucode/Makefile" cccccccccccccccccccccccccccccccccccccccc
assert_layout "${SDK_OLD}" old

SDK_SPLIT="${TMP_ROOT}/sdk-split"
write_source_makefile "${SDK_SPLIT}/feeds/base_root/package/libs/libubox/Makefile" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
write_source_makefile "${SDK_SPLIT}/feeds/base_root/package/system/uci/Makefile" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
write_source_makefile "${SDK_SPLIT}/feeds/base_root/package/utils/ucode/Makefile" cccccccccccccccccccccccccccccccccccccccc
assert_layout "${SDK_SPLIT}" split-feed

write_source_makefile "${SDK_SPLIT}/package/libs/libubox/Makefile" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
if SETUP_UCODE_DISCOVERY_ONLY=1 sh "${SETUP_SCRIPT}" "${SDK_SPLIT}" \
    > "${TMP_ROOT}/ambiguous.out" 2> "${TMP_ROOT}/ambiguous.err"; then
    fail "ambiguous libubox source layout was accepted"
fi
grep -q 'Expected exactly one SDK source Makefile for libubox, found 2' "${TMP_ROOT}/ambiguous.err" ||
    fail "ambiguous layout did not report the exact conflict"
echo "PASS: setup_ucode rejects ambiguous SDK source layouts"
