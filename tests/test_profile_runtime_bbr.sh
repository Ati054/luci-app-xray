#!/bin/sh

set -eu

echo "=== Runtime-only BBR profile overlay ==="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATOR="${SCRIPT_DIR}/../core/root/usr/share/xray/profile_runtime.uc"

if ! command -v ucode >/dev/null 2>&1; then
    if [ "${CI:-}" = "true" ] || [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        echo "ucode is required in CI" >&2
        exit 1
    fi
    echo "[SKIP] ucode is unavailable"
    exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

SOURCE="${TMP_DIR}/stored.json"
RUNTIME="${TMP_DIR}/runtime.json"
SOURCE_HASH="${TMP_DIR}/stored.sha256"

cat >"$SOURCE" <<'EOF'
{
  "outbounds": [
    {
      "tag": "reverse-default",
      "protocol": "vless",
      "settings": { "reverse": { "tag": "portal" } },
      "streamSettings": { "network": "xhttp", "sockopt": { "tcpUserTimeout": 15000 } }
    },
    {
      "tag": "reverse-override",
      "protocol": "vless",
      "settings": { "reverse": { "tag": "portal-2" } },
      "streamSettings": { "sockopt": { "tcpcongestion": "cubic" } }
    },
    {
      "tag": "ordinary",
      "protocol": "vless",
      "settings": { "vnext": [] },
      "streamSettings": { "sockopt": {} }
    }
  ]
}
EOF

sha256sum "$SOURCE" >"$SOURCE_HASH"
ucode "$GENERATOR" "$SOURCE" >"$RUNTIME"
sha256sum -c "$SOURCE_HASH"

python3 - "$RUNTIME" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    cfg = json.load(handle)

outbounds = {item["tag"]: item for item in cfg["outbounds"]}
assert outbounds["reverse-default"]["streamSettings"]["sockopt"]["tcpcongestion"] == "bbr"
assert outbounds["reverse-default"]["streamSettings"]["sockopt"]["tcpUserTimeout"] == 15000
assert outbounds["reverse-override"]["streamSettings"]["sockopt"]["tcpcongestion"] == "cubic"
assert "tcpcongestion" not in outbounds["ordinary"]["streamSettings"]["sockopt"]
PY

printf '%s\n' '{"outbounds":[{"protocol":"freedom"}]}' >"${TMP_DIR}/not-reverse.json"
if ucode "$GENERATOR" "${TMP_DIR}/not-reverse.json" >"${TMP_DIR}/invalid.json" 2>/dev/null; then
    echo "non-Reverse profile was accepted unexpectedly" >&2
    exit 1
fi

grep -Fq '+kmod-tcp-bbr' "${SCRIPT_DIR}/../core/Makefile"
grep -Fq 'profile_runtime.uc' "${SCRIPT_DIR}/../core/Makefile"

echo "PROFILE_RUNTIME_BBR_OK"
