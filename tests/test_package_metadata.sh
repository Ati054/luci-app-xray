#!/bin/sh
# Validates core package Makefile metadata, symlinks, and complete module installation

set -e

PASSED=0
FAILED=0

assert_equal() {
    local expected="$1"
    local actual="$2"
    local msg="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  [PASS] $msg"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] $msg (expected '$expected', got '$actual')"
        FAILED=$((FAILED + 1))
    fi
}

echo "=== Test Suite: Package Metadata & Module Completeness ==="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CORE_MAKEFILE="${SCRIPT_DIR}/../core/Makefile"
STATUS_MAKEFILE="${SCRIPT_DIR}/../status/Makefile"
GEODATA_MAKEFILE="${SCRIPT_DIR}/../geodata/Makefile"

# Test 1: core/Makefile must not have +xray-core in DEPENDS
DEPENDS_LINE=$(grep "DEPENDS:=" "${CORE_MAKEFILE}" || true)
HAS_XRAY_CORE_DEP=$(echo "${DEPENDS_LINE}" | grep -c "+xray-core" || true)
assert_equal "0" "${HAS_XRAY_CORE_DEP}" "core/Makefile must not depend on +xray-core"

# Test 2: core/Makefile must point symlink to /opt/xray/current/xray
HAS_OPT_SYMLINK=$(grep -c "LN.*opt/xray/current/xray" "${CORE_MAKEFILE}" || true)
assert_equal "1" "$((HAS_OPT_SYMLINK > 0))" "core/Makefile must install symlink pointing to /opt/xray/current/xray"

# Test 3: PKG_RELEASE must be 10 across core, status, and geodata Makefiles
CORE_REL=$(grep "^PKG_RELEASE:=" "${CORE_MAKEFILE}" | cut -d= -f2 | tr -d ' \r\n' || true)
STATUS_REL=$(grep "^PKG_RELEASE:=" "${STATUS_MAKEFILE}" | cut -d= -f2 | tr -d ' \r\n' || true)
GEODATA_REL=$(grep "^PKG_RELEASE:=" "${GEODATA_MAKEFILE}" | cut -d= -f2 | tr -d ' \r\n' || true)

assert_equal "10" "${CORE_REL}" "core/Makefile has PKG_RELEASE:=10"
assert_equal "10" "${STATUS_REL}" "status/Makefile has PKG_RELEASE:=10"
assert_equal "10" "${GEODATA_REL}" "geodata/Makefile has PKG_RELEASE:=10"

# The OpenWrt 23.05 luci.mk helper drops PKG_RELEASE from the package VERSION.
# Use package.mk directly so both legacy IPK and modern APK builders encode R10.
HAS_NATIVE_PACKAGE_MK=$(grep -Fc 'include $(INCLUDE_DIR)/package.mk' "${CORE_MAKEFILE}" || true)
HAS_LUCI_MK=$(grep -Fc 'feeds/luci/luci.mk' "${CORE_MAKEFILE}" || true)
HAS_BUILD_PACKAGE=$(grep -Fc '$(eval $(call BuildPackage,$(PKG_NAME)))' "${CORE_MAKEFILE}" || true)
assert_equal "1" "$((HAS_NATIVE_PACKAGE_MK > 0))" "core/Makefile uses package.mk so IPK preserves release 10"
assert_equal "0" "${HAS_LUCI_MK}" "core/Makefile does not use luci.mk version override"
assert_equal "1" "$((HAS_BUILD_PACKAGE > 0))" "core/Makefile evaluates its package definition"

# Test 3b: core/Makefile must contain required runtime dependencies
LUCI_DEP_LINE=$(grep "^[[:space:]]*LUCI_DEPENDS:=" "${CORE_MAKEFILE}" || true)
HAS_FW4=$(echo "${LUCI_DEP_LINE}" | grep -c "+firewall4" || true)
HAS_DNSMASQ=$(echo "${LUCI_DEP_LINE}" | grep -c "+dnsmasq" || true)
HAS_SS=$(echo "${LUCI_DEP_LINE}" | grep -E -c '(^|[[:space:]])\+ss([[:space:]]|$)' || true)
assert_equal "1" "$((HAS_FW4 > 0))" "core/Makefile contains +firewall4 in LUCI_DEPENDS"
assert_equal "1" "$((HAS_DNSMASQ > 0))" "core/Makefile contains +dnsmasq in LUCI_DEPENDS"
assert_equal "1" "$((HAS_SS > 0))" "core/Makefile contains +ss in LUCI_DEPENDS"

# Test 4: core/Makefile installs xray_profiles init script and rpcd backend
HAS_PROFILES_INIT=$(grep -c "init.d/xray_profiles" "${CORE_MAKEFILE}" || true)
HAS_PROFILES_RPCD=$(grep -c "rpcd/xray_profiles" "${CORE_MAKEFILE}" || true)
HAS_PROFILES_VIEW=$(grep -c "view/xray/profiles.js" "${CORE_MAKEFILE}" || true)
HAS_GEN_MJS=$(grep -c "gen_config.mjs" "${CORE_MAKEFILE}" || true)
HAS_SOCKSTATS=$(grep -c "usr/libexec/xray-sockstats" "${CORE_MAKEFILE}" || true)
HAS_TARGET_ARCH=$(grep -Fc 'PKGARCH:=$(ARCH_PACKAGES)' "${CORE_MAKEFILE}" || true)

assert_equal "1" "$((HAS_PROFILES_INIT > 0))" "core/Makefile installs init.d/xray_profiles"
assert_equal "1" "$((HAS_PROFILES_RPCD > 0))" "core/Makefile installs rpcd/xray_profiles"
assert_equal "1" "$((HAS_PROFILES_VIEW > 0))" "core/Makefile installs view/xray/profiles.js"
assert_equal "1" "$((HAS_GEN_MJS > 0))" "core/Makefile installs gen_config.mjs"
assert_equal "1" "$((HAS_SOCKSTATS > 0))" "core/Makefile installs the native read-only socket collector"
assert_equal "1" "$((HAS_TARGET_ARCH > 0))" "core package is architecture-specific because it contains a native collector"

# Test 5: core/Makefile installs all 7 protocol modules
for proto in http hysteria shadowsocks socks trojan vless vmess; do
    HAS_PROTO=$(grep -c "protocol/${proto}.mjs" "${CORE_MAKEFILE}" || true)
    assert_equal "1" "$((HAS_PROTO > 0))" "core/Makefile installs protocol/${proto}.mjs"
done

# Test 6: core/Makefile must not install permanent xray.pid symlink
PID_LN_COUNT=$(grep -c "LN.*xray.pid" "${CORE_MAKEFILE}" || true)
assert_equal "0" "${PID_LN_COUNT}" "core/Makefile does not install permanent xray.pid symlink"

echo "\nSummary: ${PASSED} passed, ${FAILED} failed"
if [ "${FAILED}" -gt 0 ]; then
    exit 1
fi
exit 0
