#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RPCD_XRAY="${SCRIPT_DIR}/../core/root/usr/libexec/rpcd/xray_profiles"

echo "=== Test 8-11: No rand() and portable exclusive temp creation ==="

if grep -q "rand()" "$RPCD_XRAY"; then
    echo "FAIL: rpcd script still uses rand()"
    exit 1
fi

if ! grep -q 'function make_temp_dir' "$RPCD_XRAY" || ! grep -q 'if (mkdir(path, 0700))' "$RPCD_XRAY"; then
    echo "FAIL: rpcd script does not use portable atomic directory creation"
    exit 1
fi

if grep -q 'open(.*"wx"' "$RPCD_XRAY"; then
    echo "FAIL: rpcd script uses unsupported fopen mode wx instead of an exclusive temporary directory"
    exit 1
fi

if ! grep -q 'open(tmp_path, "w", 0600)' "$RPCD_XRAY"; then
    echo "FAIL: temporary profile content is not opened with mode 0600"
    exit 1
fi

if grep -q 'let meta = { pid: 0' "$RPCD_XRAY" || ! grep -q 'readfile("/proc/self/stat")' "$RPCD_XRAY"; then
    echo "FAIL: lock ownership does not record the live backend PID"
    exit 1
fi

echo "PASS: rpcd script uses owned locks, exclusive temporary directories, mode 0600, and no rand()."
exit 0
