#!/bin/sh
set -eu

echo "=== R10 apk help exit-status compatibility ==="

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
INSTALLER="${ROOT_DIR}/install_and_smoke_r10.sh"
MASTER_RUNNER="${ROOT_DIR}/tests/run_tests.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT INT TERM

HOST_CHMOD="$(command -v chmod)"
HOST_CAT="$(command -v cat)"
HOST_GREP="$(command -v grep)"
HOST_RM="$(command -v rm)"
[ -n "${HOST_CHMOD}" ] && [ -n "${HOST_CAT}" ] && \
    [ -n "${HOST_GREP}" ] && [ -n "${HOST_RM}" ] || {
    echo "FAIL: host chmod, cat, grep, and rm are required" >&2
    exit 1
}

BIN_DIR="${TMP_DIR}/bin"
mkdir -p "${BIN_DIR}"

cat > "${BIN_DIR}/apk" <<'EOF'
#!/bin/sh
command_name="global"
help_rc="${R10_FAKE_GLOBAL_HELP_RC:-0}"
case "$*" in
    --version)
        printf '%s\n' 'apk-tools 3.0.5, compiled for aarch64.'
        exit 0
        ;;
    "--no-network --version")
        if [ "${R10_FAKE_EMPTY_NO_NETWORK_PROBE:-0}" -ne 1 ]; then
            printf '%s\n' "${R10_FAKE_NO_NETWORK_PROBE_OUTPUT:-apk-tools 3.0.5, compiled for aarch64.}"
        fi
        exit "${R10_FAKE_NO_NETWORK_PROBE_RC:-0}"
        ;;
    --help)
        command_name="global"
        help_rc="${R10_FAKE_GLOBAL_HELP_RC:-0}"
        ;;
    "info --help")
        command_name="info"
        help_rc="${R10_FAKE_INFO_HELP_RC:-0}"
        ;;
    "add --help")
        command_name="add"
        help_rc="${R10_FAKE_ADD_HELP_RC:-0}"
        ;;
    "adbdump --help")
        command_name="adbdump"
        help_rc="${R10_FAKE_ADBDUMP_HELP_RC:-0}"
        ;;
    "list --help")
        command_name="list"
        help_rc="${R10_FAKE_LIST_HELP_RC:-0}"
        ;;
    add*|fix*|upgrade*|install*)
        printf '%s\n' "$*" > "${R10_PACKAGE_MARKER}"
        exit 99
        ;;
    *)
        echo "fake apk received unexpected arguments: $*" >&2
        exit 98
        ;;
esac

if [ "${R10_FAKE_EMPTY_HELP:-}" != "${command_name}" ]; then
    case "${command_name}" in
        global)
            printf '%s\n' 'apk-tools 3.0.5, compiled for aarch64.'
            printf '%s\n' 'Usage: apk [<GLOBAL OPTIONS>...] COMMAND [<OPTIONS>...]'
            ;;
        info)
            printf '%s\n' 'Usage: apk info [<OPTIONS>]'
            [ "${R10_FAKE_MISSING_CAPABILITY:-}" = "exists" ] || printf '%s\n' '  --exists'
            ;;
        add)
            printf '%s\n' 'Usage: apk add [<OPTIONS>]'
            [ "${R10_FAKE_MISSING_CAPABILITY:-}" = "simulate" ] || printf '%s\n' '  --simulate'
            if [ "${R10_FAKE_MISSING_CAPABILITY:-}" != "no-network" ]; then
                case "${R10_FAKE_NETWORK_HELP_STYLE:-explicit}" in
                    explicit) printf '%s\n' '  --no-network' ;;
                    boolean) printf '%s\n' '  --network[=BOOL]' ;;
                    *) echo "invalid fake network help style" >&2; exit 97 ;;
                esac
            fi
            ;;
        adbdump)
            printf '%s\n' 'Usage: apk adbdump [<OPTIONS>]'
            [ "${R10_FAKE_MISSING_CAPABILITY:-}" = "format" ] || printf '%s\n' '  --format FORMAT'
            ;;
        list)
            printf '%s\n' 'Usage: apk list [<OPTIONS>]'
            [ "${R10_FAKE_MISSING_CAPABILITY:-}" = "installed" ] || printf '%s\n' '  --installed'
            ;;
    esac
fi
exit "${help_rc}"
EOF
"${HOST_CHMOD}" 0755 "${BIN_DIR}/apk"

for command_name in cat grep rm; do
    case "${command_name}" in
        cat) host_command="${HOST_CAT}" ;;
        grep) host_command="${HOST_GREP}" ;;
        rm) host_command="${HOST_RM}" ;;
    esac
    cat > "${BIN_DIR}/${command_name}" <<EOF
#!/bin/sh
exec "${host_command}" "\$@"
EOF
    "${HOST_CHMOD}" 0755 "${BIN_DIR}/${command_name}"
done

LEGACY_HARNESS="${TMP_DIR}/legacy-harness.sh"
cat > "${LEGACY_HARNESS}" <<'EOF'
#!/bin/sh
set -eu
apk --version
apk --help
echo LEGACY_BARE_HELP_REACHED_END
EOF
"${HOST_CHMOD}" 0755 "${LEGACY_HARNESS}"

LEGACY_OUTPUT="${TMP_DIR}/legacy.out"
if R10_FAKE_GLOBAL_HELP_RC=1 \
    R10_PACKAGE_MARKER="${TMP_DIR}/legacy-package-operation" \
    PATH="${BIN_DIR}" \
    /bin/sh "${LEGACY_HARNESS}" > "${LEGACY_OUTPUT}" 2>&1; then
    echo "FAIL: legacy bare apk --help unexpectedly accepted status 1" >&2
    exit 1
fi
grep -q 'Usage: apk' "${LEGACY_OUTPUT}" || {
    echo "FAIL: physical apk-tools 3.0.5 help output was not reproduced" >&2
    exit 1
}
if grep -q 'LEGACY_BARE_HELP_REACHED_END' "${LEGACY_OUTPUT}"; then
    echo "FAIL: legacy set -e harness continued after help status 1" >&2
    exit 1
fi
echo "PASS: physical failure reproduced: valid global help status 1 terminates the legacy set -e probe."

grep -Fq 'sh "${SCRIPT_DIR}/test_apk_help_compatibility.sh"' "${MASTER_RUNNER}" || {
    echo "FAIL: apk-help compatibility regression is not wired into the master runner" >&2
    exit 1
}

HELPERS="${TMP_DIR}/apk-help-helpers.sh"
PREFLIGHT="${TMP_DIR}/apk-help-preflight.sh"
sed -n '/^# BEGIN R10_APK_HELP_COMPATIBILITY_HELPERS$/,/^# END R10_APK_HELP_COMPATIBILITY_HELPERS$/p' \
    "${INSTALLER}" > "${HELPERS}"
sed -n '/^# BEGIN R10_APK_HELP_COMPATIBILITY_PREFLIGHT$/,/^# END R10_APK_HELP_COMPATIBILITY_PREFLIGHT$/p' \
    "${INSTALLER}" > "${PREFLIGHT}"

grep -q '^r10_capture_apk_help()' "${HELPERS}" && [ -s "${PREFLIGHT}" ] || {
    echo "FAIL: old installer has no status-1-safe apk help compatibility logic" >&2
    exit 1
}

HARNESS="${TMP_DIR}/harness.sh"
cat > "${HARNESS}" <<'EOF'
#!/bin/sh
set -eu
. "${R10_HELPERS}"
BACKUP_DIR="${R10_CASE_DIR}/preflight"
. "${R10_PREFLIGHT}"
[ ! -e "${R10_PACKAGE_MARKER}" ] || {
    echo "FAIL: package operation executed during apk capability preflight" >&2
    exit 1
}
echo APK_HELP_PREFLIGHT_REACHED_END
EOF
"${HOST_CHMOD}" 0755 "${HARNESS}"

run_case() (
    case_name="$1"
    expected_rc="$2"
    expected_text="$3"
    shift 3
    case_dir="${TMP_DIR}/${case_name}"
    mkdir -p "${case_dir}"
    for assignment in "$@"; do
        export "${assignment}"
    done
    export R10_HELPERS="${HELPERS}"
    export R10_PREFLIGHT="${PREFLIGHT}"
    export R10_CASE_DIR="${case_dir}"
    export R10_PACKAGE_MARKER="${case_dir}/package-operation"
    export PATH="${BIN_DIR}"
    case_output="${case_dir}/output"
    if /bin/sh "${HARNESS}" > "${case_output}" 2>&1; then
        actual_rc=0
    else
        actual_rc=$?
    fi
    [ "${actual_rc}" -eq "${expected_rc}" ] || {
        echo "FAIL: ${case_name} exit ${actual_rc}, expected ${expected_rc}" >&2
        cat "${case_output}" >&2
        exit 1
    }
    grep -Fq "${expected_text}" "${case_output}" || {
        echo "FAIL: ${case_name} missing diagnostic/marker: ${expected_text}" >&2
        cat "${case_output}" >&2
        exit 1
    }
    [ ! -e "${R10_PACKAGE_MARKER}" ] || {
        echo "FAIL: ${case_name} executed a package operation" >&2
        exit 1
    }
)

run_case global_status_0 0 APK_HELP_PREFLIGHT_REACHED_END \
    R10_FAKE_GLOBAL_HELP_RC=0
echo "PASS: valid global help status 0 is accepted."

run_case global_status_1 0 APK_HELP_PREFLIGHT_REACHED_END \
    R10_FAKE_GLOBAL_HELP_RC=1
echo "PASS: valid global help status 1 is accepted under set -e."

run_case subcommand_status_1 0 APK_HELP_PREFLIGHT_REACHED_END \
    R10_FAKE_INFO_HELP_RC=1 R10_FAKE_ADD_HELP_RC=1 \
    R10_FAKE_ADBDUMP_HELP_RC=1 R10_FAKE_LIST_HELP_RC=1
echo "PASS: valid subcommand help status 1 is accepted."

run_case network_boolean_help 0 APK_HELP_PREFLIGHT_REACHED_END \
    R10_FAKE_NETWORK_HELP_STYLE=boolean
echo "PASS: target apk --network[=BOOL] help is accepted when --no-network parses successfully."

run_case no_network_probe_failure 1 'ERROR: target apk --no-network probe failed with exit 2' \
    R10_FAKE_NETWORK_HELP_STYLE=boolean R10_FAKE_NO_NETWORK_PROBE_RC=2
echo "PASS: an unexpected --no-network parsing failure is rejected explicitly."

run_case empty_no_network_probe 1 'ERROR: target apk --no-network probe produced no output' \
    R10_FAKE_NETWORK_HELP_STYLE=boolean R10_FAKE_EMPTY_NO_NETWORK_PROBE=1
echo "PASS: empty --no-network probe output is rejected."

run_case invalid_no_network_probe 1 'ERROR: target apk --no-network probe output is invalid' \
    R10_FAKE_NETWORK_HELP_STYLE=boolean R10_FAKE_NO_NETWORK_PROBE_OUTPUT='unexpected output'
echo "PASS: invalid --no-network probe output is rejected."

run_case unexpected_status_2 1 'ERROR: apk help command failed with exit 2: apk' \
    R10_FAKE_GLOBAL_HELP_RC=2
echo "PASS: unexpected help status 2 is rejected with an explicit diagnostic."

run_case empty_help 1 'ERROR: apk help command produced no output: apk' \
    R10_FAKE_GLOBAL_HELP_RC=1 R10_FAKE_EMPTY_HELP=global
echo "PASS: empty help output is rejected."

run_case missing_exists 1 'ERROR: target apk does not support apk info --exists' \
    R10_FAKE_MISSING_CAPABILITY=exists
echo "PASS: missing apk info --exists is rejected."

run_case missing_simulate 1 'ERROR: target apk does not support --simulate' \
    R10_FAKE_MISSING_CAPABILITY=simulate
echo "PASS: missing apk add --simulate is rejected."

run_case missing_no_network 1 'ERROR: target apk does not support --no-network' \
    R10_FAKE_MISSING_CAPABILITY=no-network
echo "PASS: missing apk add --no-network is rejected."

run_case missing_format 1 'ERROR: target apk adbdump lacks JSON format support' \
    R10_FAKE_MISSING_CAPABILITY=format
echo "PASS: missing apk adbdump --format is rejected."

run_case missing_installed 1 'ERROR: target apk list lacks --installed' \
    R10_FAKE_MISSING_CAPABILITY=installed
echo "PASS: missing apk list --installed is rejected."

echo "PASS: no package add, fix, upgrade, or install operation ran during any preflight case."
echo "R10_APK_NETWORK_BOOLEAN_HELP_OK"
echo "R10_APK_HELP_COMPATIBILITY_OK"
