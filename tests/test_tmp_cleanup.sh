#!/bin/sh
set -e
echo "Testing xray_profiles temporary file cleanup on failure..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/../"

PROFILES_DIR="${SCRIPT_DIR}/../scratch/profiles_test"
mkdir -p "${PROFILES_DIR}"

# Run xray_profiles to import a broken profile that causes validate failure or we can just mock Xray binary to fail
export PROFILES_DIR
export XRAY_BIN="/bin/false"
export XRAY_LOCATION_ASSET="/tmp"

# Count tmp files before
TMP_BEFORE="$(ls -1 "${PROFILES_DIR}" | grep "\.tmp_" | wc -l || true)"

# Call validate with dummy content
./core/root/usr/libexec/rpcd/xray_profiles --mock-dir "${PROFILES_DIR}" call validate '{"content":"{\"dummy\":\"test\"}"}' >/dev/null 2>&1 || true

# Count tmp files after
TMP_AFTER="$(ls -1 "${PROFILES_DIR}" | grep "\.tmp_" | wc -l || true)"

if [ "$TMP_BEFORE" != "$TMP_AFTER" ]; then
    echo "FAIL: Temporary files leaked! Before: $TMP_BEFORE, After: $TMP_AFTER"
    ls -l "${PROFILES_DIR}"
    exit 1
fi

echo "PASS: Temporary files are properly cleaned up."
exit 0
