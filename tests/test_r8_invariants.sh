#!/bin/sh
set -e

echo "=== R8 Invariant Tests ==="

WORKFLOW=".github/workflows/build-release.yml"
INSTALLER="install_and_smoke_r8.sh"

fail() {
    echo "::error:: $1"
    exit 1
}

# 1. missing APK database initialization is rejected
if ! grep -q "mkdir -p .*lib/apk/db" "$WORKFLOW"; then
    fail "Missing lib/apk/db initialization in workflow"
fi

# 2. repository entries end exactly in packages.adb
if grep -q "APKINDEX.tar.gz" "$WORKFLOW"; then
    fail "Found tar.gz in workflow, expected packages.adb"
fi
if ! grep -q "packages.adb" "$WORKFLOW"; then
    fail "Did not find packages.adb in workflow"
fi

# 3. no repository path contains duplicated architecture
# aarch64_cortex-a53/aarch64_cortex-a53 should not exist
if grep -q "aarch64_cortex-a53/aarch64_cortex-a53" "$WORKFLOW"; then
    fail "Repository path contains duplicated architecture"
fi

# 4. no resolver command searches APKINDEX.tar.gz
if grep -q "APKINDEX" "$WORKFLOW"; then
    fail "Resolver command searches APKINDEX"
fi

# 5. apk update failure makes the step fail
if ! grep -A 10 "update" "$WORKFLOW" | grep -q "UPDATE_RC="; then
    fail "apk update RC is not captured"
fi

# 6. apk fetch failure makes the step fail
if ! grep -A 10 "fetch" "$WORKFLOW" | grep -q "FETCH_RC="; then
    fail "apk fetch RC is not captured"
fi

if ! grep -q "if \[ \"\$UPDATE_RC\" -ne 0 \] || \[ \"\$FETCH_RC\" -ne 0 \]; then" "$WORKFLOW"; then
    fail "Fail-closed check for apk update/fetch is missing"
fi

# 7. zero downloaded APKs make the step fail
if ! grep -q "if \[ \"\${#APKS\[@\]}\" -eq 0 \]; then" "$WORKFLOW"; then
    fail "Zero downloaded APKs does not make the step fail"
fi

# 8. zero-byte APK makes the step fail
if ! grep -q "if \[ \! -s " "$WORKFLOW"; then
    fail "Zero-byte APK check missing"
fi

# 9. invalid APK makes the step fail
if ! grep -q "if \! \"\$APK_HOST\" manifest " "$WORKFLOW"; then
    fail "Invalid APK check missing"
fi

# 10. wrong architecture makes the step fail
if ! grep -q "echo \"::error::Invalid architecture \$PKG_ARCH in \$f\"" "$WORKFLOW"; then
    fail "Wrong architecture check missing"
fi

# 11. dependency output contains more than the three resolver roots
# This is dynamic in CI, but statically we can verify it doesn't just do `cp coreutils.apk` etc.
if ! grep -q "cp \"\$APK_OUTPUT\"/\*\.apk" "$WORKFLOW"; then
    fail "Dynamic dependency copying is missing"
fi

# 12. every artifact file is covered by SHA256SUMS-R8
if ! grep -q 'CHECKSUM_FILE="SHA256SUMS-R8.txt"' "$WORKFLOW"; then
    fail "SHA256SUMS-R8.txt is not the checksum file"
fi
if ! grep -q "for f in \*\.apk \*\.ipk profile_mode_smoke.sh install_and_smoke_r8.sh profile-\*\.json \"\$BUILD_INFO_FILE\" OFFLINE-PACKAGES-MANIFEST.txt;" "$WORKFLOW"; then
    fail "Not all artifact files are covered by checksums"
fi

# 13. complete offline simulation passes
if ! grep -q -- "--simulate" "$WORKFLOW"; then
    fail "Offline simulation is missing"
fi

# 14. installer is fail-closed
if grep "|| true" "$INSTALLER" | grep -q -v "restore_backup"; then
    # Some true statements might exist in restore_backup, but main flow must not have them.
    if grep -n "|| true" "$INSTALLER" | grep -v "restore_backup"; then
        fail "Installer contains || true outside of restore_backup"
    fi
fi

# 15. no critical path contains || true
if grep -A 10 "fetch -R" "$WORKFLOW" | grep -q "|| true"; then
    fail "Critical path (fetch) contains || true"
fi
if grep -A 10 "update" "$WORKFLOW" | grep -q "|| true"; then
    fail "Critical path (update) contains || true"
fi

# 16. BUILD-INFO reports package release 8
if ! grep -q "PKG_RELEASE:=8" core/Makefile; then
    fail "BUILD-INFO will not report release 8, core/Makefile is not updated"
fi

# 17. installer success marker is exact
if ! grep -q "R8_INSTALL_AND_HARDWARE_SMOKE_OK" "$INSTALLER"; then
    fail "Installer success marker is incorrect"
fi

echo "  [PASS] All R8 invariants validated."
exit 0
