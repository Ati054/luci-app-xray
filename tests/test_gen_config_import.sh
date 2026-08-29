#!/bin/sh
set -e
echo "Testing gen_config.uc import boundary..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/../"

# Create a dummy ucode script that imports gen_config.uc
cat << 'EOF' > scratch/dummy_import.uc
import { gen_config } from "./core/root/usr/share/xray/gen_config.uc";
printf("IMPORT_OK\n");
EOF

# Run it and check output
OUT="$(ucode scratch/dummy_import.uc 2>&1 || true)"
if echo "$OUT" | grep -q "inbounds"; then
    echo "FAIL: gen_config.uc leaked JSON to stdout upon import"
    exit 1
fi
if ! echo "$OUT" | grep -q "IMPORT_OK"; then
    echo "FAIL: Dummy script did not execute properly"
    exit 1
fi

echo "PASS: gen_config.uc respects module boundaries."
exit 0
