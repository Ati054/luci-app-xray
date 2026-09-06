#!/bin/sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WATCHDOG="${ROOT_DIR}/core/root/usr/libexec/xray-profile-watchdog"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

BIN_DIR="${TMP_DIR}/bin"
STATE_DIR="${TMP_DIR}/state"
mkdir -p "$BIN_DIR" "$STATE_DIR"

cat > "${TMP_DIR}/functions.sh" <<'EOF'
config_load() { return 0; }
config_foreach() {
    local callback="$1"
    "$callback" p1
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
    '@.*.available') printf '%s\n' true ;;
    '@.*.connections') cat '${TMP_DIR}/connections' ;;
esac
EOF

cat > "${BIN_DIR}/xray-sockstats" <<EOF
#!/bin/sh
pid="\$(cat '${TMP_DIR}/pid')"
printf '{"%s":{"available":true,"connections":%s}}\n' "\$pid" "\$(cat '${TMP_DIR}/connections')"
EOF

cat > "${BIN_DIR}/ss" <<EOF
#!/bin/sh
pid="\$(cat '${TMP_DIR}/pid')"
printf 'SYN-SENT 0 1 192.0.2.2:50000 198.51.100.7:2443 users:(("xray",pid=%s,fd=3))\n' "\$pid"
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
printf '%s\n' 1 > "${TMP_DIR}/connections"
printf '%s\n' 0 > "${TMP_DIR}/peer-reachable"
printf '%s\n' 4242 > "${TMP_DIR}/pid"

run_once() {
    printf '%s 0.00\n' "$1" > "${TMP_DIR}/uptime"
    XRAY_WATCHDOG_FUNCTIONS_SH="${TMP_DIR}/functions.sh" \
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
    XRAY_WATCHDOG_CHECK_INTERVAL_SECONDS=0 \
    XRAY_WATCHDOG_DISCONNECT_GRACE_SECONDS=15 \
    XRAY_WATCHDOG_CONNECTED_REARM_SECONDS=10 \
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
printf '%s\n' 0 > "${TMP_DIR}/connections"
run_once 100
run_once 10000
assert_restart_count 0 "boot-time server outage causes no restart while the peer is unreachable"

# When that peer comes back, the initial process gets exactly one recovery
# attempt even though no healthy connection was observed before the outage.
printf '%s\n' 1 > "${TMP_DIR}/peer-reachable"
run_once 10001
assert_restart_count 1 "boot-time outage recovers once when the peer becomes reachable"
printf '%s\n' 5252 > "${TMP_DIR}/pid"
run_once 20000
assert_restart_count 1 "boot-time recovery stays disarmed across the replacement PID"

# A stable connection rearms recovery after the one initial attempt.
printf '%s\n' 1 > "${TMP_DIR}/connections"
run_once 20001
run_once 20012
assert_restart_count 1 "stable initial connection only arms recovery"

# A short transient disconnect remains below the grace window.
printf '%s\n' 0 > "${TMP_DIR}/connections"
run_once 20013
printf '%s\n' 1 > "${TMP_DIR}/connections"
run_once 20020
assert_restart_count 1 "short transient disconnect is ignored"

# A later long outage stays quiet while the peer is unavailable.
printf '%s\n' 0 > "${TMP_DIR}/connections"
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
printf '%s\n' 1 > "${TMP_DIR}/connections"
run_once 40001
run_once 40012
printf '%s\n' 0 > "${TMP_DIR}/connections"
run_once 40013
run_once 40029
assert_restart_count 3 "stable recovery rearms exactly one restart for a later outage"

echo "Profile watchdog state-machine tests completed successfully."
