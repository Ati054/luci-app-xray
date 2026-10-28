#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
HELPER="${ROOT_DIR}/core/root/usr/libexec/xray-update"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT HUP INT TERM

BIN_DIR="${TMP_DIR}/bin"
STATE="${TMP_DIR}/state"
mkdir -p "${BIN_DIR}" "${STATE}"

cat > "${BIN_DIR}/apk" <<'EOF'
#!/bin/sh
case "$1" in
	query)
		cat <<'JSON'
{
  "name": "luci-app-xray",
  "version": "3.7.1-r12",
  "arch": "aarch64_cortex-a53"
}
JSON
		;;
	version) printf '%s\n' '>' ;;
	*) exit 1 ;;
esac
EOF

cat > "${BIN_DIR}/start-stop-daemon" <<'EOF'
#!/bin/sh
if [ "${1:-}" = --help ]; then
	printf '%s\n' 'start-stop-daemon -S -b -m -p PIDFILE -x EXECUTABLE -O FILE -- ARGS'
	exit 0
fi
printf '%s\n' "$*" > "${XRAY_UPDATE_TEST_SSD_LOG}"
pidfile=''
while [ "$#" -gt 0 ]; do
	if [ "$1" = -p ]; then
		pidfile=$2
		break
	fi
	shift
done
[ -n "${pidfile}" ]
printf '%s\n' 4242 > "${pidfile}"
EOF

cat > "${BIN_DIR}/xray" <<'EOF'
#!/bin/sh
printf '%s\n' 'Xray 26.10.21 (Xray, Penetrates Everything.)'
EOF

cat > "${BIN_DIR}/logger" <<'EOF'
#!/bin/sh
exit 0
EOF

chmod 0700 "${BIN_DIR}"/*
export PATH="${BIN_DIR}:${PATH}"
export XRAY_UPDATE_STATE="${STATE}"
export XRAY_UPDATE_RUNNER="${TMP_DIR}/runner"
export XRAY_UPDATE_CANDIDATE="${TMP_DIR}/candidate.tar.gz"
export XRAY_UPDATE_EXTRACTED="${TMP_DIR}/extracted"
export XRAY_UPDATE_HELPER_SOURCE="${HELPER}"
export XRAY_UPDATE_XRAY_BIN="${BIN_DIR}/xray"
export XRAY_UPDATE_TEST_SSD_LOG="${TMP_DIR}/ssd.log"

check_output="$(sh "${HELPER}" check)"
[ "${check_output}" = 'started=pending' ]
grep -Fq -- '-S -b -m -p' "${XRAY_UPDATE_TEST_SSD_LOG}"
grep -Fq -- '-x /bin/sh -O' "${XRAY_UPDATE_TEST_SSD_LOG}"
grep -Fq -- 'check-worker' "${XRAY_UPDATE_TEST_SSD_LOG}"
[ -s "${STATE}/worker.pid" ]

echo XRAY_UPDATE_DETACH_OK
