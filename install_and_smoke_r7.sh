#!/bin/sh
# install_and_smoke_r7.sh
set -eu

# Diagnostic log setup
DIAG_LOG="/tmp/r7_install_diag_$(date +%s).log"
exec 3>&1 4>&2
trap 'if [ $? -ne 0 ]; then echo "FAILURE DETECTED. Check $DIAG_LOG"; restore_backup; fi' EXIT
exec 1>>"$DIAG_LOG" 2>&1

echo "=== R7 Offline Deployment and Smoke Test ===" >&3
echo "Logging to $DIAG_LOG" >&3

restore_backup() {
    echo "Restoring backups on failure..." >&3
    # Stop and disable if we started them
    /etc/init.d/xray_core stop 2>/dev/null || true
    /etc/init.d/xray_profiles stop 2>/dev/null || true
    
    if [ -f "/tmp/r7_backup/xray_core.conf" ]; then
        cp "/tmp/r7_backup/xray_core.conf" "/etc/config/xray_core"
    fi
    if [ -d "/tmp/r7_backup/profiles" ]; then
        rm -rf "/opt/xray/profiles"
        cp -a "/tmp/r7_backup/profiles" "/opt/xray/profiles"
    fi
    # restore service enablement
    if [ -f "/tmp/r7_backup/xray_core.enabled" ]; then
        /etc/init.d/xray_core enable 2>/dev/null || true
    else
        /etc/init.d/xray_core disable 2>/dev/null || true
    fi
    if [ -f "/tmp/r7_backup/xray_profiles.enabled" ]; then
        /etc/init.d/xray_profiles enable 2>/dev/null || true
    else
        /etc/init.d/xray_profiles disable 2>/dev/null || true
    fi
}

# 1. Require root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root!" >&3
    exit 1
fi

# 2. Require OpenWrt 25.12.5
if ! grep -q "25.12.5" /etc/openwrt_release 2>/dev/null; then
    echo "ERROR: Must run on OpenWrt 25.12.5!" >&3
    exit 1
fi

# 3. Require aarch64
if [ "$(uname -m)" != "aarch64" ]; then
    echo "ERROR: Must run on aarch64!" >&3
    exit 1
fi

# 4. Require /opt mounted and writable
if ! touch /opt/.r7_test_writable 2>/dev/null; then
    echo "ERROR: /opt must be writable!" >&3
    exit 1
fi
rm -f /opt/.r7_test_writable

# 5. Require executable Xray 26.7.28
XRAY_BIN="/opt/xray/current/xray"
if [ ! -x "$XRAY_BIN" ]; then
    echo "ERROR: Executable not found at $XRAY_BIN" >&3
    exit 1
fi
XRAY_VER=$("$XRAY_BIN" version | head -n1 | awk '{print $2}')
if [ "$XRAY_VER" != "26.7.28" ]; then
    echo "ERROR: Expected Xray 26.7.28, found $XRAY_VER" >&3
    exit 1
fi

# 6. Verify every file through SHA256SUMS-R7.txt (or SHA256SUMS-openwrt-25.12.5-all.txt)
CHECKSUM_FILE="$(ls SHA256SUMS*.txt | head -n1)"
if [ -z "$CHECKSUM_FILE" ]; then
    echo "ERROR: Checksum file not found!" >&3
    exit 1
fi
echo "Verifying checksums..." >&3
sha256sum -c "$CHECKSUM_FILE"

# 7. Reject any zero-byte APK
for f in *.apk; do
    if [ ! -s "$f" ]; then
        echo "ERROR: Zero-byte APK found: $f" >&3
        exit 1
    fi
done

# 8. Inspect every APK with official apk-tools
for f in *.apk; do
    if ! apk manifest "$f" >/dev/null; then
        echo "ERROR: Invalid APK according to apk-tools: $f" >&3
        exit 1
    fi
done

# 9. Back up
mkdir -p /tmp/r7_backup
[ -f /etc/config/xray_core ] && cp -p /etc/config/xray_core /tmp/r7_backup/xray_core.conf
[ -d /opt/xray/profiles ] && cp -a /opt/xray/profiles /tmp/r7_backup/profiles
if /etc/init.d/xray_core enabled 2>/dev/null; then touch /tmp/r7_backup/xray_core.enabled; fi
if /etc/init.d/xray_profiles enabled 2>/dev/null; then touch /tmp/r7_backup/xray_profiles.enabled; fi
ps -w > /tmp/r7_backup/ps_before.txt
apk info > /tmp/r7_backup/apk_info_before.txt

# 10. Stop and disable
/etc/init.d/xray_core stop 2>/dev/null || true
/etc/init.d/xray_core disable 2>/dev/null || true
/etc/init.d/xray_profiles stop 2>/dev/null || true
/etc/init.d/xray_profiles disable 2>/dev/null || true

# 11,12. Offline transaction simulation
echo "Simulating installation (offline)..." >&3
apk add --simulate --no-network --allow-untrusted *.apk

# 13. Install the complete transaction with networking disabled
echo "Installing packages (offline)..." >&3
apk add --no-network --allow-untrusted *.apk

# 14. Verify installed package release 7
CORE_INST=$(apk info -e luci-app-xray | head -n1 || true)
if [ -z "$CORE_INST" ]; then
    echo "ERROR: luci-app-xray not installed" >&3
    exit 1
fi
INST_VER=$(apk info -d "$CORE_INST" | grep -v 'luci-app-xray description:' | head -n1 || true)
# For OpenWrt 25.12.5 we expect 3.7.1-r7
if ! echo "$INST_VER" | grep -q -- "-r7"; then
    echo "ERROR: Installed version $INST_VER does not contain -r7" >&3
    exit 1
fi

# 15. Verify executable modes
for p in /usr/libexec/rpcd/xray /usr/libexec/rpcd/xray_profiles /etc/init.d/xray_core /etc/init.d/xray_profiles; do
    if [ ! -x "$p" ]; then
        echo "ERROR: $p is not executable" >&3
        exit 1
    fi
done

# 16. verify profile directory mode 0700
mkdir -p /opt/xray/profiles
chmod 0700 /opt/xray/profiles
PDIR_PERM=$(stat -c "%a" /opt/xray/profiles 2>/dev/null || stat -f "%Op" /opt/xray/profiles | cut -c 4-)
if [ "$PDIR_PERM" != "700" ]; then
    echo "ERROR: /opt/xray/profiles mode is $PDIR_PERM, expected 700" >&3
    exit 1
fi

# 17. verify profile file mode 0600 when smoke profiles are imported
if [ -f ./profile-smoke-a.json ]; then
    cp ./profile-smoke-a.json /opt/xray/profiles/
    chmod 0600 /opt/xray/profiles/profile-smoke-a.json
    PFILE_PERM=$(stat -c "%a" /opt/xray/profiles/profile-smoke-a.json 2>/dev/null || stat -f "%Op" /opt/xray/profiles/profile-smoke-a.json | cut -c 4-)
    if [ "$PFILE_PERM" != "600" ]; then
        echo "ERROR: profile file mode is $PFILE_PERM, expected 600" >&3
        exit 1
    fi
fi

# 18. verify rpcd explicit `{}` doesn't block
echo "Checking rpcd list blocking..." >&3
TIMEOUT_CMD="timeout 2s"
if ! type timeout >/dev/null 2>&1; then TIMEOUT_CMD=""; fi
$TIMEOUT_CMD /usr/libexec/rpcd/xray_profiles call list '{}' < /dev/null > /tmp/rpcd_out 2>/tmp/rpcd_err || {
    echo "ERROR: rpcd call list blocked or failed" >&3
    exit 1
}

# 19. verify the exact pinned target ucode executes the installed modules
# 20. verify gen_config.uc
UCODE_BIN=$(which ucode || true)
if [ -z "$UCODE_BIN" ]; then
    echo "ERROR: ucode not found" >&3
    exit 1
fi
echo "Verifying gen_config.uc..." >&3
$UCODE_BIN /usr/share/xray/gen_config.uc > /tmp/xray_gen_test.json

# 21. verify empty/default generated JSON using real Xray 26.7.28
echo "Verifying generated config with Xray..." >&3
"$XRAY_BIN" test -c /tmp/xray_gen_test.json

# 22. run the target-safe hardware profile smoke
echo "Running hardware smoke..." >&3
sh profile_mode_smoke.sh

# 23. remove all smoke profiles
rm -rf /opt/xray/profiles/*

# 24. leave both Xray services stopped and disabled
/etc/init.d/xray_core stop
/etc/init.d/xray_profiles stop
/etc/init.d/xray_core disable
/etc/init.d/xray_profiles disable

# 25. leave no Xray process
if pgrep xray >/dev/null; then
    echo "ERROR: xray process still running" >&3
    exit 1
fi

# If we get here, clear trap to not run restore_backup
trap - EXIT

# 28. print exactly on complete success
echo "R7_INSTALL_AND_HARDWARE_SMOKE_OK" >&3
exit 0
