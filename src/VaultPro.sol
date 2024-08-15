// SPDX-License-Identifier: Business license

pragma solidity ^0.8.26;

import {Ownable} from "solady/src/auth/Ownable.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {ERC721Extended} from "shared/tokens/ERC721Extended.sol";
import {Permit} from "shared/structs/Permit.sol";
import {Math} from "openzeppelin/utils/math/Math.sol";

import {IWETH9} from "shared/interfaces/IWETH9.sol";
import {IPermitERC20, IERC20} from "shared/interfaces/IERC20Extended.sol";
import {IUniswapV2Factory} from "v2-core/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "v2-core/interfaces/IUniswapV2Pair.sol";
import {IPayMaster} from "./interfaces/IPayMaster.sol";
import {IVaultPro} from "./interfaces/IVaultPro.sol";
import {Token} from "./MigrationToken.sol";
import {ISuccessor} from "./interfaces/ISuccessor.sol";


/// @notice A Liquidity Locker for Uniswap V2 that allows for fee collection without
///         compromising trading safety.
/// @author Blockinside (https://blockinside.org/)
contract VaultPro is IVaultPro, ERC721Extended, Ownable {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          EVENTS                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    event Minted(
        uint256 indexed id,
        address indexed referrer,
        address token0,
        address token1,
        uint40 lockTime,
        uint16 feeLevelBIPS,
        uint256 snapshotLiquidity,
        uint256 snapshotBalance0,
        uint256 snapshotBalance1,
        bytes referralFee
    );
    event Increased(
        uint256 indexed id, 
        uint256 snapshotLiquidity,
        uint256 snapshotBalance0,
        uint256 snapshotBalance1
    );
    event Collected(
        uint256 indexed id, 
        uint256 ownerFee0,
        uint256 ownerFee1,
        uint256 snapshotLiquidity,
        uint256 snapshotBalance0,
        uint256 snapshotBalance1,
        bytes referralFee0,
        bytes referralFee1
    );
    event Extended(
        uint256 indexed id, 
        uint32 additionalTime,
        uint16 feeLevelBIPS,
        address newReferrer
    );
    event Redeemed(uint256 indexed id);
    event Migrated(uint256 indexed id, address newToken);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CONSTANTS                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    bytes32 constant INIT_CODE_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;
    IUniswapV2Factory constant V2_FACTORY = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant ETH = address(0);
    address constant UNCHANGED_REFERRER = address(type(uint160).max);
    uint32 public constant LOCK_FOREVER = type(uint32).max;
    uint32 constant MIN_LOCK_DURATION = 7 days;
    uint40 constant LOCKED_FOREVER = type(uint40).max;
    uint16 constant BIP_DIVISOR = 10_000;
    IPayMaster immutable payMaster;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          ERRORS                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    error IdenticalTokens();
    error ZeroTokenAmount();
    error InvalidLiquiditySnapshot();
    error NotUnlocked();
    error InsufficientFunds();
    error NotPayMaster();
    error NotRegisteredRefferer();
    error InvalidFee();
    error InvalidFeeLevel();
    error InvalidLiquidityAdditionalAmounts();
    error InsufficientLiquidityBurned();
    error InvalidLockDuration();

    function name() public pure override returns (string memory) { return "Vault Protocol"; }
    function symbol() public pure override returns (string memory) { return "VaultPro"; }

    function tokenURI(uint256 id) public pure override returns (string memory) {
        return "";
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STORAGE                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    uint256 private _idTracker;

    /// Bits Layout of '_feeInfoSlot':
    /// - [0..159]    160 bits   `mintMaxFee`
    /// - [160..175]   16 bits   `refMintFeeCutBIPS`
    /// - [176..191]   16 bits   `refCollectFeeCutBIPS`
    /// - [192..207]   16 bits   `refMintDiscountBIPS`
    /// - [208..223]   16 bits   `mintMaxDiscountBIPS`
    /// - [224..239]   16 bits   `protocolMinCollectFeeCutBIPS`
    uint256 _feeInfoSlot =      0.1 ether | 
                                 0 << 160 |
                             7_333 << 176 |
                             3_000 << 192 |
                            10_000 << 208 |
                             2_667 << 224;

    ISuccessor _successor;

    /// Bits Layout of 'hashInfoForCertificateID.slot':
    /// - [0..159]     160 bits  `snapshotHash: keccak256(abi.encodePacked(token0, token1, snapshotIn0, snapshotIn1, liquidity))`
    /// - [160..256]    96 bits  `referralHash`
    mapping(uint256 => bytes32) hashInfoForCertificateID;

    mapping(address => bool) public registeredReferrers;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     STORAGE HITCHHIKING                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// Bits Layout of 'extraData':
    /// - [0..39]    40 bits   `unlockTime`
    /// - [40..55]   16 bits   `feeLevelBIPS`
    /// - [56..58]    3 bits   `collectFeeOption`
    /// - [59]        1 bits   `ignoreReferrer`

    constructor(IPayMaster pm) {
        payMaster = pm;
        _initializeOwner(msg.sender);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*             SLOT DECODING/ENCODING FUNCTIONS               */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    function _decodeExtraData(uint96 slot) internal pure returns (uint40 unlockTime, uint16 feeLevelBIPS, CollectFeeOption collectFeeOption, bool ignoreReferrer) {
        unlockTime = uint40(slot);
        feeLevelBIPS = uint16(slot >> 40);
        collectFeeOption = CollectFeeOption(uint8((slot >> 56) & 0x7));
        ignoreReferrer = (slot >> 59) & 0x1 == 1;
    }

    function _encodeExtraData(uint40 unlockTime, uint16 feeLevelBIPS, CollectFeeOption collectFeeOption, bool ignoreReferrer) internal pure returns (uint96 extraData) {
        extraData = uint96(unlockTime) | 
                    (uint96(feeLevelBIPS) << 40) | 
                    (uint96(uint8(collectFeeOption) & 0x7) << 56) |
                    (ignoreReferrer ? uint96(1) << 59 : 0);
    }

    function _decodeFeeSlot(uint256 slot) internal pure returns (FeeInfo memory) {
        return FeeInfo({
            mintMaxFee: uint160(slot),
            refMintFeeCutBIPS: uint16(slot >> 160),
            refCollectFeeCutBIPS: uint16(slot >> 176),
            refMintDiscountBIPS: uint16(slot >> 192),
            mintMaxDiscountBIPS: uint16(slot >> 208),
            procotolCollectMinFeeCutBIPS: uint16(slot >> 224)
        });
    }

    function _encodeHashInfo(uint160 snapshotHash, uint96 referralHash) internal pure returns (bytes32) {
        return bytes32((uint256(referralHash) << 160) | uint256(snapshotHash));
    }

    function _decodeHashInfo(bytes32 hashInfo) internal pure returns (uint160 snapshotHash, uint96 referralHash) {
        referralHash = uint96(uint256(hashInfo) >> 160);
        snapshotHash = uint160(uint256(hashInfo));
    }

    function _encodeSnapshotID(Snapshot memory snapshot) pure internal returns (uint160) {
        return uint160(uint256(keccak256(
            abi.encodePacked(
                snapshot.token0,
                snapshot.token1,
                snapshot.balance0,
                snapshot.balance1,
                snapshot.liquidity
            )
        )));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*               HELPER FUNCTIONS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    function _resetReferralHash(uint256 id, address referrer, uint160 snapshotHash) internal {
        hashInfoForCertificateID[id] = _encodeHashInfo(
            snapshotHash,
            uint96(uint256(keccak256(abi.encodePacked(referrer, uint256(0)))))
        );
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*               PAYMENT HELPER FUNCTIONS                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    function _resolveAndPermitIfNecessary(address token, Permit memory permit, uint256 amount) internal returns (address) {
        if (permit.enable && token != WETH) IPermitERC20(token).permit(msg.sender, address(this), amount, permit.deadline, permit.v, permit.r, permit.s);
        return token;
    }

    function _getAndValidateCertificateInfo(uint256 id) internal view returns (uint96 extraData, address owner) {
        (owner, extraData) = _getOwnershipSlot(id);
        if (!_isApprovedOrOwner(msg.sender, id, owner)) revert NotOwnerNorApproved();
        if (owner == address(0)) revert TokenDoesNotExist(); 
    }

    function _getWETHNeeded(address tokenA, address tokenB, uint256 amountA, uint256 amountB) internal pure returns (uint256) {
        if (tokenA == ETH || tokenA == WETH) return amountA;
        if (tokenB == ETH || tokenB == WETH) return amountB;
        return 0;
    }

    function _validateFunds(uint256 fee, uint256 wethNeeded) internal returns (uint256 remainingBal) {
        remainingBal = msg.value;
        if (msg.value < fee) revert InsufficientFunds();
        remainingBal -= fee;

        if (wethNeeded > 0) {
            if (remainingBal < wethNeeded) revert InsufficientFunds();
            IWETH9(WETH).deposit{value: wethNeeded}();
            remainingBal -= wethNeeded;
        }
    }

    function _swapFeesIfNeccessary(address pool, address token0, address token1, bool oneForZero, uint256 cutToSwap, uint256 ownerFeeToSwap) internal returns (uint256 swappedCut, uint256 swappedOwnerFee) {
        uint256 swapIn = cutToSwap + ownerFeeToSwap;
        if (swapIn == 0) return (0, 0);

        (address tokenIn, address tokenOut) = oneForZero ? (token1, token0) : (token0, token1);
        (uint256 r0, uint256 r1, ) = IUniswapV2Pair(pool).getReserves();
        (uint256 rIn, uint256 rOut) = oneForZero ? (r1, r0) : (r0, r1);

        /// @dev we do early transfer then immediately query the balance due to potential tax tokens
        SafeTransferLib.safeTransfer(tokenIn, pool, swapIn);
        uint256 amountIn = IERC20(tokenIn).balanceOf(pool) - rIn;

        /// @dev Inlined from UniswapV2Library
        uint amountInWithFee = amountIn * 997;
        uint numerator = amountInWithFee * rOut;
        uint denominator = rIn * 1000 + amountInWithFee;
        uint amountOut = numerator / denominator;

        /// @dev since out token may be a tax token amountOut may not be correct amount either so we should adjust
        uint256 tokenOutPreBalance = tokenOut != WETH ? IERC20(tokenOut).balanceOf(address(this)) : 0;

        IUniswapV2Pair(pool).swap(oneForZero ? amountOut : 0, oneForZero ? 0 : amountOut, address(this), new bytes(0));

        /// @dev since out token may be a tax token amountOut may not be correct amount either so we should adjust
        if (tokenOut != WETH) amountOut = IERC20(tokenOut).balanceOf(address(this)) - tokenOutPreBalance;

        swappedCut = amountOut * cutToSwap / swapIn;
        swappedOwnerFee = amountOut - swappedCut;
    }

    function _payFeeCut(uint256 refCut, uint256 protocolCut, address token) internal {
        if (refCut + protocolCut == 0) return;
        if (token == WETH) payMaster.payFees{ value: refCut + protocolCut }(protocolCut);
        else {
            if (refCut > 0) SafeTransferLib.safeTransfer(token, address(payMaster), refCut);
            if (protocolCut > 0) SafeTransferLib.safeTransfer(token, payMaster.OWNER(), refCut);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  UNISWAP FUNCTIONS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    function _orderTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function _pairFor(address tokenA, address tokenB) internal pure returns (address pair) {
        (address token0, address token1) = _orderTokens(tokenA, tokenB);
        pair = address(uint160(uint256(keccak256(abi.encodePacked(
            hex'ff',
            address(V2_FACTORY),
            keccak256(abi.encodePacked(token0, token1)),
            INIT_CODE_HASH
        )))));
    }

    function _removeLiquidity(address pool, uint liquidity, address to) internal returns (uint amount0, uint amount1) {
        IUniswapV2Pair pair = IUniswapV2Pair(pool);
        SafeTransferLib.safeTransfer(pool, pool, liquidity);
        (amount0, amount1) = pair.burn(to); 
    }

    /// @dev input assumptions: amounts non zero, token0 & token1 are valid to the pair
    function _addLiquidityV2(address pool, address token0, address token1, uint256 amount0, uint256 amount1, bool transferFrom0, bool transferFrom1) internal returns (uint256 liquidity, uint256 balance0, uint256 balance1, uint256 refundETH) {
        IUniswapV2Pair pair = IUniswapV2Pair(pool);

        (uint256 actualAmount0, uint256 actualAmount1) = (amount0, amount1);
        (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();

        // Quote price only if and the pool has reserves
        if (!(reserve0 == 0 && reserve1 == 0)) {
            (actualAmount0, actualAmount1) = (amount0, amount0 * reserve1 / reserve0);
            if (actualAmount1 == 0 || actualAmount1 > amount1) 
                (actualAmount0, actualAmount1) = (amount1 * reserve0 / reserve1, amount1);
            if (actualAmount0 == 0 || actualAmount1 == 0 || actualAmount0 > amount0 || actualAmount1 > amount1) 
                revert InvalidLiquidityAdditionalAmounts();
        }

        // sent directly from the sender
        if (transferFrom0) SafeTransferLib.safeTransferFrom(token0, msg.sender, pool, actualAmount0);
        if (transferFrom1) SafeTransferLib.safeTransferFrom(token1, msg.sender, pool, actualAmount1);
        // sent from the contract [only used for NATIVE ETH -> WETH] and we should refund
        if (!transferFrom0) {
            SafeTransferLib.safeTransfer(token0, pool, actualAmount0);
            if (token0 == WETH && amount0 > actualAmount0) refundETH = amount0 - actualAmount0;
        }
        if (!transferFrom1) {
            SafeTransferLib.safeTransfer(token1, pool, actualAmount1);
            if (token1 == WETH && amount1 > actualAmount1) refundETH = amount1 - actualAmount1;
        } 

        if (refundETH > 0) IWETH9(WETH).withdraw(refundETH);

        liquidity = pair.mint(address(this));

        // Amount from liquidity
        balance0 = IERC20(token0).balanceOf(pool);
        balance1 = IERC20(token1).balanceOf(pool);
    }


    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  EXTERNAL FUNCTIONS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    
    /// @dev Only allows ETH from entry point functions & WETH.withdraws
    receive() external payable { 
        if (msg.sender != WETH) revert();
    }
    fallback() external payable { 
        if (msg.sender != WETH) revert();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  GETTER FUNCTIONS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    function mintFee(bool isReferred, uint16 feeLevelBIPS) public view returns (uint256 mintFee, uint256 refFeeCut, FeeInfo memory feeInfo) {
        if (feeLevelBIPS > BIP_DIVISOR) revert InvalidFeeLevel();

        feeInfo = _decodeFeeSlot(_feeInfoSlot);
        if (isReferred) {
            mintFee = feeInfo.mintMaxFee - feeInfo.mintMaxFee * feeInfo.refMintDiscountBIPS / BIP_DIVISOR;
            refFeeCut = mintFee * feeInfo.refMintFeeCutBIPS / BIP_DIVISOR;
        }
        else {
            uint256 discount = feeInfo.mintMaxFee * feeInfo.mintMaxDiscountBIPS / BIP_DIVISOR;
            mintFee = feeInfo.mintMaxFee - (discount * uint256(feeLevelBIPS) / BIP_DIVISOR);
        }

    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  SETTER FUNCTIONS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    function setFees(FeeInfo calldata feeInfo) external onlyOwner {
        FeeInfo memory oldFeeInfo = _decodeFeeSlot(_feeInfoSlot);
        if (feeInfo.mintMaxFee > type(uint144).max) revert InvalidFee();
        if (feeInfo.procotolCollectMinFeeCutBIPS > oldFeeInfo.procotolCollectMinFeeCutBIPS) revert InvalidFee();
        if (feeInfo.refMintFeeCutBIPS > BIP_DIVISOR) revert InvalidFee();
        if (feeInfo.refMintDiscountBIPS > BIP_DIVISOR) revert InvalidFee();
        if (feeInfo.refCollectFeeCutBIPS > BIP_DIVISOR) revert InvalidFee();
        if (feeInfo.mintMaxDiscountBIPS > BIP_DIVISOR) revert InvalidFee();
        if (uint256(feeInfo.refCollectFeeCutBIPS) + uint256(feeInfo.procotolCollectMinFeeCutBIPS) > BIP_DIVISOR) revert InvalidFee();

        /// @dev inlined what would have been _encodeFeeSlot for smaller bytecode
        _feeInfoSlot = uint256(uint160(feeInfo.mintMaxFee)) |
           (uint256(feeInfo.refMintFeeCutBIPS) << 160) |
           (uint256(feeInfo.refCollectFeeCutBIPS) << 176) |
           (uint256(feeInfo.refMintDiscountBIPS) << 192) |
           (uint256(feeInfo.mintMaxDiscountBIPS) << 208) |
           (uint256(feeInfo.procotolCollectMinFeeCutBIPS) << 224);

    }

    function setSuccessor(address successor) external onlyOwner {
        _successor = ISuccessor(successor);
    }

    function setReferrer(address referrer, bool value) external onlyOwner {
        registeredReferrers[referrer] = value;
    }

    function setCollectFeeOption(uint256 id, CollectFeeOption feeOption) external {
        (uint96 extraData, address owner) = _getAndValidateCertificateInfo(id);
        (uint40 unlockTime, uint16 feeLeverBIPS, , bool ignoreReferrer) = _decodeExtraData(extraData);

        _setOwnershipSlot(id, owner, _encodeExtraData(unlockTime, feeLeverBIPS, feeOption, ignoreReferrer));
    }


    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    API  FUNCTIONS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    function verifySnapshot(uint256 id, Snapshot calldata snapshot) public view returns (uint160 snapshotHash, uint96 referralHash) {
        (snapshotHash, referralHash) = _decodeHashInfo(hashInfoForCertificateID[id]);
        if (snapshotHash != _encodeSnapshotID(snapshot)) revert InvalidLiquiditySnapshot();
    }

    function resetReferralHash(uint256 id, address referrer) external {
        if (msg.sender != address(payMaster)) revert NotPayMaster();

        (uint160 snapshotHash, ) = _decodeHashInfo(hashInfoForCertificateID[id]);
        _resetReferralHash(id, referrer, snapshotHash);
    }


    /**
     * @notice Launches a uniswap v2 liquidity position that is locked that allows owners to collect swap fees.
     * @notice You can create locked lp by directly locking existing LP tokens or by sending the consit
     * @dev Never transfer ERC20 tokens directly to this contract only native ETH.
     * @dev ERC20 tokens may only be transferred to this contract via permit or approval
     * @param recipient The recipient and owner of the resulting locked liquidity position.
     * @param referrer The recipient and owner of the resulting locked liquidity position.
     * @param params The required arguments within a struct needed to allow permit transfer, structured as follows:
     *        - address tokenA: The address of the first token.
     *        - address tokenB: The address of the second token.
     *        - Permit permitA: A struct containing the permit details for tokenA.
     *        - Permit permitB: A struct containing the permit details for tokenB.
     *        - uint256 amountA: The amount of tokenA to add to the pool.
     *        - uint256 amountB: The amount of tokenB to add to the pool.
     *        - uint256 amountB: The amount of tokenB to add to the pool.
     *        - uint32 lockDuration: The duration for which the liquidity should be locked.
     *        - uint16 feeLevelBIPS: The amount of discount the user choses for their mint fee (BIPS)
     *        - CollectFeeOption collectFeeOption: The amount of discount the user choses for their mint fee (BIPS)
     * @return id The ID of the minted liquidity position.
     * @return snapshot A data structure representing the snapshot of the users liquidity position 
    **/
    function mint(address recipient, address referrer, MintParams calldata params) public payable returns (uint256 id, Snapshot memory snapshot) {
        bool isReferred = referrer != address(0);
        if (isReferred && !registeredReferrers[referrer]) revert NotRegisteredRefferer();

        if (params.lockDuration < MIN_LOCK_DURATION) revert InvalidLockDuration();
        (uint256 mintFee, uint256 refMintFeeCut, ) = mintFee(isReferred, params.feeLevelBIPS);
        uint256 protocolMintFeeCut = mintFee - refMintFeeCut;
        uint96 referrerHash = isReferred ? uint96(uint256(keccak256(abi.encodePacked(referrer, refMintFeeCut)))) : 0;

        uint256 remainingBalance = _validateFunds(mintFee, params.isLPToken ? 0 : _getWETHNeeded(params.tokenA, params.tokenB, params.amountA, params.amountB));
        uint40 unlockTime = params.lockDuration == LOCK_FOREVER || (block.timestamp + params.lockDuration) > type(uint40).max ? LOCKED_FOREVER : uint40(block.timestamp + uint256(params.lockDuration));

        // Pay Fee
        payMaster.payFees{ value: mintFee }(protocolMintFeeCut);

        uint256 refundETH;
        // Token Validation & Address Resolvement
        if (params.isLPToken) {
            _resolveAndPermitIfNecessary(params.tokenA, params.permitA, params.amountA);
            SafeTransferLib.safeTransferFrom(params.tokenA, msg.sender, address(this), params.amountA);

            IUniswapV2Pair pair = IUniswapV2Pair(params.tokenA);
            snapshot.token0 = pair.token0();
            snapshot.token1 = pair.token1();
            uint256 balance0 = IERC20(snapshot.token0).balanceOf(address(pair));
            uint256 balance1 = IERC20(snapshot.token1).balanceOf(address(pair));
            
            snapshot.liquidity = params.amountA;
            snapshot.balance0 = balance0;
            snapshot.balance1 = balance1;
        }
        else {
            if (params.tokenA == params.tokenB) revert IdenticalTokens();
            if (params.tokenA == WETH && params.tokenB == ETH) revert IdenticalTokens();
            if (params.tokenB == WETH && params.tokenA == ETH) revert IdenticalTokens();
            if (params.amountA == 0 || params.amountB == 0) revert ZeroTokenAmount();
            (address tokenA, address tokenB) = (
                (params.tokenA == ETH || params.tokenA == WETH) ? WETH : _resolveAndPermitIfNecessary(params.tokenA, params.permitA, params.amountA),
                (params.tokenB == ETH || params.tokenB == WETH) ? WETH : _resolveAndPermitIfNecessary(params.tokenB, params.permitB, params.amountB)
            );

            (snapshot.token0, snapshot.token1) = _orderTokens(tokenA, tokenB);
            (uint256 desiredAmount0, uint256 desiredAmount1) = snapshot.token0 == tokenA ? (params.amountA, params.amountB) : 
                                                                                           (params.amountB, params.amountA);
            address pool = V2_FACTORY.getPair(tokenA, tokenB);
            pool = pool == address(0) ? V2_FACTORY.createPair(tokenA, tokenB) : pool;

            /// @dev had to be sourced from params since tokenA/B && snapshot.token# are resolved
            (bool isNativeETH0, bool isNativeETH1) = snapshot.token0 == tokenA ? (params.tokenA == ETH, params.tokenB == ETH) : 
                                                                                 (params.tokenB == ETH, params.tokenA == ETH);
            (snapshot.liquidity, snapshot.balance0, snapshot.balance1, refundETH) = _addLiquidityV2(
                pool, 
                snapshot.token0,
                snapshot.token1,
                desiredAmount0, 
                desiredAmount1, 
                !isNativeETH0, 
                !isNativeETH1
            );
        }

        // Refund
        if (remainingBalance + refundETH > 0) payable(msg.sender).transfer(remainingBalance + refundETH);

        hashInfoForCertificateID[_idTracker] = _encodeHashInfo(
            _encodeSnapshotID(snapshot),
            referrerHash
        );

        id = _idTracker;
        emit Transfer(address(0), recipient, _idTracker);
        emit Minted(
            _idTracker, 
            referrer,
            snapshot.token0,
            snapshot.token1,
            params.lockDuration,
            isReferred ? 0 : params.feeLevelBIPS,
            snapshot.liquidity, 
            snapshot.balance0,
            snapshot.balance1,
            isReferred ? abi.encode(uint256(refMintFeeCut)) : bytes("")
        );

        _setOwnershipSlot(_idTracker, recipient, _encodeExtraData(unlockTime, isReferred ? 0 : params.feeLevelBIPS, params.collectFeeOption, false));
        _incrementBalance(recipient, 1);
        _idTracker++;
    }

    /**
     * @notice Collects owed fees from a Uniswap V2 liquidity pool without compromising the security and properties of the lock.
     * @dev Anyone can call this on behalf of a vaulted position, but fees will only be collected by the owner of the position.
     * @param id The ID of the vaulted liquidity position.
     * @param snapshot A struct containing the necessary data to collect fees from a Uniswap V2 liquidity pool:
     *        - address token0: The address of the first token in the liquidity pool.
     *        - address token1: The address of the second token in the liquidity pool.
     *        - uint256 balance0: The amount of the first token in the pool.
     *        - uint256 balance1: The amount of the second token in the pool.
     *        - uint256 liquidity: The lock's liquidity share of the pool.
     * @return fees The amount of fee collected in token0.
    **/
    function collect(uint256 id, Snapshot calldata snapshot) external returns (CollectedFees memory fees) {
        (, uint96 referralHash) = verifySnapshot(id, snapshot);
        (address owner, uint96 extraData) = _getOwnershipSlot(id);
        (, uint256 feeLevelBIPS, CollectFeeOption collectFeeOption, bool ignoreReferrer) = _decodeExtraData(extraData);

        address pool = _pairFor(snapshot.token0, snapshot.token1);
        uint256 balance0 = IERC20(snapshot.token0).balanceOf(pool);
        uint256 balance1 = IERC20(snapshot.token1).balanceOf(pool);
        uint256 totalLiquidity = IERC20(pool).totalSupply();

        /// @dev link to calculation TODO
        uint256 feeLiquidity = totalLiquidity - Math.sqrt(Math.mulDiv(totalLiquidity * totalLiquidity, snapshot.balance0 * snapshot.balance1, balance0 * balance1));
        feeLiquidity = feeLiquidity * snapshot.liquidity / totalLiquidity;

        if (feeLiquidity == 0) revert InsufficientLiquidityBurned();
        (fees.ownerFee0, fees.ownerFee1) = _removeLiquidity(pool, feeLiquidity, address(this));

        balance0 = balance0 - fees.ownerFee0;
        balance1 = balance1 - fees.ownerFee1;

        /// @section Fee Breakdown
        FeeInfo memory feeInfo = _decodeFeeSlot(_feeInfoSlot);

        if (referralHash != 0 && !ignoreReferrer) (fees.cut0, fees.cut1) = (
            fees.ownerFee0 * (feeInfo.refCollectFeeCutBIPS + feeInfo.procotolCollectMinFeeCutBIPS) / BIP_DIVISOR, 
            fees.ownerFee1 * (feeInfo.refCollectFeeCutBIPS + feeInfo.procotolCollectMinFeeCutBIPS) / BIP_DIVISOR);
        else {
            // if feeLevelBIPS max it was max discount, therefore smallest amount of fee and ther fore greatst amount to protcol
            uint256 lowFeeCut0 = fees.ownerFee0 * feeInfo.procotolCollectMinFeeCutBIPS / BIP_DIVISOR;
            uint256 lowFeeCut1 = fees.ownerFee1 * feeInfo.procotolCollectMinFeeCutBIPS / BIP_DIVISOR;

            /// @dev highest userFeeDiscountBIPS == 10_000 (100%) => gives protocol (fee0, fee1)
            ///      lowest  userFeeDiscountBIPS ==      0   (0%) => gives protocol (lowFeeCut0, lowFeeCut1)
            (fees.cut0, fees.cut1) = (
                lowFeeCut0 + (fees.ownerFee0 - lowFeeCut0) * feeLevelBIPS / BIP_DIVISOR,
                lowFeeCut1 + (fees.ownerFee1 - lowFeeCut1) * feeLevelBIPS / BIP_DIVISOR
            );
        }

        fees.ownerFee0 = fees.ownerFee0 - fees.cut0;
        fees.ownerFee1 = fees.ownerFee1 - fees.cut1;

        /// @dev all cut fees will be given in ETH and need to be swapped
        uint256 swapCut0For1 = snapshot.token1 == WETH ? fees.cut0 : 0;
        uint256 swapCut1For0 = snapshot.token0 == WETH ? fees.cut1 : 0;

        uint256 ownerSwap0For1 = collectFeeOption == CollectFeeOption.TOKEN_1 ? fees.ownerFee0 : 0;
        uint256 ownerSwap1For0 = collectFeeOption == CollectFeeOption.TOKEN_0 ? fees.ownerFee1 : 0;


        /// @dev all fee cuts will be taken in SUPPORTED BASE TOKENS whenever possible
        (uint256 swapedCut0, uint256 swapedOwnerFees0) = _swapFeesIfNeccessary(pool, snapshot.token0, snapshot.token1, true, swapCut1For0, ownerSwap1For0);
        (uint256 swapedCut1, uint256 swapedOwnerFees1) = _swapFeesIfNeccessary(pool, snapshot.token0, snapshot.token1, false, swapCut0For1, ownerSwap0For1);
        fees.ownerFee0 = fees.ownerFee0 + swapedOwnerFees0;
        fees.ownerFee0 = fees.ownerFee0 - ownerSwap0For1;
        fees.ownerFee1 = fees.ownerFee1 + swapedOwnerFees1;
        fees.ownerFee1 = fees.ownerFee1 - ownerSwap1For0;
        fees.cut0 = fees.cut0 + swapedCut0;
        fees.cut0 = fees.cut0 - swapCut0For1;
        fees.cut1 = fees.cut1 + swapedCut1;
        fees.cut1 = fees.cut1 - swapCut1For0;

        // Prep: WETH -> ETH
        if (snapshot.token0 == WETH && (fees.ownerFee0 + fees.cut0) > 0) IWETH9(WETH).withdraw(fees.ownerFee0 + fees.cut0);
        if (snapshot.token1 == WETH && (fees.ownerFee1 + fees.cut1) > 0) IWETH9(WETH).withdraw(fees.ownerFee1 + fees.cut1);

        // Payout: owner
        if (fees.ownerFee0 > 0) {
            if (snapshot.token0 == WETH) payable(owner).transfer(fees.ownerFee0);
            else SafeTransferLib.safeTransfer(snapshot.token0, owner, fees.ownerFee0);
        }
        if (fees.ownerFee1 > 1) {
            if (snapshot.token1 == WETH) payable(owner).transfer(fees.ownerFee1);
            else SafeTransferLib.safeTransfer(snapshot.token1, owner, fees.ownerFee1);
        }


        // Update the Payout Merkle root
        if (referralHash != 0 && !ignoreReferrer) {
            if (feeInfo.refCollectFeeCutBIPS > 0) {
                uint16 cutFeeBIPS = feeInfo.refCollectFeeCutBIPS + feeInfo.procotolCollectMinFeeCutBIPS;
                fees.referralCut0 = fees.cut0 * feeInfo.refCollectFeeCutBIPS / cutFeeBIPS;
                fees.referralCut1 = fees.cut1 * feeInfo.refCollectFeeCutBIPS / cutFeeBIPS;
            }
            referralHash = uint96(uint256(keccak256(abi.encodePacked(
                uint96(uint256(keccak256(abi.encodePacked(referralHash, fees.referralCut0)))),
                fees.referralCut1
            ))));
        }
     

        // Payout: referrer or protocol
        _payFeeCut(fees.referralCut0, fees.cut0 - fees.referralCut0, snapshot.token0);
        _payFeeCut(fees.referralCut1, fees.cut1 - fees.referralCut1, snapshot.token1);

        hashInfoForCertificateID[id] = _encodeHashInfo(
            _encodeSnapshotID(Snapshot({
                token0: snapshot.token0,
                token1: snapshot.token1,
                balance0: balance0,
                balance1: balance1,
                liquidity: snapshot.liquidity - feeLiquidity
            })),
            referralHash
        );

        emit Collected(
            id, 
            fees.ownerFee0,
            fees.ownerFee1,
            snapshot.liquidity - feeLiquidity,
            balance0,
            balance1,
            fees.referralCut0 > 0 ? abi.encode(fees.referralCut0) : bytes(""),
            fees.referralCut1 > 0 ? abi.encode(fees.referralCut1) : bytes("")
        );
    }


    /**
     * @notice Redeems a locked liquidity position once its lock time is up.
     * @param id The ID of the liquidity position.
     * @param snapshot The required arguments within a struct needed to allow permit transfer, structured as follows:
     *        - address token0: The address of the first token.
     *        - address token1: The address of the second token.
     *        - uint256 balance0: The amount of the first token in the pool.
     *        - uint256 balance1: The amount of the second token in the pool.
     *        - uint256 liquidity: The lock's liquidity share of the pool.
     * @param removeLP If true, sends underlying tokens of the pool to the owner; if false, liquidity tokens are sent.
    **/
    function redeem(uint256 id, Snapshot calldata snapshot, bool removeLP) external {
        verifySnapshot(id, snapshot);
        (uint96 extraData, address owner) = _getAndValidateCertificateInfo(id);
        (uint40 unlockTime, , ,) = _decodeExtraData(extraData);

        if (unlockTime == LOCKED_FOREVER || block.timestamp <= unlockTime) revert NotUnlocked();

        address pool = _pairFor(snapshot.token0, snapshot.token1);
        if (removeLP) _removeLiquidity(pool, snapshot.liquidity, owner);
        else IERC20(pool).transfer(owner, snapshot.liquidity);

        hashInfoForCertificateID[id] = 0;
        _burn(address(0), id, owner, true);
        emit Redeemed(id);
    }

    /**
     * @notice Extend the lock time of a locked liquidity position.
     * @notice Locks can also change referrer & fee level
     * @param id The id of the liquidity position.
     * @param additionalTime The additional time to extend the lock duration. If set to LOCK_FOREVER, the position will be locked forever.
     * @param newFeeLevelBIPS The new fee level in basis points (BIPS) for the extended lock duration.
     * @param oldReferrer The referrer address before the extension.
     * @param referrer The new referrer address to be set after the extension.
     */
    function extend(uint256 id, uint32 additionalTime, uint16 newFeeLevelBIPS, address oldReferrer, address referrer) payable external {
        if (additionalTime < MIN_LOCK_DURATION) revert InvalidLockDuration();

        (uint96 extraData, ) = _getAndValidateCertificateInfo(id);
        (uint40 unlockTime, uint16 feeLevelBIPS, CollectFeeOption collectFeeOption, bool ignoreReferrer) = _decodeExtraData(extraData);
        if (unlockTime == LOCKED_FOREVER) revert(); /// @dev: already locked forever

        bool simpleExtend = newFeeLevelBIPS > feeLevelBIPS && oldReferrer == address(0) && referrer == address(0);

        if (!simpleExtend && (block.timestamp > uint256(unlockTime) || (unlockTime - block.timestamp) <= (MIN_LOCK_DURATION * 4 / 10))) {
            (uint160 snapshotHash, uint96 referralHash) = _decodeHashInfo(hashInfoForCertificateID[id]);
            bool hadReferrer = referralHash != 0;
            bool wantsReferrer = referrer != address(0);

            if (newFeeLevelBIPS < feeLevelBIPS) {
                FeeInfo memory feeInfo = _decodeFeeSlot(_feeInfoSlot);
                uint256 feeOwed = feeInfo.mintMaxFee * (feeLevelBIPS - newFeeLevelBIPS) / BIP_DIVISOR;
                uint256 refundETH = _validateFunds(feeOwed, 0);

                // Pay Fee
                payMaster.payFees{ value: feeOwed }(feeOwed);

                feeLevelBIPS = newFeeLevelBIPS;
                if (refundETH > 0) payable(msg.sender).transfer(refundETH);
            }
            if (wantsReferrer) {
                if (!registeredReferrers[referrer]) revert NotRegisteredRefferer();
                if (hadReferrer) {
                    uint96 zeroedReferrerHash = uint96(uint256(keccak256(abi.encodePacked(oldReferrer, uint256(0)))));
                    /// @dev: Old referrer account must be zeroed b4 you can extend with new referrer
                    if (referralHash != zeroedReferrerHash) revert();
                }
                _resetReferralHash(id, referrer, snapshotHash);    
                ignoreReferrer = false;
            }

            // need to flag the extradata
            if (hadReferrer && !wantsReferrer) ignoreReferrer = true;
        }
        
        if (additionalTime == LOCK_FOREVER || additionalTime >= (LOCKED_FOREVER - unlockTime)) unlockTime = LOCKED_FOREVER;
        else unlockTime += additionalTime;

        if (block.timestamp >= unlockTime) revert InvalidLockDuration(); /// @dev invalid extend time

        _setExtraData(id, _encodeExtraData(unlockTime, feeLevelBIPS, collectFeeOption, ignoreReferrer));
        emit Extended(
            id, 
            additionalTime, 
            newFeeLevelBIPS, 
            simpleExtend ? UNCHANGED_REFERRER : ignoreReferrer ? address(0) : referrer
        );
    }

    /**
     * @notice Increases the liquidity of an already locked liquidity position
     * @param id The id of the liquidity position
     * @param params The required arguments within a struct needed to allow permit transfer, structured as follows:
     *        - uint256 additional0: The additional amount of the first token to add to the pool.
     *        - uint256 additional1: The additional amount of the second token to add to the pool.
     *        - Permit permit0: A struct containing the permit details for the first token.
     *        - Permit permit1: A struct containing the permit details for the second token.
     * @param snapshot The required arguments within a struct needed to allow permit transfer, structured as follows:
     *        - address token0: The address of the first token.
     *        - address token1: The address of the second token.
     *        - uint256 balance0: The amount of the first token in the pool.
     *        - uint256 balance1: The amount of the second token in the pool.
     *        - uint256 liquidity: The lock's liquidity share of the pool.
     * @return additionalLiquidity The amount of the second token added to the pool.
    **/
    function increase(uint256 id, IncreaseParams calldata params, Snapshot calldata snapshot) payable external returns (uint256 additionalLiquidity) {
        (, uint96 referralHash) = verifySnapshot(id, snapshot);
        _getAndValidateCertificateInfo(id);
        uint256 remainingBalance = _validateFunds(0, _getWETHNeeded(snapshot.token0, snapshot.token1, params.additional0, params.additional1));

        address pair = _pairFor(snapshot.token0, snapshot.token1);
        if (snapshot.token0 != WETH) _resolveAndPermitIfNecessary(snapshot.token0, params.permit0, params.additional0);
        if (snapshot.token1 != WETH) _resolveAndPermitIfNecessary(snapshot.token1, params.permit1, params.additional1);
        
        (bool isNativeETH0, bool isNativeETH1) = (snapshot.token0 == WETH, snapshot.token1 == WETH);

        // Collect to ensure accurate updated snapshot
        try this.collect(id, snapshot) {}
        catch {}

        // Need to get current amount from 
        uint256 refundETH;
        (uint256 balance0, uint256 balance1) = (0, 0);
        (additionalLiquidity, balance0, balance1, refundETH) = _addLiquidityV2(
            pair, 
            snapshot.token0,
            snapshot.token1,
            params.additional0, 
            params.additional1, 
            !isNativeETH0, 
            !isNativeETH1 
        );

        // Refund
        if (remainingBalance + refundETH > 0) payable(msg.sender).transfer(remainingBalance + refundETH);

        hashInfoForCertificateID[id] = _encodeHashInfo(
            _encodeSnapshotID(Snapshot({
                token0: snapshot.token0, 
                token1: snapshot.token1,
                balance0: balance0,
                balance1: balance1,
                liquidity: snapshot.liquidity + additionalLiquidity
            })),
            referralHash
        );

        emit Increased(
            id, 
            snapshot.liquidity + additionalLiquidity,
            balance0,
            balance1
        );
    }


    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          MIGRATION                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    address constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    mapping(address => bool) _migrated;
    error MigrateNotAvailable();
    error AlreadyMigrated();
    error NotMajorityLiquidityHolder();
    error NonETHPair();

    /**
     * @notice Safely upgrades an existing liquidity vault to our new vault technology.
            Note that an upgrade is not forced on any user. Users will be able to inspect the new contract
            and make that decision on their own.
     * @param id The ID of the liquidity position.
     * @param snapshot The required arguments within a struct needed to allow permit transfer, structured as follows:
     *        - address token0: The address of the first token.
     *        - address token1: The address of the second token.
     *        - uint256 balance0: The amount of the first token in the pool.
     *        - uint256 balance1: The amount of the second token in the pool.
     *        - uint256 liquidity: The lock's liquidity share of the pool.
     * @param successorParams The encoded params to be sent to the new vault
    **/
    function migrate(uint256 id, Snapshot calldata snapshot, bytes calldata successorParams) external returns (address token) {
        if (address(_successor) == address(0)) revert MigrateNotAvailable();
        verifySnapshot(id, snapshot);
        (uint96 extraData, address owner) = _getAndValidateCertificateInfo(id);
        (uint40 unlockTime, , ,) = _decodeExtraData(extraData);

        address pool = _pairFor(snapshot.token0, snapshot.token1);
        if (_migrated[pool]) revert AlreadyMigrated();

        // Neccessary Conditions
        uint256 totalLiquidity = IERC20(pool).totalSupply();
        if (snapshot.liquidity < totalLiquidity / 2) revert NotMajorityLiquidityHolder();
        if (snapshot.token0 != WETH && snapshot.token1 != WETH) revert NonETHPair();
        _migrated[pool] = true;

        try this.collect(id, snapshot) {}
        catch {}

        (uint256 amount0, uint256 amount1) = _removeLiquidity(
            pool,
            snapshot.liquidity,
            address(this)
        );


        address targetToken = snapshot.token0 != WETH ? snapshot.token0 : snapshot.token1; 
        (uint256 ethAmount, uint256 tokenAmount) = snapshot.token0 == WETH ? (amount0, amount1) : (amount1, amount0);
        IWETH9(WETH).withdraw(ethAmount);

        IERC20 oldToken = IERC20(targetToken);
        Token newToken = new Token(targetToken);
        token = address(newToken);
        SafeTransferLib.safeTransfer(token, address(_successor), tokenAmount);
        SafeTransferLib.safeTransfer(token, token, oldToken.totalSupply() - tokenAmount);
        SafeTransferLib.safeTransfer(targetToken, DEAD_ADDRESS, tokenAmount);

        _successor.mint{ value: ethAmount }(msg.sender, _successor.encodeParams(unlockTime, successorParams));

        hashInfoForCertificateID[id] = 0;
        _burn(address(0), id, owner, true);
        emit Migrated(id, token);
    }
}