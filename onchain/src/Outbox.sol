// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;
import "./IOutbox.sol";

contract Outbox is IOutbox {
    function send(
        uint256 destinationChainId,
        address target,
        bytes calldata payload
    ) public {
        emit Message(
            Envelope(
                block.chainid,
                msg.sender,
                destinationChainId,
                target,
                payload
            )
        );
    }
}
