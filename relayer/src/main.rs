mod solidity_types;
use crate::solidity_types::LightClient::LightClientInstance;
use crate::solidity_types::{LightClient, Message};
use alloy::consensus::{Block, BlockHeader};
use alloy::eips::BlockNumberOrTag;
use alloy::eips::eip2718::Encodable2718;
use alloy::primitives::{Address, B256, Bytes, Signature, U256, keccak256};
use alloy::providers::{Provider, ProviderBuilder, WsConnect};
use alloy::rpc::types::{Filter, TransactionReceipt};
use alloy::signers::local::PrivateKeySigner;
use alloy::sol_types::SolEvent;
use alloy::trie::{HashBuilder, Nibbles, proof::ProofRetainer, root::adjust_index_for_rlp};
use alloy_rlp::{RlpDecodable, RlpEncodable};
use futures::StreamExt;
use serde::Deserialize;
use serde_json;
use std::fs;

#[derive(Debug, Clone, RlpEncodable, RlpDecodable)]
struct QbftExtraData {
    vanity: B256,
    validators: Vec<Address>,
    vote: Vec<Bytes>,
    round: u32,
    seals: Vec<Bytes>,
}

#[derive(Debug, Deserialize)]
struct Deployments {
    chain_a: Chain,
    chain_b: Chain,
}

#[derive(Debug, Deserialize)]
struct Chain {
    #[serde(rename = "chainId")]
    chain_id: u64,
    inbox: Address,
    outbox: Address,
    bridge: Address,
    token: Address,
}

struct HeaderSubmission {
    header_rlp: Vec<u8>,
    seals: Vec<LightClient::Seal>,
}

const CHAIN_A_WS: &str = "ws://127.0.0.1:8645";
const CHAIN_B_WS: &str = "ws://127.0.0.1:9645";
const PRIVATE_KEY: &str = "8f2a55949038a9610f50fb23b5883af3b4ecb3c3bb792cbcefbd1542c692be63"; // Well-known Besu test key, do not use in production
const DEPLOYMENTS_FILE: &str = "../onchain/deployments/local.json";

#[tokio::main]
async fn main() {
    let contents = fs::read_to_string(DEPLOYMENTS_FILE).expect("Couldn't read deployments config");
    let deployments: Deployments = serde_json::from_str(&contents).unwrap();

    let chain_a_provider = ProviderBuilder::new()
        .connect_ws(WsConnect::new(CHAIN_A_WS))
        .await
        .unwrap();

    let signer: PrivateKeySigner = PRIVATE_KEY.parse().unwrap();
    let chain_b_provider = ProviderBuilder::new()
        .wallet(signer)
        .connect_ws(WsConnect::new(CHAIN_B_WS))
        .await
        .unwrap();

    let client = LightClient::new(deployments.chain_a.inbox, &chain_b_provider);

    let filter = Filter::new()
        .address(deployments.chain_a.outbox)
        .event_signature(Message::SIGNATURE_HASH);

    let sub = chain_a_provider.subscribe_logs(&filter).await.unwrap();
    let mut stream = sub.into_stream();

    while let Some(log) = stream.next().await {
        let block_number = log.block_number.unwrap();

        let block = chain_a_provider
            .get_block_by_number(block_number.into())
            .await
            .unwrap()
            .unwrap();

        let block_header = read_block_header(
            &block.header,
            &chain_a_provider,
            Some(alloy::eips::BlockNumberOrTag::Number(block_number)),
        )
        .await;

        let tx_receipt = submit_block_header(&client, block_header).await;
        if tx_receipt.inner.status() {
            println!("Consensus pushed for block {block_number}");
        }

        let block_log_index = log.log_index.unwrap();
        let tx_index = log.transaction_index.unwrap() as usize;

        let receipts = chain_a_provider
            .get_block_receipts(block_number.into())
            .await
            .unwrap()
            .unwrap();

        let (proof, log_index) = receipt_proof(
            &receipts,
            block.header.receipts_root,
            tx_index,
            block_log_index,
        );

        let deliver_receipt = deliver_message(&client, block_number, tx_index, proof, log_index);
        match tx_receipt.inner.status() {
            true => println!("Submitted outbox msg to inbox!"),
            false => println!("Submission failed"),
        }
    }
}

async fn deliver_message<P: Provider>(
    client: &LightClientInstance<P>,
    block_number: u64,
    tx_index: usize,
    proof: Vec<Bytes>,
    log_index: u64,
) -> TransactionReceipt {
    client
        .deliver(
            U256::from(block_number),
            U256::from(tx_index),
            proof,
            U256::from(log_index),
        )
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap()
}

async fn submit_block_header<P: Provider>(
    client: &LightClientInstance<P>,
    submission: HeaderSubmission,
) -> TransactionReceipt {
    client
        .postConsensus(submission.header_rlp.into(), submission.seals)
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap()
}

async fn read_block_header<P: Provider>(
    header: &alloy::rpc::types::Header,
    provider: &P,
    block_number: Option<alloy::eips::BlockNumberOrTag>,
) -> HeaderSubmission {
    let extra: QbftExtraData = alloy::rlp::decode_exact(&header.extra_data).unwrap();

    let mut stripped_extra = extra.clone();
    stripped_extra.seals.clear();
    let encoded_stripped_extra = alloy_rlp::encode(stripped_extra);

    let mut stripped_header = header.inner.clone();
    stripped_header.extra_data = encoded_stripped_extra.into();
    let encoded_stripped_header = alloy::rlp::encode(stripped_header);

    let mut seals: Vec<(Address, LightClient::Seal)> = extra
        .seals
        .iter()
        .map(|seal| {
            let signer = Signature::from_raw(seal)
                .unwrap()
                .recover_address_from_prehash(&keccak256(&encoded_stripped_header))
                .unwrap();
            let seal = LightClient::Seal {
                r: B256::from_slice(&seal[0..32]),
                s: B256::from_slice(&seal[32..64]),
                v: seal[64] + 27, // + 27 because ecrecover expects 27 or 28 (evm precompile) for historical
                                  // reasons, and Besu headers report 1/0 for v
            };
            (signer, seal)
        })
        .collect();

    seals.sort_by_key(|(signer, _)| *signer);
    let ordered_seals = seals.into_iter().map(|(_, seal)| seal).collect();

    return HeaderSubmission {
        header_rlp: encoded_stripped_header,
        seals: ordered_seals,
    };
}

/// Builds the receipts trie of a block and returns the Merkle proof for the receipt at `tx_index`,
/// plus the position of `block_log_index` within that receipt's own log list.
/// Panics if the rebuilt root doesn't match the header's `receiptsRoot`.
fn receipt_proof(
    receipts: &[TransactionReceipt],
    receipts_root: B256,
    tx_index: usize,
    block_log_index: u64,
) -> (Vec<Bytes>, u64) {
    // The trie values: EIP-2718 encoding of each receipt (type byte + rlp for typed receipts)
    let encoded: Vec<Vec<u8>> = receipts
        .iter()
        .map(|r| r.inner.clone().map_logs(|l| l.inner).encoded_2718())
        .collect();

    // The trie keys: rlp(index). Leaves must be inserted in sorted key order, which is
    // what adjust_index_for_rlp gives us (same as alloy's ordered_trie_root)
    let key = |index: usize| Nibbles::unpack(alloy_rlp::encode_fixed_size(&index));
    let target = key(tx_index);

    let mut hb =
        HashBuilder::default().with_proof_retainer(ProofRetainer::new(vec![target.clone()]));
    for i in 0..encoded.len() {
        let index = adjust_index_for_rlp(i, encoded.len());
        hb.add_leaf(key(index), &encoded[index]);
    }

    let root = hb.root();
    assert_eq!(
        root, receipts_root,
        "rebuilt receipts trie doesn't match header"
    );

    let proof: Vec<Bytes> = hb
        .take_proof_nodes()
        .matching_nodes_sorted(&target)
        .into_iter()
        .map(|(_, node)| node)
        .collect();

    // RPC log_index is block-wide; the contract needs the position within the receipt
    let first_in_receipt = receipts[tx_index]
        .inner
        .logs()
        .first()
        .and_then(|l| l.log_index)
        .expect("receipt has no logs");

    (proof, block_log_index - first_in_receipt)
}
