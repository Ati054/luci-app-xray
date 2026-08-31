#!/bin/sh
# One-command, fail-closed OpenWrt 25.12.5 offline installer for R9.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CHECKSUM_FILE="${SCRIPT_DIR}/SHA256SUMS-R9.txt"
XRAY_BIN="/opt/xray/current/xray"
DIAG_LOG="/tmp/xray-r9-install-$(date +%Y%m%dT%H%M%S)-$$.log"
BACKUP_DIR="/tmp/xray-r9-backup-$(date +%Y%m%dT%H%M%S)-$$"
BACKUP_READY=0
PACKAGE_TRANSACTION_STARTED=0
SUCCESS=0

exec 3>&1 4>&2
exec >>"${DIAG_LOG}" 2>&1

console() {
    printf '%s\n' "$*" >&3
}

service_exists() {
    [ -x "/etc/init.d/$1" ]
}

service_enabled() {
    service_exists "$1" && "/etc/init.d/$1" enabled >/dev/null 2>&1
}

service_running() {
    service_exists "$1" && "/etc/init.d/$1" status >/dev/null 2>&1
}

stop_service_strict() {
    service_name="$1"
    service_exists "${service_name}" || return 0
    if service_running "${service_name}"; then
        "/etc/init.d/${service_name}" stop
        ! service_running "${service_name}" || {
            echo "ERROR: failed to stop ${service_name}" >&2
            return 1
        }
    fi
}

disable_service_strict() {
    service_name="$1"
    service_exists "${service_name}" || return 0
    "/etc/init.d/${service_name}" disable
    ! service_enabled "${service_name}" || {
        echo "ERROR: failed to disable ${service_name}" >&2
        return 1
    }
}

# BEGIN R9_TARGET_PORTABILITY_HELPERS
r9_file_size_bytes() {
    r9_size_path="$1"
    [ -f "${r9_size_path}" ] && [ ! -L "${r9_size_path}" ] && [ -r "${r9_size_path}" ] || return 1
    r9_size_value="$(LC_ALL=C wc -c < "${r9_size_path}")" || return 1
    case "${r9_size_value}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ -f "${r9_size_path}" ] && [ ! -L "${r9_size_path}" ] && [ -r "${r9_size_path}" ] || return 1
    printf '%s\n' "${r9_size_value}"
}

r9_verify_exact_file_size() {
    r9_expected_bytes="$2"
    case "${r9_expected_bytes}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    r9_actual_bytes="$(r9_file_size_bytes "$1")" || return 1
    [ "${r9_actual_bytes}" = "${r9_expected_bytes}" ]
}
# END R9_TARGET_PORTABILITY_HELPERS

# BEGIN R9_APK_HELP_COMPATIBILITY_HELPERS
r9_capture_apk_help() {
    r9_help_output_path="$1"
    shift
    [ "$#" -gt 0 ] || {
        echo "ERROR: apk help command is missing" >&2
        return 1
    }

    if "$@" --help > "${r9_help_output_path}" 2>&1; then
        r9_help_rc=0
    else
        r9_help_rc=$?
    fi

    case "${r9_help_rc}" in
        0|1) ;;
        *)
            echo "ERROR: apk help command failed with exit ${r9_help_rc}: $*" >&2
            return 1
            ;;
    esac

    [ -s "${r9_help_output_path}" ] || {
        echo "ERROR: apk help command produced no output: $*" >&2
        return 1
    }
}
# END R9_APK_HELP_COMPATIBILITY_HELPERS

# BEGIN R9_UCODE_MODULE_COMPATIBILITY_HELPERS
r9_compile_ucode_source() {
    r9_ucode_bin="$1"
    r9_module_path="$2"
    r9_import_wrapper="$3"
    r9_compile_stderr="$4"
    r9_compile_source="${r9_module_path}"

    case "${r9_module_path}" in
        *.mjs)
            r9_escaped_module="$(printf '%s' "${r9_module_path}" | sed 's/[\\"]/\\&/g')"
            printf 'import * as module_under_test from "%s";\n' \
                "${r9_escaped_module}" > "${r9_import_wrapper}"
            r9_compile_source="${r9_import_wrapper}"
            ;;
    esac

    : > "${r9_compile_stderr}"
    if "${r9_ucode_bin}" -cdynlink=ubus -o /dev/null "${r9_compile_source}" \
        > /dev/null 2> "${r9_compile_stderr}"; then
        r9_compile_rc=0
    else
        r9_compile_rc=$?
    fi
    return "${r9_compile_rc}"
}
# END R9_UCODE_MODULE_COMPATIBILITY_HELPERS

manifest_source_allowed() {
    case "$1" in
        https://downloads.openwrt.org/releases/25.12.5/targets/bcm27xx/bcm2710/packages/packages.adb|\
        https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/base/packages.adb|\
        https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/luci/packages.adb|\
        https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/packages/packages.adb|\
        https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/routing/packages.adb|\
        https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/telephony/packages.adb|\
        https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/video/packages.adb)
            return 0
            ;;
    esac
    return 1
}

restore_data_backup() {
    [ "${BACKUP_READY}" -eq 1 ] || return 0

    if [ "$(cat "${BACKUP_DIR}/xray_core.exists")" = "1" ]; then
        cp -p "${BACKUP_DIR}/xray_core" /etc/config/xray_core
    else
        rm -f /etc/config/xray_core
    fi

    if [ "$(cat "${BACKUP_DIR}/profiles.exists")" = "1" ]; then
        mkdir -p /opt/xray/profiles
        chmod 0700 /opt/xray/profiles
        cp -a "${BACKUP_DIR}/profiles/." /opt/xray/profiles/
    else
        rmdir /opt/xray/profiles/.trash 2>/dev/null || :
        rmdir /opt/xray/profiles 2>/dev/null || :
    fi
}

restore_pretransaction_services() {
    [ "${BACKUP_READY}" -eq 1 ] || return 0
    for service_name in xray_core xray_profiles; do
        service_exists "${service_name}" || continue
        if [ "$(cat "${BACKUP_DIR}/${service_name}.enabled")" = "1" ]; then
            "/etc/init.d/${service_name}" enable
        else
            "/etc/init.d/${service_name}" disable
        fi
        if [ "$(cat "${BACKUP_DIR}/${service_name}.running")" = "1" ]; then
            "/etc/init.d/${service_name}" start
        fi
    done
}

failure_handler() {
    primary_rc=$?
    [ "${SUCCESS}" -eq 0 ] || return 0
    set +e
    rm -f "${BACKUP_DIR}.metadata.json"
    console "R9 installation failed; diagnostic log: ${DIAG_LOG}"
    echo "PRIMARY_EXIT_CODE=${primary_rc}"

    if [ "${BACKUP_READY}" -eq 0 ]; then
        console "No complete target backup was created; preflight made no service or package changes."
        return "${primary_rc}"
    fi

    stop_service_strict xray_core || :
    stop_service_strict xray_profiles || :
    disable_service_strict xray_core || :
    disable_service_strict xray_profiles || :
    restore_data_backup || echo "WARNING: data backup restoration was incomplete"

    if [ "${PACKAGE_TRANSACTION_STARTED}" -eq 0 ]; then
        restore_pretransaction_services || echo "WARNING: service-state restoration was incomplete"
    else
        echo "PACKAGE_ROLLBACK=not-performed"
        echo "Package files were not rolled back because previous APK payloads are not bundled."
        echo "Services remain stopped and disabled for safety."
    fi

    console "Backup retained at: ${BACKUP_DIR}"
    return "${primary_rc}"
}
trap failure_handler EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

console "R9 offline installation started; diagnostic log: ${DIAG_LOG}"

[ "$(id -u)" -eq 0 ] || {
    echo "ERROR: installer must run as root" >&2
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

awk '$2 == "/opt" { found = 1 } END { exit(found ? 0 : 1) }' /proc/mounts || {
    echo "ERROR: /opt must be a distinct mounted filesystem" >&2
    exit 1
}
OPT_WRITE_TEST="$(mktemp -d /opt/.xray-r9-write.XXXXXX)" || {
    echo "ERROR: /opt is not writable" >&2
    exit 1
}
rmdir "${OPT_WRITE_TEST}"

[ -x "${XRAY_BIN}" ] || {
    echo "ERROR: Xray is not executable at ${XRAY_BIN}" >&2
    exit 1
}
XRAY_VERSION_LINE="$("${XRAY_BIN}" version 2>&1 | sed -n '1p')"
case "${XRAY_VERSION_LINE}" in
    "Xray 26.7.28"*) ;;
    *)
        echo "ERROR: expected Xray 26.7.28, found ${XRAY_VERSION_LINE:-unknown}" >&2
        exit 1
        ;;
esac

command -v apk >/dev/null 2>&1 || {
    echo "ERROR: OpenWrt apk is unavailable" >&2
    exit 1
}
for required_command in awk find grep jsonfilter pidof sed sha256sum sort wc; do
    command -v "${required_command}" >/dev/null 2>&1 || {
        echo "ERROR: required target command is unavailable: ${required_command}" >&2
        exit 1
    }
done

# BEGIN R9_APK_HELP_COMPATIBILITY_PREFLIGHT
APK_GLOBAL_HELP_PATH="${BACKUP_DIR}.apk-global-help"
APK_INFO_HELP_PATH="${BACKUP_DIR}.apk-info-help"
APK_ADD_HELP_PATH="${BACKUP_DIR}.apk-add-help"
APK_ADBDUMP_HELP_PATH="${BACKUP_DIR}.apk-adbdump-help"
APK_LIST_HELP_PATH="${BACKUP_DIR}.apk-list-help"
APK_NO_NETWORK_PROBE_PATH="${BACKUP_DIR}.apk-no-network-probe"

apk --version
r9_capture_apk_help "${APK_GLOBAL_HELP_PATH}" apk
r9_capture_apk_help "${APK_INFO_HELP_PATH}" apk info
r9_capture_apk_help "${APK_ADD_HELP_PATH}" apk add
r9_capture_apk_help "${APK_ADBDUMP_HELP_PATH}" apk adbdump
r9_capture_apk_help "${APK_LIST_HELP_PATH}" apk list
cat "${APK_GLOBAL_HELP_PATH}" "${APK_INFO_HELP_PATH}" "${APK_ADD_HELP_PATH}" \
    "${APK_ADBDUMP_HELP_PATH}" "${APK_LIST_HELP_PATH}"

grep -q 'Usage: apk' "${APK_GLOBAL_HELP_PATH}" || {
    echo "ERROR: target apk global help output is invalid" >&2
    exit 1
}
grep -q -- '--exists' "${APK_INFO_HELP_PATH}" || {
    echo "ERROR: target apk does not support apk info --exists" >&2
    exit 1
}
grep -q -- '--simulate' "${APK_ADD_HELP_PATH}" || {
    echo "ERROR: target apk does not support --simulate" >&2
    exit 1
}
if grep -q -- '--no-network' "${APK_ADD_HELP_PATH}"; then
    :
elif grep -Fq -- '--network[=BOOL]' "${APK_ADD_HELP_PATH}"; then
    :
else
    echo "ERROR: target apk does not support --no-network" >&2
    exit 1
fi
if apk --no-network --version > "${APK_NO_NETWORK_PROBE_PATH}" 2>&1; then
    APK_NO_NETWORK_PROBE_RC=0
else
    APK_NO_NETWORK_PROBE_RC=$?
fi
[ "${APK_NO_NETWORK_PROBE_RC}" -eq 0 ] || {
    echo "ERROR: target apk --no-network probe failed with exit ${APK_NO_NETWORK_PROBE_RC}" >&2
    exit 1
}
[ -s "${APK_NO_NETWORK_PROBE_PATH}" ] || {
    echo "ERROR: target apk --no-network probe produced no output" >&2
    exit 1
}
grep -q '^apk-tools ' "${APK_NO_NETWORK_PROBE_PATH}" || {
    echo "ERROR: target apk --no-network probe output is invalid" >&2
    exit 1
}
grep -q -- '--format' "${APK_ADBDUMP_HELP_PATH}" || {
    echo "ERROR: target apk adbdump lacks JSON format support" >&2
    exit 1
}
grep -q -- '--installed' "${APK_LIST_HELP_PATH}" || {
    echo "ERROR: target apk list lacks --installed" >&2
    exit 1
}
rm -f "${APK_GLOBAL_HELP_PATH}" "${APK_INFO_HELP_PATH}" "${APK_ADD_HELP_PATH}" \
    "${APK_ADBDUMP_HELP_PATH}" "${APK_LIST_HELP_PATH}" "${APK_NO_NETWORK_PROBE_PATH}"
# END R9_APK_HELP_COMPATIBILITY_PREFLIGHT

for required_package in kmod-nf-tproxy kmod-nft-tproxy firewall4 luci-base dnsmasq ca-bundle; do
    apk info --exists "${required_package}" >/dev/null 2>&1 || {
        echo "ERROR: required installed target package is missing: ${required_package}" >&2
        exit 1
    }
done

[ -s "${CHECKSUM_FILE}" ] || {
    echo "ERROR: SHA256SUMS-R9.txt is missing or empty" >&2
    exit 1
}
cd "${SCRIPT_DIR}"
if find . -maxdepth 1 -type f -size 0 -print | grep -q .; then
    echo "ERROR: bundle contains a zero-byte file" >&2
    exit 1
fi

for required_bundle_file in \
    install_and_smoke_r9.sh \
    profile_mode_smoke.sh \
    profile-smoke-a.json \
    profile-smoke-b.json \
    profile-invalid.json \
    OFFLINE-PACKAGES-MANIFEST.txt \
    OFFLINE-TRANSACTION.log \
    BUILD-INFO-openwrt-25.12.5-all.txt \
    ROLLBACK-R9.txt; do
    [ -s "${required_bundle_file}" ] || {
        echo "ERROR: required bundle file is missing or empty: ${required_bundle_file}" >&2
        exit 1
    }
    grep -Fq "  ${required_bundle_file}" "${CHECKSUM_FILE}" || {
        echo "ERROR: checksum coverage is missing for ${required_bundle_file}" >&2
        exit 1
    }
done

MANIFEST_HEADER="filename;package;version;release;architecture;bytes;sha256;direct_dependencies;source_repository"
[ "$(sed -n '1p' OFFLINE-PACKAGES-MANIFEST.txt)" = "${MANIFEST_HEADER}" ] || {
    echo "ERROR: offline dependency manifest header is invalid" >&2
    exit 1
}
awk -F ';' '
    NR == 1 { next }
    NF != 9 || !$1 || !$2 || !$3 || !$5 || !$6 || !$7 || !$9 { exit 1 }
    seen_filename[$1]++ || seen_package[$2]++ { exit 1 }
    { records++ }
    END { exit(records > 0 ? 0 : 1) }
' OFFLINE-PACKAGES-MANIFEST.txt || {
    echo "ERROR: offline dependency manifest has malformed or duplicate records" >&2
    exit 1
}

set -- ./*.apk
[ -e "$1" ] || {
    echo "ERROR: bundle contains no APK files" >&2
    exit 1
}
CORE_APK_COUNT=0
STATUS_APK_COUNT=0
for apk_file in "$@"; do
    [ -s "${apk_file}" ] || {
        echo "ERROR: zero-byte APK: ${apk_file}" >&2
        exit 1
    }
    apk adbdump --format json "${apk_file}" > "${BACKUP_DIR}.metadata.json"
    apk_package="$(jsonfilter -i "${BACKUP_DIR}.metadata.json" -e '@.info.name')"
    apk_version="$(jsonfilter -i "${BACKUP_DIR}.metadata.json" -e '@.info.version')"
    apk_arch="$(jsonfilter -i "${BACKUP_DIR}.metadata.json" -e '@.info.arch')"
    [ -n "${apk_package}" ] && [ -n "${apk_version}" ] && [ -n "${apk_arch}" ] || {
        echo "ERROR: APK metadata is incomplete: ${apk_file}" >&2
        exit 1
    }
    case "${apk_arch}" in
        aarch64_cortex-a53|aarch64|all|noarch) ;;
        *)
            echo "ERROR: APK has unexpected architecture ${apk_arch}: ${apk_file}" >&2
            exit 1
            ;;
    esac
    case "${apk_package}" in
        luci-app-xray)
            [ "${apk_version}" = "3.7.1-r9" ] || {
                echo "ERROR: core APK has unexpected version ${apk_version}" >&2
                exit 1
            }
            CORE_APK_COUNT=$((CORE_APK_COUNT + 1))
            ;;
        luci-app-xray-status)
            [ "${apk_version}" = "3.7.1-r9" ] || {
                echo "ERROR: status APK has unexpected version ${apk_version}" >&2
                exit 1
            }
            STATUS_APK_COUNT=$((STATUS_APK_COUNT + 1))
            ;;
        *)
            dependency_filename="${apk_file#./}"
            manifest_matches="$(awk -F ';' -v filename="${dependency_filename}" 'NR > 1 && $1 == filename { count++ } END { print count + 0 }' OFFLINE-PACKAGES-MANIFEST.txt)"
            [ "${manifest_matches}" -eq 1 ] || {
                echo "ERROR: dependency APK is absent from offline manifest: ${apk_file#./}" >&2
                exit 1
            }
            manifest_package="$(awk -F ';' -v filename="${dependency_filename}" '$1 == filename { print $2 }' OFFLINE-PACKAGES-MANIFEST.txt)"
            manifest_version="$(awk -F ';' -v filename="${dependency_filename}" '$1 == filename { print $3 }' OFFLINE-PACKAGES-MANIFEST.txt)"
            manifest_release="$(awk -F ';' -v filename="${dependency_filename}" '$1 == filename { print $4 }' OFFLINE-PACKAGES-MANIFEST.txt)"
            manifest_arch="$(awk -F ';' -v filename="${dependency_filename}" '$1 == filename { print $5 }' OFFLINE-PACKAGES-MANIFEST.txt)"
            manifest_bytes="$(awk -F ';' -v filename="${dependency_filename}" '$1 == filename { print $6 }' OFFLINE-PACKAGES-MANIFEST.txt)"
            manifest_sha256="$(awk -F ';' -v filename="${dependency_filename}" '$1 == filename { print $7 }' OFFLINE-PACKAGES-MANIFEST.txt)"
            manifest_source="$(awk -F ';' -v filename="${dependency_filename}" '$1 == filename { print $9 }' OFFLINE-PACKAGES-MANIFEST.txt)"
            manifest_full_version="${manifest_version}"
            [ -z "${manifest_release}" ] || manifest_full_version="${manifest_version}-${manifest_release}"
            [ "${manifest_package}" = "${apk_package}" ] && \
                [ "${manifest_full_version}" = "${apk_version}" ] && \
                [ "${manifest_arch}" = "${apk_arch}" ] && \
                r9_verify_exact_file_size "${apk_file}" "${manifest_bytes}" && \
                [ "${manifest_sha256}" = "$(sha256sum "${apk_file}" | awk '{ print $1 }')" ] || {
                echo "ERROR: manifest metadata does not match ${dependency_filename}" >&2
                exit 1
            }
            manifest_source_allowed "${manifest_source}" || {
                echo "ERROR: manifest source is not an approved OpenWrt 25.12.5 repository: ${manifest_source}" >&2
                exit 1
            }
            ;;
    esac
    grep -Fq "  ${apk_file#./}" "${CHECKSUM_FILE}" || {
        echo "ERROR: checksum coverage is missing for ${apk_file#./}" >&2
        exit 1
    }
done
rm -f "${BACKUP_DIR}.metadata.json"
[ "${CORE_APK_COUNT}" -eq 1 ] && [ "${STATUS_APK_COUNT}" -eq 1 ] || {
    echo "ERROR: bundle must contain exactly one core and one status R9 APK" >&2
    exit 1
}

awk -F ';' 'NR > 1 { print $1 }' OFFLINE-PACKAGES-MANIFEST.txt | while IFS= read -r dependency_filename; do
    [ -n "${dependency_filename}" ] && [ -s "${dependency_filename}" ] || {
        echo "ERROR: manifest dependency file is missing or empty: ${dependency_filename}" >&2
        exit 1
    }
done

sha256sum -c SHA256SUMS-R9.txt

mkdir -p "${BACKUP_DIR}"
chmod 0700 "${BACKUP_DIR}"
if [ -f /etc/config/xray_core ]; then
    echo 1 > "${BACKUP_DIR}/xray_core.exists"
    cp -p /etc/config/xray_core "${BACKUP_DIR}/xray_core"
else
    echo 0 > "${BACKUP_DIR}/xray_core.exists"
fi
if [ -d /opt/xray/profiles ]; then
    echo 1 > "${BACKUP_DIR}/profiles.exists"
    mkdir -p "${BACKUP_DIR}/profiles"
    cp -a /opt/xray/profiles/. "${BACKUP_DIR}/profiles/"
else
    echo 0 > "${BACKUP_DIR}/profiles.exists"
fi
apk list --installed > "${BACKUP_DIR}/installed-packages.txt"
for service_name in xray_core xray_profiles; do
    if service_enabled "${service_name}"; then echo 1; else echo 0; fi > "${BACKUP_DIR}/${service_name}.enabled"
    if service_running "${service_name}"; then echo 1; else echo 0; fi > "${BACKUP_DIR}/${service_name}.running"
done
BACKUP_READY=1
console "R9 target backup completed: ${BACKUP_DIR}"

stop_service_strict xray_core
stop_service_strict xray_profiles
disable_service_strict xray_core
disable_service_strict xray_profiles

console "Simulating complete APK transaction with networking disabled"
apk add --simulate --no-network --allow-untrusted ./*.apk

console "Installing complete APK transaction with networking disabled"
PACKAGE_TRANSACTION_STARTED=1
apk add --no-network --allow-untrusted ./*.apk

apk list --installed luci-app-xray | grep -Eq '^luci-app-xray-3\.7\.1-r9([[:space:]]|$)' || {
    echo "ERROR: luci-app-xray 3.7.1-r9 is not installed" >&2
    exit 1
}
apk list --installed luci-app-xray-status | grep -Eq '^luci-app-xray-status-3\.7\.1-r9([[:space:]]|$)' || {
    echo "ERROR: luci-app-xray-status 3.7.1-r9 is not installed" >&2
    exit 1
}
command -v timeout >/dev/null 2>&1 || {
    echo "ERROR: installed coreutils-timeout did not provide a timeout command" >&2
    exit 1
}

for executable_path in \
    /etc/init.d/xray_core \
    /etc/init.d/xray_profiles \
    /usr/libexec/rpcd/xray \
    /usr/libexec/rpcd/xray_profiles \
    /usr/share/xray/gen_config.uc \
    /usr/share/xray/default_gateway.uc \
    /usr/share/xray/dnsmasq_include.ut \
    /usr/share/xray/firewall_include.ut; do
    [ -x "${executable_path}" ] || {
        echo "ERROR: installed executable mode is wrong: ${executable_path}" >&2
        exit 1
    }
done

timeout 5 /usr/libexec/rpcd/xray_profiles call list '{}' </dev/null > "${BACKUP_DIR}/backend-list.json" 2> "${BACKUP_DIR}/backend-list.stderr"
[ ! -s "${BACKUP_DIR}/backend-list.stderr" ] || {
    echo "ERROR: backend list wrote to stderr" >&2
    exit 1
}
[ "$(jsonfilter -i "${BACKUP_DIR}/backend-list.json" -e '@.ok')" = "true" ] || {
    echo "ERROR: backend list did not return ok=true" >&2
    exit 1
}

UCODE_BIN="$(command -v ucode)" || {
    echo "ERROR: installed ucode is unavailable" >&2
    exit 1
}
UCODE_MODULE_LIST="${BACKUP_DIR}/ucode-modules.list"
UCODE_IMPORT_WRAPPER="${BACKUP_DIR}/ucode-import-wrapper.uc"
UCODE_COMPILE_STDERR="${BACKUP_DIR}/ucode-current.stderr"
UCODE_PARSE_STDERR="${BACKUP_DIR}/ucode-parse.stderr"
: > "${UCODE_PARSE_STDERR}"
find /usr/share/xray -type f \( -name '*.uc' -o -name '*.mjs' \) -print | sort > "${UCODE_MODULE_LIST}"
while IFS= read -r module_path; do
    if ! r9_compile_ucode_source "${UCODE_BIN}" "${module_path}" \
        "${UCODE_IMPORT_WRAPPER}" "${UCODE_COMPILE_STDERR}"; then
        {
            echo "ERROR: installed ucode source did not compile: ${module_path}"
            cat "${UCODE_COMPILE_STDERR}"
        } >> "${UCODE_PARSE_STDERR}"
        cat "${UCODE_PARSE_STDERR}" >&2
        exit 1
    fi
    if [ -s "${UCODE_COMPILE_STDERR}" ]; then
        {
            echo "ERROR: installed ucode source wrote to stderr: ${module_path}"
            cat "${UCODE_COMPILE_STDERR}"
        } >> "${UCODE_PARSE_STDERR}"
        cat "${UCODE_PARSE_STDERR}" >&2
        exit 1
    fi
done < "${UCODE_MODULE_LIST}"
rm -f "${UCODE_IMPORT_WRAPPER}" "${UCODE_COMPILE_STDERR}"
[ ! -s "${UCODE_PARSE_STDERR}" ] || {
    echo "ERROR: installed ucode sources produced compile errors" >&2
    exit 1
}

mkdir -p "${BACKUP_DIR}/uci"
cat > "${BACKUP_DIR}/uci/xray_core" <<'EOF'
config general 'general'
	option reverse_only '1'
	option transparent_proxy_enable '0'
	option xray_bin '/opt/xray/current/xray'
	option xray_location_asset '/opt/xray/current'
	option loglevel 'warning'
EOF
UCI_CONFIG_DIR="${BACKUP_DIR}/uci" "${UCODE_BIN}" /usr/share/xray/gen_config.uc \
    > "${BACKUP_DIR}/generated-empty.json" 2> "${BACKUP_DIR}/gen_config.stderr"
[ ! -s "${BACKUP_DIR}/gen_config.stderr" ] || {
    echo "ERROR: installed gen_config.uc wrote to stderr" >&2
    exit 1
}
XRAY_LOCATION_ASSET=/opt/xray/current "${XRAY_BIN}" run -test -config "${BACKUP_DIR}/generated-empty.json"

R9_INSTALLER_FINAL_DISABLED=1 sh "${SCRIPT_DIR}/profile_mode_smoke.sh"

stop_service_strict xray_core
stop_service_strict xray_profiles
disable_service_strict xray_core
disable_service_strict xray_profiles

if pidof xray >/dev/null 2>&1; then
    echo "ERROR: an Xray process remains after installation smoke" >&2
    pidof xray >&2
    exit 1
fi

SUCCESS=1
trap - EXIT INT TERM
console "R9_INSTALL_AND_HARDWARE_SMOKE_OK"
exit 0
