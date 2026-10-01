// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import {RLPReader} from "optimism-bedrock-contracts/rlp/RLPReader.sol";
import {RLPWriter} from "optimism-bedrock-contracts/rlp/RLPWriter.sol";
import {MerkleTrie} from "optimism-bedrock-contracts/trie/MerkleTrie.sol";
import {Bytes} from "optimism-bedrock-contracts/Bytes.sol";
import "./IOutbox.sol";
import "./IMessageReceiver.sol";

contract Inbox {
    event BlockSubmitted(uint256);

    struct Seal {
        bytes32 r;
        bytes32 s;
        uint8 v;
    }

    address public immutable OUTBOX;

    address[] public validators;

    mapping(address => bool) private _isValidator;
    mapping(uint256 => bytes32) private _receiptsRoots;
    mapping(bytes32 => bool) private _delivered;

    constructor(address[] memory initialValidators, address outbox) {
        require(initialValidators.length > 0);
        require(outbox != address(0));

        OUTBOX = outbox;

        validators = initialValidators;
        for (uint256 i = 0; i < initialValidators.length; i++) {
            address validator = initialValidators[i];
            require(validator != address(0), "Invalid validator address");
            require(!_isValidator[validator], "Duplicate validator");
            _isValidator[validator] = true;
        }
    }

    function getValidators() external view returns (address[] memory) {
        return validators;
    }

    // TODO: inbox shouldn't really handle light client duties, move to a new contract
    function postConsensus(
        bytes calldata header,
        Seal[] calldata seals
    ) external {
        // Get the header hash (the data that has been signed)
        bytes32 sealHash = keccak256(header);

        address lastSigner = address(0);
        uint256 count;

        for (uint256 i = 0; i < seals.length; i++) {
            Seal calldata seal = seals[i];
            address signer = ecrecover(sealHash, seal.v, seal.r, seal.s);
            require(signer > lastSigner, "Seals not sorted, or duplicate");
            lastSigner = signer;
            require(_isValidator[signer], "Not a validator");
            count++;
        }

        require(
            count >= (validators.length * 2 + 2) / 3,
            "Quorum not reached with known validators"
        );

        // Decode header RLP
        RLPReader.RLPItem memory item = RLPReader.toRLPItem(header);
        RLPReader.RLPItem[] memory fields = RLPReader.readList(item);

        // Store receipts root against block number
        uint256 number = RLPReader.readUint256(fields[8]);
        bytes32 receiptsRoot = RLPReader.readBytes32(fields[5]);

        require(_receiptsRoots[number] == 0, "State already stored");
        _receiptsRoots[number] = receiptsRoot;

        emit BlockSubmitted(number);
    }

    function deliver(
        uint256 blockNumber,
        uint256 txIndex,
        bytes[] calldata proof,
        uint256 logIndex
    ) external {
        bytes32 root = _receiptsRoots[blockNumber];
        require(root != bytes32(0), "Header not submitted");

        // Replay protection
        bytes32 messageId = keccak256(
            abi.encode(blockNumber, txIndex, logIndex)
        );
        require(!_delivered[messageId], "Already delivered");
        _delivered[messageId] = true;

        bytes memory key = RLPWriter.writeUint(txIndex);
        bytes memory receipt = MerkleTrie.get(key, proof, root);

        (
            address emitter,
            bytes32[] memory topics,
            bytes memory data
        ) = _readLog(receipt, logIndex);

        require(emitter == OUTBOX, "Event not posted from the outbox");
        require(
            topics[0] == IOutbox.Message.selector,
            "The event is not a valid outbox message"
        );

        IOutbox.Envelope memory envelope = abi.decode(data, (IOutbox.Envelope));
        require(
            envelope.destinationChainId == block.chainid,
            "Delivered to incorrect destination chain"
        );

        IMessageReceiver(envelope.target).handleInboxMessage(
            envelope.sourceChainId,
            envelope.sender,
            envelope.payload
        );
    }

    function _readLog(
        bytes memory receipt,
        uint256 logIndex
    )
        internal
        pure
        returns (address emitter, bytes32[] memory topics, bytes memory data)
    {
        // Typed receipts start with a type byte (0x01-0x7f); legacy ones start with an RLP list prefix (>= 0xc0)
        if (uint8(receipt[0]) < 0x80) {
            receipt = Bytes.slice(receipt, 1);
        }

        RLPReader.RLPItem[] memory fields = RLPReader.readList(receipt);
        require(RLPReader.readUint256(fields[0]) == 1, "Tx failed");

        RLPReader.RLPItem[] memory logs = RLPReader.readList(fields[3]);
        RLPReader.RLPItem[] memory log = RLPReader.readList(logs[logIndex]);

        emitter = RLPReader.readAddress(log[0]);

        RLPReader.RLPItem[] memory rawTopics = RLPReader.readList(log[1]);
        topics = new bytes32[](rawTopics.length);
        for (uint256 i = 0; i < rawTopics.length; i++) {
            topics[i] = RLPReader.readBytes32(rawTopics[i]);
        }

        data = RLPReader.readBytes(log[2]);
    }
}
