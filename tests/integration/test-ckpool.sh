#!/bin/bash
set -euo pipefail

# Integration test for the ckpool image.
#
# Runs on the host and observes the container's externally visible behaviour:
# does it boot, does it drop root, does it bind the stratum port, does it run in
# solo (-B) mode. A real bitcoind is not provided — ckpool logs that it cannot
# reach the RPC and keeps its stratum listener up, so these assertions hold
# without a full node in CI.

IMAGE="${IMAGE:?IMAGE must be set (e.g. IMAGE=ckpool:v0.0.0.local)}"
DEBUG="${DEBUG:-0}"

CONTAINER="ckpool-itest-$$"
STRATUM_PORT=3333
CONFIG_DIR="$(mktemp -d)"

failures=0

cleanup() {
    if [ "$DEBUG" = "1" ]; then
        echo "── container logs ──"
        docker logs "$CONTAINER" 2>&1 | tail -25 || true
    fi
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
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

# A minimal solo config. `notify: true` makes ckpool ask bitcoind to push block
# notifications; there is no bitcoind here, which is fine — we are testing the
# stratum server, not a full mining round.
cat > "${CONFIG_DIR}/ckpool.conf" <<'EOF'
{
"btcd" : [
    {
        "url" : "127.0.0.1:8332",
        "auth" : "itest",
        "pass" : "itest",
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

# Solo mode is the whole point of this image. ckpool logs "ckpool-btcsolo" (or
# the btcsolo mode) on startup when launched with -B.
solo_mode() { docker logs "$CONTAINER" 2>&1 | grep -qiE "btcsolo|solo"; }
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

echo
if [ "$failures" -gt 0 ]; then
    echo "❌ ${failures} check(s) failed"
    exit 1
fi
echo "✅ All checks passed"
