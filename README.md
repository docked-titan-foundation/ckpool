[![CI_CD](https://github.com/docked-titan-foundation/ckpool/actions/workflows/pipeline.yml/badge.svg)](https://github.com/docked-titan-foundation/ckpool/actions/workflows/pipeline.yml)
![Release](https://img.shields.io/github/v/release/docked-titan-foundation/ckpool)
[![Renovate](https://img.shields.io/badge/renovate-enabled-brightgreen.svg)](https://renovatebot.com)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
![Stars](https://img.shields.io/github/stars/docked-titan-foundation/ckpool?style=social)

## 📝 Description

A hardened container image for **ckpool** — Con Kolivas' ultra-low-overhead
Bitcoin mining stratum server — built for **solo mining**.

ckpool bridges Stratum-speaking miners (a Bitaxe, a NerdQAxe, an old ASIC) to a
`bitcoind` that only speaks `getblocktemplate`. In solo mode (`-B`) each miner
authenticates with the Bitcoin address it wants a found block to pay, set as its
stratum username. There is no operator, no cut, and no shared payout.

## ✨ What this image does differently

ckpool's author publishes **source only** — no releases, no official image. Every
ckpool image on Docker Hub is an unaudited personal build by an anonymous account.
Since this process assembles the coinbase output that pays out a solved block —
it decides who gets the money — that is not a supply chain you want to guess at.

| | A typical Docker Hub ckpool | This image |
|---|---|---|
| Provenance | anonymous account, no signature | cosign-signed, SLSA provenance, SPDX SBOM |
| Source | "trust me" | a **pinned** upstream commit, re-asserted after fetch |
| User | often root | **non-root** (uid 1000) |
| Base | often unpinned | pinned by digest, rebuilt and re-scanned weekly |
| Dev donation | whatever the config shipped | **you** decide — `donation` is not silently set |

## 📋 Version Matrix

The image tag tracks *this repo's* releases; the ckpool commit column records
which upstream source is compiled in (upstream has no versions of its own).

### Stable Releases

| Version | ckpool commit | Base | Date |
|---|---|---|---|

### Beta Releases

| Version | ckpool commit | Base | Date |
|---|---|---|---|
| 1.0.0-beta.1 (latest beta) | `37984cff4373` | bookworm-slim | 2026-07-23 |

## 🚀 Usage

ckpool needs a config file (it carries the bitcoind RPC credential, so none is
baked into the image) and a bitcoind reachable over RPC + ZMQ.

```bash
docker run -d --name ckpool \
  -p 3333:3333 \
  -v "$PWD/ckpool.conf:/config/ckpool.conf:ro" \
  ghcr.io/docked-titan-foundation/ckpool:<version>
```

A minimal solo `ckpool.conf`:

```json
{
  "btcd": [{ "url": "bitcoind:8332", "auth": "bitcoin", "pass": "<rpc password>", "notify": true }],
  "serverurl": ["0.0.0.0:3333"],
  "zmqblock": "tcp://bitcoind:28332",
  "mindiff": 1,
  "startdiff": 1000,
  "logdir": "/var/lib/ckpool/logs"
}
```

Then point a miner at `stratum+tcp://<host>:3333`, username = the Bitcoin address
a found block should pay.

For Kubernetes, use the
[bitcoin-stack](https://github.com/docked-titan-foundation/bitcoin-stack) chart,
which renders this config, wires the node and pool together, and pins this image
by digest.

### A note on the dev donation

Upstream ckpool contributes 0.5% of solved blocks to its author **in pool mode**;
solo mode does not donate unless you set `"donation"` yourself. This image changes
nothing about that — supporting the author is a choice you make in your config,
not one made for you. ckpool is excellent software; if you run it, consider it.

## 🔐 Verifying the image

Every release is cosign-signed (keyless) with an SPDX SBOM attestation.

```bash
cosign verify ghcr.io/docked-titan-foundation/ckpool:<version> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp "https://github.com/docked-titan-foundation/ckpool"

cosign verify-attestation --type spdxjson \
  ghcr.io/docked-titan-foundation/ckpool:<version> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp "https://github.com/docked-titan-foundation/ckpool"
```

## 🛠️ Development

```bash
mise install
mise run build   # docker build
mise run test    # boot the image; assert non-root, solo mode, stratum bound
mise run lint    # hadolint + shellcheck
```

## 📄 License

GPL-3.0, matching upstream ckpool.
