#!/bin/sh
# Hardware Smoke Test for OpenWrt 25.12.5 (aarch64) Raspberry Pi 3
# Validates complete multi-process JSON Reverse Profile Mode isolation & lifecycle

set -e

echo "=== OpenWrt 25.12.5 Raspberry Pi 3 Profile Mode Hardware Smoke Test ==="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Robust multi-path fixture resolution
resolve_fixture() {
    local fname="$1"
    if [ -f "${SCRIPT_DIR}/${fname}" ]; then
        echo "${SCRIPT_DIR}/${fname}"
    elif [ -f "${SCRIPT_DIR}/fixtures/${fname}" ]; then
        echo "${SCRIPT_DIR}/fixtures/${fname}"
    elif [ -f "${SCRIPT_DIR}/../fixtures/${fname}" ]; then
        echo "${SCRIPT_DIR}/../fixtures/${fname}"
    elif [ -f "${SCRIPT_DIR}/tests/fixtures/${fname}" ]; then
        echo "${SCRIPT_DIR}/tests/fixtures/${fname}"
    else
        echo ""
    fi
}

FIXTURE_A="$(resolve_fixture "profile-smoke-a.json")"
FIXTURE_B="$(resolve_fixture "profile-smoke-b.json")"
FIXTURE_INV="$(resolve_fixture "profile-invalid.json")"

if [ -z "${FIXTURE_A}" ] || [ -z "${FIXTURE_B}" ] || [ -z "${FIXTURE_INV}" ]; then
    echo "::error::Required smoke fixtures not found"
    exit 1
fi

# Preflight mode for CI or artifact validation
if [ "$1" = "--preflight" ] || [ "$1" = "--check-fixtures" ]; then
    echo "  [PASS] Fixture A resolved: ${FIXTURE_A}"
    echo "  [PASS] Fixture B resolved: ${FIXTURE_B}"
    echo "  [PASS] Fixture Invalid resolved: ${FIXTURE_INV}"
    echo "SMOKE_BUNDLE_PREFLIGHT_OK"
    exit 0
fi

# 1. Verify platform and architecture
ARCH="$(uname -m 2>/dev/null || true)"
if [ "$1" != "--force" ]; then
    if [ "${ARCH}" != "aarch64" ]; then
        echo "::error::Non-aarch64 architecture detected (${ARCH}). Use --force if running in simulation."
        exit 1
    fi
fi

# 2. Verify Xray 26.7.28
XRAY_BIN="${XRAY_BIN:-/opt/xray/current/xray}"
if [ ! -x "${XRAY_BIN}" ]; then
    echo "::error::Executable Xray binary missing at ${XRAY_BIN}"
    exit 1
fi
XRAY_VER="$("${XRAY_BIN}" version 2>/dev/null | head -n 1 || true)"
echo "Found Xray runtime: ${XRAY_VER}"
if [ "$1" != "--force" ]; then
    if ! echo "${XRAY_VER}" | grep -q "26.7.28"; then
        echo "::error::Xray 26.7.28 required. Found: ${XRAY_VER}"
        exit 1
    fi
fi

RPCD_BACKEND="/usr/libexec/rpcd/xray_profiles"
if [ ! -x "${RPCD_BACKEND}" ]; then
    echo "::error::Profile management backend missing or not executable at ${RPCD_BACKEND}"
    exit 1
fi

# 3. Capture baseline environment state
TMP_DIR="$(mktemp -d)"
cleanup() {
    echo "Cleaning up smoke test artifacts..."
    "${RPCD_BACKEND}" call delete '{"id": "smoke_a"}' </dev/null >/dev/null 2>&1 || true
    "${RPCD_BACKEND}" call delete '{"id": "smoke_b"}' </dev/null >/dev/null 2>&1 || true
    /etc/init.d/xray_profiles stop >/dev/null 2>&1 || true
    if [ -f "${TMP_DIR}/uci_backup.export" ]; then
        uci import xray_core < "${TMP_DIR}/uci_backup.export" 2>/dev/null || true
        uci commit xray_core 2>/dev/null || true
    fi
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

uci export xray_core > "${TMP_DIR}/uci_backup.export" 2>/dev/null || true
ip rule show > "${TMP_DIR}/ip_rules_before.txt" 2>/dev/null || true
ip -6 rule show > "${TMP_DIR}/ip6_rules_before.txt" 2>/dev/null || true
nft list ruleset > "${TMP_DIR}/nftables_before.txt" 2>/dev/null || true

# 4. Import Smoke Profiles
echo "--- Importing Smoke Profiles via RPCD Backend ---"
# use base64 or safe JSON construction to avoid quoting hell, or simply format properly
CONTENT_A="$(cat "${FIXTURE_A}" | tr -d '\n\r' | sed 's/"/\\"/g')"
CONTENT_B="$(cat "${FIXTURE_B}" | tr -d '\n\r' | sed 's/"/\\"/g')"
CONTENT_INV="$(cat "${FIXTURE_INV}" | tr -d '\n\r' | sed 's/"/\\"/g')"

RES_A="$("${RPCD_BACKEND}" call import "{\"name\":\"Smoke A\",\"filename\":\"smoke-a.json\",\"content\":\"${CONTENT_A}\",\"autostart\":false}" </dev/null)"
echo "Import A Result: ${RES_A}"
echo "${RES_A}" | grep -q '"ok":true' || { echo "::error::Failed to import smoke-a.json"; exit 1; }

RES_B="$("${RPCD_BACKEND}" call import "{\"name\":\"Smoke B\",\"filename\":\"smoke-b.json\",\"content\":\"${CONTENT_B}\",\"autostart\":false}" </dev/null)"
echo "Import B Result: ${RES_B}"
echo "${RES_B}" | grep -q '"ok":true' || { echo "::error::Failed to import smoke-b.json"; exit 1; }

# 5. Verify Invalid Profile Rejection
echo "--- Verifying Invalid Profile Rejection Policy ---"
# Disable set -e for the validate call because rpcd might exit non-zero
set +e
RES_INV="$("${RPCD_BACKEND}" call validate "{\"content\":\"${CONTENT_INV}\"}" </dev/null)"
set -e
echo "Validation Invalid Result: ${RES_INV}"
echo "${RES_INV}" | grep -q '"ok":false' || { echo "::error::Invalid profile was unexpectedly accepted"; exit 1; }

# 6. Start Profile A and Profile B independently
echo "--- Starting Profile A and Profile B ---"
START_A="$("${RPCD_BACKEND}" call start '{"id": "smoke_a"}' </dev/null)"
echo "Start A: ${START_A}"

START_B="$("${RPCD_BACKEND}" call start '{"id": "smoke_b"}' </dev/null)"
echo "Start B: ${START_B}"

# 7. Check List & Record PIDs using jsonfilter
LIST_RES="$("${RPCD_BACKEND}" call list '{}' </dev/null)"
echo "Profile List: ${LIST_RES}"

# We check if jsonfilter is available, if not fallback to awk
if type jsonfilter >/dev/null 2>&1; then
    PID_A="$(echo "${LIST_RES}" | jsonfilter -e '@.profiles[@.id="smoke_a"].pid' || true)"
    PID_B="$(echo "${LIST_RES}" | jsonfilter -e '@.profiles[@.id="smoke_b"].pid' || true)"
else
    # Simple fallback parsing JSON with sed/awk securely
    PID_A="$(echo "${LIST_RES}" | sed -n 's/.*"id":"smoke_a".*"pid":\([0-9]*\).*/\1/p' || true)"
    PID_B="$(echo "${LIST_RES}" | sed -n 's/.*"id":"smoke_b".*"pid":\([0-9]*\).*/\1/p' || true)"
fi

if [ -z "${PID_A}" ] || [ "${PID_A}" = "null" ] || [ "${PID_A}" -le 0 ]; then
    echo "::error::Profile A failed to start or has invalid PID: ${PID_A}"
    exit 1
fi
if [ -z "${PID_B}" ] || [ "${PID_B}" = "null" ] || [ "${PID_B}" -le 0 ]; then
    echo "::error::Profile B failed to start or has invalid PID: ${PID_B}"
    exit 1
fi
if [ "${PID_A}" = "${PID_B}" ]; then
    echo "::error::Profiles A and B share the same PID: ${PID_A}"
    exit 1
fi

echo "  [PASS] Profile A running (PID: ${PID_A})"
echo "  [PASS] Profile B running (PID: ${PID_B})"

# 8. Stop Profile A and prove Profile B PID is unchanged
echo "--- Stopping Profile A ---"
"${RPCD_BACKEND}" call stop '{"id": "smoke_a"}' </dev/null >/dev/null 2>&1

LIST_AFTER_STOP_A="$("${RPCD_BACKEND}" call list '{}' </dev/null)"
if type jsonfilter >/dev/null 2>&1; then
    PID_B_AFTER="$(echo "${LIST_AFTER_STOP_A}" | jsonfilter -e '@.profiles[@.id="smoke_b"].pid' || true)"
else
    PID_B_AFTER="$(echo "${LIST_AFTER_STOP_A}" | sed -n 's/.*"id":"smoke_b".*"pid":\([0-9]*\).*/\1/p' || true)"
fi

if [ "${PID_B}" != "${PID_B_AFTER}" ]; then
    echo "::error::Process isolation violated: Stopping A altered PID of B (${PID_B} -> ${PID_B_AFTER})"
    exit 1
fi
echo "  [PASS] Profile B PID strictly preserved (${PID_B} == ${PID_B_AFTER})"

# 9. Restart Profile B and prove only B changes PID
echo "--- Restarting Profile B ---"
"${RPCD_BACKEND}" call restart '{"id": "smoke_b"}' </dev/null >/dev/null 2>&1

LIST_AFTER_RESTART_B="$("${RPCD_BACKEND}" call list '{}' </dev/null)"
if type jsonfilter >/dev/null 2>&1; then
    PID_B_NEW="$(echo "${LIST_AFTER_RESTART_B}" | jsonfilter -e '@.profiles[@.id="smoke_b"].pid' || true)"
else
    PID_B_NEW="$(echo "${LIST_AFTER_RESTART_B}" | sed -n 's/.*"id":"smoke_b".*"pid":\([0-9]*\).*/\1/p' || true)"
fi

if [ -z "${PID_B_NEW}" ] || [ "${PID_B_NEW}" = "null" ]; then
    echo "::error::Profile B not running after restart"
    exit 1
fi
if [ "${PID_B_NEW}" = "${PID_B}" ]; then
    echo "::error::Restarting B failed to spawn new PID: ${PID_B_NEW}"
    exit 1
fi
echo "  [PASS] Profile B restarted with new PID (${PID_B} -> ${PID_B_NEW})"

# 10. Stop and delete profiles
echo "--- Cleaning up Smoke Profiles ---"
"${RPCD_BACKEND}" call stop '{"id": "smoke_b"}' </dev/null >/dev/null 2>&1
"${RPCD_BACKEND}" call delete '{"id": "smoke_a"}' </dev/null >/dev/null 2>&1
"${RPCD_BACKEND}" call delete '{"id": "smoke_b"}' </dev/null >/dev/null 2>&1

# 11. Verify absence of network or firewall side-effects
ip rule show > "${TMP_DIR}/ip_rules_after.txt" 2>/dev/null || true
if grep -E -q "fwmark (0xfb|251) lookup 251(\b|$)" "${TMP_DIR}/ip_rules_after.txt"; then
    echo "::error::Unexpected fwmark table 251 found in ip rules"
    exit 1
fi

ip -6 rule show > "${TMP_DIR}/ip6_rules_after.txt" 2>/dev/null || true
if grep -E -q "fwmark (0xfb|251) lookup 251(\b|$)" "${TMP_DIR}/ip6_rules_after.txt"; then
    echo "::error::Unexpected IPv6 fwmark table 251 found in ip6 rules"
    exit 1
fi

if [ -f /tmp/dnsmasq.d/xray.conf ] || [ -f /etc/dnsmasq.d/xray.conf ]; then
    echo "::error::Unexpected dnsmasq xray.conf artifact created"
    exit 1
fi

echo "HARDWARE_PROFILE_MODE_SMOKE_OK"
exit 0
