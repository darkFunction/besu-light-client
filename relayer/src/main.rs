use std::collections;

use alloy::network::ReceiptResponse;
use alloy::primitives::{Address, B256, Bytes, Signature, keccak256};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::types::TransactionReceipt;
use alloy::signers::local::PrivateKeySigner;
use alloy::sol;
use alloy::transports::http::reqwest::Url;
use alloy_rlp::{RlpDecodable, RlpEncodable};

#[derive(Debug, Clone, RlpEncodable, RlpDecodable)]
struct QbftExtraData {
    vanity: B256,
    validators: Vec<Address>,
    vote: Vec<Bytes>,
    round: u32,
    seals: Vec<Bytes>,
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

const SOURCE_CHAIN_RPC: &str = "http://localhost:8545";
const TARGET_CHAIN_RPC: &str = "http://localhost:9545";

// Well-known Besu test key, do not use in production
const PRIVATE_KEY: &str = "8f2a55949038a9610f50fb23b5883af3b4ecb3c3bb792cbcefbd1542c692be63";

const TARGET_CONTRACT_ADDRESS: &str = "0xa50a51c09a5c451C52BB714527E1974b686D8e77";

#[tokio::main]
async fn main() {
    let block_data = read_block_data(SOURCE_CHAIN_RPC.parse().unwrap()).await;
    let tx_receipt = submit_block_data(TARGET_CHAIN_RPC.parse().unwrap(), block_data).await;

    println!("{tx_receipt:#?}");
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
                v: seal[64] + 27, // + 27 because ecrecover expects 27 or 28 for historical
                                  // reasons
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
