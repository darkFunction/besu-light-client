// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Inbox} from "../src/Inbox.sol";

contract InboxTest is Test {
    Inbox public client;

    // Validators sorted by address, ascending, with their private keys
    address[] internal validatorAddrs;
    uint256[] internal validatorKeys;

    // Storage slot of `_receiptsRoots` (see `forge inspect Inbox storageLayout`).
    // Only needed until the contract exposes a getter.
    uint256 internal constant RECEIPTS_ROOTS_SLOT = 2;

    function setUp() public {
        for (uint256 i = 0; i < 4; i++) {
            (address addr, uint256 key) = makeAddrAndKey(
                string.concat("validator", vm.toString(i))
            );
            validatorAddrs.push(addr);
            validatorKeys.push(key);
        }
        _sortValidators();
        client = new Inbox(validatorAddrs);
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    function test_Constructor_StoresValidators() public view {
        for (uint256 i = 0; i < validatorAddrs.length; i++) {
            assertEq(client.validators(i), validatorAddrs[i]);
        }
    }

    function test_Constructor_RevertsOnEmptySet() public {
        address[] memory none = new address[](0);
        vm.expectRevert();
        new Inbox(none);
    }

    function test_Constructor_RevertsOnZeroAddress() public {
        address[] memory vals = new address[](2);
        vals[0] = address(0xA);
        vals[1] = address(0);
        vm.expectRevert();
        new Inbox(vals);
    }

    function test_Constructor_RevertsOnDuplicate() public {
        address[] memory vals = new address[](2);
        vals[0] = address(0xA);
        vals[1] = address(0xA);
        vm.expectRevert();
        new Inbox(vals);
    }

    // ---------------------------------------------------------------------
    // postConsensus: happy paths
    // ---------------------------------------------------------------------

    function test_AcceptsExactQuorum() public {
        // 4 validators -> quorum is 3
        bytes32 receiptsRoot = keccak256("receipts-100");
        bytes memory header = _header(100, receiptsRoot);

        client.postConsensus(header, _seals(header, _indices3(0, 1, 2)));

        assertEq(_storedReceiptsRoot(100), receiptsRoot);
    }

    function test_AcceptsAllValidators() public {
        bytes32 receiptsRoot = keccak256("receipts-100");
        bytes memory header = _header(100, receiptsRoot);

        client.postConsensus(header, _seals(header, _indices4(0, 1, 2, 3)));

        assertEq(_storedReceiptsRoot(100), receiptsRoot);
    }

    function test_AcceptsAnySubsetMeetingQuorum() public {
        // Validator 0 offline: remaining three still reach quorum
        bytes32 receiptsRoot = keccak256("receipts-100");
        bytes memory header = _header(100, receiptsRoot);

        client.postConsensus(header, _seals(header, _indices3(1, 2, 3)));

        assertEq(_storedReceiptsRoot(100), receiptsRoot);
    }

    function test_AcceptsOutOfOrderBlocks() public {
        bytes32 root105 = keccak256("receipts-105");
        bytes32 root100 = keccak256("receipts-100");
        bytes memory header105 = _header(105, root105);
        bytes memory header100 = _header(100, root100);

        client.postConsensus(header105, _seals(header105, _indices3(0, 1, 2)));
        client.postConsensus(header100, _seals(header100, _indices3(0, 1, 2)));

        assertEq(_storedReceiptsRoot(105), root105);
        assertEq(_storedReceiptsRoot(100), root100);
    }

    function test_StoresLargeBlockNumber() public {
        uint256 number = 123_456_789;
        bytes32 receiptsRoot = keccak256("receipts-big");
        bytes memory header = _header(number, receiptsRoot);

        client.postConsensus(header, _seals(header, _indices3(0, 1, 2)));

        assertEq(_storedReceiptsRoot(number), receiptsRoot);
    }

    // ---------------------------------------------------------------------
    // postConsensus: rejections
    // ---------------------------------------------------------------------

    function test_RevertsBelowQuorum() public {
        bytes memory header = _header(100, keccak256("r"));
        Inbox.Seal[] memory seals = _seals(header, _indices2(0, 1));

        vm.expectRevert("Quorum not reached with known validators");
        client.postConsensus(header, seals);
    }

    function test_RevertsWithNoSeals() public {
        bytes memory header = _header(100, keccak256("r"));
        Inbox.Seal[] memory seals = new Inbox.Seal[](0);

        vm.expectRevert("Quorum not reached with known validators");
        client.postConsensus(header, seals);
    }

    function test_RevertsOnUnsortedSeals() public {
        bytes memory header = _header(100, keccak256("r"));
        Inbox.Seal[] memory seals = _seals(header, _indices3(1, 0, 2));

        vm.expectRevert("Seals not sorted, or duplicate");
        client.postConsensus(header, seals);
    }

    function test_RevertsOnDuplicateSeal() public {
        // Validator 0 seal repeated to try to fake a quorum
        bytes memory header = _header(100, keccak256("r"));
        Inbox.Seal[] memory seals = _seals(header, _indices3(0, 0, 1));

        vm.expectRevert("Seals not sorted, or duplicate");
        client.postConsensus(header, seals);
    }

    function test_RevertsOnNonValidatorSigner() public {
        bytes memory header = _header(100, keccak256("r"));
        (, uint256 outsiderKey) = makeAddrAndKey("outsider");

        Inbox.Seal[] memory seals = new Inbox.Seal[](1);
        seals[0] = _sign(outsiderKey, keccak256(header));

        vm.expectRevert("Not a validator");
        client.postConsensus(header, seals);
    }

    function test_RevertsOnMalformedSignature() public {
        // ecrecover returns address(0) for an invalid signature
        bytes memory header = _header(100, keccak256("r"));
        Inbox.Seal[] memory seals = new Inbox.Seal[](1);
        seals[0] = Inbox.Seal({r: bytes32(0), s: bytes32(0), v: 27});

        vm.expectRevert("Seals not sorted, or duplicate");
        client.postConsensus(header, seals);
    }

    function test_RevertsWhenHeaderTampered() public {
        // Seals are genuine, but for a different header (e.g. relayer swapped the receipts root)
        bytes memory signedHeader = _header(100, keccak256("real"));
        bytes memory forgedHeader = _header(100, keccak256("forged"));
        Inbox.Seal[] memory seals = _seals(signedHeader, _indices3(0, 1, 2));

        // Recovered signers are effectively random: either unsorted or not validators
        vm.expectRevert();
        client.postConsensus(forgedHeader, seals);
    }

    // ---------------------------------------------------------------------
    // Helpers: seals
    // ---------------------------------------------------------------------

    function _sign(
        uint256 key,
        bytes32 hash
    ) internal pure returns (Inbox.Seal memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, hash);
        return Inbox.Seal({r: r, s: s, v: v});
    }

    /// Seals from the given validator indices, in the given order
    function _seals(
        bytes memory header,
        uint256[] memory idxs
    ) internal view returns (Inbox.Seal[] memory seals) {
        bytes32 hash = keccak256(header);
        seals = new Inbox.Seal[](idxs.length);
        for (uint256 i = 0; i < idxs.length; i++) {
            seals[i] = _sign(validatorKeys[idxs[i]], hash);
        }
    }

    function _indices2(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256[] memory idxs) {
        idxs = new uint256[](2);
        (idxs[0], idxs[1]) = (a, b);
    }

    function _indices3(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal pure returns (uint256[] memory idxs) {
        idxs = new uint256[](3);
        (idxs[0], idxs[1], idxs[2]) = (a, b, c);
    }

    function _indices4(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 d
    ) internal pure returns (uint256[] memory idxs) {
        idxs = new uint256[](4);
        (idxs[0], idxs[1], idxs[2], idxs[3]) = (a, b, c, d);
    }

    function _sortValidators() internal {
        uint256 n = validatorAddrs.length;
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j + 1 < n - i; j++) {
                if (validatorAddrs[j] > validatorAddrs[j + 1]) {
                    (validatorAddrs[j], validatorAddrs[j + 1]) = (
                        validatorAddrs[j + 1],
                        validatorAddrs[j]
                    );
                    (validatorKeys[j], validatorKeys[j + 1]) = (
                        validatorKeys[j + 1],
                        validatorKeys[j]
                    );
                }
            }
        }
    }

    function _storedReceiptsRoot(
        uint256 number
    ) internal view returns (bytes32) {
        bytes32 slot = keccak256(abi.encode(number, RECEIPTS_ROOTS_SLOT));
        return vm.load(address(client), slot);
    }

    // ---------------------------------------------------------------------
    // Helpers: header RLP
    // ---------------------------------------------------------------------

    /// A synthetic stripped header with the standard 13 pre-London fields
    function _header(
        uint256 number,
        bytes32 receiptsRoot
    ) internal pure returns (bytes memory) {
        bytes[] memory f = new bytes[](13);
        f[0] = _rlpBytes(abi.encodePacked(keccak256("parent"))); // parentHash
        f[1] = _rlpBytes(abi.encodePacked(keccak256(hex"c0"))); // ommersHash
        f[2] = _rlpBytes(abi.encodePacked(address(0xBEEF))); // beneficiary
        f[3] = _rlpBytes(abi.encodePacked(keccak256("state"))); // stateRoot
        f[4] = _rlpBytes(abi.encodePacked(keccak256("txs"))); // transactionsRoot
        f[5] = _rlpBytes(abi.encodePacked(receiptsRoot)); // receiptsRoot
        f[6] = _rlpBytes(new bytes(256)); // logsBloom
        f[7] = _rlpUint(1); // difficulty
        f[8] = _rlpUint(number); // number
        f[9] = _rlpUint(30_000_000); // gasLimit
        f[10] = _rlpUint(0); // gasUsed
        f[11] = _rlpUint(1_700_000_000); // timestamp
        f[12] = _rlpBytes(abi.encodePacked(bytes32(0), hex"c0", hex"c0")); // extraData
        return _rlpList(f);
    }

    function _rlpBytes(bytes memory b) internal pure returns (bytes memory) {
        if (b.length == 1 && uint8(b[0]) < 0x80) return b;
        return bytes.concat(_rlpLength(b.length, 0x80), b);
    }

    function _rlpUint(uint256 x) internal pure returns (bytes memory) {
        return _rlpBytes(_minimalBytes(x));
    }

    function _rlpList(
        bytes[] memory items
    ) internal pure returns (bytes memory) {
        bytes memory payload;
        for (uint256 i = 0; i < items.length; i++) {
            payload = bytes.concat(payload, items[i]);
        }
        return bytes.concat(_rlpLength(payload.length, 0xc0), payload);
    }

    function _rlpLength(
        uint256 len,
        uint256 offset
    ) internal pure returns (bytes memory) {
        if (len < 56) return abi.encodePacked(uint8(offset + len));
        bytes memory lenBytes = _minimalBytes(len);
        return
            bytes.concat(
                abi.encodePacked(uint8(offset + 55 + lenBytes.length)),
                lenBytes
            );
    }

    /// Big-endian bytes with no leading zeros (zero -> empty)
    function _minimalBytes(uint256 x) internal pure returns (bytes memory out) {
        uint256 n;
        for (uint256 t = x; t > 0; t >>= 8) n++;
        out = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            out[n - 1 - i] = bytes1(uint8(x >> (8 * i)));
        }
    }
}
