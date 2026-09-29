// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

contract Outbox {
    event Message(
        uint256 sourceChainId,
        address sender,
        uint256 destinationChainId,
        address target,
        bytes payload
    );

    function send(
        uint256 destinationChainId,
        address target,
        bytes calldata payload
    ) public {
        emit Message(
            block.chainid,
            msg.sender,
            destinationChainId,
            target,
            payload
        );
    }
}
