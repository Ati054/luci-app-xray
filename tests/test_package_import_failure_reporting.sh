#!/bin/sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_ROOT="$(mktemp -d)"

cleanup() {
    rm -rf "${TMP_ROOT}"
}
trap cleanup EXIT

mkdir -p "${TMP_ROOT}/bin"
cat <<'EOF' > "${TMP_ROOT}/bin/ucode"
#!/bin/sh
echo "synthetic ucode failure" >&2
exit 254
EOF
chmod 755 "${TMP_ROOT}/bin/ucode"

if PATH="${TMP_ROOT}/bin:${PATH}" sh "${SCRIPT_DIR}/test_package_imports.sh" \
    > "${TMP_ROOT}/stdout" 2> "${TMP_ROOT}/stderr"; then
    echo "FAIL: package import test accepted a failing ucode runtime" >&2
    exit 1
fi

grep -q 'gen_config.uc failed with exit 254' "${TMP_ROOT}/stderr" || {
    echo "FAIL: package import test did not report the ucode exit status" >&2
    exit 1
}
grep -q 'synthetic ucode failure' "${TMP_ROOT}/stderr" || {
    echo "FAIL: package import test did not expose ucode stderr" >&2
    exit 1
}

echo "PASS: package import test preserves failing ucode diagnostics"
