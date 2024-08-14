// SPDX-License-Identifier: Business license

pragma solidity ^0.8.26;

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {IPayMaster} from "./interfaces/IPayMaster.sol";
import {ILiquidityVaultReferral} from "./interfaces/ILiquidityVault.sol";

/// @notice The Paymaster for LiquidityVault that allows for referrers to collect
///         their fees via a merkle proof
/// @author Blockinside (https://github.com/0xblockinside/LiquidityVault/blob/master/src/PayMaster.sol)
contract LiquidityVaultPayMaster is IPayMaster {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          EVENTS                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    event Claimed(uint256 indexed id);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          ERRORS                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    error NotOwner();
    error LiquidityVaultAlreadySet();
    error LPVaultNotSet();
    error MismatchFeeArrays();
    error FeeProofInvalid();

    struct ClaimParams {
        uint256 id;
        address referrer;
        ILiquidityVaultReferral.Snapshot snapshot; 
        uint256 mintFee;
        uint256[] fee0s;
        uint256[] fee1s;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STORAGE                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    ILiquidityVaultReferral lpVault;
    address immutable _OWNER;

    constructor(address owner) {
        _OWNER = owner;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          EXTERNAL                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    receive() external payable { revert(); }
    fallback() external payable { revert(); }

    function setLiquidityVault(address vault) external {
        /// @dev: only set once
        if (msg.sender != _OWNER) revert NotOwner();
        if (address(lpVault) != address(0)) revert LiquidityVaultAlreadySet();
        lpVault = ILiquidityVaultReferral(vault);
    }

    function OWNER() external view returns (address) { return _OWNER; }

    function payFees(uint256 devFee) external payable {
        if (devFee > 0 && devFee <= msg.value) payable(_OWNER).transfer(devFee);
    }

    function claimReferralFees(ClaimParams[] calldata params) external {
        ILiquidityVaultReferral _lpVault = lpVault; /// @dev Cached for gas savings
        address WETH = _lpVault.WETH();

        if (address(_lpVault) == address(0)) revert LPVaultNotSet();

        // Calculate Proof
        for (uint i; i < params.length; i++) {
            if (params[i].fee0s.length != params[i].fee1s.length) revert MismatchFeeArrays();

            // verify the snapshot
            (, uint96 referralHash) = _lpVault.verifySnapshot(params[i].id, params[i].snapshot);

            uint96 proof = uint96(uint256(keccak256(abi.encodePacked(params[i].referrer, params[i].mintFee))));
            uint256 totalFee0;
            uint256 totalFee1;
            for (uint j; j < params[i].fee0s.length; j++) {
                totalFee0 += params[i].fee0s[j];
                totalFee1 += params[i].fee1s[j];
                proof = uint96(uint256(keccak256(abi.encodePacked(
                    uint96(uint256(keccak256(abi.encodePacked(proof, params[i].fee0s[j])))),
                    params[i].fee1s[j]
                ))));
            }

            if (proof != referralHash) revert FeeProofInvalid();

            // Send Owed Fees Tokens/ETH
            if (params[i].snapshot.token0 == WETH && (totalFee0 + params[i].mintFee) > 0) payable(params[i].referrer).transfer(totalFee0 + params[i].mintFee);
            else if (totalFee0 > 0) SafeTransferLib.safeTransfer(params[i].snapshot.token0, params[i].referrer, totalFee0);
            if (params[i].snapshot.token1 == WETH && (totalFee1 + params[i].mintFee) > 0) payable(params[i].referrer).transfer(totalFee1 + params[i].mintFee);
            else if (totalFee1 > 0) SafeTransferLib.safeTransfer(params[i].snapshot.token1, params[i].referrer, totalFee1);

            // If neither tokens were WETH then we still own the referrer the mint fee in WETH
            if (params[i].snapshot.token0 != WETH && params[i].snapshot.token1 != WETH) payable(params[i].referrer).transfer(params[i].mintFee);
            _lpVault.resetReferralHash(params[i].id, params[i].referrer);

            emit Claimed(params[i].id);
        }
    }
}