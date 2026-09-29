// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "./IMessageReceiver.sol";
import "./Token.sol";
import "./IOutbox.sol";

contract Bridge is IMessageReceiver {
    event MintEvent(address account, uint256 amount);

    uint256 immutable REMOTE_CHAIN_ID;
    address immutable REMOTE_BRIDGE;
    address immutable INBOX;
    IOutbox immutable OUTBOX;

    Token public token;

    constructor(
        uint256 remoteChainId,
        address remoteBridge,
        address inbox,
        IOutbox outbox,
        uint256 initialMintAmount,
        address mintAccount
    ) {
        require(remoteBridge != address(0));
        require(inbox != address(0));
        require(address(outbox) != address(0));

        REMOTE_CHAIN_ID = remoteChainId;
        REMOTE_BRIDGE = remoteBridge;
        INBOX = inbox;
        OUTBOX = outbox;

        token = new Token(
            "DepositToken",
            "GBP",
            initialMintAmount,
            mintAccount,
            address(this)
        );
    }

    function handleInboxMessage(
        uint256 remoteChainId,
        address sender,
        bytes memory payload
    ) external {
        require(msg.sender == INBOX);
        require(sender == REMOTE_BRIDGE);
        require(remoteChainId == REMOTE_CHAIN_ID);

        (address account, uint256 amount) = abi.decode(
            payload,
            (address, uint256)
        );

        // We know that the remote chain burnt an equal amount of tokens, so we issue a mint instruction
        token.bridgeMint(account, amount);

        emit MintEvent(account, amount);
    }

    function teleportTokens(address account, uint256 amount) public {
        // Burn tokens...
        token.bridgeBurn(msg.sender, amount);

        // ... and send to counterparty bridge
        bytes memory payload = abi.encode(account, amount);
        OUTBOX.sendMessage(REMOTE_CHAIN_ID, REMOTE_BRIDGE, payload);
    }
}
