use alloy::primitives::{Address, B256, Bytes, Signature, keccak256};
use alloy::providers::{Provider, ProviderBuilder, WsConnect};
use alloy::rpc::types::{Filter, TransactionReceipt};
use alloy::signers::local::PrivateKeySigner;
use alloy::sol;
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

    let filter = Filter::new()
        .address(deployments.chain_a.outbox)
        .event_signature(Message::SIGNATURE_HASH);

    let sub = chain_a_provider.subscribe_logs(&filter).await.unwrap();
    let mut stream = sub.into_stream();

    while let Some(log) = stream.next().await {
        let block_number = log.block_number.unwrap();
        let block_header = read_block_header(
            &chain_a_provider,
            Some(alloy::eips::BlockNumberOrTag::Number(block_number)),
        )
        .await;

        let tx_receipt =
            submit_block_header(&chain_b_provider, deployments.chain_b.inbox, block_header).await;
        if tx_receipt.inner.status() {
            println!("Consensus pushed for block {block_number}");
        }
        //println!("{tx_receipt:#?}");

        // TODO:
        // - calculate merkle proof for message and post to inbox of target chain
        // ie, show that the log was inside the receiptRoot we've posted
        // the proof contains the receipt of the log-emitting transaction,
        // which contains the logs of the transaction, which we select with
        // log_index. the log contains the emitter, the topics, and the data which
        // is the abi encoded envelope
    }
}

async fn submit_block_header<P: Provider>(
    provider: &P,
    contract_address: Address,
    submission: HeaderSubmission,
) -> TransactionReceipt {
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

async fn read_block_header<P: Provider>(
    provider: &P,
    block_number: Option<alloy::eips::BlockNumberOrTag>,
) -> HeaderSubmission {
    let block = provider
        .get_block_by_number(block_number.unwrap_or(alloy::eips::BlockNumberOrTag::Latest))
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
