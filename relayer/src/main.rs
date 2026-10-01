use alloy::eips::{BlockId, eip2718::Encodable2718};
use alloy::network::ReceiptResponse;
use alloy::primitives::{Address, B256, Bytes, Signature, keccak256};
use alloy::providers::{Provider, ProviderBuilder, WsConnect};
use alloy::rpc::types::{Filter, TransactionReceipt};
use alloy::signers::local::PrivateKeySigner;
use alloy::sol;
use alloy::sol_types::SolEvent;
use alloy::transports::http::reqwest::Url;
use alloy::trie::root::ordered_trie_root_encoded;
use alloy_rlp::{RlpDecodable, RlpEncodable};
use futures::{FutureExt, StreamExt};
use serde::Deserialize;
use serde_json;
use std::collections;
use std::fs;
use std::iter::chain;

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

sol! {
    #[sol(rpc)]
    contract LightClient {
        struct Seal {
            bytes32 r;
            bytes32 s;
            uint8 v;
        }
        function postConsensus(bytes header, Seal[] seals) external;
        function validators(uint256 index) external view returns (address);
    }
}

sol! {
    struct Envelope {
        uint256 sourceChainId;
        address sender;
        uint256 destinationChainId;
        address target;
        bytes payload;
    }
    event Message(Envelope envelope);
}

const SOURCE_CHAIN_RPC: &str = "http://localhost:8545";
const TARGET_CHAIN_RPC: &str = "http://localhost:9545";
const CHAIN_A_WS: &str = "ws://127.0.0.1:8645";
const CHAIN_B_WS: &str = "ws://127.0.0.1:9645";

// Well-known Besu test key, do not use in production
const PRIVATE_KEY: &str = "8f2a55949038a9610f50fb23b5883af3b4ecb3c3bb792cbcefbd1542c692be63";

const TARGET_CONTRACT_ADDRESS: &str = "0xa50a51c09a5c451C52BB714527E1974b686D8e77";
const DEPLOYMENTS_FILE: &str = "../onchain/deployments/local.json";

#[tokio::main]
async fn main() {
    let contents = fs::read_to_string(DEPLOYMENTS_FILE).expect("Couldn't read deployments config");
    let deployments: Deployments = serde_json::from_str(&contents).unwrap();
    println!("{:#?}", deployments.chain_a);

    let chain_a_provider = ProviderBuilder::new()
        .connect_ws(WsConnect::new(CHAIN_A_WS))
        .await
        .unwrap();

    let filter = Filter::new()
        .address(deployments.chain_a.outbox)
        .event_signature(Message::SIGNATURE_HASH);

    let sub = chain_a_provider.subscribe_logs(&filter).await.unwrap();
    let mut stream = sub.into_stream();

    while let Some(log) = stream.next().await {
        println!("{log:#?}")
    }
    // let block_data = read_block_data(SOURCE_CHAIN_RPC.parse().unwrap()).await;
    // let tx_receipt = submit_block_data(TARGET_CHAIN_RPC.parse().unwrap(), block_data).await;

    // println!("{tx_receipt:#?}");

    // TODO:
    // - monitor outboxes on known chains for messages
    // - calculate merkle proofs for messages and post to inbox of target chain
}

async fn submit_block_data(url: Url, submission: HeaderSubmission) -> TransactionReceipt {
    let signer: PrivateKeySigner = PRIVATE_KEY.parse().unwrap();
    let provider = ProviderBuilder::new()
        .wallet(signer)
        .connect_http(TARGET_CHAIN_RPC.parse().unwrap());

    let contract_address = TARGET_CONTRACT_ADDRESS.parse().unwrap();
    let client = LightClient::new(contract_address, &provider);
    client
        .postConsensus(submission.header_rlp.into(), submission.seals)
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap()
}

async fn read_block_data(url: Url) -> HeaderSubmission {
    let provider = ProviderBuilder::new().connect_http(url);

    let block = provider
        .get_block_by_number(alloy::eips::BlockNumberOrTag::Latest)
        .await
        .unwrap();

    let header = block.unwrap().header;
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
