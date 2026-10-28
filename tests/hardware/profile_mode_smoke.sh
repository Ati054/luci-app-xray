#!/bin/sh
# Target-safe OpenWrt 25.12.5 / aarch64 hardware proof for isolated JSON profiles.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
XRAY_BIN="/opt/xray/current/xray"
RPCD_BACKEND="/usr/libexec/rpcd/xray_profiles"
PROFILES_DIR="/opt/xray/profiles"
RUNTIME_PROFILES_DIR="/var/run/xray-profiles"

resolve_fixture() {
    fixture_name="$1"
    for fixture_path in \
        "${SCRIPT_DIR}/${fixture_name}" \
        "${SCRIPT_DIR}/fixtures/${fixture_name}" \
        "${SCRIPT_DIR}/../fixtures/${fixture_name}"; do
        if [ -s "${fixture_path}" ]; then
            printf '%s\n' "${fixture_path}"
            return 0
        fi
    done
    return 1
}

FIXTURE_A="$(resolve_fixture profile-smoke-a.json)" || {
    echo "ERROR: profile-smoke-a.json is missing or empty" >&2
    exit 1
}
FIXTURE_B="$(resolve_fixture profile-smoke-b.json)" || {
    echo "ERROR: profile-smoke-b.json is missing or empty" >&2
    exit 1
}
FIXTURE_INVALID="$(resolve_fixture profile-invalid.json)" || {
    echo "ERROR: profile-invalid.json is missing or empty" >&2
    exit 1
}

if [ "${1:-}" = "--preflight" ]; then
    for fixture in "${FIXTURE_A}" "${FIXTURE_B}" "${FIXTURE_INVALID}"; do
        grep -q '"outbounds"' "${fixture}" || {
            echo "ERROR: fixture is not a complete Xray JSON profile: ${fixture}" >&2
            exit 1
        }
    done
    grep -q '^echo "HARDWARE_PROFILE_MODE_SMOKE_OK"$' "$0" || {
        echo "ERROR: hardware smoke success marker is missing" >&2
        exit 1
    }
    echo "PROFILE_MODE_SMOKE_PREFLIGHT_OK"
    exit 0
fi

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: required command is missing: $1" >&2
        exit 1
    }
}

# BEGIN R13_TARGET_PORTABILITY_HELPERS
r13_permission_field() {
    r13_mode_listing="$(LC_ALL=C ls -ld "$1")" || return 1
    r13_mode_field="${r13_mode_listing%% *}"
    [ -n "${r13_mode_field}" ] || return 1
    printf '%s\n' "${r13_mode_field}"
}

r13_exact_private_directory() {
    r13_mode_path="$1"
    [ -d "${r13_mode_path}" ] && [ ! -L "${r13_mode_path}" ] || return 1
    r13_verified_mode="$(r13_permission_field "${r13_mode_path}")" || return 1
    [ -d "${r13_mode_path}" ] && [ ! -L "${r13_mode_path}" ] && [ "${r13_verified_mode}" = "drwx------" ]
}

r13_exact_private_regular_file() {
    r13_mode_path="$1"
    [ -f "${r13_mode_path}" ] && [ ! -L "${r13_mode_path}" ] || return 1
    r13_verified_mode="$(r13_permission_field "${r13_mode_path}")" || return 1
    [ -f "${r13_mode_path}" ] && [ ! -L "${r13_mode_path}" ] && [ "${r13_verified_mode}" = "-rw-------" ]
}
# END R13_TARGET_PORTABILITY_HELPERS

for command_name in awk cat find grep ip jsonfilter ls mktemp nft sed sha256sum sort ss timeout tr ubus uci; do
    require_command "${command_name}"
done

SYSTEM_TCP_CC_BEFORE="$(cat /proc/sys/net/ipv4/tcp_congestion_control)"
grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control || {
    echo "ERROR: BBR is unavailable to reverse profile sockets" >&2
    exit 1
}

[ -r /etc/openwrt_release ] || {
    echo "ERROR: /etc/openwrt_release is unavailable" >&2
    exit 1
}
OPENWRT_RELEASE="$(sed -n "s/^DISTRIB_RELEASE=['\"]\([^'\"]*\)['\"]$/\1/p" /etc/openwrt_release)"
[ "${OPENWRT_RELEASE}" = "25.12.5" ] || {
    echo "ERROR: expected OpenWrt 25.12.5, found ${OPENWRT_RELEASE:-unknown}" >&2
    exit 1
}
[ "$(uname -m)" = "aarch64" ] || {
    echo "ERROR: expected aarch64, found $(uname -m)" >&2
    exit 1
}
[ -x "${XRAY_BIN}" ] || {
    echo "ERROR: Xray is not executable at ${XRAY_BIN}" >&2
    exit 1
}
XRAY_VERSION_LINE="$(${XRAY_BIN} version 2>&1 | sed -n '1p')"
case "${XRAY_VERSION_LINE}" in
    "Xray 26.10.21"*) ;;
    *)
        echo "ERROR: expected Xray 26.10.21, found ${XRAY_VERSION_LINE:-unknown}" >&2
        exit 1
        ;;
esac
[ -x "${RPCD_BACKEND}" ] || {
    echo "ERROR: rpcd backend is not executable: ${RPCD_BACKEND}" >&2
    exit 1
}
for service_script in /etc/init.d/xray_core /etc/init.d/xray_profiles; do
    [ -x "${service_script}" ] || {
        echo "ERROR: service script is not executable: ${service_script}" >&2
        exit 1
    }
done

TMP_DIR="$(mktemp -d /tmp/xray-r13-smoke.XXXXXX)"
chmod 0700 "${TMP_DIR}"
IMPORTED_A=0
IMPORTED_B=0
UCI_SAVED=0
SERVICES_SAVED=0
CLEANUP_DONE=0
SMOKE_PHASE="initialization"

set_smoke_phase() {
    SMOKE_PHASE="$1"
    echo "Hardware smoke phase: ${SMOKE_PHASE}" >&2
}

service_enabled() {
    "/etc/init.d/$1" enabled >/dev/null 2>&1
}

service_running() {
    "/etc/init.d/$1" status >/dev/null 2>&1
}

backend_call() {
    method_name="$1"
    method_payload="$2"
    timeout 10 "${RPCD_BACKEND}" call "${method_name}" "${method_payload}" </dev/null
}

json_get() {
    json_document="$1"
    json_expression="$2"
    printf '%s\n' "${json_document}" | jsonfilter -e "${json_expression}"
}

json_get_optional() {
    json_document="$1"
    json_expression="$2"
    printf '%s\n' "${json_document}" | jsonfilter -e "${json_expression}" 2>/dev/null || :
}

json_payload() {
    payload_name="$1"
    payload_filename="$2"
    payload_path="$3"
    payload_content="$(tr -d '\r\n' < "${payload_path}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    printf '{"name":"%s","filename":"%s","content":"%s","autostart":false}\n' \
        "${payload_name}" "${payload_filename}" "${payload_content}"
}

capture_network_state() {
    state_prefix="$1"
    ip rule show > "${state_prefix}.ipv4"
    ip -6 rule show > "${state_prefix}.ipv6"
    nft --stateless list ruleset > "${state_prefix}.nft"
    : > "${state_prefix}.dnsmasq-xray"
    for dns_root in /tmp/dnsmasq.d /etc/dnsmasq.d /var/etc; do
        [ -d "${dns_root}" ] || continue
        find "${dns_root}" -type f -name '*xray*' -exec sha256sum '{}' ';' >> "${state_prefix}.dnsmasq-xray"
    done
    sort -o "${state_prefix}.dnsmasq-xray" "${state_prefix}.dnsmasq-xray"
}

state_files_equal() {
    left_hash="$(sha256sum "$1" | awk '{ print $1 }')"
    right_hash="$(sha256sum "$2" | awk '{ print $1 }')"
    [ "${left_hash}" = "${right_hash}" ]
}

assert_no_smoke_processes() {
    for proc_cmdline in /proc/[0-9]*/cmdline; do
        [ -r "${proc_cmdline}" ] || continue
        if process_command="$(tr '\000' ' ' < "${proc_cmdline}" 2>/dev/null)"; then
            case "${process_command}" in
                *smoke-a.json*|*smoke-b.json*)
                    echo "ERROR: smoke-test process remains: ${process_command}" >&2
                    return 1
                    ;;
            esac
        fi
    done
    return 0
}

stop_test_instances() {
    if [ "${IMPORTED_A}" -eq 1 ]; then
        backend_call stop '{"id":"smoke_a"}' >/dev/null 2>&1
    fi
    if [ "${IMPORTED_B}" -eq 1 ]; then
        backend_call stop '{"id":"smoke_b"}' >/dev/null 2>&1
    fi
}

purge_test_profiles() {
    if [ "${IMPORTED_A}" -eq 1 ]; then
        backend_call delete '{"id":"smoke_a","purge":true}' >/dev/null
        IMPORTED_A=0
    fi
    if [ "${IMPORTED_B}" -eq 1 ]; then
        backend_call delete '{"id":"smoke_b","purge":true}' >/dev/null
        IMPORTED_B=0
    fi
}

restore_uci() {
    if [ "${UCI_SAVED}" -eq 1 ]; then
        if uci -q revert xray_core; then
            :
        fi
        uci import xray_core < "${TMP_DIR}/xray_core.uci"
        uci commit xray_core
    fi
}

stop_services() {
    /etc/init.d/xray_core stop >/dev/null 2>&1
    /etc/init.d/xray_profiles stop >/dev/null 2>&1
    ! service_running xray_core && ! service_running xray_profiles || {
        echo "ERROR: failed to stop Xray services while changing smoke state" >&2
        return 1
    }
}

restore_services() {
    stop_services
    if [ "$(cat "${TMP_DIR}/xray_core.enabled")" = "1" ]; then
        /etc/init.d/xray_core enable
    else
        /etc/init.d/xray_core disable
    fi
    if [ "$(cat "${TMP_DIR}/xray_profiles.enabled")" = "1" ]; then
        /etc/init.d/xray_profiles enable
    else
        /etc/init.d/xray_profiles disable
    fi
    if [ "$(cat "${TMP_DIR}/xray_core.running")" = "1" ]; then
        /etc/init.d/xray_core start
    fi
    if [ "$(cat "${TMP_DIR}/xray_profiles.running")" = "1" ]; then
        /etc/init.d/xray_profiles start
    fi
}

failure_cleanup() {
    primary_rc=$?
    [ "${CLEANUP_DONE}" -eq 1 ] && return "${primary_rc}"
    set +e
    echo "Hardware smoke failed during phase '${SMOKE_PHASE}'; restoring test state" >&2
    stop_test_instances || :
    purge_test_profiles || :
    restore_uci || :
    if [ "${SERVICES_SAVED}" -eq 1 ]; then restore_services; fi
    rm -rf "${TMP_DIR}"
    return "${primary_rc}"
}
trap failure_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

set_smoke_phase "capture initial target state"
capture_network_state "${TMP_DIR}/before"
uci export xray_core > "${TMP_DIR}/xray_core.uci"
UCI_SAVED=1

if service_enabled xray_core; then echo 1; else echo 0; fi > "${TMP_DIR}/xray_core.enabled"
if service_enabled xray_profiles; then echo 1; else echo 0; fi > "${TMP_DIR}/xray_profiles.enabled"
if service_running xray_core; then echo 1; else echo 0; fi > "${TMP_DIR}/xray_core.running"
if service_running xray_profiles; then echo 1; else echo 0; fi > "${TMP_DIR}/xray_profiles.running"
SERVICES_SAVED=1

set_smoke_phase "stop production services"
/etc/init.d/xray_core stop >/dev/null 2>&1
/etc/init.d/xray_profiles stop >/dev/null 2>&1
! service_running xray_core && ! service_running xray_profiles || {
    echo "ERROR: both Xray services must be stopped before profile smoke" >&2
    exit 1
}
capture_network_state "${TMP_DIR}/profile-baseline"

set_smoke_phase "inspect reserved smoke profile IDs"
INITIAL_LIST="$(backend_call list '{}')"
for reserved_id in smoke_a smoke_b; do
    if existing_id="$(json_get "${INITIAL_LIST}" "@.profiles[@.id=\"${reserved_id}\"].id" 2>/dev/null)"; then
        :
    else
        existing_id=""
    fi
    [ -z "${existing_id}" ] || {
        echo "ERROR: refusing to overwrite pre-existing profile ${reserved_id}" >&2
        exit 1
    }
done
[ ! -e "${PROFILES_DIR}/smoke-a.json" ] && [ ! -e "${PROFILES_DIR}/smoke-b.json" ] || {
    echo "ERROR: refusing to overwrite pre-existing smoke profile files" >&2
    exit 1
}

set_smoke_phase "validate smoke fixtures"
XRAY_LOCATION_ASSET=/opt/xray/current "${XRAY_BIN}" run -test -config "${FIXTURE_A}"
XRAY_LOCATION_ASSET=/opt/xray/current "${XRAY_BIN}" run -test -config "${FIXTURE_B}"

set_smoke_phase "verify Reverse policy rejection"
INVALID_PAYLOAD="$(json_payload Invalid profile-invalid.json "${FIXTURE_INVALID}")"
if INVALID_RESULT="$(backend_call validate "${INVALID_PAYLOAD}")"; then
    echo "ERROR: invalid inbound fixture passed Reverse profile policy" >&2
    exit 1
fi
[ "$(json_get "${INVALID_RESULT}" '@.ok')" = "false" ] || {
    echo "ERROR: invalid fixture did not return structured rejection" >&2
    exit 1
}

set_smoke_phase "import isolated smoke profiles"
if ! IMPORT_A_RESULT="$(backend_call import "$(json_payload 'Smoke A' smoke-a.json "${FIXTURE_A}")")"; then
    echo "ERROR: profile A import RPC failed: ${IMPORT_A_RESULT:-no response}" >&2
    exit 1
fi
[ "$(json_get "${IMPORT_A_RESULT}" '@.ok')" = "true" ] || {
    echo "ERROR: failed to import profile A" >&2
    exit 1
}
IMPORTED_A=1

if ! IMPORT_B_RESULT="$(backend_call import "$(json_payload 'Smoke B' smoke-b.json "${FIXTURE_B}")")"; then
    echo "ERROR: profile B import RPC failed: ${IMPORT_B_RESULT:-no response}" >&2
    exit 1
fi
[ "$(json_get "${IMPORT_B_RESULT}" '@.ok')" = "true" ] || {
    echo "ERROR: failed to import profile B" >&2
    exit 1
}
IMPORTED_B=1

set_smoke_phase "verify private profile storage"
r13_exact_private_directory "${PROFILES_DIR}" || {
    echo "ERROR: profile directory mode is not 0700" >&2
    exit 1
}
for profile_file in "${PROFILES_DIR}/smoke-a.json" "${PROFILES_DIR}/smoke-b.json"; do
    r13_exact_private_regular_file "${profile_file}" || {
        echo "ERROR: profile file mode is not 0600: ${profile_file}" >&2
        exit 1
    }
done

set_smoke_phase "start isolated smoke profiles"
if ! START_A_RESULT="$(backend_call start '{"id":"smoke_a"}')"; then
    echo "ERROR: profile A start RPC failed: ${START_A_RESULT:-no response}" >&2
    exit 1
fi
if ! START_B_RESULT="$(backend_call start '{"id":"smoke_b"}')"; then
    echo "ERROR: profile B start RPC failed: ${START_B_RESULT:-no response}" >&2
    exit 1
fi
[ "$(cat /proc/sys/net/ipv4/tcp_congestion_control)" = "${SYSTEM_TCP_CC_BEFORE}" ] || {
    echo "ERROR: starting reverse profiles changed the system TCP congestion algorithm" >&2
    exit 1
}
for runtime_profile in \
    "${RUNTIME_PROFILES_DIR}/profile_smoke_a.json" \
    "${RUNTIME_PROFILES_DIR}/profile_smoke_b.json"; do
    r13_exact_private_regular_file "${runtime_profile}" || {
        echo "ERROR: BBR runtime profile is missing or not private: ${runtime_profile}" >&2
        exit 1
    }
    [ "$(jsonfilter -i "${runtime_profile}" -e '@.outbounds[@.settings.reverse].streamSettings.sockopt.tcpcongestion')" = "bbr" ] || {
        echo "ERROR: runtime profile does not select BBR: ${runtime_profile}" >&2
        exit 1
    }
done
for stored_profile in "${PROFILES_DIR}/smoke-a.json" "${PROFILES_DIR}/smoke-b.json"; do
    [ -z "$(jsonfilter -i "${stored_profile}" -e '@.outbounds[@.settings.reverse].streamSettings.sockopt.tcpcongestion' 2>/dev/null)" ] || {
        echo "ERROR: stored profile was modified with a runtime-only BBR setting: ${stored_profile}" >&2
        exit 1
    }
done
if ! RUNNING_LIST="$(backend_call list '{}')"; then
    echo "ERROR: unable to list running smoke profiles" >&2
    exit 1
fi
PID_A="$(json_get "${RUNNING_LIST}" '@.profiles[@.id="smoke_a"].pid')"
PID_B="$(json_get "${RUNNING_LIST}" '@.profiles[@.id="smoke_b"].pid')"
STACK_A="$(json_get "${RUNNING_LIST}" '@.profiles[@.id="smoke_a"].protocol_stack')"
STACK_B="$(json_get "${RUNNING_LIST}" '@.profiles[@.id="smoke_b"].protocol_stack')"
case "${PID_A}" in ''|*[!0-9]*|0) echo "ERROR: invalid PID for profile A: ${PID_A}" >&2; exit 1;; esac
case "${PID_B}" in ''|*[!0-9]*|0) echo "ERROR: invalid PID for profile B: ${PID_B}" >&2; exit 1;; esac
[ "${PID_A}" != "${PID_B}" ] || {
    echo "ERROR: profiles A and B share PID ${PID_A}" >&2
    exit 1
}
[ "${STACK_A}" = "VLESS + REALITY + Vision" ] && [ "${STACK_B}" = "VLESS + XHTTP + REALITY" ] || {
    echo "ERROR: protocol stack labels are incorrect: A=${STACK_A}; B=${STACK_B}" >&2
    exit 1
}
set_smoke_phase "wait for native TCP_INFO metrics"
TRAFFIC_READY=0
TRAFFIC_ATTEMPT=0
while [ "${TRAFFIC_ATTEMPT}" -lt 15 ]; do
    TRAFFIC_ATTEMPT=$((TRAFFIC_ATTEMPT + 1))
    if RUNNING_LIST="$(backend_call list '{}')"; then
        TRAFFIC_READY=1
        for profile_id in smoke_a smoke_b; do
            TRAFFIC_AVAILABLE="$(json_get_optional "${RUNNING_LIST}" "@.profiles[@.id=\"${profile_id}\"].traffic.available")"
            TRAFFIC_BYTES_AVAILABLE="$(json_get_optional "${RUNNING_LIST}" "@.profiles[@.id=\"${profile_id}\"].traffic.bytes_available")"
            TRAFFIC_RETRANS_AVAILABLE="$(json_get_optional "${RUNNING_LIST}" "@.profiles[@.id=\"${profile_id}\"].traffic.retrans_available")"
            TRAFFIC_RETRANS_BYTES="$(json_get_optional "${RUNNING_LIST}" "@.profiles[@.id=\"${profile_id}\"].traffic.retrans_bytes")"
            TRAFFIC_SOURCE="$(json_get_optional "${RUNNING_LIST}" "@.profiles[@.id=\"${profile_id}\"].traffic.source")"
            TRAFFIC_UPTIME="$(json_get_optional "${RUNNING_LIST}" "@.profiles[@.id=\"${profile_id}\"].traffic.uptime_seconds")"
            if [ "${TRAFFIC_AVAILABLE}" != "true" ] || \
                [ "${TRAFFIC_BYTES_AVAILABLE}" != "true" ] || \
                [ "${TRAFFIC_RETRANS_AVAILABLE}" != "true" ] || \
                [ "${TRAFFIC_SOURCE}" != "pidfd_tcp_info" ]; then
                TRAFFIC_READY=0
                break
            fi
            case "${TRAFFIC_RETRANS_BYTES}" in ''|*[!0-9]*) TRAFFIC_READY=0; break;; esac
            case "${TRAFFIC_UPTIME}" in ''|*[!0-9]*) TRAFFIC_READY=0; break;; esac
        done
    else
        TRAFFIC_READY=0
    fi
    [ "${TRAFFIC_READY}" -eq 1 ] && break
    sleep 1
done
[ "${TRAFFIC_READY}" -eq 1 ] || {
    echo "ERROR: native TCP_INFO traffic metrics are unavailable after 15 seconds" >&2
    printf '%s\n' "${RUNNING_LIST:-no backend response}" >&2
    exit 1
}

set_smoke_phase "verify network isolation"
capture_network_state "${TMP_DIR}/during"
for state_kind in ipv4 ipv6 nft dnsmasq-xray; do
    state_files_equal "${TMP_DIR}/profile-baseline.${state_kind}" "${TMP_DIR}/during.${state_kind}" || {
        echo "ERROR: ${state_kind} state changed while profile instances were running" >&2
        sha256sum "${TMP_DIR}/profile-baseline.${state_kind}" "${TMP_DIR}/during.${state_kind}" >&2
        exit 1
    }
done

set_smoke_phase "verify independent stop and restart"
backend_call stop '{"id":"smoke_a"}' >/dev/null
AFTER_STOP_LIST="$(backend_call list '{}')"
if PID_A_AFTER="$(json_get "${AFTER_STOP_LIST}" '@.profiles[@.id="smoke_a"].pid' 2>/dev/null)"; then
    :
else
    PID_A_AFTER=""
fi
PID_B_AFTER="$(json_get "${AFTER_STOP_LIST}" '@.profiles[@.id="smoke_b"].pid')"
[ -z "${PID_A_AFTER}" ] || [ "${PID_A_AFTER}" = "null" ] || {
    echo "ERROR: profile A is still running after stop" >&2
    exit 1
}
[ "${PID_B_AFTER}" = "${PID_B}" ] || {
    echo "ERROR: stopping A changed B PID (${PID_B} -> ${PID_B_AFTER})" >&2
    exit 1
}

backend_call restart '{"id":"smoke_b"}' >/dev/null
AFTER_RESTART_LIST="$(backend_call list '{}')"
PID_B_NEW="$(json_get "${AFTER_RESTART_LIST}" '@.profiles[@.id="smoke_b"].pid')"
case "${PID_B_NEW}" in ''|*[!0-9]*|0) echo "ERROR: invalid restarted PID for B: ${PID_B_NEW}" >&2; exit 1;; esac
[ "${PID_B_NEW}" != "${PID_B}" ] || {
    echo "ERROR: restarting B preserved the old PID ${PID_B}" >&2
    exit 1
}

set_smoke_phase "restore production state"
stop_test_instances
assert_no_smoke_processes
purge_test_profiles
restore_uci
restore_services

uci export xray_core > "${TMP_DIR}/xray_core.after.uci"
state_files_equal "${TMP_DIR}/xray_core.uci" "${TMP_DIR}/xray_core.after.uci" || {
    echo "ERROR: xray_core UCI state was not restored exactly" >&2
    sha256sum "${TMP_DIR}/xray_core.uci" "${TMP_DIR}/xray_core.after.uci" >&2
    exit 1
}
for restored_service in xray_core xray_profiles; do
    if service_enabled "${restored_service}"; then restored_enabled=1; else restored_enabled=0; fi
    if service_running "${restored_service}"; then restored_running=1; else restored_running=0; fi
    [ "${restored_enabled}" = "$(cat "${TMP_DIR}/${restored_service}.enabled")" ] && \
        [ "${restored_running}" = "$(cat "${TMP_DIR}/${restored_service}.running")" ] || {
        echo "ERROR: ${restored_service} enablement/running state was not restored" >&2
        exit 1
    }
done

FINAL_LIST="$(backend_call list '{}')"
for removed_id in smoke_a smoke_b; do
    if final_id="$(json_get "${FINAL_LIST}" "@.profiles[@.id=\"${removed_id}\"].id" 2>/dev/null)"; then
        :
    else
        final_id=""
    fi
    [ -z "${final_id}" ] || {
        echo "ERROR: smoke profile remains after cleanup: ${removed_id}" >&2
        exit 1
    }
done

set_smoke_phase "verify exact target restoration"
capture_network_state "${TMP_DIR}/after"
for state_kind in ipv4 ipv6 nft dnsmasq-xray; do
    state_files_equal "${TMP_DIR}/before.${state_kind}" "${TMP_DIR}/after.${state_kind}" || {
        echo "ERROR: ${state_kind} state changed during profile-mode smoke" >&2
        sha256sum "${TMP_DIR}/before.${state_kind}" "${TMP_DIR}/after.${state_kind}" >&2
        exit 1
    }
done

CLEANUP_DONE=1
trap - EXIT INT TERM
rm -rf "${TMP_DIR}"
echo "HARDWARE_PROFILE_MODE_SMOKE_OK"
