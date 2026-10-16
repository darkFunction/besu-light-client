use alloy::sol;

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
        function deliver(
            uint256 blockNumber,
            uint256 txIndex,
            bytes[] calldata proof,
            uint256 logIndex
        ) external;
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
