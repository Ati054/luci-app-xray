#!/bin/sh
# Fetches, verifies, and extracts official Xray-core release binary

set -e

XRAY_VERSION="${1:-v26.7.28}"
DEST_DIR="${2:-/tmp/xray-bin}"
XRAY_ZIP="Xray-linux-64.zip"
BASE_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}"
ZIP_URL="${BASE_URL}/${XRAY_ZIP}"
DGST_URL="${BASE_URL}/${XRAY_ZIP}.dgst"

mkdir -p "${DEST_DIR}"
cd "${DEST_DIR}"

echo "Fetching Xray-core ${XRAY_VERSION} from GitHub releases..."
wget -q -O "${XRAY_ZIP}" "${ZIP_URL}"
wget -q -O "${XRAY_ZIP}.dgst" "${DGST_URL}"

# Parse SHA256 from digest file robustly
parse_sha256() {
    local dgst_file="$1"
    local sha_lines=""
    sha_lines=$(grep -iE "^(SHA256|SHA2-256)[[:space:]]*=" "${dgst_file}" || grep -iE "^SHA256[[:space:]]*\([^)]+\)[[:space:]]*=" "${dgst_file}" || true)

    if [ -z "${sha_lines}" ]; then
        echo "::error::No SHA-256 checksum found in ${dgst_file}" >&2
        return 1
    fi

    # Extract hash values
    local hashes=""
    hashes=$(echo "${sha_lines}" | sed -E 's/.*=[[:space:]]*//' | tr -d ' \r\n' | tr 'A-Z' 'a-z')

    # Validate 64 hex characters
    local count=$(echo "${sha_lines}" | wc -l)
    if [ "${count}" -gt 1 ]; then
        local first_hash=$(echo "${sha_lines}" | head -n 1 | sed -E 's/.*=[[:space:]]*//' | tr -d ' \r\n' | tr 'A-Z' 'a-z')
        local second_hash=$(echo "${sha_lines}" | tail -n 1 | sed -E 's/.*=[[:space:]]*//' | tr -d ' \r\n' | tr 'A-Z' 'a-z')
        if [ "${first_hash}" != "${second_hash}" ]; then
            echo "::error::Conflicting SHA-256 lines in ${dgst_file}" >&2
            return 1
        fi
        hashes="${first_hash}"
    fi

    case "${hashes}" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
            echo "${hashes}"
            return 0
            ;;
        *)
            echo "::error::Malformed SHA-256 hash in ${dgst_file}: '${hashes}'" >&2
            return 1
            ;;
    esac
}

EXPECTED_SHA=$(parse_sha256 "${XRAY_ZIP}.dgst")
echo "Verifying checksum: ${EXPECTED_SHA}  ${XRAY_ZIP}"
echo "${EXPECTED_SHA}  ${XRAY_ZIP}" | sha256sum -c -

echo "Extracting ${XRAY_ZIP}..."
unzip -q -o "${XRAY_ZIP}"
chmod +x xray

VERSION_OUTPUT=$("${DEST_DIR}/xray" version 2>&1 || true)
if ! echo "${VERSION_OUTPUT}" | grep -q "26.7.28"; then
    echo "::error::Extracted Xray binary does not match expected version 26.7.28 (got '${VERSION_OUTPUT}')" >&2
    exit 1
fi

echo "Successfully verified Xray-core binary at ${DEST_DIR}/xray"
echo "${DEST_DIR}/xray"
exit 0
