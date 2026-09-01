#!/bin/sh
set -eu

echo "=== R10 installer fail-closed unit contracts ==="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALLER="${ROOT_DIR}/install_and_smoke_r10.sh"
TMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "${TMP_DIR}" || :
}
trap cleanup EXIT INT TERM

sh -n "${INSTALLER}"

cat > "${TMP_DIR}/id" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-u" ]; then
    echo 65534
    exit 0
fi
exit 1
EOF
chmod 0755 "${TMP_DIR}/id"

if PATH="${TMP_DIR}:${PATH}" sh "${INSTALLER}" > "${TMP_DIR}/stdout" 2> "${TMP_DIR}/stderr"; then
    echo "FAIL: installer accepted a non-root caller" >&2
    exit 1
fi
DIAG_LOG="$(sed -n 's/^R10 offline installation started; diagnostic log: //p' "${TMP_DIR}/stdout" | head -n 1)"
[ -n "${DIAG_LOG}" ] && [ -s "${DIAG_LOG}" ] || {
    echo "FAIL: failing installer did not preserve its diagnostic log" >&2
    exit 1
}
grep -q 'installer must run as root' "${DIAG_LOG}" || {
    echo "FAIL: installer did not report the root precondition" >&2
    exit 1
}
grep -q 'preflight made no service or package changes' "${TMP_DIR}/stdout" || {
    echo "FAIL: preflight failure did not remain explicitly non-mutating" >&2
    exit 1
}
! grep -q '^R10_INSTALL_AND_HARDWARE_SMOKE_OK$' "${TMP_DIR}/stdout" "${TMP_DIR}/stderr" || {
    echo "FAIL: failing installer emitted the final success marker" >&2
    exit 1
}
rm -f "${DIAG_LOG}"

[ "$(grep -c '^console "R10_INSTALL_AND_HARDWARE_SMOKE_OK"$' "${INSTALLER}")" -eq 1 ] || {
    echo "FAIL: installer must contain exactly one final marker emission" >&2
    exit 1
}
! grep -q 'xray test -c' "${INSTALLER}" || {
    echo "FAIL: forbidden Xray invocation remains in installer" >&2
    exit 1
}
grep -q 'manifest metadata does not match' "${INSTALLER}" && \
    grep -q 'manifest_source_allowed' "${INSTALLER}" || {
    echo "FAIL: installer does not verify dependency APKs against the checksummed bundle manifest" >&2
    exit 1
}

CHECKSUM_LINE="$(grep -n '^sha256sum -c SHA256SUMS-R10.txt$' "${INSTALLER}" | cut -d: -f1)"
SIMULATION_LINE="$(grep -n '^console "Simulating complete APK transaction with networking disabled"$' "${INSTALLER}" | cut -d: -f1)"
INSTALL_LINE="$(grep -n '^apk add --no-network --allow-untrusted ./\*\.apk$' "${INSTALLER}" | cut -d: -f1)"
[ -n "${CHECKSUM_LINE}" ] && [ -n "${SIMULATION_LINE}" ] && [ -n "${INSTALL_LINE}" ] && \
[ "${CHECKSUM_LINE}" -lt "${SIMULATION_LINE}" ] && [ "${SIMULATION_LINE}" -lt "${INSTALL_LINE}" ] || {
    echo "FAIL: checksum/simulation/install order is unsafe" >&2
    exit 1
}
grep -q 'BLOCKED: POST_TRANSACTION_HARDWARE_FAILURE' "${INSTALLER}" || {
    echo "FAIL: installer omits the exact post-transaction hard-stop marker" >&2
    exit 1
}

SNAPSHOT_LINE="$(grep -n 'profiles-before.json' "${INSTALLER}" | head -n 1 | cut -d: -f1)"
BACKUP_READY_LINE="$(grep -n '^BACKUP_READY=1$' "${INSTALLER}" | cut -d: -f1)"
SMOKE_LINE="$(grep -n '^sh "${SCRIPT_DIR}/profile_mode_smoke.sh"$' "${INSTALLER}" | cut -d: -f1)"
RESTORE_LINE="$(grep -n '^restore_pretransaction_services$' "${INSTALLER}" | tail -n 1 | cut -d: -f1)"
VERIFY_RESTORE_LINE="$(grep -n '^verify_pretransaction_services_restored$' "${INSTALLER}" | cut -d: -f1)"
SUCCESS_LINE="$(grep -n '^console "R10_INSTALL_AND_HARDWARE_SMOKE_OK"$' "${INSTALLER}" | cut -d: -f1)"
[ -n "${SNAPSHOT_LINE}" ] && [ -n "${BACKUP_READY_LINE}" ] && [ -n "${SMOKE_LINE}" ] && \
[ -n "${RESTORE_LINE}" ] && [ -n "${VERIFY_RESTORE_LINE}" ] && [ -n "${SUCCESS_LINE}" ] && \
[ "${SNAPSHOT_LINE}" -lt "${BACKUP_READY_LINE}" ] && [ "${SMOKE_LINE}" -lt "${RESTORE_LINE}" ] && \
[ "${RESTORE_LINE}" -lt "${VERIFY_RESTORE_LINE}" ] && [ "${VERIFY_RESTORE_LINE}" -lt "${SUCCESS_LINE}" ] || {
    echo "FAIL: active-profile snapshot/restore/verification order is unsafe" >&2
    exit 1
}
grep -q 'running-profile-ids.txt' "${INSTALLER}" && \
    grep -q 'has invalid restored PID' "${INSTALLER}" || {
    echo "FAIL: installer does not verify exact active profiles after update" >&2
    exit 1
}

echo "PASS: installer is fail-closed and restores verified active profiles before success."
