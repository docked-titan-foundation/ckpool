# ============================================================
# Stage 1: Builder
# ============================================================
# ckpool publishes no releases and no official image — upstream ships source
# only. We build from source at a pinned commit. The commit SHA is the integrity
# check: git is content-addressed, so checking out a full SHA cannot silently
# give us different code the way a mutable branch or a re-generated tarball can.
ARG DEBIAN_BASE=debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818
# hadolint ignore=DL3006
FROM ${DEBIAN_BASE} AS build

ARG CKPOOL_REPO=https://bitbucket.org/ckolivas/ckpool.git
ARG CKPOOL_COMMIT=308410ddf321349704f252f36b82d77f2ae007fc

# ckpool is C built with autotools. yasm compiles the x86-64 SHA-NI assembly
# path; libzmq is what lets the pool react to a new block the instant it lands
# (the zmqblock config option) instead of only polling bitcoind.
# hadolint ignore=DL3008
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        build-essential \
        autoconf \
        automake \
        libtool \
        pkg-config \
        yasm \
        libzmq3-dev && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

WORKDIR /build

# Fetch exactly the pinned commit, then assert we got it. `git fetch <sha>` fails
# outright if the remote no longer serves that object, and the HEAD check means a
# compromised remote cannot hand us a different tree under this SHA.
RUN git init -q . && \
    git remote add origin "${CKPOOL_REPO}" && \
    git fetch --depth 1 origin "${CKPOOL_COMMIT}" && \
    git checkout -q FETCH_HEAD && \
    test "$(git rev-parse HEAD)" = "${CKPOOL_COMMIT}"

# `make` only, not `make install`: the install hook runs `setcap
# CAP_NET_BIND_SERVICE` on the binary (to allow binding ports below 1024) and
# symlinks ckproxy. We need neither — stratum runs on 3333, and this is solo
# mode, not proxy mode — so we copy the built binaries straight out of src/.
RUN ./autogen.sh && \
    ./configure && \
    make -j"$(nproc)" && \
    strip src/ckpool src/ckpmsg src/notifier

# ============================================================
# Stage 2: Runtime
# ============================================================
# hadolint ignore=DL3006
FROM ${DEBIAN_BASE} AS runtime

ARG APP_VERSION
ARG BUILD_DATE
ARG VCS_REF
ARG CKPOOL_COMMIT=308410ddf321349704f252f36b82d77f2ae007fc

# upstream.revision records which ckpool commit is baked in — the image tag
# tracks *this* repo's releases, not upstream's (upstream has none).
LABEL org.opencontainers.image.title="ckpool" \
      org.opencontainers.image.description="Hardened ckpool — low-overhead Bitcoin solo mining stratum server" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="https://github.com/docked-titan-foundation/ckpool" \
      org.opencontainers.image.licenses="GPL-3.0" \
      org.opencontainers.image.vendor="Docked Titan Foundation" \
      org.opencontainers.image.base.name="docker.io/library/debian:bookworm-slim" \
      org.opencontainers.image.upstream.source="https://bitbucket.org/ckolivas/ckpool" \
      org.opencontainers.image.upstream.revision="${CKPOOL_COMMIT}"

# libzmq5 is the only runtime shared-library dependency beyond libc. tini reaps
# zombies and forwards signals, so a `docker stop` / pod eviction actually
# terminates the stratum listener instead of waiting out the timeout.
# hadolint ignore=DL3008
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libzmq5 \
        tini \
        ca-certificates && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --from=build /build/src/ckpool   /usr/local/bin/ckpool
COPY --from=build /build/src/ckpmsg   /usr/local/bin/ckpmsg
COPY --from=build /build/src/notifier /usr/local/bin/notifier

# Non-root. Upstream's install scripts run ckpool as a dedicated user; we do the
# same, with a fixed uid/gid so a Kubernetes securityContext and volume fsGroup
# can be set to match.
RUN groupadd -g 1000 ckpool && \
    useradd -u 1000 -g 1000 -s /usr/sbin/nologin -M ckpool && \
    mkdir -p /var/lib/ckpool /tmp/ckpool && \
    chown -R ckpool:ckpool /var/lib/ckpool /tmp/ckpool

# 3333 = stratum (miners). Bitcoin RPC and ZMQ are outbound only, so nothing else
# is exposed.
EXPOSE 3333

USER ckpool

# ckpool has no HTTP surface at all — the stratum port binding is the only signal
# it is alive and serving. bash's /dev/tcp opens a real TCP connection to it.
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD bash -c 'exec 3<>/dev/tcp/127.0.0.1/3333' || exit 1

# Solo mining (-B): each miner authenticates with the Bitcoin address it wants a
# found block to pay, set as its stratum username. The sockdir must be writable;
# /tmp/ckpool is created above and is an emptyDir under Kubernetes. The config
# file is supplied at runtime (bind-mount, or the chart's rendered ckpool.conf) —
# the image ships none, because the config carries the RPC credential.
ENTRYPOINT ["/usr/bin/tini", "--", "ckpool"]
CMD ["-B", "-s", "/tmp/ckpool", "-c", "/config/ckpool.conf"]
