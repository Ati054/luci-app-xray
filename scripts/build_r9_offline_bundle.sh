#!/usr/bin/env bash
# Resolve, verify, and prove the OpenWrt 25.12.5 aarch64 offline transaction.

set -euo pipefail

if [[ $# -ne 5 ]]; then
    echo "Usage: $0 APK_HOST OUTPUT_DIR CORE_APK STATUS_APK WORKSPACE" >&2
    exit 2
fi

APK_HOST="$1"
OUTPUT_DIR="$2"
CORE_APK="$3"
STATUS_APK="$4"
WORKSPACE="$5"
TARGET_ARCH="aarch64_cortex-a53"

REPOSITORIES=(
    "https://downloads.openwrt.org/releases/25.12.5/targets/bcm27xx/bcm2710/packages/packages.adb"
    "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/base/packages.adb"
    "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/luci/packages.adb"
    "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/packages/packages.adb"
    "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/routing/packages.adb"
    "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/telephony/packages.adb"
    "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/video/packages.adb"
)

# These are resolver roots, not a hard-coded closure. apk recursively resolves
# every transitive userland dependency from the exact repositories above.
USERLAND_ROOTS=(
    coreutils
    coreutils-base64
    coreutils-timeout
    ip-full
    wget
    ucode
    ucode-mod-fs
    ucode-mod-uci
)
TARGET_PRECONDITIONS=(
    kmod-nf-tproxy
    kmod-nft-tproxy
    firewall4
    luci-base
    dnsmasq
    ca-bundle
)

[[ -x "${APK_HOST}" ]] || {
    echo "ERROR: SDK host apk is not executable: ${APK_HOST}" >&2
    exit 1
}
[[ -s "${CORE_APK}" && -s "${STATUS_APK}" ]] || {
    echo "ERROR: core/status APK input is missing or empty" >&2
    exit 1
}
mkdir -p "${OUTPUT_DIR}"
if find "${OUTPUT_DIR}" -mindepth 1 -maxdepth 1 -print | grep -q .; then
    echo "ERROR: offline bundle output directory must be empty: ${OUTPUT_DIR}" >&2
    exit 1
fi

TMP_ROOT="$(mktemp -d)"
cleanup() {
    local primary_rc=$?
    if ! rm -rf "${TMP_ROOT}"; then
        echo "ERROR: failed to remove temporary resolver root ${TMP_ROOT}" >&2
        [[ ${primary_rc} -ne 0 ]] && return "${primary_rc}"
        return 1
    fi
    return "${primary_rc}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "${TMP_ROOT}/deps" "${TMP_ROOT}/seed" "${TMP_ROOT}/indexes"

APK_HELP="${TMP_ROOT}/apk-help.txt"
FETCH_HELP="${TMP_ROOT}/fetch-help.txt"
ADD_HELP="${TMP_ROOT}/add-help.txt"
ADBDUMP_HELP="${TMP_ROOT}/adbdump-help.txt"
MKNDX_HELP="${TMP_ROOT}/mkndx-help.txt"
LIST_HELP="${TMP_ROOT}/list-help.txt"

capture_apk_help() {
    local output="$1"
    local help_rc
    shift
    if "${APK_HOST}" "$@" --help > "${output}" 2>&1; then
        help_rc=0
    else
        help_rc=$?
    fi
    [[ ${help_rc} -eq 0 || ${help_rc} -eq 1 ]] || {
        echo "ERROR: apk $* --help failed with unexpected status ${help_rc}" >&2
        exit 1
    }
    [[ -s "${output}" ]] || {
        echo "ERROR: apk $* --help returned no capability description" >&2
        exit 1
    }
}

capture_apk_help "${APK_HELP}"
capture_apk_help "${FETCH_HELP}" fetch
capture_apk_help "${ADD_HELP}" add
capture_apk_help "${ADBDUMP_HELP}" adbdump
capture_apk_help "${MKNDX_HELP}" mkndx
capture_apk_help "${LIST_HELP}" list
cat "${APK_HELP}" "${FETCH_HELP}" "${ADD_HELP}" "${ADBDUMP_HELP}" "${MKNDX_HELP}" "${LIST_HELP}"

grep -q -- '--recursive' "${FETCH_HELP}" || grep -q -- '-R' "${FETCH_HELP}" || {
    echo "ERROR: SDK apk fetch has no recursive option" >&2
    exit 1
}
grep -q -- '--url' "${FETCH_HELP}" || {
    echo "ERROR: SDK apk fetch cannot report source URLs" >&2
    exit 1
}
grep -q -- '--output' "${FETCH_HELP}" || {
    echo "ERROR: SDK apk fetch cannot write a dependency directory" >&2
    exit 1
}
grep -q -- '--network' "${ADD_HELP}" || {
    echo "ERROR: SDK apk add lacks the boolean --network capability" >&2
    exit 1
}
grep -q -- '--usermode' "${ADD_HELP}" || {
    echo "ERROR: SDK apk lacks non-root isolated database support" >&2
    exit 1
}
grep -q -- '--simulate' "${ADD_HELP}" || {
    echo "ERROR: SDK apk add lacks --simulate" >&2
    exit 1
}
grep -q -- '--format' "${ADBDUMP_HELP}" || {
    echo "ERROR: SDK apk adbdump lacks JSON format support" >&2
    exit 1
}
grep -q -- '--output' "${MKNDX_HELP}" || {
    echo "ERROR: SDK apk mkndx cannot create a local packages.adb" >&2
    exit 1
}
grep -q -- '--installed' "${LIST_HELP}" || {
    echo "ERROR: SDK apk list cannot verify the isolated installed set" >&2
    exit 1
}

if grep -q -- '--recursive' "${FETCH_HELP}"; then
    RECURSIVE_OPTION="--recursive"
else
    RECURSIVE_OPTION="-R"
fi

init_apk_root() {
    local root="$1"
    mkdir -p \
        "${root}/etc/apk/repositories.d" \
        "${root}/etc/apk/keys" \
        "${root}/lib/apk/db" \
        "${root}/var/cache/apk" \
        "${root}/tmp"
    : > "${root}/etc/apk/world"
    printf '%s\nall\n' "${TARGET_ARCH}" > "${root}/etc/apk/arch"
}

RESOLVER_ROOT="${TMP_ROOT}/resolver-root"
init_apk_root "${RESOLVER_ROOT}"
REPOSITORY_FILE="${RESOLVER_ROOT}/etc/apk/repositories"
printf '%s\n' "${REPOSITORIES[@]}" > "${REPOSITORY_FILE}"

"${APK_HOST}" \
    --root "${RESOLVER_ROOT}" \
    --arch "${TARGET_ARCH}" \
    --allow-untrusted \
    --repositories-file "${REPOSITORY_FILE}" \
    update

"${APK_HOST}" \
    --root "${RESOLVER_ROOT}" \
    --arch "${TARGET_ARCH}" \
    --allow-untrusted \
    --repositories-file "${REPOSITORY_FILE}" \
    fetch "${RECURSIVE_OPTION}" --url "${USERLAND_ROOTS[@]}" > "${TMP_ROOT}/dependency-urls.txt"

"${APK_HOST}" \
    --root "${RESOLVER_ROOT}" \
    --arch "${TARGET_ARCH}" \
    --allow-untrusted \
    --repositories-file "${REPOSITORY_FILE}" \
    fetch "${RECURSIVE_OPTION}" --output "${TMP_ROOT}/deps" "${USERLAND_ROOTS[@]}"

mapfile -t DEPENDENCY_APKS < <(find "${TMP_ROOT}/deps" -maxdepth 1 -type f -name '*.apk' -print | sort)
[[ ${#DEPENDENCY_APKS[@]} -gt ${#USERLAND_ROOTS[@]} ]] || {
    echo "ERROR: recursive resolver did not produce a transitive closure" >&2
    exit 1
}

python3 "${WORKSPACE}/scripts/r9_apk_manifest.py" \
    --apk-bin "${APK_HOST}" \
    --apk-dir "${TMP_ROOT}/deps" \
    --urls "${TMP_ROOT}/dependency-urls.txt" \
    --output "${OUTPUT_DIR}/OFFLINE-PACKAGES-MANIFEST.txt"

cp -p "${DEPENDENCY_APKS[@]}" "${OUTPUT_DIR}/"
cp -p "${CORE_APK}" "${STATUS_APK}" "${OUTPUT_DIR}/"

# Establish the exact Raspberry Pi 3 kernel ABI before fetching any temporary
# kmod seed APK. Seed packages are used only to model already-installed target
# prerequisites and are never copied into the artifact.
TARGET_BASE="https://downloads.openwrt.org/releases/25.12.5/targets/bcm27xx/bcm2710"
TARGET_MANIFEST="openwrt-25.12.5-bcm27xx-bcm2710.manifest"
wget -q -O "${TMP_ROOT}/sha256sums" "${TARGET_BASE}/sha256sums"
wget -q -O "${TMP_ROOT}/${TARGET_MANIFEST}" "${TARGET_BASE}/${TARGET_MANIFEST}"
awk -v filename="${TARGET_MANIFEST}" '$2 == filename || $2 == "*" filename { print }' \
    "${TMP_ROOT}/sha256sums" > "${TMP_ROOT}/manifest.sha256"
[ "$(wc -l < "${TMP_ROOT}/manifest.sha256")" -eq 1 ] || {
    echo "ERROR: target manifest checksum entry is missing or ambiguous" >&2
    exit 1
}
(
    cd "${TMP_ROOT}"
    sha256sum -c manifest.sha256
)
TARGET_KERNEL_VERSION="$(awk '$1 == "kernel" && $2 == "-" { print $3 }' "${TMP_ROOT}/${TARGET_MANIFEST}")"
[[ -n "${TARGET_KERNEL_VERSION}" ]] || {
    echo "ERROR: target manifest has no exact kernel version" >&2
    exit 1
}
if [[ "${TARGET_KERNEL_VERSION}" =~ ^([^~]+)~([0-9a-f]+)-r([0-9]+)$ ]]; then
    EXPECTED_KMOD_DIR="${BASH_REMATCH[1]}-${BASH_REMATCH[3]}-${BASH_REMATCH[2]}"
else
    echo "ERROR: target kernel version has an unsupported ABI form: ${TARGET_KERNEL_VERSION}" >&2
    exit 1
fi

wget -q -O "${TMP_ROOT}/kmods-index.html" "${TARGET_BASE}/kmods/"
mapfile -t KMOD_DIRS < <(
    sed -n 's/.*href="\([^"/][^"/]*\)\/".*/\1/p' "${TMP_ROOT}/kmods-index.html" |
        grep -v '^\.\.$' |
        sort -u
)
[[ ${#KMOD_DIRS[@]} -eq 1 && "${KMOD_DIRS[0]}" == "${EXPECTED_KMOD_DIR}" ]] || {
    echo "ERROR: exact kmods ABI directory ${EXPECTED_KMOD_DIR} was not uniquely verified" >&2
    printf '%s\n' "${KMOD_DIRS[@]}" >&2
    exit 1
}
KMOD_REPOSITORY="${TARGET_BASE}/kmods/${KMOD_DIRS[0]}/packages.adb"

SEED_ROOT="${TMP_ROOT}/seed-resolver-root"
init_apk_root "${SEED_ROOT}"
SEED_REPOSITORIES="${SEED_ROOT}/etc/apk/repositories"
printf '%s\n' "${REPOSITORIES[@]}" "${KMOD_REPOSITORY}" > "${SEED_REPOSITORIES}"
"${APK_HOST}" \
    --root "${SEED_ROOT}" \
    --arch "${TARGET_ARCH}" \
    --allow-untrusted \
    --repositories-file "${SEED_REPOSITORIES}" \
    update
"${APK_HOST}" \
    --root "${SEED_ROOT}" \
    --arch "${TARGET_ARCH}" \
    --allow-untrusted \
    --repositories-file "${SEED_REPOSITORIES}" \
    fetch "${RECURSIVE_OPTION}" --output "${TMP_ROOT}/seed" "${TARGET_PRECONDITIONS[@]}"

mapfile -t SEED_APKS < <(find "${TMP_ROOT}/seed" -maxdepth 1 -type f -name '*.apk' -print | sort)
[[ ${#SEED_APKS[@]} -gt 0 ]] || {
    echo "ERROR: target prerequisite seed is empty" >&2
    exit 1
}
KMOD_COUNT=0
KERNEL_COUNT=0
for apk_file in "${SEED_APKS[@]}"; do
    [[ -s "${apk_file}" ]] || {
        echo "ERROR: zero-byte seed APK: ${apk_file}" >&2
        exit 1
    }
    PACKAGE_NAME="$(python3 "${WORKSPACE}/scripts/r9_apk_manifest.py" \
        --apk-bin "${APK_HOST}" --inspect "${apk_file}" --field name)"
    PACKAGE_DEPS="$(python3 "${WORKSPACE}/scripts/r9_apk_manifest.py" \
        --apk-bin "${APK_HOST}" --inspect "${apk_file}" --field depends)"
    PACKAGE_VERSION="$(python3 "${WORKSPACE}/scripts/r9_apk_manifest.py" \
        --apk-bin "${APK_HOST}" --inspect "${apk_file}" --field version)"
    if [[ "${PACKAGE_NAME}" == kmod-* ]]; then
        KMOD_COUNT=$((KMOD_COUNT + 1))
        [[ " ${PACKAGE_DEPS} " == *" kernel=${TARGET_KERNEL_VERSION} "* ]] || {
            echo "ERROR: ${PACKAGE_NAME} does not require exact kernel ${TARGET_KERNEL_VERSION}" >&2
            exit 1
        }
    elif [[ "${PACKAGE_NAME}" == kernel ]]; then
        KERNEL_COUNT=$((KERNEL_COUNT + 1))
        [[ "${PACKAGE_VERSION}" == "${TARGET_KERNEL_VERSION}" ]] || {
            echo "ERROR: seed kernel ${PACKAGE_VERSION} does not match target ${TARGET_KERNEL_VERSION}" >&2
            exit 1
        }
    fi
done
[[ ${KMOD_COUNT} -gt 0 ]] || {
    echo "ERROR: no verified kmod prerequisite was resolved" >&2
    exit 1
}
[[ ${KERNEL_COUNT} -eq 1 ]] || {
    echo "ERROR: expected exactly one verified target kernel seed, found ${KERNEL_COUNT}" >&2
    exit 1
}

SEED_INDEX_DIR="${TMP_ROOT}/seed-index"
ARTIFACT_INDEX_DIR="${TMP_ROOT}/artifact-index"
mkdir -p "${SEED_INDEX_DIR}" "${ARTIFACT_INDEX_DIR}"
cp -p "${SEED_APKS[@]}" "${SEED_INDEX_DIR}/"
cp -p "${OUTPUT_DIR}"/*.apk "${ARTIFACT_INDEX_DIR}/"
(
    cd "${SEED_INDEX_DIR}"
    "${APK_HOST}" --allow-untrusted mkndx --output packages.adb ./*.apk
)
(
    cd "${ARTIFACT_INDEX_DIR}"
    "${APK_HOST}" --allow-untrusted mkndx --output packages.adb ./*.apk
)

SIM_ROOT="${TMP_ROOT}/simulation-root"
init_apk_root "${SIM_ROOT}"
SEED_REPOSITORY="file://${SEED_INDEX_DIR}/packages.adb"
ARTIFACT_REPOSITORY="file://${ARTIFACT_INDEX_DIR}/packages.adb"

"${APK_HOST}" \
    --usermode \
    --root "${SIM_ROOT}" \
    --arch "${TARGET_ARCH}" \
    --allow-untrusted \
    --repositories-file /dev/null \
    --repository "${SEED_REPOSITORY}" \
    add --initdb --no-cache --no-network --no-scripts "${TARGET_PRECONDITIONS[@]}"

OFFLINE_LOG="${OUTPUT_DIR}/OFFLINE-TRANSACTION.log"
NETWORK_TRACE="${TMP_ROOT}/offline-network.trace"
: > "${OFFLINE_LOG}"
{
    echo "target_arch=${TARGET_ARCH}"
    echo "target_kernel=${TARGET_KERNEL_VERSION}"
    echo "verified_kmods_repository=${KMOD_REPOSITORY}"
    echo "artifact_repository=${ARTIFACT_REPOSITORY}"
    echo "network_mode=apk --no-network; repositories-file=/dev/null; local file repository only"
    echo "--- SIMULATION ---"
} >> "${OFFLINE_LOG}"

strace -f -e trace=network -o "${NETWORK_TRACE}" \
    "${APK_HOST}" \
    --usermode \
    --root "${SIM_ROOT}" \
    --arch "${TARGET_ARCH}" \
    --allow-untrusted \
    --repositories-file /dev/null \
    --repository "${ARTIFACT_REPOSITORY}" \
    add --simulate --no-cache --no-network --no-scripts \
    luci-app-xray luci-app-xray-status "${USERLAND_ROOTS[@]}" >> "${OFFLINE_LOG}" 2>&1

{
    echo "--- INSTALL ---"
} >> "${OFFLINE_LOG}"
strace -f -e trace=network -o "${NETWORK_TRACE}.install" \
    "${APK_HOST}" \
    --usermode \
    --root "${SIM_ROOT}" \
    --arch "${TARGET_ARCH}" \
    --allow-untrusted \
    --repositories-file /dev/null \
    --repository "${ARTIFACT_REPOSITORY}" \
    add --no-cache --no-network --no-scripts \
    luci-app-xray luci-app-xray-status "${USERLAND_ROOTS[@]}" >> "${OFFLINE_LOG}" 2>&1

cat "${NETWORK_TRACE}" "${NETWORK_TRACE}.install" >> "${OFFLINE_LOG}"
if grep -E 'socket\(AF_INET|socket\(AF_INET6|sa_family=AF_INET|sa_family=AF_INET6' "${NETWORK_TRACE}" "${NETWORK_TRACE}.install"; then
    echo "ERROR: network syscall observed during offline transaction" >&2
    exit 1
fi

"${APK_HOST}" \
    --usermode \
    --root "${SIM_ROOT}" \
    --arch "${TARGET_ARCH}" \
    --repositories-file /dev/null \
    list --installed luci-app-xray luci-app-xray-status >> "${OFFLINE_LOG}"

grep -q '^luci-app-xray-3\.7\.1-r9' "${OFFLINE_LOG}" || {
    echo "ERROR: offline root does not contain core R9" >&2
    exit 1
}
grep -q '^luci-app-xray-status-3\.7\.1-r9' "${OFFLINE_LOG}" || {
    echo "ERROR: offline root does not contain status R9" >&2
    exit 1
}
echo "R9_OFFLINE_TRANSACTION_OK" >> "${OFFLINE_LOG}"

if find "${OUTPUT_DIR}" -maxdepth 1 -type f -size 0 -print | grep -q .; then
    echo "ERROR: zero-byte file found in offline bundle output" >&2
    exit 1
fi

echo "R9 offline dependency closure and transaction proof completed successfully."
