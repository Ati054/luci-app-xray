#!/bin/sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RENDERER="${SCRIPT_DIR}/../core/root/usr/libexec/xray-profile-runtime-config"
UCODE_BIN="${UCODE_BIN:-ucode}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SOURCE="${TMP_DIR}/profile.json"
OUTPUT="${TMP_DIR}/runtime.json"
cat > "$SOURCE" <<'EOF'
{"outbounds":[{"protocol":"vless","settings":{"reverse":{"tag":"reverse-in"}},"streamSettings":{"security":"reality","sockopt":{"tcpKeepAliveIdle":77}}},{"protocol":"freedom","tag":"direct"}]}
EOF
SOURCE_HASH="$(sha256sum "$SOURCE" | awk '{print $1}')"

XRAY_PROFILE_SOURCE="$SOURCE" \
XRAY_PROFILE_TCP_KEEPALIVE_IDLE=10 \
XRAY_PROFILE_TCP_KEEPALIVE_INTERVAL=3 \
XRAY_PROFILE_TCP_USER_TIMEOUT=15000 \
    "$UCODE_BIN" "$RENDERER" > "$OUTPUT"

grep -Eq '"tcpKeepAliveIdle"[[:space:]]*:[[:space:]]*77' "$OUTPUT"
grep -Eq '"tcpKeepAliveInterval"[[:space:]]*:[[:space:]]*3' "$OUTPUT"
grep -Eq '"tcpUserTimeout"[[:space:]]*:[[:space:]]*15000' "$OUTPUT"
grep -Eq '"protocol"[[:space:]]*:[[:space:]]*"freedom"' "$OUTPUT"
[ "$SOURCE_HASH" = "$(sha256sum "$SOURCE" | awk '{print $1}')" ]

printf '%s\n' '{"outbounds":[{"protocol":"freedom"}]}' > "${TMP_DIR}/not-reverse.json"
if XRAY_PROFILE_SOURCE="${TMP_DIR}/not-reverse.json" "$UCODE_BIN" "$RENDERER" >/dev/null 2>&1; then
    echo "FAIL: non-Reverse profile was accepted" >&2
    exit 1
fi

echo "Profile runtime TCP liveness configuration tests completed successfully."
