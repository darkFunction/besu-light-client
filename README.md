# Besu QBFT light client

A trust-minimised bridge between two Hyperledger Besu QBFT chains. The destination chain verifies source-chain block
headers on-chain by checking that ≥2/3 of the known validator set sealed them. Once it trusts a header, it can verify
Merkle proofs of receipts, and therefore event logs, against that header's `receiptsRoot`. The relayer only moves data
between the chains; the contracts verify everything themselves.

## Layout

| Path                                        | What                                                                                |
| ------------------------------------------- | ----------------------------------------------------------------------------------- |
| `docker-compose.yml`, `config/`, `scripts/` | Two local 4-validator QBFT chains                                                   |
| `relayer/`                                  | Rust (alloy): reads source-chain headers and submits them to the destination        |
| `onchain/`                                  | Foundry: `Inbox` (light client and message delivery) and `Outbox` (message emitter) |

## Status

**Relayer**: fetches the latest chain-a header, decodes the QBFT `extraData`
(`[vanity, validators, vote, round, seals]`) and rebuilds the header RLP with an empty seal list, which is the payload
the validators signed. It then splits each seal into `r`, `s` and `v` (`+27` for `ecrecover`), sorts the seals by
recovered signer, and calls `Inbox.postConsensus` on chain-b. It submits one block per run.

**`Inbox`** (destination):

- The validator set is fixed at deployment (there's no rotation yet).
- `postConsensus(header, seals)` recovers the signers from `keccak256(header)` and requires strictly increasing,
  known signers reaching a quorum of `ceil(2n/3)`. It parses `number` and `receiptsRoot` from the same bytes it hashed,
  stores the root and emits `BlockSubmitted`. Headers can be submitted sparsely and in any order, since QBFT blocks
  are final immediately.
- `deliver(blockNumber, txIndex, proof, logIndex)` (in progress) verifies a receipt against the stored root with
  `MerkleTrie.get(rlp(txIndex), proof, root)`, decodes the receipt (removing the EIP-2718 type byte) and reads the
  selected log.

**`Outbox`** (source): `send(destinationChainId, target, payload)` emits a `Message` event stamped with
`block.chainid` and `msg.sender`, so receivers can tell which source contract sent it.

**Tests**: `onchain/test/` uses synthetic headers signed with Foundry keys to cover the quorum threshold,
unsorted, duplicate, unknown and malformed seals, tampered headers and out-of-order submission.

Dependencies: RLP and trie verification come from
[succinctlabs/optimism-bedrock-contracts](https://github.com/succinctlabs/optimism-bedrock-contracts) (a git submodule).

## Running

```sh
scripts/generate.sh                  # genesis and validator keys into networks/ (git-ignored)
docker-compose up -d
scripts/status.sh                    # chainId, head, peers and validator set per node

cd onchain && forge test
cd relayer && cargo run              # relay the latest chain-a header to chain-b
```

To clone: `git clone --recursive`, or run `git submodule update --init` afterwards.

## Networks

|                           | chain-a (source)      | chain-b (destination) |
| ------------------------- | --------------------- | --------------------- |
| chainId                   | 20001                 | 20002                 |
| HTTP RPC (validators 1–4) | `localhost:8545-8548` | `localhost:9545-9548` |
| WS RPC                    | `localhost:8645-8648` | `localhost:9645-9648` |

- Besu `25.8.0`, 2s blocks, London and Shanghai active from genesis, zero gas (`--min-gas-price=0`, `zeroBaseFee`)
- RPC APIs: `ETH,NET,WEB3,QBFT,ADMIN`, bound to 127.0.0.1 only
- Validator selection is header-based, so the validator list lives in `extraData`
- Bonsai storage keeps about 512 blocks of state. Use `--data-storage-format=FOREST` if you need old-block `eth_getProof`
- `docker-compose down` wipes chain data. `stop` and `start` keep it. `generate.sh --force` creates **new** validator keys

Both chains prefund the well-known Besu dev account (local use only):

```
address 0xfe3b557e8fb62b89f4916b721be55ceb828dbd73
key     0x8f2a55949038a9610f50fb23b5883af3b4ecb3c3bb792cbcefbd1542c692be63
```

Transactions need `--legacy --gas-price 0` with `cast`/`forge`.

### Recipes

```sh
# Quorum: 4 validators tolerate 1 fault
docker-compose stop a-validator4                  # chain-a keeps producing
docker-compose stop a-validator3                  # chain-a halts
docker-compose start a-validator3 a-validator4    # resumes after 30–60s (round timers back off)

# Validator rotation: a majority must vote. Repeat on :8546 and :8547,
# then call qbft_discardValidatorVote on each node, or they keep voting
curl -s localhost:8545 -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"qbft_proposeValidatorVote","params":["<address>", false]}'

# Consensus debug logging
curl -s localhost:8545 -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"admin_changeLogLevel","params":["DEBUG",["org.hyperledger.besu.consensus"]]}'
```

SELinux (Fedora): the bind mounts use `:z`, and containers run as the image's `besu` user.
