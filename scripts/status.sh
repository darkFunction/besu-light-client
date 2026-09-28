#!/usr/bin/env bash
# Prints chainId, head block, peer count and validator set for every node.
# Nodes that don't answer are shown as DOWN.
set -uo pipefail

rpc() { # rpc <port> <method> [params-json]
  curl -s -m 2 -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":${3:-[]}}" \
    "http://127.0.0.1:$1" | jq -r '.result // empty' 2>/dev/null
}

for chain in a:8545 b:9545; do
  name=${chain%%:*}; base=${chain##*:}
  echo "chain-$name"
  for n in 1 2 3 4; do
    port=$((base + n - 1))
    head=$(rpc "$port" eth_blockNumber)
    if [[ -z "$head" ]]; then
      printf '  validator%s  :%s  DOWN\n' "$n" "$port"; continue
    fi
    printf '  validator%s  :%s  chainId=%d  block=%d  peers=%d\n' "$n" "$port" \
      "$(rpc "$port" eth_chainId)" "$head" "$(rpc "$port" net_peerCount)"
    validators=${validators:-$(rpc "$port" qbft_getValidatorsByBlockNumber '["latest"]' | jq -r 'join(" ")')}
  done
  echo "  validators: ${validators:-?}"
  unset validators
done
