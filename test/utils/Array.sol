// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

library Array {
    function find(uint256[] storage arr, uint256 val) internal view returns (uint256) {
        for (uint i = 0; i < arr.length; i++) {
            if (arr[i] == val) return i;
        }
        return type(uint256).max;
    }

    function sortedAdd(uint256[] storage arr, uint256 val, function (uint256, uint256) internal returns (bool) cmp) internal returns (uint256) {
        uint256 i = 0;
        while (i < arr.length && cmp(arr[i], val)) i++;
        arr.push(val);
        for (uint j = arr.length - 1; j > i; j--) arr[j] = arr[j - 1];
        arr[i] = val;
        return i;
    }

    function removeAt(uint256[] storage arr, uint256 idx) internal returns (uint256) {
        uint256 val = arr[idx];
        for (uint i = idx; i < arr.length - 1; i++) arr[i] = arr[i + 1];
        arr.pop();
        return val;
    }

}