// SPDX-License-Identifier: Business license

pragma solidity ^0.8.26;

interface IPayMaster {
    function OWNER() external returns (address);
    function payFees(uint256 devFee) external payable;
}

