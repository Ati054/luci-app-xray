#!/bin/sh
# Fetches, verifies, and extracts official Xray-core release binary

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/checksum_lib.sh"

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

EXPECTED_SHA=$(parse_sha256_digest "${XRAY_ZIP}.dgst")
echo "Verifying checksum: ${EXPECTED_SHA}  ${XRAY_ZIP}"
echo "${EXPECTED_SHA}  ${XRAY_ZIP}" | sha256sum -c -

echo "Extracting ${XRAY_ZIP}..."
unzip -q -o "${XRAY_ZIP}"
chmod +x xray

VERSION_OUTPUT=$("${DEST_DIR}/xray" version 2>&1 || true)
FIRST_LINE=$(echo "${VERSION_OUTPUT}" | head -n 1)
case "${FIRST_LINE}" in
    "Xray 26.7.28"*)
        echo "Version signature verified: ${FIRST_LINE}"
        ;;
    *)
        echo "::error::Extracted Xray binary first line '${FIRST_LINE}' does not start with 'Xray 26.7.28'" >&2
        exit 1
        ;;
esac

echo "Successfully verified Xray-core binary at ${DEST_DIR}/xray"
echo "${DEST_DIR}/xray"
exit 0
