// SPDX-License-Identifier: Business license

pragma solidity ^0.8.26;

interface ISuccessor {
    function encodeParams(uint40 unlockTime, bytes memory params) pure external returns (bytes memory);
    function mint(address recipient, bytes memory params) payable external;
}
