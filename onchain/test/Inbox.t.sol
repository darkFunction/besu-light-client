// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import {Inbox} from "../src/Inbox.sol";
import {InboxTestBase} from "./utils/InboxTestBase.sol";

/// Light client: constructor and header submission (postConsensus)
contract InboxTest is InboxTestBase {
    event BlockSubmitted(uint256);

    Inbox public inbox;
    address internal constant OUTBOX = address(0x0B0B);

    function setUp() public {
        _setUpValidators(4);
        inbox = new Inbox(validatorAddrs, OUTBOX);
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    function test_Constructor_StoresValidators() public view {
        for (uint256 i = 0; i < validatorAddrs.length; i++) {
            assertEq(inbox.validators(i), validatorAddrs[i]);
        }
    }

    function test_Constructor_StoresOutbox() public view {
        assertEq(inbox.OUTBOX(), OUTBOX);
    }

    function test_GetValidators_ReturnsFullSet() public view {
        address[] memory vals = inbox.getValidators();
        assertEq(vals.length, validatorAddrs.length);
        for (uint256 i = 0; i < vals.length; i++) {
            assertEq(vals[i], validatorAddrs[i]);
        }
    }

    function test_Constructor_RevertsOnEmptySet() public {
        address[] memory none = new address[](0);
        vm.expectRevert();
        new Inbox(none, OUTBOX);
    }

    function test_Constructor_RevertsOnZeroOutbox() public {
        vm.expectRevert();
        new Inbox(validatorAddrs, address(0));
    }

    function test_Constructor_RevertsOnZeroAddress() public {
        address[] memory vals = new address[](2);
        vals[0] = address(0xA);
        vals[1] = address(0);
        vm.expectRevert("Invalid validator address");
        new Inbox(vals, OUTBOX);
    }

    function test_Constructor_RevertsOnDuplicate() public {
        address[] memory vals = new address[](2);
        vals[0] = address(0xA);
        vals[1] = address(0xA);
        vm.expectRevert("Duplicate validator");
        new Inbox(vals, OUTBOX);
    }

    // ---------------------------------------------------------------------
    // postConsensus: happy paths
    // ---------------------------------------------------------------------

    function test_AcceptsExactQuorum() public {
        // 4 validators -> quorum is 3
        bytes32 receiptsRoot = keccak256("receipts-100");
        bytes memory header = _header(100, receiptsRoot);

        inbox.postConsensus(header, _seals(header, _indices3(0, 1, 2)));

        assertEq(_storedReceiptsRoot(inbox, 100), receiptsRoot);
    }

    function test_AcceptsAllValidators() public {
        bytes32 receiptsRoot = keccak256("receipts-100");
        bytes memory header = _header(100, receiptsRoot);

        inbox.postConsensus(header, _seals(header, _indices4(0, 1, 2, 3)));

        assertEq(_storedReceiptsRoot(inbox, 100), receiptsRoot);
    }

    function test_AcceptsAnySubsetMeetingQuorum() public {
        // Validator 0 offline: remaining three still reach quorum
        bytes32 receiptsRoot = keccak256("receipts-100");
        bytes memory header = _header(100, receiptsRoot);

        inbox.postConsensus(header, _seals(header, _indices3(1, 2, 3)));

        assertEq(_storedReceiptsRoot(inbox, 100), receiptsRoot);
    }

    function test_AcceptsOutOfOrderBlocks() public {
        bytes32 root105 = keccak256("receipts-105");
        bytes32 root100 = keccak256("receipts-100");

        _submitHeader(inbox, 105, root105);
        _submitHeader(inbox, 100, root100);

        assertEq(_storedReceiptsRoot(inbox, 105), root105);
        assertEq(_storedReceiptsRoot(inbox, 100), root100);
    }

    function test_StoresLargeBlockNumber() public {
        uint256 number = 123_456_789;
        bytes32 receiptsRoot = keccak256("receipts-big");

        _submitHeader(inbox, number, receiptsRoot);

        assertEq(_storedReceiptsRoot(inbox, number), receiptsRoot);
    }

    function test_EmitsBlockSubmitted() public {
        bytes memory header = _header(100, keccak256("r"));
        Inbox.Seal[] memory seals = _seals(header, _indices3(0, 1, 2));

        vm.expectEmit(address(inbox));
        emit BlockSubmitted(100);
        inbox.postConsensus(header, seals);
    }

    // ---------------------------------------------------------------------
    // postConsensus: rejections
    // ---------------------------------------------------------------------

    function test_RevertsOnResubmittingBlock() public {
        _submitHeader(inbox, 100, keccak256("r"));

        bytes memory header = _header(100, keccak256("r"));
        Inbox.Seal[] memory seals = _seals(header, _indices3(0, 1, 2));

        vm.expectRevert("State already stored");
        inbox.postConsensus(header, seals);
    }

    function test_RevertsBelowQuorum() public {
        bytes memory header = _header(100, keccak256("r"));
        Inbox.Seal[] memory seals = _seals(header, _indices2(0, 1));

        vm.expectRevert("Quorum not reached with known validators");
        inbox.postConsensus(header, seals);
    }

    function test_RevertsWithNoSeals() public {
        bytes memory header = _header(100, keccak256("r"));
        Inbox.Seal[] memory seals = new Inbox.Seal[](0);

        vm.expectRevert("Quorum not reached with known validators");
        inbox.postConsensus(header, seals);
    }

    function test_RevertsOnUnsortedSeals() public {
        bytes memory header = _header(100, keccak256("r"));
        Inbox.Seal[] memory seals = _seals(header, _indices3(1, 0, 2));

        vm.expectRevert("Seals not sorted, or duplicate");
        inbox.postConsensus(header, seals);
    }

    function test_RevertsOnDuplicateSeal() public {
        // Validator 0 seal repeated to try to fake a quorum
        bytes memory header = _header(100, keccak256("r"));
        Inbox.Seal[] memory seals = _seals(header, _indices3(0, 0, 1));

        vm.expectRevert("Seals not sorted, or duplicate");
        inbox.postConsensus(header, seals);
    }

    function test_RevertsOnNonValidatorSigner() public {
        bytes memory header = _header(100, keccak256("r"));
        (, uint256 outsiderKey) = makeAddrAndKey("outsider");

        Inbox.Seal[] memory seals = new Inbox.Seal[](1);
        seals[0] = _sign(outsiderKey, keccak256(header));

        vm.expectRevert("Not a validator");
        inbox.postConsensus(header, seals);
    }

    function test_RevertsOnMalformedSignature() public {
        // ecrecover returns address(0) for an invalid signature
        bytes memory header = _header(100, keccak256("r"));
        Inbox.Seal[] memory seals = new Inbox.Seal[](1);
        seals[0] = Inbox.Seal({r: bytes32(0), s: bytes32(0), v: 27});

        vm.expectRevert("Seals not sorted, or duplicate");
        inbox.postConsensus(header, seals);
    }

    function test_RevertsWhenHeaderTampered() public {
        // Seals are genuine, but for a different header (e.g. relayer swapped the receipts root)
        bytes memory signedHeader = _header(100, keccak256("real"));
        bytes memory forgedHeader = _header(100, keccak256("forged"));
        Inbox.Seal[] memory seals = _seals(signedHeader, _indices3(0, 1, 2));

        // Recovered signers are effectively random: either unsorted or not validators
        vm.expectRevert();
        inbox.postConsensus(forgedHeader, seals);
    }
}
