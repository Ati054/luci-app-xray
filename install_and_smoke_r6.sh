#!/bin/sh
set -e

echo "=== R6 Offline Deployment and Smoke Test ==="

if [ "$(id -u)" -ne 0 ]; then
    echo "Must run as root!"
    exit 1
fi

echo "Installing offline dependencies..."
for apk_file in coreutils*.apk ip-full*.apk; do
    if [ -f "$apk_file" ]; then
        apk add --allow-untrusted "$apk_file" || true
    fi
done

echo "Installing luci-app-xray packages..."
for apk_file in luci-app-xray*.apk; do
    if [ -f "$apk_file" ]; then
        apk add --allow-untrusted "$apk_file"
    fi
done

echo "Running hardware smoke test..."
sh profile_mode_smoke.sh

echo "R6 Deployment and Test completed successfully."
exit 0
