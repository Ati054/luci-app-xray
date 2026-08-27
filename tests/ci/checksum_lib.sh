#!/bin/sh
# Reusable checksum parser library for Xray-core release validation

parse_sha256_digest() {
    local dgst_file="$1"
    if [ ! -f "${dgst_file}" ]; then
        echo "::error::Digest file '${dgst_file}' does not exist" >&2
        return 1
    fi

    # Extract all lines that declare SHA256 / SHA2-256
    local sha_lines=""
    sha_lines=$(grep -iE "^(SHA256|SHA2-256)[[:space:]]*=" "${dgst_file}" || true)
    if [ -z "${sha_lines}" ]; then
        sha_lines=$(grep -iE "^SHA256[[:space:]]*\([^)]+\)[[:space:]]*=" "${dgst_file}" || true)
    fi

    if [ -z "${sha_lines}" ]; then
        echo "::error::No SHA-256 checksum found in ${dgst_file}" >&2
        return 1
    fi

    # Reject if multiple SHA-256 lines exist (any duplicate or conflicting declaration)
    local line_count
    line_count=$(echo "${sha_lines}" | grep -c -v "^$" || true)
    if [ "${line_count}" -ne 1 ]; then
        echo "::error::Multiple or duplicate SHA-256 lines found in ${dgst_file} (count: ${line_count})" >&2
        return 1
    fi

    # Extract clean 64-hex hash
    local hash_val
    hash_val=$(echo "${sha_lines}" | sed -E 's/.*=[[:space:]]*//' | tr -d ' \r\n\t' | tr 'A-Z' 'a-z')

    case "${hash_val}" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
            echo "${hash_val}"
            return 0
            ;;
        *)
            echo "::error::Malformed SHA-256 hash in ${dgst_file}: '${hash_val}'" >&2
            return 1
            ;;
    esac
}
