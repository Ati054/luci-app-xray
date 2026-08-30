#!/bin/sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RPCD_XRAY="${SCRIPT_DIR}/../core/root/usr/libexec/rpcd/xray_profiles"

echo "=== Test 6 & 7: rpcd stdin blocking on {} ==="

if ! command -v ucode >/dev/null 2>&1; then
    echo "  [SKIP] ucode CLI not available in current environment."
    exit 0
fi

# Using timeout to ensure it doesn't block
if ! timeout 2 ucode "$RPCD_XRAY" call list '{}' </dev/null >/dev/null 2>&1; then
    echo "FAIL: rpcd script blocked or timed out when provided {}"
    exit 1
fi

echo "PASS: rpcd script handled {} correctly without blocking."
exit 0
