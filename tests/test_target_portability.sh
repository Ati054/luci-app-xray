#!/bin/sh
set -eu

echo "=== R10 target portability without stat ==="

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
INSTALLER="${ROOT_DIR}/install_and_smoke_r10.sh"
HARDWARE_SMOKE="${ROOT_DIR}/tests/hardware/profile_mode_smoke.sh"
MASTER_RUNNER="${ROOT_DIR}/tests/run_tests.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT INT TERM

assert_no_target_stat() {
    script_path="$1"
    script_name="$2"
    if grep -E '(^|[^[:alnum:]_])stat([[:space:]]|$)|stat[[:space:]]+-[cf]' "${script_path}" >/dev/null; then
        echo "FAIL: unsupported target stat dependency remains in ${script_name}" >&2
        return 1
    fi
    echo "PASS: ${script_name} has no target stat invocation."
}

assert_no_target_stat "${INSTALLER}" "install_and_smoke_r10.sh"
assert_no_target_stat "${HARDWARE_SMOKE}" "tests/hardware/profile_mode_smoke.sh"
grep -Fq 'sh "${SCRIPT_DIR}/test_target_portability.sh"' "${MASTER_RUNNER}" || {
    echo "FAIL: target portability regression is not wired into the master runner" >&2
    exit 1
}
echo "PASS: target portability regression is wired into the CI master runner."

HELPERS="${TMP_DIR}/portability-helpers.sh"
sed -n '/^# BEGIN R10_TARGET_PORTABILITY_HELPERS$/,/^# END R10_TARGET_PORTABILITY_HELPERS$/p' \
    "${INSTALLER}" "${HARDWARE_SMOKE}" > "${HELPERS}"

for helper_name in r10_file_size_bytes r10_verify_exact_file_size \
    r10_exact_private_directory r10_exact_private_regular_file; do
    grep -q "^${helper_name}()" "${HELPERS}" || {
        echo "FAIL: runtime portability helper is missing: ${helper_name}" >&2
        exit 1
    }
done

BIN_DIR="${TMP_DIR}/bin"
mkdir -p "${BIN_DIR}"
HOST_CHMOD="$(command -v chmod)"
REAL_WC="$(command -v wc)"
[ -n "${HOST_CHMOD}" ] && [ -n "${REAL_WC}" ] || {
    echo "FAIL: host chmod and wc are required by the portability regression" >&2
    exit 1
}

cat > "${BIN_DIR}/wc" <<EOF
#!/bin/sh
case "\${R10_TEST_WC_MODE:-normal}" in
    fail) exit 1 ;;
    malformed) printf '%s\n' not-a-number; exit 0 ;;
esac
exec "${REAL_WC}" "\$@"
EOF
"${HOST_CHMOD}" 0755 "${BIN_DIR}/wc"

MODE_DB="${TMP_DIR}/busybox-modes"
: > "${MODE_DB}"
cat > "${BIN_DIR}/chmod" <<'EOF'
#!/bin/sh
[ "$#" -ge 2 ] || exit 2
mode="$1"
shift
for mode_path in "$@"; do
    printf '%s|%s\n' "${mode}" "${mode_path}" >> "${R10_TEST_MODE_DB}"
done
EOF
"${HOST_CHMOD}" 0755 "${BIN_DIR}/chmod"

cat > "${BIN_DIR}/ls" <<'EOF'
#!/bin/sh
[ "$#" -eq 2 ] && [ "$1" = "-ld" ] || exit 2
mode_path="$2"
if [ "${R10_TEST_LS_MODE:-normal}" = "malformed" ]; then
    printf '%s\n' malformed-permission-output
    exit 0
fi
recorded_mode=""
while IFS='|' read -r candidate_mode candidate_path; do
    [ "${candidate_path}" = "${mode_path}" ] && recorded_mode="${candidate_mode}"
done < "${R10_TEST_MODE_DB}"
case "${recorded_mode}" in
    0700|700) permission_bits='rwx------' ;;
    0755|755) permission_bits='rwxr-xr-x' ;;
    0600|600) permission_bits='rw-------' ;;
    0644|644) permission_bits='rw-r--r--' ;;
    *) exit 1 ;;
esac
if [ -L "${mode_path}" ]; then
    type_field='l'
elif [ -d "${mode_path}" ]; then
    type_field='d'
elif [ -f "${mode_path}" ]; then
    type_field='-'
else
    exit 1
fi
printf '%s%s 1 root root 0 Jan 1 00:00 %s\n' "${type_field}" "${permission_bits}" "${mode_path}"
EOF
"${HOST_CHMOD}" 0755 "${BIN_DIR}/ls"

PACKAGE_MARKER="${TMP_DIR}/package-command-ran"
cat > "${BIN_DIR}/apk" <<EOF
#!/bin/sh
printf '%s\n' invoked > "${PACKAGE_MARKER}"
exit 99
EOF
chmod 0755 "${BIN_DIR}/apk"

APK_FILE="${TMP_DIR}/dependency.apk"
UNREADABLE_APK="${TMP_DIR}/unreadable.apk"
MISSING_APK="${TMP_DIR}/missing.apk"
PRIVATE_DIR="${TMP_DIR}/profiles"
PRIVATE_FILE="${TMP_DIR}/profile.json"
printf 'abcdef' > "${APK_FILE}"
printf 'private' > "${UNREADABLE_APK}"
printf '{}' > "${PRIVATE_FILE}"
mkdir "${PRIVATE_DIR}"
chmod 000 "${UNREADABLE_APK}"
chmod 0700 "${PRIVATE_DIR}"
chmod 0600 "${PRIVATE_FILE}"

MSYS=winsymlinks:sys ln -s "${PRIVATE_DIR}" "${TMP_DIR}/profiles-link"
MSYS=winsymlinks:sys ln -s "${PRIVATE_FILE}" "${TMP_DIR}/profile-link.json"
[ -L "${TMP_DIR}/profiles-link" ] && [ -L "${TMP_DIR}/profile-link.json" ] || {
    echo "FAIL: regression environment did not create real symbolic links" >&2
    exit 1
}

HARNESS="${TMP_DIR}/harness.sh"
cat > "${HARNESS}" <<'EOF'
#!/bin/sh
set -eu

. "${R10_HELPERS}"

command -v stat >/dev/null 2>&1 && {
    echo "FAIL: stat unexpectedly exists in restricted target PATH" >&2
    exit 1
}

chmod 0700 "${R10_PRIVATE_DIR}"
chmod 0600 "${R10_PRIVATE_FILE}"

r10_verify_exact_file_size "${R10_APK_FILE}" 6 || {
    echo "FAIL: correct APK byte size was rejected" >&2
    exit 1
}
echo "PASS: correct APK byte size is accepted without stat."

if r10_verify_exact_file_size "${R10_APK_FILE}" 7; then
    echo "FAIL: incorrect APK byte size was accepted" >&2
    exit 1
fi
echo "PASS: incorrect APK byte size is rejected."

if r10_verify_exact_file_size "${R10_MISSING_APK}" 0; then
    echo "FAIL: missing APK was accepted" >&2
    exit 1
fi
echo "PASS: missing APK is rejected."

R10_TEST_WC_MODE=fail
export R10_TEST_WC_MODE
if r10_verify_exact_file_size "${R10_UNREADABLE_APK}" 7; then
    echo "FAIL: unreadable APK was accepted" >&2
    exit 1
fi
unset R10_TEST_WC_MODE
echo "PASS: unreadable APK is rejected."

R10_TEST_WC_MODE=malformed
export R10_TEST_WC_MODE
if r10_file_size_bytes "${R10_APK_FILE}" >/dev/null; then
    echo "FAIL: malformed byte-count output was accepted" >&2
    exit 1
fi
unset R10_TEST_WC_MODE
echo "PASS: malformed byte-count output is rejected fail-closed."

r10_exact_private_directory "${R10_PRIVATE_DIR}" || {
    echo "FAIL: directory mode 0700 was rejected" >&2
    exit 1
}
echo "PASS: real directory mode 0700 is accepted."

chmod 0755 "${R10_PRIVATE_DIR}"
if r10_exact_private_directory "${R10_PRIVATE_DIR}"; then
    echo "FAIL: directory mode 0755 was accepted" >&2
    exit 1
fi
chmod 0700 "${R10_PRIVATE_DIR}"
echo "PASS: directory mode 0755 is rejected."

if r10_exact_private_directory "${R10_PRIVATE_DIR_LINK}"; then
    echo "FAIL: directory symlink was accepted" >&2
    exit 1
fi
echo "PASS: directory symlink is rejected."

r10_exact_private_regular_file "${R10_PRIVATE_FILE}" || {
    echo "FAIL: regular file mode 0600 was rejected" >&2
    exit 1
}
echo "PASS: real regular file mode 0600 is accepted."

chmod 0644 "${R10_PRIVATE_FILE}"
if r10_exact_private_regular_file "${R10_PRIVATE_FILE}"; then
    echo "FAIL: regular file mode 0644 was accepted" >&2
    exit 1
fi
chmod 0600 "${R10_PRIVATE_FILE}"
echo "PASS: regular file mode 0644 is rejected."

if r10_exact_private_regular_file "${R10_PRIVATE_FILE_LINK}"; then
    echo "FAIL: file symlink was accepted" >&2
    exit 1
fi
echo "PASS: file symlink is rejected."

R10_TEST_LS_MODE=malformed
export R10_TEST_LS_MODE
if r10_exact_private_directory "${R10_PRIVATE_DIR}" || \
    r10_exact_private_regular_file "${R10_PRIVATE_FILE}"; then
    echo "FAIL: malformed permission output was accepted" >&2
    exit 1
fi
unset R10_TEST_LS_MODE
echo "PASS: malformed permission output is rejected fail-closed."

[ ! -e "${R10_PACKAGE_MARKER}" ] || {
    echo "FAIL: package command ran during portability preflight" >&2
    exit 1
}
echo "PASS: portability preflight executes no package command."

echo "TARGET_PORTABILITY_WITHOUT_STAT_OK"
EOF
chmod 0755 "${HARNESS}"

R10_HELPERS="${HELPERS}" \
R10_APK_FILE="${APK_FILE}" \
R10_UNREADABLE_APK="${UNREADABLE_APK}" \
R10_MISSING_APK="${MISSING_APK}" \
R10_PRIVATE_DIR="${PRIVATE_DIR}" \
R10_PRIVATE_DIR_LINK="${TMP_DIR}/profiles-link" \
R10_PRIVATE_FILE="${PRIVATE_FILE}" \
R10_PRIVATE_FILE_LINK="${TMP_DIR}/profile-link.json" \
R10_PACKAGE_MARKER="${PACKAGE_MARKER}" \
R10_TEST_MODE_DB="${MODE_DB}" \
PATH="${BIN_DIR}" \
/bin/sh "${HARNESS}"
