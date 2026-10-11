#!/bin/sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
UCODE_BIN="${UCODE_BIN:-ucode}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT INT TERM

mkdir -p "${TMP_DIR}/root/opt/xray/profiles" "${TMP_DIR}/bin"

cat > "${TMP_DIR}/bin/logread" <<'EOF'
#!/bin/sh
echo 'unrelated daemon message'
i=1
while [ "$i" -le 40 ]; do
    echo "Sun Oct 12 12:00:${i} 2026 daemon.warn xray[4242]: bounded diagnostic line ${i}"
    i=$((i + 1))
done
echo 'another unrelated message'
EOF
chmod 0755 "${TMP_DIR}/bin/logread"

PATH="${TMP_DIR}/bin:${PATH}" "${UCODE_BIN}" \
    "${ROOT_DIR}/core/root/usr/libexec/rpcd/xray_profiles" \
    --mock-dir "${TMP_DIR}/root" call logs '{"limit":25}' > "${TMP_DIR}/result.json"

"${PYTHON_BIN}" - "${TMP_DIR}/result.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["ok"] is True
assert data["storage"] == "ram"
assert data["source"] == "logd"
assert data["limit"] == 25
assert data["maximum_limit"] == 500
assert data["available"] == 40
assert data["returned"] == 25
assert data["lines"][0].endswith("bounded diagnostic line 16")
assert data["lines"][-1].endswith("bounded diagnostic line 40")
assert all("unrelated" not in line for line in data["lines"])
PY

PATH="${TMP_DIR}/bin:${PATH}" "${UCODE_BIN}" \
    "${ROOT_DIR}/core/root/usr/libexec/rpcd/xray_profiles" \
    --mock-dir "${TMP_DIR}/root" call logs '{"limit":9999}' > "${TMP_DIR}/clamped.json"

"${PYTHON_BIN}" - "${TMP_DIR}/clamped.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["ok"] is True
assert data["limit"] == 500
assert data["returned"] == 40
PY

echo "RAM-only bounded log backend tests completed successfully."
