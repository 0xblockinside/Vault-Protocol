// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {ISuccessor} from "../src/interfaces/ISuccessor.sol";

contract MockMigrationContract is ISuccessor {
    function mint(address recipient, bytes memory params) payable external {

    }

    function encodeParams(uint40 unlockTime, bytes memory params) pure external returns (bytes memory) {

    }
}
