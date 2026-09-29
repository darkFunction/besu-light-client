// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Outbox} from "../src/Outbox.sol";
import {Inbox} from "../src/Inbox.sol";
import {Bridge} from "../src/Bridge.sol";
import {Token} from "../src/Token.sol";

contract Deploy is Script {
    uint256 constant CHAIN_A = 20001;
    uint256 constant CHAIN_B = 20002;

    // Storage instead of locals: keeps run() clear of "stack too deep"
    uint256 forkA;
    uint256 forkB;
    uint256 pk;
    address deployer;
    Outbox outboxA;
    Outbox outboxB;
    Inbox inboxA;
    Inbox inboxB;
    Token tokenA;
    Token tokenB;

    function run() external {
        pk = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(pk);
        forkA = vm.createFork("chain_a");
        forkB = vm.createFork("chain_b");

        // 1. Outboxes
        vm.selectFork(forkA);
        vm.startBroadcast(pk);
        outboxA = new Outbox();
        vm.stopBroadcast();

        vm.selectFork(forkB);
        vm.startBroadcast(pk);
        outboxB = new Outbox();
        vm.stopBroadcast();

        // 2. Inboxes: each verifies the OTHER chain
        vm.selectFork(forkA);
        vm.startBroadcast(pk);
        inboxA = new Inbox(
            vm.envAddress("CHAIN_B_VALIDATORS", ","),
            address(outboxB)
        );
        vm.stopBroadcast();

        vm.selectFork(forkB);
        vm.startBroadcast(pk);
        inboxB = new Inbox(
            vm.envAddress("CHAIN_A_VALIDATORS", ","),
            address(outboxA)
        );
        vm.stopBroadcast();

        // 3. Predict each Bridge's address from the deployer's next nonce on its chain
        vm.selectFork(forkA);
        address predictedA = vm.computeCreateAddress(
            deployer,
            vm.getNonce(deployer)
        );
        vm.selectFork(forkB);
        address predictedB = vm.computeCreateAddress(
            deployer,
            vm.getNonce(deployer)
        );

        // 4. Bridges, each pointing at the other's predicted address
        vm.selectFork(forkA);
        vm.startBroadcast(pk);
        Bridge bridgeA = new Bridge(
            CHAIN_B,
            predictedB,
            address(inboxA),
            outboxA,
            1_000_000e18,
            deployer
        );
        vm.stopBroadcast();
        tokenA = bridgeA.token();

        vm.selectFork(forkB);
        vm.startBroadcast(pk);
        Bridge bridgeB = new Bridge(
            CHAIN_A,
            predictedA,
            address(inboxB),
            outboxB,
            0,
            deployer
        );
        vm.stopBroadcast();
        tokenB = bridgeB.token();

        require(
            address(bridgeA) == predictedA && address(bridgeB) == predictedB,
            "Address prediction failed"
        );

        _writeDeployments(bridgeA, bridgeB);
    }

    function _writeDeployments(Bridge bridgeA, Bridge bridgeB) internal {
        vm.serializeUint("a", "chainId", CHAIN_A);
        vm.serializeAddress("a", "outbox", address(outboxA));
        vm.serializeAddress("a", "inbox", address(inboxA));
        vm.serializeAddress("a", "bridge", address(bridgeA));
        string memory a = vm.serializeAddress("a", "token", address(tokenA));

        vm.serializeUint("b", "chainId", CHAIN_B);
        vm.serializeAddress("b", "outbox", address(outboxB));
        vm.serializeAddress("b", "inbox", address(inboxB));
        vm.serializeAddress("b", "bridge", address(bridgeB));
        string memory b = vm.serializeAddress("b", "token", address(tokenB));

        vm.serializeString("root", "chain_a", a);
        string memory json = vm.serializeString("root", "chain_b", b);

        vm.createDir("./deployments", true);
        vm.writeJson(json, "./deployments/local.json");
    }
}
