#!/bin/bash
set -euo pipefail

# Integration test for the ckpool image.
#
# Runs on the host and observes the container's externally visible behaviour:
# does it boot, does it drop root, does it run in solo (-B) mode, does it bind
# the stratum port.
#
# By default (WITH_REGTEST=1) it also boots a throwaway `bitcoind -regtest`
# sidecar, points ckpool at it, and drives the full mining path end to end: a
# miner subscribes over stratum and must receive a `mining.notify` job, which
# ckpool can only build from a successful getblocktemplate against the node. Set
# WITH_REGTEST=0 for the lean, no-bitcoind smoke test: ckpool logs that it cannot
# reach the RPC, keeps its stratum listener up, and the RPC assertions are skipped.

IMAGE="${IMAGE:?IMAGE must be set (e.g. IMAGE=ckpool:v0.0.0.local)}"
DEBUG="${DEBUG:-0}"

# WITH_REGTEST=1 (the default) boots a throwaway `bitcoind -regtest` sidecar and
# points ckpool at it. regtest is a private, empty chain — no network sync — so
# getblocktemplate answers immediately, exercising the real RPC path end to end.
# Set WITH_REGTEST=0 to skip the sidecar (lean smoke test).
WITH_REGTEST="${WITH_REGTEST:-1}"
BITCOIND_IMAGE="${BITCOIND_IMAGE:-lncm/bitcoind:v27.0}"

CONTAINER="ckpool-itest-$$"
STRATUM_PORT=3333
CONFIG_DIR="$(mktemp -d)"
DOCKER_NETWORK=""
BITCOIND=""
REGTEST_ADDR=""

# Bitcoin RPC target. Defaults point at a deliberately-dead RPC so the suite
# needs no bitcoind; the regtest sidecar below overrides it with a live node.
BTC_URL="127.0.0.1:8332"
BTC_USER="itest"
BTC_PASS="itest"

failures=0

cleanup() {
    if [ "$DEBUG" = "1" ]; then
        echo "── container logs ──"
        docker logs "$CONTAINER" 2>&1 | tail -25 || true
        [ -n "$BITCOIND" ] && { echo "── bitcoind logs ──"; docker logs "$BITCOIND" 2>&1 | tail -10 || true; }
    fi
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    if [ -n "$BITCOIND" ]; then docker rm -f "$BITCOIND" >/dev/null 2>&1 || true; fi
    if [ -n "$DOCKER_NETWORK" ]; then docker network rm "$DOCKER_NETWORK" >/dev/null 2>&1 || true; fi
    rm -rf "$CONFIG_DIR"
}
trap cleanup EXIT

check() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "✅ PASS  $name"
    else
        echo "❌ FAIL  $name"
        failures=$((failures + 1))
    fi
}

# ── Optional regtest sidecar ──────────────────────────────────────────────────
if [ "$WITH_REGTEST" = "1" ]; then
    echo "🧱 Booting regtest bitcoind (${BITCOIND_IMAGE})"
    DOCKER_NETWORK="ck-itest-net-$$"
    BITCOIND="bitcoind-itest-$$"
    docker network create "$DOCKER_NETWORK" >/dev/null

    docker run -d --name "$BITCOIND" --network "$DOCKER_NETWORK" \
        --entrypoint bitcoind "$BITCOIND_IMAGE" \
        -regtest -server -rpcbind=0.0.0.0 -rpcallowip=0.0.0.0/0 \
        -rpcuser=itest -rpcpassword=itest -fallbackfee=0.0002 -listen=0 >/dev/null

    btc_cli() { docker exec "$BITCOIND" bitcoin-cli -regtest -rpcuser=itest -rpcpassword=itest "$@"; }

    for _ in $(seq 1 30); do
        btc_cli getblockchaininfo >/dev/null 2>&1 && break
        sleep 1
    done

    # A wallet holds the coinbase; mine past maturity so getblocktemplate has a
    # real chain tip to build on, like a live node would.
    btc_cli createwallet itest >/dev/null 2>&1 || btc_cli loadwallet itest >/dev/null 2>&1 || true
    REGTEST_ADDR="$(btc_cli getnewaddress)"
    btc_cli generatetoaddress 101 "$REGTEST_ADDR" >/dev/null

    BTC_URL="${BITCOIND}:18443"
fi

# A minimal solo config. `notify: true` makes ckpool ask bitcoind to push block
# notifications. With the regtest sidecar this points at a live node; without it,
# at a dead RPC (which ckpool tolerates while keeping stratum up).
cat > "${CONFIG_DIR}/ckpool.conf" <<EOF
{
"btcd" : [
    {
        "url" : "${BTC_URL}",
        "auth" : "${BTC_USER}",
        "pass" : "${BTC_PASS}",
        "notify" : true
    }
],
"serverurl" : [ "0.0.0.0:3333" ],
"mindiff" : 1,
"startdiff" : 1000,
"logdir" : "/var/lib/ckpool/logs"
}
EOF

echo "🧪 Testing ${IMAGE}"

docker run -d --name "$CONTAINER" \
    ${DOCKER_NETWORK:+--network "$DOCKER_NETWORK"} \
    -v "${CONFIG_DIR}/ckpool.conf:/config/ckpool.conf:ro" \
    "$IMAGE" >/dev/null

# Wait for the stratum listener to come up.
for _ in $(seq 1 30); do
    if docker logs "$CONTAINER" 2>&1 | grep -qiE "listener|stratum|Startup complete"; then
        break
    fi
    sleep 1
done

is_running()    { [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" = "true" ]; }
container_uid() { docker exec "$CONTAINER" id -u; }

# A crash-on-boot is the failure we care about most.
check "container is running" is_running

# Upstream builds run as whatever user starts them. Ours must be non-root — the
# single most important regression to catch if the Dockerfile is refactored.
runs_as_ckpool() { [ "$(container_uid)" = "1000" ]; }
not_root()       { [ "$(container_uid)" != "0" ]; }
check "runs as non-root (uid 1000)" runs_as_ckpool
check "does not run as root" not_root

# Solo mode is the whole point of this image. Assert it from the launch flag
# itself (`-B` in PID 1's argv), which holds whether or not a bitcoind is
# reachable — unlike the "Mining solo…" log line, which only prints once the node
# connects.
solo_mode() { docker exec "$CONTAINER" cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ' | grep -q -- '-B'; }
check "started in solo (-B) mode" solo_mode

# Stratum is the whole point of a stratum server: if this port never binds,
# miners cannot connect no matter how healthy everything else looks.
stratum_bound() {
    docker exec "$CONTAINER" bash -c "exec 3<>/dev/tcp/127.0.0.1/${STRATUM_PORT}"
}
check "stratum port ${STRATUM_PORT} accepts TCP" stratum_bound

# The runtime image must not carry the C toolchain. gcc landing in the final
# layer means the multi-stage split regressed.
check "no build toolchain in the runtime image" \
    bash -c "! docker exec ${CONTAINER} sh -c 'command -v gcc'"

# The sockdir and logdir must be writable by the unprivileged user, or ckpool
# cannot create its unix sockets and dies.
check "sockdir is writable by ckpool" \
    docker exec "$CONTAINER" test -w /tmp/ckpool
check "logdir is writable by ckpool" \
    docker exec "$CONTAINER" test -w /var/lib/ckpool

# With a real (regtest) node behind it, exercise the full mining path. ckpool
# only calls getblocktemplate once a miner subscribes, so we run a minimal
# stratum handshake and assert we get a mining.notify job back — which ckpool can
# only build from a successful getblocktemplate against the node.
if [ "$WITH_REGTEST" = "1" ]; then
    no_rpc_failure() { ! docker logs "$CONTAINER" 2>&1 | grep -qiE "Failed to connect socket to.*8332|No live nodes"; }

    receives_mining_job() {
        docker exec -e ADDR="$REGTEST_ADDR" -e PORT="$STRATUM_PORT" "$CONTAINER" bash -c '
            exec 3<>/dev/tcp/127.0.0.1/"$PORT" || exit 1
            printf "{\"id\":1,\"method\":\"mining.subscribe\",\"params\":[\"itest\"]}\n" >&3
            printf "{\"id\":2,\"method\":\"mining.authorize\",\"params\":[\"$ADDR\",\"x\"]}\n" >&3
            end=$((SECONDS + 15))
            while [ "$SECONDS" -lt "$end" ]; do
                if IFS= read -r -t 15 line <&3; then
                    case "$line" in *mining.notify*) exit 0 ;; esac
                else
                    break
                fi
            done
            exit 1
        '
    }

    check "miner receives job (getblocktemplate → mining.notify)" receives_mining_job
    check "no RPC connection failure against regtest node" no_rpc_failure
fi

echo
if [ "$failures" -gt 0 ]; then
    echo "❌ ${failures} check(s) failed"
    exit 1
fi
echo "✅ All checks passed"
