// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {ERC20} from "solady/src/tokens/ERC20.sol";

contract TestTaxedERC20 is ERC20 {
    uint256 public constant BUY_TAX = 5; // 5%
    uint256 public constant SELL_TAX = 10; // 10%

    mapping(address => bool) public isTaxExempt;

    function name() public pure override returns (string memory) { return "TEST"; }
    function symbol() public pure override returns (string memory) { return "TEST"; }

    address constant V2_LIQUIDITY_POOL = address(0x0);
    address constant V3_LIQUIDITY_POOL = address(0x0);

    constructor() {
        isTaxExempt[V2_LIQUIDITY_POOL] = true;
        isTaxExempt[V3_LIQUIDITY_POOL] = true;
        _mint(msg.sender, 1_000_000_000 * 10 ** decimals());
    }

    function mint(uint amount) external {
        _mint(msg.sender, amount);
    }

    function setTaxExemptStatus(address _address, bool _status) public {
        isTaxExempt[_address] = _status;
    }

    function _transfer(address sender, address recipient, uint256 amount) internal override {
        if (isTaxExempt[sender] || isTaxExempt[recipient]) {
            super._transfer(sender, recipient, amount);
        } else {
            uint256 taxAmount = amount * SELL_TAX / 100;
            uint256 amountAfterTax = amount - taxAmount;
            super._transfer(sender, recipient, amountAfterTax);
            super._transfer(sender, address(this), taxAmount);
        }
    }
}