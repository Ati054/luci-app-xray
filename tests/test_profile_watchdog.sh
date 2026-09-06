#!/bin/sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WATCHDOG="${ROOT_DIR}/core/root/usr/libexec/xray-profile-watchdog"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

BIN_DIR="${TMP_DIR}/bin"
STATE_DIR="${TMP_DIR}/state"
PROFILES_DIR="${TMP_DIR}/profiles"
mkdir -p "$BIN_DIR" "$STATE_DIR" "$PROFILES_DIR"
printf '%s\n' '{}' > "${PROFILES_DIR}/p1.json"

cat > "${TMP_DIR}/functions.sh" <<'EOF'
config_load() { return 0; }
config_foreach() {
    local callback="$1"
    "$callback" p1
}
config_get() {
    local destination="$1" option="$3" default="$4" value
    case "$option" in
        filename) value="p1.json" ;;
        *) value="$default" ;;
    esac
    eval "$destination=\$value"
}
EOF

cat > "${BIN_DIR}/ubus" <<'EOF'
#!/bin/sh
printf '%s\n' '{"xray_profiles":{"instances":{"profile_p1":{"running":true,"pid":4242}}}}'
EOF

cat > "${BIN_DIR}/jsonfilter" <<EOF
#!/bin/sh
expression=""
while [ "\$#" -gt 0 ]; do
    if [ "\$1" = "-e" ]; then expression="\$2"; shift 2; else shift; fi
done
case "\$expression" in
    *.running) printf '%s\n' true ;;
    *.pid) cat '${TMP_DIR}/pid' ;;
    '@.outbounds[@.settings.reverse].settings.address') printf '%s\n' '198.51.100.7' ;;
    '@.outbounds[@.settings.reverse].settings.port') printf '%s\n' '2443' ;;
    '@.outbounds[@.settings.reverse].streamSettings.sockopt.tcpUserTimeout') cat '${TMP_DIR}/tcp-user-timeout' ;;
    '@.*.available') printf '%s\n' true ;;
    '@.*.connections') cat '${TMP_DIR}/tunnel-connections' ;;
esac
EOF

cat > "${BIN_DIR}/xray-sockstats" <<EOF
#!/bin/sh
pid="\$(cat '${TMP_DIR}/pid')"
printf '{"%s":{"available":true,"connections":%s}}\n' "\$pid" "\$(cat '${TMP_DIR}/tunnel-connections')"
EOF

cat > "${BIN_DIR}/ss" <<EOF
#!/bin/sh
pid="\$(cat '${TMP_DIR}/pid')"
tunnel_connections="\$(cat '${TMP_DIR}/tunnel-connections')"
tunnel_stalled="\$(cat '${TMP_DIR}/tunnel-stalled')"
user_connections="\$(cat '${TMP_DIR}/user-connections')"
index=0
while [ "\$index" -lt "\$user_connections" ]; do
    if [ "\$index" -eq 0 ]; then
        peer='203.0.113.9:2443'
    else
        peer='198.51.100.7:443'
    fi
    printf 'ESTAB 0 0 192.0.2.2:%s %s users:(("xray",pid=%s,fd=%s))\n' "\$((51000 + index))" "\$peer" "\$pid" "\$((10 + index))"
    index="\$((index + 1))"
done
index=0
while [ "\$index" -lt "\$tunnel_connections" ]; do
    if [ "\$index" -lt "\$tunnel_stalled" ]; then
        printf 'ESTAB 0 1024 192.0.2.2:%s 198.51.100.7:2443 users:(("xray",pid=%s,fd=%s)) timer:(on,8.000sec,6)\n' "\$((52000 + index))" "\$pid" "\$((20 + index))"
    else
        printf 'ESTAB 0 0 192.0.2.2:%s 198.51.100.7:2443 users:(("xray",pid=%s,fd=%s))\n' "\$((52000 + index))" "\$pid" "\$((20 + index))"
    fi
    index="\$((index + 1))"
done
if [ "\$tunnel_connections" -eq 0 ]; then
    printf 'SYN-SENT 0 1 192.0.2.2:50000 198.51.100.7:2443 users:(("xray",pid=%s,fd=3))\n' "\$pid"
fi
EOF

cat > "${BIN_DIR}/nc" <<EOF
#!/bin/sh
[ "\$(cat '${TMP_DIR}/peer-reachable')" = "1" ]
EOF

cat > "${BIN_DIR}/timeout" <<'EOF'
#!/bin/sh
shift
exec "$@"
EOF

cat > "${BIN_DIR}/xray_profiles" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> '${TMP_DIR}/restarts'
EOF

cat > "${BIN_DIR}/logger" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> '${TMP_DIR}/watchdog.log'
EOF

chmod 0755 "${BIN_DIR}"/*
: > "${TMP_DIR}/restarts"
: > "${TMP_DIR}/watchdog.log"
printf '%s\n' 1 > "${TMP_DIR}/tunnel-connections"
printf '%s\n' 0 > "${TMP_DIR}/tunnel-stalled"
printf '%s\n' 2 > "${TMP_DIR}/user-connections"
printf '%s\n' 0 > "${TMP_DIR}/tcp-user-timeout"
printf '%s\n' 0 > "${TMP_DIR}/peer-reachable"
printf '%s\n' 4242 > "${TMP_DIR}/pid"

run_once() {
    printf '%s 0.00\n' "$1" > "${TMP_DIR}/uptime"
    XRAY_WATCHDOG_FUNCTIONS_SH="${TMP_DIR}/functions.sh" \
    XRAY_WATCHDOG_PROFILES_DIR="$PROFILES_DIR" \
    XRAY_WATCHDOG_STATE_DIR="$STATE_DIR" \
    XRAY_WATCHDOG_UBUS_BIN="${BIN_DIR}/ubus" \
    XRAY_WATCHDOG_JSONFILTER_BIN="${BIN_DIR}/jsonfilter" \
    XRAY_WATCHDOG_SOCKSTATS_BIN="${BIN_DIR}/xray-sockstats" \
    XRAY_WATCHDOG_SS_BIN="${BIN_DIR}/ss" \
    XRAY_WATCHDOG_NC_BIN="${BIN_DIR}/nc" \
    XRAY_WATCHDOG_TIMEOUT_BIN="${BIN_DIR}/timeout" \
    XRAY_WATCHDOG_INIT_SCRIPT="${BIN_DIR}/xray_profiles" \
    XRAY_WATCHDOG_LOGGER_BIN="${BIN_DIR}/logger" \
    XRAY_WATCHDOG_UPTIME_FILE="${TMP_DIR}/uptime" \
    XRAY_WATCHDOG_CHECK_INTERVAL_SECONDS=5 \
    XRAY_WATCHDOG_DISCONNECT_GRACE_SECONDS=15 \
    XRAY_WATCHDOG_CONNECTED_REARM_SECONDS=10 \
    XRAY_WATCHDOG_USER_TIMEOUT_MARGIN_SECONDS=15 \
    XRAY_WATCHDOG_PROBE_TIMEOUT_SECONDS=1 \
    XRAY_WATCHDOG_MAX_ITERATIONS=1 \
        sh "$WATCHDOG"
}

restart_count() {
    wc -l < "${TMP_DIR}/restarts" | tr -d ' '
}

assert_restart_count() {
    expected="$1"
    description="$2"
    actual="$(restart_count)"
    if [ "$actual" != "$expected" ]; then
        echo "FAIL: ${description} (expected ${expected}, got ${actual})" >&2
        cat "${TMP_DIR}/restarts" >&2
        exit 1
    fi
    echo "PASS: ${description}"
}

# A server outage that already exists at boot stays quiet for as long as the
# peer is unreachable.
printf '%s\n' 0 > "${TMP_DIR}/tunnel-connections"
run_once 100
run_once 10000
assert_restart_count 0 "user traffic cannot mask a boot-time tunnel outage while the peer is unreachable"

# When that peer comes back, the initial process gets exactly one recovery
# attempt even though no healthy connection was observed before the outage.
printf '%s\n' 1 > "${TMP_DIR}/peer-reachable"
run_once 10001
assert_restart_count 1 "boot-time outage recovers once when the peer becomes reachable"
printf '%s\n' 5252 > "${TMP_DIR}/pid"
run_once 20000
assert_restart_count 1 "boot-time recovery stays disarmed across the replacement PID"

# A stable connection rearms recovery after the one initial attempt.
printf '%s\n' 1 > "${TMP_DIR}/tunnel-connections"
run_once 20001
run_once 20012
assert_restart_count 1 "stable initial connection only arms recovery"

# A short transient disconnect remains below the grace window.
printf '%s\n' 0 > "${TMP_DIR}/tunnel-connections"
run_once 20013
printf '%s\n' 1 > "${TMP_DIR}/tunnel-connections"
run_once 20020
assert_restart_count 1 "short transient disconnect is ignored"

# A later long outage stays quiet while the peer is unavailable.
printf '%s\n' 0 > "${TMP_DIR}/tunnel-connections"
printf '%s\n' 0 > "${TMP_DIR}/peer-reachable"
run_once 20021
run_once 20037
run_once 30000
assert_restart_count 1 "long server outage causes no restart while the peer is unreachable"

# As soon as the peer becomes reachable, exactly one targeted restart is
# allowed for this outage.
printf '%s\n' 1 > "${TMP_DIR}/peer-reachable"
run_once 30001
assert_restart_count 2 "reachable peer after confirmed outage triggers one recovery restart"
grep -qx 'restart p1' "${TMP_DIR}/restarts" || {
    echo "FAIL: watchdog did not use an isolated profile restart" >&2
    exit 1
}

# The watchdog stays disarmed even over a long interval until a stable tunnel
# is observed again, preventing restart storms and repeated false positives.
run_once 40000
assert_restart_count 2 "one outage cannot trigger repeated restarts"

# After a new stable connection, a later independent outage is recoverable.
printf '%s\n' 1 > "${TMP_DIR}/tunnel-connections"
run_once 40001
run_once 40012
printf '%s\n' 0 > "${TMP_DIR}/tunnel-connections"
run_once 40013
run_once 40029
assert_restart_count 3 "stable recovery rearms exactly one restart for a later outage"

# A single backpressured endpoint socket must not restart an otherwise healthy
# multi-socket Reverse tunnel. A persistent retransmission majority is a stale
# kernel ESTABLISHED state and becomes recoverable once the peer is reachable.
rm -f "${STATE_DIR}"/*
: > "${TMP_DIR}/restarts"
printf '%s\n' 7000 > "${TMP_DIR}/pid"
printf '%s\n' 3 > "${TMP_DIR}/tunnel-connections"
printf '%s\n' 1 > "${TMP_DIR}/tunnel-stalled"
printf '%s\n' 1 > "${TMP_DIR}/peer-reachable"
run_once 50000
run_once 50011
assert_restart_count 0 "a minority of backpressured tunnel sockets causes no false restart"
printf '%s\n' 2 > "${TMP_DIR}/tunnel-stalled"
printf '%s\n' 0 > "${TMP_DIR}/peer-reachable"
run_once 50012
run_once 50028
assert_restart_count 0 "stale established sockets stay quiet while the server is unreachable"
printf '%s\n' 1 > "${TMP_DIR}/peer-reachable"
run_once 50029
assert_restart_count 1 "stale established tunnel sockets trigger one restart when the server returns"
run_once 60000
assert_restart_count 1 "stale established outage cannot create a restart loop"

# Explicit JSON socket policy remains authoritative. The fallback watchdog
# must not restart the process before Xray's configured TCP user timeout plus
# the configured recovery margin has elapsed.
rm -f "${STATE_DIR}"/*
: > "${TMP_DIR}/restarts"
printf '%s\n' 8000 > "${TMP_DIR}/pid"
printf '%s\n' 3 > "${TMP_DIR}/tunnel-connections"
printf '%s\n' 2 > "${TMP_DIR}/tunnel-stalled"
printf '%s\n' 1 > "${TMP_DIR}/peer-reachable"
printf '%s\n' 60000 > "${TMP_DIR}/tcp-user-timeout"
run_once 70000
run_once 70030
run_once 70074
assert_restart_count 0 "watchdog honors the JSON TCP user timeout without a premature restart"
run_once 70075
assert_restart_count 1 "watchdog provides one fallback restart after the JSON timeout and recovery margin"

echo "Profile watchdog state-machine tests completed successfully."
