// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Bridge} from "../src/Bridge.sol";
import {Token} from "../src/Token.sol";
import {Inbox} from "../src/Inbox.sol";
import {Outbox} from "../src/Outbox.sol";
import {IOutbox} from "../src/IOutbox.sol";
import {InboxTestBase} from "./utils/InboxTestBase.sol";

/// Two chains simulated in one EVM by switching `block.chainid`:
///   chain A: outboxA, inboxA (verifies chain B), bridgeA, tokenA (holds the initial supply)
///   chain B: outboxB, inboxB (verifies chain A), bridgeB, tokenB
/// For simplicity both inboxes trust the same validator keys.
contract BridgeTest is InboxTestBase {
    event MintEvent(address account, uint256 amount);

    uint256 internal constant CHAIN_A = 20001;
    uint256 internal constant CHAIN_B = 20002;
    uint256 internal constant INITIAL_SUPPLY = 1_000_000e18;
    uint256 internal constant USER_BALANCE = 1_000e18;

    Outbox public outboxA;
    Outbox public outboxB;
    Inbox public inboxA;
    Inbox public inboxB;
    Bridge public bridgeA;
    Bridge public bridgeB;
    Token public tokenA;
    Token public tokenB;

    address internal deployer = makeAddr("deployer");
    address internal user = makeAddr("user");
    address internal recipient = makeAddr("recipient");

    uint256 internal nextBlockNumber = 1000;

    function setUp() public {
        _setUpValidators(4);
        vm.chainId(CHAIN_A);

        outboxA = new Outbox();
        outboxB = new Outbox();
        inboxA = new Inbox(validatorAddrs, address(outboxB));
        inboxB = new Inbox(validatorAddrs, address(outboxA));

        // Each bridge needs the other's address at construction: predict both from this contract's nonce
        uint64 nonce = vm.getNonce(address(this));
        address predictedA = vm.computeCreateAddress(address(this), nonce);
        address predictedB = vm.computeCreateAddress(address(this), nonce + 1);

        bridgeA = new Bridge(CHAIN_B, predictedB, address(inboxA), outboxA, INITIAL_SUPPLY, deployer);
        bridgeB = new Bridge(CHAIN_A, predictedA, address(inboxB), outboxB, 0, deployer);

        tokenA = bridgeA.token();
        tokenB = bridgeB.token();

        vm.prank(deployer);
        tokenA.transfer(user, USER_BALANCE);
    }

    // ---------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------

    function test_Deploy_PredictedAddressesMatch() public view {
        // bridgeA was built with bridgeB's predicted address, and vice versa
        assertEq(address(bridgeA), vm.computeCreateAddress(address(this), vm.getNonce(address(this)) - 2));
        assertEq(address(bridgeB), vm.computeCreateAddress(address(this), vm.getNonce(address(this)) - 1));
    }

    function test_Deploy_InitialSupplyToMintAccount() public view {
        assertEq(tokenA.totalSupply(), INITIAL_SUPPLY);
        assertEq(tokenA.balanceOf(deployer), INITIAL_SUPPLY - USER_BALANCE);
        assertEq(tokenA.balanceOf(address(bridgeA)), 0);
        assertEq(tokenB.totalSupply(), 0);
    }

    function test_Deploy_BridgeIsTokenAuthority() public view {
        assertEq(tokenA.BRIDGE(), address(bridgeA));
        assertEq(tokenB.BRIDGE(), address(bridgeB));
    }

    function test_Deploy_RevertsOnZeroRemoteBridge() public {
        vm.expectRevert();
        new Bridge(CHAIN_B, address(0), address(inboxA), outboxA, 0, deployer);
    }

    function test_Deploy_RevertsOnZeroInbox() public {
        vm.expectRevert();
        new Bridge(CHAIN_B, address(bridgeB), address(0), outboxA, 0, deployer);
    }

    function test_Deploy_RevertsOnZeroOutbox() public {
        vm.expectRevert();
        new Bridge(CHAIN_B, address(bridgeB), address(inboxA), IOutbox(address(0)), 0, deployer);
    }

    // ---------------------------------------------------------------------
    // Token access control
    // ---------------------------------------------------------------------

    function test_Token_OnlyBridgeCanMint() public {
        vm.prank(user);
        vm.expectRevert("Only the bridge can mint tokens");
        tokenA.bridgeMint(user, 1e18);
    }

    function test_Token_OnlyBridgeCanBurn() public {
        vm.prank(user);
        vm.expectRevert("Only the bridge can burn tokens");
        tokenA.bridgeBurn(user, 1e18);
    }

    function test_Token_DeployerCannotMint() public {
        vm.prank(deployer);
        vm.expectRevert("Only the bridge can mint tokens");
        tokenA.bridgeMint(deployer, 1e18);
    }

    // ---------------------------------------------------------------------
    // teleportTokens
    // ---------------------------------------------------------------------

    function test_Teleport_BurnsFromCaller() public {
        vm.prank(user);
        bridgeA.teleportTokens(recipient, 100e18);

        assertEq(tokenA.balanceOf(user), USER_BALANCE - 100e18);
        assertEq(tokenA.totalSupply(), INITIAL_SUPPLY - 100e18);
    }

    function test_Teleport_EmitsMessageToRemoteBridge() public {
        (Log[] memory logs, uint256 messageIndex) = _teleport(bridgeA, CHAIN_A, user, recipient, 100e18);

        Log memory message = logs[messageIndex];
        assertEq(message.emitter, address(outboxA));
        assertEq(message.topics[0], IOutbox.Message.selector);

        IOutbox.Envelope memory envelope = abi.decode(message.data, (IOutbox.Envelope));
        assertEq(envelope.sourceChainId, CHAIN_A);
        assertEq(envelope.sender, address(bridgeA));
        assertEq(envelope.destinationChainId, CHAIN_B);
        assertEq(envelope.target, address(bridgeB));
        assertEq(envelope.payload, abi.encode(recipient, 100e18));
    }

    function test_Teleport_RevertsWithInsufficientBalance() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user, USER_BALANCE, USER_BALANCE + 1)
        );
        bridgeA.teleportTokens(recipient, USER_BALANCE + 1);
    }

    function test_Teleport_CannotBurnSomeoneElsesTokens() public {
        // The recipient argument only chooses who receives on the other chain; the burn is always from the caller
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, attacker, 0, 100e18));
        bridgeA.teleportTokens(user, 100e18);

        assertEq(tokenA.balanceOf(user), USER_BALANCE);
    }

    // ---------------------------------------------------------------------
    // handleInboxMessage
    // ---------------------------------------------------------------------

    function test_Handle_MintsToAccount() public {
        vm.chainId(CHAIN_B);

        vm.expectEmit(address(bridgeB));
        emit MintEvent(recipient, 5e18);

        vm.prank(address(inboxB));
        bridgeB.handleInboxMessage(CHAIN_A, address(bridgeA), abi.encode(recipient, 5e18));

        assertEq(tokenB.balanceOf(recipient), 5e18);
    }

    function test_Handle_RevertsIfNotFromInbox() public {
        vm.prank(user);
        vm.expectRevert("Only transactions from the Inbox contract are allowed.");
        bridgeB.handleInboxMessage(CHAIN_A, address(bridgeA), abi.encode(user, 5e18));
    }

    function test_Handle_RevertsOnUntrustedSender() public {
        vm.prank(address(inboxB));
        vm.expectRevert("Only messages from the remote bridge are allowed.");
        bridgeB.handleInboxMessage(CHAIN_A, makeAddr("impostor"), abi.encode(user, 5e18));
    }

    function test_Handle_RevertsOnWrongSourceChain() public {
        vm.prank(address(inboxB));
        vm.expectRevert("Only message from the remote chain ID are allowed.");
        bridgeB.handleInboxMessage(99999, address(bridgeA), abi.encode(user, 5e18));
    }

    // ---------------------------------------------------------------------
    // End to end: teleport -> Outbox log -> receipt proof -> Inbox.deliver -> mint
    // ---------------------------------------------------------------------

    function test_EndToEnd_AtoB() public {
        _relay(bridgeA, CHAIN_A, inboxB, CHAIN_B, user, recipient, 100e18);

        assertEq(tokenA.balanceOf(user), USER_BALANCE - 100e18);
        assertEq(tokenB.balanceOf(recipient), 100e18);
        assertEq(tokenA.totalSupply() + tokenB.totalSupply(), INITIAL_SUPPLY);
    }

    function test_EndToEnd_RoundTrip() public {
        _relay(bridgeA, CHAIN_A, inboxB, CHAIN_B, user, recipient, 100e18);
        _relay(bridgeB, CHAIN_B, inboxA, CHAIN_A, recipient, user, 40e18);

        assertEq(tokenA.balanceOf(user), USER_BALANCE - 100e18 + 40e18);
        assertEq(tokenB.balanceOf(recipient), 60e18);
        assertEq(tokenA.totalSupply() + tokenB.totalSupply(), INITIAL_SUPPLY);
    }

    function test_EndToEnd_ReplayDoesNotDoubleMint() public {
        (uint256 blockNumber, bytes[] memory proof, uint256 messageIndex) =
            _relay(bridgeA, CHAIN_A, inboxB, CHAIN_B, user, recipient, 100e18);

        vm.expectRevert("Already delivered");
        inboxB.deliver(blockNumber, 0, proof, messageIndex);

        assertEq(tokenB.balanceOf(recipient), 100e18);
    }

    function test_EndToEnd_MessageForOtherChainIsRejected() public {
        // A chain-A message delivered back to chain A's own inbox: wrong emitter (inboxA trusts outboxB)
        (Log[] memory logs, uint256 messageIndex) = _teleport(bridgeA, CHAIN_A, user, recipient, 100e18);
        (bytes32 root, bytes[] memory proof) = _singleReceiptTrie(_receipt(2, true, logs));
        _submitHeader(inboxA, 777, root);

        vm.expectRevert("Event not posted from the outbox");
        inboxA.deliver(777, 0, proof, messageIndex);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// Teleports on `bridge` as `caller` on `chainId`; returns every log the transaction emitted
    /// and the index of the Outbox message among them.
    function _teleport(Bridge bridge, uint256 chainId, address caller, address to, uint256 amount)
        internal
        returns (Log[] memory logs, uint256 messageIndex)
    {
        vm.chainId(chainId);
        vm.recordLogs();
        vm.prank(caller);
        bridge.teleportTokens(to, amount);
        Vm.Log[] memory recorded = vm.getRecordedLogs();

        logs = new Log[](recorded.length);
        bool found;
        for (uint256 i = 0; i < recorded.length; i++) {
            logs[i] = Log(recorded[i].emitter, recorded[i].topics, recorded[i].data);
            if (recorded[i].topics[0] == IOutbox.Message.selector) {
                messageIndex = i;
                found = true;
            }
        }
        require(found, "no Outbox message emitted");
    }

    /// Full relay: teleport on the source chain, then post the header and deliver on the destination
    function _relay(
        Bridge sourceBridge,
        uint256 sourceChain,
        Inbox destInbox,
        uint256 destChain,
        address caller,
        address to,
        uint256 amount
    ) internal returns (uint256 blockNumber, bytes[] memory proof, uint256 messageIndex) {
        Log[] memory logs;
        (logs, messageIndex) = _teleport(sourceBridge, sourceChain, caller, to, amount);

        // The burn's Transfer event comes first, so the message is not at log index 0
        bytes32 root;
        (root, proof) = _singleReceiptTrie(_receipt(2, true, logs));
        blockNumber = nextBlockNumber++;
        _submitHeader(destInbox, blockNumber, root);

        vm.chainId(destChain);
        destInbox.deliver(blockNumber, 0, proof, messageIndex);
    }
}
