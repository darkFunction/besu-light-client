#!/usr/bin/env bash
# Generates genesis + validator keys for both QBFT chains using
# `besu operator generate-blockchain-config`, then lays them out as:
#
#   networks/chain-<x>/genesis.json
#   networks/chain-<x>/validator<N>/{key,key.pub,address}
#   networks/chain-<x>/static-nodes.json   (all 4 validators, for peering)
#
# Usage: scripts/generate.sh [--force]   (--force wipes existing networks/)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BESU_IMAGE="${BESU_IMAGE:-hyperledger/besu:25.8.0}"
OUT="$ROOT/networks"
CHAINS=(a b)
# Must match the subnets in docker-compose.yml; validatorN gets <prefix>.1N.
declare -A SUBNET_PREFIX=([a]=172.28.1 [b]=172.28.2)

if [[ -d "$OUT" ]]; then
  if [[ "${1:-}" == "--force" ]]; then
    rm -rf "$OUT"
  else
    echo "networks/ already exists; re-run with --force to regenerate (this changes all keys)." >&2
    exit 1
  fi
fi

for c in "${CHAINS[@]}"; do
  echo "==> Generating chain-$c"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  cp "$ROOT/config/chain-$c/qbftConfigFile.json" "$tmp/"

  docker run --rm --user "$(id -u):$(id -g)" -v "$tmp:/work:z" --entrypoint besu "$BESU_IMAGE" \
    operator generate-blockchain-config \
    --config-file=/work/qbftConfigFile.json \
    --to=/work/out \
    --private-key-file-name=key >/dev/null

  dest="$OUT/chain-$c"
  mkdir -p "$dest"
  cp "$tmp/out/genesis.json" "$dest/genesis.json"

  # Key dirs are named by validator address; sort so validatorN numbering
  # is deterministic (validatorN is sorted by address, not extraData order).
  i=1
  for keydir in $(find "$tmp/out/keys" -mindepth 1 -maxdepth 1 -type d | sort); do
    vdir="$dest/validator$i"
    mkdir -p "$vdir"
    cp "$keydir/key" "$keydir/key.pub" "$vdir/"
    basename "$keydir" > "$vdir/address"
    i=$((i + 1))
  done

  enodes=()
  for n in 1 2 3 4; do
    pub="$(sed 's/^0x//' "$dest/validator$n/key.pub")"
    enodes+=("\"enode://${pub}@${SUBNET_PREFIX[$c]}.1${n}:30303\"")
  done
  (IFS=,; echo "[${enodes[*]}]") | jq . > "$dest/static-nodes.json"

  rm -rf "$tmp"
  trap - EXIT
done

echo "==> Done. Wrote networks/"
for c in "${CHAINS[@]}"; do
  echo "chain-$c validators:"; for v in "$OUT/chain-$c"/validator*; do echo "  $(basename "$v"): $(cat "$v/address")"; done
done
