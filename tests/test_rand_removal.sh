#!/bin/sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RPCD_XRAY="${SCRIPT_DIR}/../core/root/usr/libexec/rpcd/xray_profiles"

echo "=== Test 8-11: No rand() and exclusive temp file creation ==="

if grep -q "rand()" "$RPCD_XRAY"; then
    echo "FAIL: rpcd script still uses rand()"
    exit 1
fi

if ! grep -q "mkdtemp" "$RPCD_XRAY"; then
    echo "FAIL: rpcd script does not use mkdtemp"
    exit 1
fi

echo "PASS: rpcd script uses mkdtemp and not rand()."
exit 0
