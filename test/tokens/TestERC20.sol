// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {ERC20} from "solady/src/tokens/ERC20.sol";

contract TestERC20 is ERC20 {
    function name() public pure override returns (string memory) { return "TEST"; }
    function symbol() public pure override returns (string memory) { return "TEST"; }

    constructor() {
        _mint(msg.sender, 1_000_000_000 * 10 ** decimals());
    }

    function mint(uint amount) external {
        _mint(msg.sender, amount);
    }
}