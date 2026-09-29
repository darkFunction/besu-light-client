// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Token is ERC20 {
    address public immutable BRIDGE;

    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        address mintAccount,
        address bridge
    ) ERC20(name, symbol) {
        _mint(mintAccount, initialSupply);
        BRIDGE = bridge;
    }

    function bridgeMint(address account, uint256 amount) external {
        require(msg.sender == BRIDGE, "Only the bridge can mint tokens");
        _mint(account, amount);
    }

    function bridgeBurn(address account, uint256 amount) external {
        require(msg.sender == BRIDGE, "Only the bridge can burn tokens");
        _burn(account, amount);
    }
}
