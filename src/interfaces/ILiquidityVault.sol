// SPDX-License-Identifier: Business license

pragma solidity ^0.8.26;

import {Permit} from "shared/structs/Permit.sol";

interface ILiquidityVault {
    enum CollectFeeOption {
        TOKEN_0,
        TOKEN_1,
        BOTH
    }

    struct FeeInfo {
        uint160 mintMaxFee;
        uint16 refMintFeeCutBIPS;
        uint16 refCollectFeeCutBIPS;
        uint16 refMintDiscountBIPS;
        uint16 mintMaxDiscountBIPS;
        uint16 procotolCollectMinFeeCutBIPS;
    }

    struct MintParams {
        address tokenA;
        address tokenB;
        Permit permitA;
        Permit permitB;
        uint256 amountA;
        uint256 amountB;
        bool isLPToken;
        uint32 lockDuration;
        uint16 feeLevelBIPS;
        CollectFeeOption collectFeeOption;
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

    struct Fees {
        uint256 ownerFee0;
        uint256 ownerFee1;
        uint256 cut0;
        uint256 cut1;
        uint256 referralCut0;
        uint256 referralCut1;
    }

    function WETH() external pure returns (address);
    // function ETH() external pure returns (address);
    function mintFee(bool isReferred, uint16 feeLevelBIPS) external view returns (uint256, uint256,FeeInfo memory);
    // function unlockTime(uint256 id) external view returns (uint256);

    // API
    function mint(address recipient, address referrer, MintParams calldata params) payable external returns (uint256 id, Snapshot memory snapshot);
    // function mint(MintParams calldata params) payable external returns (uint256 id, Snapshot memory snapshot);
    function increase(uint256 id, IncreaseParams calldata params, Snapshot calldata snapshot) payable external returns (uint256 added0, uint256 added1);
    function collect(uint256 id, Snapshot calldata snapshot) external returns (Fees memory fees);
    function redeem(uint256 id, Snapshot calldata snapshot, bool removeLP) external;
    function extend(uint256 id, uint32 additionalTime, uint16 newFeeLevelBIPS, address oldReferrer, address referrer) payable external;

}

interface ILiquidityVaultReferral is ILiquidityVault {
    function verifySnapshot(uint256 id, Snapshot calldata snapshot) external view returns (uint160 snapshotHash, uint96 referralHash);
    function resetReferralHash(uint256 id, address referrer) external;
}