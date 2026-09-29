// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

interface IMessageReceiver {
    function handleInboxMessage(
        uint256 sourceChainId,
        address sender,
        bytes memory payload
    ) external;
}
