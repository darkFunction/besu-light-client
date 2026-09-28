// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;
import {RLPReader} from "optimism-bedrock-contracts/rlp/RLPReader.sol";

contract LightClient {
    event BlockSubmitted(uint);

    struct Seal {
        bytes32 r;
        bytes32 s;
        uint8 v;
    }

    address[] public validators;
    mapping(address => bool) private _isValidator;

    mapping(uint => bytes32) private _receiptsRoots;

    constructor(address[] memory initialValidators) {
        require(initialValidators.length > 0);

        validators = initialValidators;
        for (uint i = 0; i < initialValidators.length; i++) {
            address validator = initialValidators[i];
            require(validator != address(0), "Invalid validator address");
            require(!_isValidator[validator], "Duplicate validator");
            _isValidator[validator] = true;
        }
    }

    function getValidators() external view returns (address[] memory) {
        return validators;
    }

    function postConsensus(
        bytes calldata header,
        Seal[] calldata seals
    ) external {
        // Get the header hash (the data that has been signed)
        bytes32 sealHash = keccak256(header);

        address lastSigner = address(0);
        uint256 count;

        for (uint i = 0; i < seals.length; i++) {
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
        _receiptsRoots[number] = receiptsRoot;

        emit BlockSubmitted(number);
    }
}
