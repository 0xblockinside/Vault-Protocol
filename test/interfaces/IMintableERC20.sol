// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

interface IMintableERC20 is IERC20 {
    function decimals() external view returns (uint8);
    function mint(uint amount) external;
}
