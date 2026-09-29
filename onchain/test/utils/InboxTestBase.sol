// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import {Test} from "forge-std/Test.sol";
import {Inbox} from "../../src/Inbox.sol";

/// Shared helpers: validator keys, RLP encoding, synthetic headers and seals,
/// receipts, and small receipt tries with proofs.
abstract contract InboxTestBase is Test {
    // Validators sorted by address, ascending, with their private keys
    address[] internal validatorAddrs;
    uint256[] internal validatorKeys;

    // Storage slot of `_receiptsRoots` (see `forge inspect Inbox storageLayout`).
    // Only needed until the contract exposes a getter.
    uint256 internal constant RECEIPTS_ROOTS_SLOT = 2;

    struct Log {
        address emitter;
        bytes32[] topics;
        bytes data;
    }

    // ---------------------------------------------------------------------
    // Validators and seals
    // ---------------------------------------------------------------------

    function _setUpValidators(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            (address addr, uint256 key) = makeAddrAndKey(string.concat("validator", vm.toString(i)));
            validatorAddrs.push(addr);
            validatorKeys.push(key);
        }
        _sortValidators();
    }

    function _sortValidators() internal {
        uint256 n = validatorAddrs.length;
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j + 1 < n - i; j++) {
                if (validatorAddrs[j] > validatorAddrs[j + 1]) {
                    (validatorAddrs[j], validatorAddrs[j + 1]) = (validatorAddrs[j + 1], validatorAddrs[j]);
                    (validatorKeys[j], validatorKeys[j + 1]) = (validatorKeys[j + 1], validatorKeys[j]);
                }
            }
        }
    }

    function _sign(uint256 key, bytes32 hash) internal pure returns (Inbox.Seal memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, hash);
        return Inbox.Seal({r: r, s: s, v: v});
    }

    /// Seals from the given validator indices, in the given order
    function _seals(bytes memory header, uint256[] memory idxs) internal view returns (Inbox.Seal[] memory seals) {
        bytes32 hash = keccak256(header);
        seals = new Inbox.Seal[](idxs.length);
        for (uint256 i = 0; i < idxs.length; i++) {
            seals[i] = _sign(validatorKeys[idxs[i]], hash);
        }
    }

    function _indices2(uint256 a, uint256 b) internal pure returns (uint256[] memory idxs) {
        idxs = new uint256[](2);
        (idxs[0], idxs[1]) = (a, b);
    }

    function _indices3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory idxs) {
        idxs = new uint256[](3);
        (idxs[0], idxs[1], idxs[2]) = (a, b, c);
    }

    function _indices4(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256[] memory idxs) {
        idxs = new uint256[](4);
        (idxs[0], idxs[1], idxs[2], idxs[3]) = (a, b, c, d);
    }

    /// Builds a header with the given receipts root and submits it with a quorum of seals
    function _submitHeader(Inbox inbox, uint256 number, bytes32 receiptsRoot) internal {
        bytes memory header = _header(number, receiptsRoot);
        inbox.postConsensus(header, _seals(header, _indices3(0, 1, 2)));
    }

    function _storedReceiptsRoot(Inbox inbox, uint256 number) internal view returns (bytes32) {
        bytes32 slot = keccak256(abi.encode(number, RECEIPTS_ROOTS_SLOT));
        return vm.load(address(inbox), slot);
    }

    // ---------------------------------------------------------------------
    // Headers
    // ---------------------------------------------------------------------

    /// A synthetic stripped header with the standard 13 pre-London fields
    function _header(uint256 number, bytes32 receiptsRoot) internal pure returns (bytes memory) {
        bytes[] memory f = new bytes[](13);
        f[0] = _rlpBytes(abi.encodePacked(keccak256("parent")));            // parentHash
        f[1] = _rlpBytes(abi.encodePacked(keccak256(hex"c0")));             // ommersHash
        f[2] = _rlpBytes(abi.encodePacked(address(0xBEEF)));                // beneficiary
        f[3] = _rlpBytes(abi.encodePacked(keccak256("state")));             // stateRoot
        f[4] = _rlpBytes(abi.encodePacked(keccak256("txs")));               // transactionsRoot
        f[5] = _rlpBytes(abi.encodePacked(receiptsRoot));                   // receiptsRoot
        f[6] = _rlpBytes(new bytes(256));                                   // logsBloom
        f[7] = _rlpUint(1);                                                 // difficulty
        f[8] = _rlpUint(number);                                            // number
        f[9] = _rlpUint(30_000_000);                                        // gasLimit
        f[10] = _rlpUint(0);                                                // gasUsed
        f[11] = _rlpUint(1_700_000_000);                                    // timestamp
        f[12] = _rlpBytes(abi.encodePacked(bytes32(0), hex"c0", hex"c0"));  // extraData
        return _rlpList(f);
    }

    // ---------------------------------------------------------------------
    // Receipts
    // ---------------------------------------------------------------------

    /// EIP-2718 receipt: `txType || rlp([status, cumulativeGasUsed, logsBloom, logs])`, or no prefix for legacy (type 0)
    function _receipt(uint8 txType, bool success, Log[] memory logs) internal pure returns (bytes memory) {
        bytes[] memory encodedLogs = new bytes[](logs.length);
        for (uint256 i = 0; i < logs.length; i++) {
            encodedLogs[i] = _encodeLog(logs[i]);
        }

        bytes[] memory fields = new bytes[](4);
        fields[0] = _rlpUint(success ? 1 : 0);
        fields[1] = _rlpUint(21_000);
        fields[2] = _rlpBytes(new bytes(256));
        fields[3] = _rlpList(encodedLogs);

        bytes memory body = _rlpList(fields);
        return txType == 0 ? body : bytes.concat(bytes1(txType), body);
    }

    function _encodeLog(Log memory log) internal pure returns (bytes memory) {
        bytes[] memory topics = new bytes[](log.topics.length);
        for (uint256 i = 0; i < log.topics.length; i++) {
            topics[i] = _rlpBytes(abi.encodePacked(log.topics[i]));
        }

        bytes[] memory fields = new bytes[](3);
        fields[0] = _rlpBytes(abi.encodePacked(log.emitter));
        fields[1] = _rlpList(topics);
        fields[2] = _rlpBytes(log.data);
        return _rlpList(fields);
    }

    function _singleLog(Log memory log) internal pure returns (Log[] memory logs) {
        logs = new Log[](1);
        logs[0] = log;
    }

    // ---------------------------------------------------------------------
    // Receipt tries
    // ---------------------------------------------------------------------

    /// Trie with one receipt at txIndex 0 (key rlp(0) = 0x80): a single leaf node
    function _singleReceiptTrie(bytes memory receipt)
        internal
        pure
        returns (bytes32 root, bytes[] memory proof)
    {
        // Leaf path 0x2080: even-length leaf flag (0x20), then the nibbles 8,0
        bytes memory leaf = _leaf(hex"2080", receipt);
        root = keccak256(leaf);
        proof = new bytes[](1);
        proof[0] = leaf;
    }

    /// Trie with receipts at txIndex 0 (key 0x80) and txIndex 1 (key 0x01):
    /// a branch node with children at nibbles 8 and 0, each an odd-length leaf holding the remaining nibble.
    function _twoReceiptTrie(bytes memory receipt0, bytes memory receipt1)
        internal
        pure
        returns (bytes32 root, bytes[] memory proof0, bytes[] memory proof1)
    {
        bytes memory leaf0 = _leaf(hex"30", receipt0); // remaining nibble 0 under branch slot 8
        bytes memory leaf1 = _leaf(hex"31", receipt1); // remaining nibble 1 under branch slot 0

        bytes[] memory slots = new bytes[](17);
        for (uint256 i = 0; i < 17; i++) {
            slots[i] = _rlpBytes("");
        }
        slots[0] = _rlpBytes(abi.encodePacked(keccak256(leaf1)));
        slots[8] = _rlpBytes(abi.encodePacked(keccak256(leaf0)));
        bytes memory branch = _rlpList(slots);

        root = keccak256(branch);

        proof0 = new bytes[](2);
        (proof0[0], proof0[1]) = (branch, leaf0);
        proof1 = new bytes[](2);
        (proof1[0], proof1[1]) = (branch, leaf1);
    }

    function _leaf(bytes memory path, bytes memory value) internal pure returns (bytes memory) {
        bytes[] memory fields = new bytes[](2);
        fields[0] = _rlpBytes(path);
        fields[1] = _rlpBytes(value);
        return _rlpList(fields);
    }

    // ---------------------------------------------------------------------
    // RLP
    // ---------------------------------------------------------------------

    function _rlpBytes(bytes memory b) internal pure returns (bytes memory) {
        if (b.length == 1 && uint8(b[0]) < 0x80) return b;
        return bytes.concat(_rlpLength(b.length, 0x80), b);
    }

    function _rlpUint(uint256 x) internal pure returns (bytes memory) {
        return _rlpBytes(_minimalBytes(x));
    }

    function _rlpList(bytes[] memory items) internal pure returns (bytes memory) {
        bytes memory payload;
        for (uint256 i = 0; i < items.length; i++) {
            payload = bytes.concat(payload, items[i]);
        }
        return bytes.concat(_rlpLength(payload.length, 0xc0), payload);
    }

    function _rlpLength(uint256 len, uint256 offset) internal pure returns (bytes memory) {
        if (len < 56) return abi.encodePacked(uint8(offset + len));
        bytes memory lenBytes = _minimalBytes(len);
        return bytes.concat(abi.encodePacked(uint8(offset + 55 + lenBytes.length)), lenBytes);
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
