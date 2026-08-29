#!/bin/sh
set -e

echo "=== Test 1 & 2: Executable permissions ==="

# Check files in git or the local tree
for f in core/root/etc/init.d/xray_core \
         core/root/etc/init.d/xray_profiles \
         core/root/usr/libexec/rpcd/xray \
         core/root/usr/libexec/rpcd/xray_profiles \
         core/root/usr/share/xray/gen_config.uc \
         core/root/usr/share/xray/default_gateway.uc \
         core/root/usr/share/xray/dnsmasq_include.ut \
         core/root/usr/share/xray/firewall_include.ut; do
    if [ ! -x "$f" ]; then
        echo "FAIL: $f does not have execute permissions locally"
        exit 1
    fi
done

echo "PASS: Executable modes are set locally."
exit 0
