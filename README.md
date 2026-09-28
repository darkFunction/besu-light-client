# Local QBFT test networks

Two independent Hyperledger Besu QBFT chains, 4 validators each, in one `docker-compose.yml`.

| | chain-a | chain-b |
|---|---|---|
| chainId | 20001 | 20002 |
| HTTP RPC (validator1-4) | `localhost:8545-8548` | `localhost:9545-9548` |
| WS RPC (validator1-4) | `localhost:8645-8648` | `localhost:9645-9648` |
| docker subnet | 172.28.1.0/24 | 172.28.2.0/24 |

- Block period 2s (`qbft.blockperiodseconds` in `config/chain-*/qbftConfigFile.json`)
- Zero gas: `--min-gas-price=0` plus `zeroBaseFee: true` in genesis (London+ with baseFee 0)
- RPC APIs: `ETH,NET,WEB3,QBFT,ADMIN` (HTTP and WS). Ports bind to 127.0.0.1 only since ADMIN is exposed.
- Besu `25.8.0` (override with `BESU_IMAGE=...`)

## Usage

```sh
scripts/generate.sh          # genesis + keys via `besu operator generate-blockchain-config`
docker-compose up -d
scripts/status.sh            # chainId / head / peers / validator set per node
docker-compose down          # wipes chain data (keys/genesis in networks/ are kept)
```

`scripts/generate.sh --force` regenerates everything **with new keys** (new validator addresses).

Layout after generation:

```
networks/chain-<x>/genesis.json
networks/chain-<x>/static-nodes.json      # all 4 validators; nodes peer via static nodes, discovery off
networks/chain-<x>/validator<N>/{key,key.pub,address}
```

## Funded account

Both genesis files prefund the well-known Besu dev account (it doesn't strictly need funds with zero gas, but value transfers do):

```
address 0xfe3b557e8fb62b89f4916b721be55ceb828dbd73
key     0x8f2a55949038a9610f50fb23b5883af3b4ecb3c3bb792cbcefbd1542c692be63
```

```sh
cast send --rpc-url http://127.0.0.1:8545 --private-key $KEY --gas-price 0 --legacy <to> --value 1ether
```

## Test recipes

**Quorum** (4 validators, f=1, quorum 3):
```sh
docker-compose stop a-validator4                 # chain-a keeps producing (slower on v4's proposer turns)
docker-compose stop a-validator3                 # chain-a halts
docker-compose start a-validator3 a-validator4   # resumes; can take ~30-60s because round timers back off exponentially while halted
```
Chain data lives in the container layer, so `stop`/`start`/`kill` keep state; `down` wipes it.

**Validator rotation** (majority of current validators must vote):
```sh
curl -s localhost:8545 -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"qbft_proposeValidatorVote","params":["<address>", false]}'
# repeat on :8546 and :8547, then check qbft_getValidatorsByBlockNumber ["latest"]
# afterwards: qbft_discardValidatorVote ["<address>"] on each node, or they keep re-voting
```

**Replay protection**: a tx signed for chain-a submitted to chain-b is rejected with `Wrong chainId`.

**Runtime log level** (via ADMIN API):
```sh
curl -s localhost:8545 -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"admin_changeLogLevel","params":["DEBUG",["org.hyperledger.besu.consensus"]]}'
```

## Notes

- SELinux (Fedora): bind mounts use `:z`; the generator does too.
- Containers run as the image's `besu` user so the root entrypoint doesn't try to chown the read-only key mounts.
- Storage is Besu's default Bonsai, which only keeps recent world state (~512 blocks). If you need `eth_getProof` / state
  queries at old blocks, add `--data-storage-format=FOREST` to the `x-besu` command list.
