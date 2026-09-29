// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import {Vm} from "forge-std/Vm.sol";
import {Inbox, IMessageReceiver} from "../src/Inbox.sol";
import {Outbox} from "../src/Outbox.sol";
import {IOutbox} from "../src/IOutbox.sol";
import {InboxTestBase} from "./utils/InboxTestBase.sol";

contract MockReceiver is IMessageReceiver {
    uint256 public calls;
    uint256 public lastSourceChainId;
    address public lastSender;
    bytes public lastPayload;
    bool public shouldRevert;

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function handleInboxMessage(uint256 sourceChainId, address sender, bytes memory payload) external {
        require(!shouldRevert, "Receiver reverted");
        calls++;
        lastSourceChainId = sourceChainId;
        lastSender = sender;
        lastPayload = payload;
    }
}

/// Outbox emission and Inbox message delivery (receipt proofs)
contract MessagingTest is InboxTestBase {
    uint256 internal constant SOURCE_CHAIN = 20001;
    uint256 internal constant DEST_CHAIN = 20002;
    uint256 internal constant BLOCK = 100;

    Outbox public outbox; // "deployed on the source chain"
    Inbox public inbox;
    MockReceiver public receiver;

    address internal sourceApp = makeAddr("sourceApp");
    bytes internal payload = abi.encode(address(0xCAFE), uint256(42));

    function setUp() public {
        _setUpValidators(4);
        outbox = new Outbox();
        inbox = new Inbox(validatorAddrs, address(outbox));
        receiver = new MockReceiver();
        vm.chainId(DEST_CHAIN);
    }

    // ---------------------------------------------------------------------
    // Outbox
    // ---------------------------------------------------------------------

    function test_Outbox_EmitsEnvelopeStampedWithChainAndSender() public {
        Log memory log = _sendFromSource(DEST_CHAIN, address(receiver), payload);

        assertEq(log.emitter, address(outbox));
        assertEq(log.topics.length, 1);
        assertEq(log.topics[0], IOutbox.Message.selector);

        IOutbox.Envelope memory envelope = abi.decode(log.data, (IOutbox.Envelope));
        assertEq(envelope.sourceChainId, SOURCE_CHAIN);
        assertEq(envelope.sender, sourceApp);
        assertEq(envelope.destinationChainId, DEST_CHAIN);
        assertEq(envelope.target, address(receiver));
        assertEq(envelope.payload, payload);
    }

    // ---------------------------------------------------------------------
    // deliver: happy paths
    // ---------------------------------------------------------------------

    function test_Deliver_CallsReceiverWithEnvelope() public {
        Log memory log = _sendFromSource(DEST_CHAIN, address(receiver), payload);
        (bytes32 root, bytes[] memory proof) = _singleReceiptTrie(_receipt(2, true, _singleLog(log)));
        _submitHeader(inbox, BLOCK, root);

        inbox.deliver(BLOCK, 0, proof, 0);

        assertEq(receiver.calls(), 1);
        assertEq(receiver.lastSourceChainId(), SOURCE_CHAIN);
        assertEq(receiver.lastSender(), sourceApp);
        assertEq(receiver.lastPayload(), payload);
    }

    function test_Deliver_LegacyReceipt() public {
        // Type-0 receipts have no EIP-2718 type byte
        Log memory log = _sendFromSource(DEST_CHAIN, address(receiver), payload);
        (bytes32 root, bytes[] memory proof) = _singleReceiptTrie(_receipt(0, true, _singleLog(log)));
        _submitHeader(inbox, BLOCK, root);

        inbox.deliver(BLOCK, 0, proof, 0);

        assertEq(receiver.calls(), 1);
    }

    function test_Deliver_SecondTransactionInBlock() public {
        // Message is in txIndex 1; txIndex 0 is an unrelated transaction
        Log memory unrelated = Log(address(0xDEAD), _topics1(keccak256("Other()")), "");
        Log memory message = _sendFromSource(DEST_CHAIN, address(receiver), payload);

        (bytes32 root,, bytes[] memory proof1) = _twoReceiptTrie(
            _receipt(2, true, _singleLog(unrelated)), _receipt(2, true, _singleLog(message))
        );
        _submitHeader(inbox, BLOCK, root);

        inbox.deliver(BLOCK, 1, proof1, 0);

        assertEq(receiver.calls(), 1);
        assertEq(receiver.lastSender(), sourceApp);
    }

    function test_Deliver_FirstTransactionInMultiTxBlock() public {
        // txIndex 0 (key 0x80) sits under branch slot 8 when other transactions exist
        Log memory message = _sendFromSource(DEST_CHAIN, address(receiver), payload);
        Log memory unrelated = Log(address(0xDEAD), _topics1(keccak256("Other()")), "");

        (bytes32 root, bytes[] memory proof0,) = _twoReceiptTrie(
            _receipt(2, true, _singleLog(message)), _receipt(2, true, _singleLog(unrelated))
        );
        _submitHeader(inbox, BLOCK, root);

        inbox.deliver(BLOCK, 0, proof0, 0);

        assertEq(receiver.calls(), 1);
    }

    function test_Deliver_SelectsLogByIndex() public {
        // The transaction emitted another log before the Outbox message
        Log[] memory logs = new Log[](2);
        logs[0] = Log(address(0xDEAD), _topics1(keccak256("Transfer(address,address,uint256)")), hex"01");
        logs[1] = _sendFromSource(DEST_CHAIN, address(receiver), payload);

        (bytes32 root, bytes[] memory proof) = _singleReceiptTrie(_receipt(2, true, logs));
        _submitHeader(inbox, BLOCK, root);

        inbox.deliver(BLOCK, 0, proof, 1);

        assertEq(receiver.calls(), 1);
    }

    function test_Deliver_TwoMessagesInSameReceipt() public {
        // Each log is a separate message with its own messageId
        Log[] memory logs = new Log[](2);
        logs[0] = _sendFromSource(DEST_CHAIN, address(receiver), payload);
        logs[1] = _sendFromSource(DEST_CHAIN, address(receiver), hex"beef");

        (bytes32 root, bytes[] memory proof) = _singleReceiptTrie(_receipt(2, true, logs));
        _submitHeader(inbox, BLOCK, root);

        inbox.deliver(BLOCK, 0, proof, 0);
        inbox.deliver(BLOCK, 0, proof, 1);

        assertEq(receiver.calls(), 2);
        assertEq(receiver.lastPayload(), hex"beef");
    }

    function test_Deliver_ReceiverRevertAllowsRetry() public {
        Log memory log = _sendFromSource(DEST_CHAIN, address(receiver), payload);
        (bytes32 root, bytes[] memory proof) = _singleReceiptTrie(_receipt(2, true, _singleLog(log)));
        _submitHeader(inbox, BLOCK, root);

        receiver.setShouldRevert(true);
        vm.expectRevert("Receiver reverted");
        inbox.deliver(BLOCK, 0, proof, 0);

        // The revert rolled back the delivered flag, so the message can be retried
        receiver.setShouldRevert(false);
        inbox.deliver(BLOCK, 0, proof, 0);

        assertEq(receiver.calls(), 1);
    }

    // ---------------------------------------------------------------------
    // deliver: rejections
    // ---------------------------------------------------------------------

    function test_Deliver_RevertsOnReplay() public {
        Log memory log = _sendFromSource(DEST_CHAIN, address(receiver), payload);
        (bytes32 root, bytes[] memory proof) = _singleReceiptTrie(_receipt(2, true, _singleLog(log)));
        _submitHeader(inbox, BLOCK, root);

        inbox.deliver(BLOCK, 0, proof, 0);

        vm.expectRevert("Already delivered");
        inbox.deliver(BLOCK, 0, proof, 0);

        assertEq(receiver.calls(), 1);
    }

    function test_Deliver_RevertsIfHeaderNotSubmitted() public {
        Log memory log = _sendFromSource(DEST_CHAIN, address(receiver), payload);
        (, bytes[] memory proof) = _singleReceiptTrie(_receipt(2, true, _singleLog(log)));

        vm.expectRevert("Header not submitted");
        inbox.deliver(BLOCK, 0, proof, 0);
    }

    function test_Deliver_RevertsOnWrongEmitter() public {
        // An identical Message event, but emitted by some other contract on the source chain
        Log memory log = _sendFromSource(DEST_CHAIN, address(receiver), payload);
        log.emitter = address(0xBAD);
        (bytes32 root, bytes[] memory proof) = _singleReceiptTrie(_receipt(2, true, _singleLog(log)));
        _submitHeader(inbox, BLOCK, root);

        vm.expectRevert();
        inbox.deliver(BLOCK, 0, proof, 0);
    }

    function test_Deliver_RevertsOnWrongTopic() public {
        Log memory log = _sendFromSource(DEST_CHAIN, address(receiver), payload);
        log.topics[0] = keccak256("NotAMessage(bytes)");
        (bytes32 root, bytes[] memory proof) = _singleReceiptTrie(_receipt(2, true, _singleLog(log)));
        _submitHeader(inbox, BLOCK, root);

        vm.expectRevert();
        inbox.deliver(BLOCK, 0, proof, 0);
    }

    function test_Deliver_RevertsOnWrongDestinationChain() public {
        Log memory log = _sendFromSource(99999, address(receiver), payload);
        (bytes32 root, bytes[] memory proof) = _singleReceiptTrie(_receipt(2, true, _singleLog(log)));
        _submitHeader(inbox, BLOCK, root);

        vm.expectRevert();
        inbox.deliver(BLOCK, 0, proof, 0);
    }

    function test_Deliver_RevertsOnFailedTransaction() public {
        Log memory log = _sendFromSource(DEST_CHAIN, address(receiver), payload);
        (bytes32 root, bytes[] memory proof) = _singleReceiptTrie(_receipt(2, false, _singleLog(log)));
        _submitHeader(inbox, BLOCK, root);

        vm.expectRevert("Tx failed");
        inbox.deliver(BLOCK, 0, proof, 0);
    }

    function test_Deliver_RevertsOnTamperedReceipt() public {
        // Proof built for one receipt, root stored for another (e.g. relayer changed the payload)
        Log memory real = _sendFromSource(DEST_CHAIN, address(receiver), payload);
        Log memory forged = _sendFromSource(DEST_CHAIN, address(receiver), hex"deadbeef");

        (bytes32 realRoot,) = _singleReceiptTrie(_receipt(2, true, _singleLog(real)));
        (, bytes[] memory forgedProof) = _singleReceiptTrie(_receipt(2, true, _singleLog(forged)));
        _submitHeader(inbox, BLOCK, realRoot);

        vm.expectRevert();
        inbox.deliver(BLOCK, 0, forgedProof, 0);
    }

    function test_Deliver_RevertsOnWrongTxIndex() public {
        Log memory unrelated = Log(address(0xDEAD), _topics1(keccak256("Other()")), "");
        Log memory message = _sendFromSource(DEST_CHAIN, address(receiver), payload);

        (bytes32 root,, bytes[] memory proof1) = _twoReceiptTrie(
            _receipt(2, true, _singleLog(unrelated)), _receipt(2, true, _singleLog(message))
        );
        _submitHeader(inbox, BLOCK, root);

        // Proof for txIndex 1, claimed as txIndex 0: the path doesn't match the proof nodes
        vm.expectRevert();
        inbox.deliver(BLOCK, 0, proof1, 0);
    }

    function test_Deliver_RevertsOnLogIndexOutOfRange() public {
        Log memory log = _sendFromSource(DEST_CHAIN, address(receiver), payload);
        (bytes32 root, bytes[] memory proof) = _singleReceiptTrie(_receipt(2, true, _singleLog(log)));
        _submitHeader(inbox, BLOCK, root);

        vm.expectRevert();
        inbox.deliver(BLOCK, 0, proof, 1);
    }

    function test_Deliver_RevertsWhenTargetHasNoCode() public {
        Log memory log = _sendFromSource(DEST_CHAIN, address(0x1234), payload);
        (bytes32 root, bytes[] memory proof) = _singleReceiptTrie(_receipt(2, true, _singleLog(log)));
        _submitHeader(inbox, BLOCK, root);

        vm.expectRevert();
        inbox.deliver(BLOCK, 0, proof, 0);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// Sends through the real Outbox as `sourceApp` on the source chain, and returns the emitted log
    function _sendFromSource(uint256 destinationChainId, address target, bytes memory data)
        internal
        returns (Log memory log)
    {
        uint256 previousChainId = block.chainid;
        vm.chainId(SOURCE_CHAIN);

        vm.recordLogs();
        vm.prank(sourceApp);
        outbox.sendMessage(destinationChainId, target, data);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        vm.chainId(previousChainId);

        require(logs.length == 1, "expected one log");
        log = Log(logs[0].emitter, logs[0].topics, logs[0].data);
    }

    function _topics1(bytes32 topic) internal pure returns (bytes32[] memory topics) {
        topics = new bytes32[](1);
        topics[0] = topic;
    }
}
