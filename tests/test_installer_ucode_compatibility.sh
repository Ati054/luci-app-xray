#!/bin/sh
set -eu

echo "=== R10 installer ucode module compatibility ==="

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
INSTALLER="${ROOT_DIR}/install_and_smoke_r10.sh"
MASTER_RUNNER="${ROOT_DIR}/tests/run_tests.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT INT TERM

grep -Fq 'sh "${SCRIPT_DIR}/test_installer_ucode_compatibility.sh"' "${MASTER_RUNNER}" || {
    echo "FAIL: installer ucode compatibility regression is not wired into the master runner" >&2
    exit 1
}

HELPERS="${TMP_DIR}/ucode-helpers.sh"
sed -n '/^# BEGIN R10_UCODE_MODULE_COMPATIBILITY_HELPERS$/,/^# END R10_UCODE_MODULE_COMPATIBILITY_HELPERS$/p' \
    "${INSTALLER}" > "${HELPERS}"
grep -q '^r10_compile_ucode_source()' "${HELPERS}" || {
    echo "FAIL: installer has no module-aware ucode compile helper" >&2
    exit 1
}
grep -Fq 'r10_compile_ucode_source "${UCODE_BIN}" "${module_path}"' "${INSTALLER}" || {
    echo "FAIL: installed-source sweep does not use the module-aware compile helper" >&2
    exit 1
}
if grep -Fq '"${UCODE_BIN}" -c "${module_path}"' "${INSTALLER}"; then
    echo "FAIL: installed-source sweep still compiles .mjs files directly" >&2
    exit 1
fi

BIN_DIR="${TMP_DIR}/bin"
mkdir -p "${BIN_DIR}"
cat > "${BIN_DIR}/ucode" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${R10_FAKE_UCODE_LOG}"
[ "$#" -eq 4 ] && [ "$1" = "-cdynlink=ubus" ] && \
    [ "$2" = "-o" ] && [ "$3" = "/dev/null" ] || {
    echo "unexpected compile arguments: $*" >&2
    exit 97
}

compile_source="$4"
case "${compile_source}" in
    *.mjs)
        echo "Syntax error: Exports may only appear at top level of a module" >&2
        exit 255
        ;;
esac

if grep -Fq 'broken.mjs' "${compile_source}"; then
    echo "synthetic module parse failure" >&2
    exit 255
fi
exit 0
EOF
chmod 0755 "${BIN_DIR}/ucode"

ENTRYPOINT="${TMP_DIR}/entrypoint.uc"
MODULE="${TMP_DIR}/module.mjs"
BROKEN_MODULE="${TMP_DIR}/broken.mjs"
IMPORT_WRAPPER="${TMP_DIR}/import-wrapper.uc"
COMPILE_STDERR="${TMP_DIR}/compile.stderr"
UCODE_LOG="${TMP_DIR}/ucode.log"
printf '%s\n' 'print("entrypoint");' > "${ENTRYPOINT}"
printf '%s\n' 'export function valid() { return true; }' > "${MODULE}"
printf '%s\n' 'export function broken() {' > "${BROKEN_MODULE}"
: > "${UCODE_LOG}"

HARNESS="${TMP_DIR}/harness.sh"
cat > "${HARNESS}" <<'EOF'
#!/bin/sh
set -eu
. "${R10_HELPERS}"

r10_compile_ucode_source "${R10_UCODE_BIN}" "${R10_ENTRYPOINT}" \
    "${R10_IMPORT_WRAPPER}" "${R10_COMPILE_STDERR}"
[ ! -s "${R10_COMPILE_STDERR}" ] || {
    echo "FAIL: direct .uc compile wrote to stderr" >&2
    exit 1
}

r10_compile_ucode_source "${R10_UCODE_BIN}" "${R10_MODULE}" \
    "${R10_IMPORT_WRAPPER}" "${R10_COMPILE_STDERR}"
[ ! -s "${R10_COMPILE_STDERR}" ] || {
    echo "FAIL: imported .mjs compile wrote to stderr" >&2
    exit 1
}
grep -Fq "import * as module_under_test from \"${R10_MODULE}\";" "${R10_IMPORT_WRAPPER}" || {
    echo "FAIL: .mjs source was not compiled through an import wrapper" >&2
    exit 1
}

if r10_compile_ucode_source "${R10_UCODE_BIN}" "${R10_BROKEN_MODULE}" \
    "${R10_IMPORT_WRAPPER}" "${R10_COMPILE_STDERR}"; then
    echo "FAIL: broken imported module was accepted" >&2
    exit 1
else
    compile_rc=$?
fi
[ "${compile_rc}" -eq 255 ] || {
    echo "FAIL: broken module exit ${compile_rc}, expected 255" >&2
    exit 1
}
grep -Fq 'synthetic module parse failure' "${R10_COMPILE_STDERR}" || {
    echo "FAIL: broken module diagnostic was not preserved" >&2
    exit 1
}
EOF
chmod 0755 "${HARNESS}"

R10_HELPERS="${HELPERS}" \
R10_UCODE_BIN="${BIN_DIR}/ucode" \
R10_ENTRYPOINT="${ENTRYPOINT}" \
R10_MODULE="${MODULE}" \
R10_BROKEN_MODULE="${BROKEN_MODULE}" \
R10_IMPORT_WRAPPER="${IMPORT_WRAPPER}" \
R10_COMPILE_STDERR="${COMPILE_STDERR}" \
R10_FAKE_UCODE_LOG="${UCODE_LOG}" \
/bin/sh "${HARNESS}"

grep -Fq -- "-cdynlink=ubus -o /dev/null ${ENTRYPOINT}" "${UCODE_LOG}" || {
    echo "FAIL: .uc entrypoint was not compiled directly with target flags" >&2
    exit 1
}
if grep -Fq -- "-cdynlink=ubus -o /dev/null ${MODULE}" "${UCODE_LOG}"; then
    echo "FAIL: .mjs module was compiled directly instead of through an import" >&2
    exit 1
fi

echo "PASS: installer compiles .uc entrypoints directly and .mjs modules through imports."
echo "PASS: imported module failures preserve the target exit code and diagnostic."
echo "R10_UCODE_MODULE_IMPORT_SWEEP_OK"
