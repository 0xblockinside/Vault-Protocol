// SPDX-License-Identifier: Business license

pragma solidity ^0.8.26;

import {Permit} from "shared/src/structs/Permit.sol";

interface ILiquidityVault {
    struct MintParams {
        address tokenA;
        address tokenB;
        Permit permitA;
        Permit permitB;
        uint256 amountA;
        uint256 amountB;
        uint32 lockDuration;
    }

    struct Snapshot {
        address token0;
        address token1;
        uint256 amountIn0;
        uint256 amountIn1;
        uint256 liquidity;
    }  

    struct IncreaseParams {
        uint256 additional0;
        uint256 additional1;
        Permit permit0;
        Permit permit1;
    }

    function WETH() external pure returns (address);
    function ETH() external pure returns (address);
    function fees() external view returns (uint256, uint256, uint256);
    function unlockTime(uint256 id) external view returns (uint256);

    // API
    function mint(address recipient, address referrer, MintParams calldata params) payable external returns (uint256 id, Snapshot memory snapshot);
    function mint(MintParams calldata params) payable external returns (uint256 id, Snapshot memory snapshot);
    function increase(uint256 id, IncreaseParams calldata params, Snapshot calldata snapshot) payable external returns (uint256 added0, uint256 added1);
    function collect(uint256 id, Snapshot calldata snapshot) external returns (uint256 collectedFee0, uint256 collectedFee1);
    function redeem(uint256 id, Snapshot calldata snapshot, bool removeLP) external;
    function extend(uint256 id, uint32 additionalTime) external;

}

interface ILiquidityVaultReferral is ILiquidityVault {
    function verifySnapshot(uint256 id, Snapshot calldata snapshot) external view returns (uint160 snapshotHash, uint96 referralHash);
    function resetReferralHash(uint256 id, address referrer) external;
}