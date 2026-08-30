#!/bin/sh
set -eu

echo "=== RPCD concurrent temporary isolation and cleanup ==="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RPCD_BACKEND="${ROOT_DIR}/core/root/usr/libexec/rpcd/xray_profiles"
UCODE_BIN="${UCODE_BIN:-ucode}"
FIXTURE="${SCRIPT_DIR}/fixtures/profile-smoke-a.json"

if ! command -v "${UCODE_BIN}" >/dev/null 2>&1 && [ ! -x "${UCODE_BIN}" ]; then
    echo "FAIL: exact ucode runtime is required"
    exit 1
fi

MOCK_ROOT="$(mktemp -d)"
cleanup() {
    rm -rf "${MOCK_ROOT}"
}
trap cleanup EXIT INT TERM

mkdir -p "${MOCK_ROOT}/etc/config" "${MOCK_ROOT}/opt/xray/current"
cat > "${MOCK_ROOT}/etc/config/xray_core" <<'EOF'
config general 'general'
	option reverse_only '1'
EOF

cat > "${MOCK_ROOT}/xray" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "version" ]; then
    echo "Xray 26.7.28 (temporary-isolation-test)"
    exit 0
fi
if [ "${1:-}" = "run" ] && [ "${2:-}" = "-test" ] && [ "${3:-}" = "-config" ]; then
    test -s "${4:-}"
    sleep 1
    [ "${MOCK_XRAY_FAIL:-0}" = "1" ] && exit 23
    exit 0
fi
exit 1
EOF
chmod 0755 "${MOCK_ROOT}/xray"

CONTENT="$(tr -d '\n\r' < "${FIXTURE}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
PAYLOAD="{\"content\":\"${CONTENT}\"}"

pids=""
i=1
while [ "${i}" -le 6 ]; do
    "${UCODE_BIN}" "${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call validate "${PAYLOAD}" > "${MOCK_ROOT}/result-${i}.json" 2>&1 &
    pids="${pids} $!"
    i=$((i + 1))
done

for pid in ${pids}; do
    wait "${pid}"
done

for result in "${MOCK_ROOT}"/result-*.json; do
    grep -q '"ok":true' "${result}" || {
        echo "FAIL: concurrent validation failed: ${result}"
        cat "${result}"
        exit 1
    }
done

if find "${MOCK_ROOT}/opt/xray/profiles" -maxdepth 1 -type d \( -name '.tmp_*' -o -name '.run_*' \) | grep -q .; then
    echo "FAIL: concurrent success leaked a temporary directory"
    find "${MOCK_ROOT}/opt/xray/profiles" -maxdepth 1 -print
    exit 1
fi

if MOCK_XRAY_FAIL=1 "${UCODE_BIN}" "${RPCD_BACKEND}" --mock-dir "${MOCK_ROOT}" call validate "${PAYLOAD}" > "${MOCK_ROOT}/failure.json" 2>&1; then
    echo "FAIL: failing Xray validation unexpectedly succeeded"
    exit 1
fi
grep -q '"ok":false' "${MOCK_ROOT}/failure.json" || {
    echo "FAIL: failing Xray validation did not return structured failure"
    exit 1
}

if find "${MOCK_ROOT}/opt/xray/profiles" -maxdepth 1 -type d \( -name '.tmp_*' -o -name '.run_*' \) | grep -q .; then
    echo "FAIL: failure path leaked a temporary directory"
    find "${MOCK_ROOT}/opt/xray/profiles" -maxdepth 1 -print
    exit 1
fi

echo "PASS: concurrent operations use isolated temporaries and clean success/failure paths."
