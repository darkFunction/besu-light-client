// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

interface IOutbox {
    struct Envelope {
        uint256 sourceChainId;
        address sender;
        uint256 destinationChainId;
        address target;
        bytes payload;
    }
    event Message(Envelope envelope);

    function sendMessage(
        uint256 destinationChainId,
        address target,
        bytes calldata payload
    ) external;
}
