#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RPCD_XRAY="${SCRIPT_DIR}/../core/root/usr/libexec/rpcd/xray_profiles"
UCODE_BIN="${UCODE_BIN:-ucode}"

echo "=== RPCD argument-presence and stdin regression ==="

if ! command -v timeout >/dev/null 2>&1; then
    echo "FAIL: timeout is required for the rpcd blocking regression"
    exit 1
fi

if ! command -v "${UCODE_BIN}" >/dev/null 2>&1 && [ ! -x "${UCODE_BIN}" ]; then
    echo "FAIL: exact ucode runtime is required"
    exit 1
fi

MOCK_ROOT="$(mktemp -d)"
WRITER_PID=""
cleanup() {
    if [ -n "${WRITER_PID}" ]; then
        kill "${WRITER_PID}" 2>/dev/null || :
        wait "${WRITER_PID}" 2>/dev/null || :
    fi
    rm -rf "${MOCK_ROOT}"
}
trap cleanup EXIT INT TERM

mkdir -p "${MOCK_ROOT}/etc/config"
cat > "${MOCK_ROOT}/etc/config/xray_core" <<'EOF'
config general 'general'
	option reverse_only '1'
EOF

# Keep stdin open without sending data. Explicit {} must make the backend skip
# stdin entirely and return before the timeout.
FIFO="${MOCK_ROOT}/open-stdin"
mkfifo "${FIFO}"
(
    exec 3>"${FIFO}"
    sleep 5
) &
WRITER_PID=$!

if ! XRAY_PROFILES_MOCK_DIR="${MOCK_ROOT}" timeout 2 "${UCODE_BIN}" "${RPCD_XRAY}" call list '{}' < "${FIFO}" > "${MOCK_ROOT}/explicit.json"; then
    echo "FAIL: explicit {} blocked on open stdin or returned failure"
    exit 1
fi
grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' "${MOCK_ROOT}/explicit.json" || {
    echo "FAIL: explicit {} did not return a successful list response"
    cat "${MOCK_ROOT}/explicit.json" >&2
    exit 1
}

kill "${WRITER_PID}" 2>/dev/null || :
wait "${WRITER_PID}" 2>/dev/null || :
WRITER_PID=""

# With no CLI JSON argument, stdin is the authoritative rpcd input channel.
if ! printf '{}\n' | XRAY_PROFILES_MOCK_DIR="${MOCK_ROOT}" timeout 2 "${UCODE_BIN}" "${RPCD_XRAY}" call list > "${MOCK_ROOT}/stdin.json"; then
    echo "FAIL: stdin invocation without a CLI argument failed"
    exit 1
fi
grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' "${MOCK_ROOT}/stdin.json" || {
    echo "FAIL: stdin invocation did not dispatch the list method"
    cat "${MOCK_ROOT}/stdin.json" >&2
    exit 1
}

echo "PASS: explicit argument and stdin modes are independent and bounded."
