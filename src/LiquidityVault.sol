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
import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";
import {Token} from "./MigrationToken.sol";
import {ISuccessor} from "./interfaces/ISuccessor.sol";


/// @notice A Liquidity Locker for Uniswap V2 that allows for fee collection without
///         compromising token traders safety.
/// @author Blockinside (https://github.com/0xblockinside/LiquidityVault/blob/master/src/LiquidityVault.sol)
contract LiquidityVault is ILiquidityVault, ERC721Extended, Ownable {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          EVENTS                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    event Minted(
        uint256 indexed id,
        address indexed referrer,
        address token0,
        address token1,
        uint40 lockTime,
        uint256 snapshotLiquidity,
        uint256 snapshotAmountIn0,
        uint256 snapshotAmountIn1,
        bytes referralFee
    );
    event Increased(
        uint256 indexed id, 
        uint256 snapshotLiquidity,
        uint256 snapshotAmountIn0,
        uint256 snapshotAmountIn1
    );
    event Collected(
        uint256 indexed id, 
        uint256 fee0,
        uint256 fee1,
        uint256 snapshotLiquidity,
        uint256 snapshotAmountIn0,
        uint256 snapshotAmountIn1,
        bytes referralFee0,
        bytes referralFee1
    );
    event Redeemed(uint256 indexed id);
    event Extended(uint256 indexed id, uint32 additionalTime);
    event Migrated(uint256 indexed id, address newToken);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CONSTANTS                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    bytes32 public constant INIT_CODE_HASH = 0x4156ccc01dad273e6c65c4335c428a2ff4a4b0c95a9a228f6bfed45a069d3fe7;
    IUniswapV2Factory public constant V2_FACTORY = IUniswapV2Factory(0x7E0987E5b3a30e3f2828572Bb659A548460a3003);
    address public constant WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
    address public constant ETH = address(0);
    uint32 public constant LOCK_FOREVER = type(uint32).max;
    uint40 public constant LOCKED_FOREVER = type(uint40).max;
    uint16 public constant FEE_DIVISOR = 10_000;
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
    error InvalidLiquidityAdditionalAmounts();
    error InsufficientLiquidityBurned();

    function name() public pure override returns (string memory) { return "Liquidity Vault"; }
    function symbol() public pure override returns (string memory) { return "LPVault"; }

    function tokenURI(uint256 id) public pure override returns (string memory) {
        return "";
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STORAGE                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    uint256 private _idTracker;

    /// Bits Layout of '_feeSlot':
    /// - [0..159]    160 bits   `mintFee`
    /// - [160..175]   16 bits   `refMintFeeBIPS`
    /// - [176..191]   16 bits   `refMintDiscountBIPS`
    /// - [192..207]   16 bits   `refCollectFeeBIPS`
    /// - [208..223]   16 bits   `mintDiscountBIPS`
    /// - [224..239]   16 bits   `minProtocolCollectFeeBIPS`
    uint256 _feeSlot = 0.1 ether << 16 | 2_000;

    ISuccessor _successor;


    /// Bits Layout of 'hashInfoForCertificateID.slot':
    /// - [0..159]     160 bits  `snapshotHash: keccak256(abi.encodePacked(token0, token1, snapshotIn0, snapshotIn1, liquidity))`
    /// - [160..256]    96 bits  `referralHash`
    mapping(uint256 => bytes32) public hashInfoForCertificateID;

    mapping(address => bool) public registeredReferrers;



    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     STORAGE HITCHHIKING                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// Bits Layout of 'extraData':
    /// - [0..39]    40 bits   `unlockTime`
    /// - [40..55]   16 bits   `feeLeverBIPS`
    /// - [56..58]   16 bits   `collectFeeLeverOption`

    constructor(IPayMaster pm) {
        payMaster = pm;
        _initializeOwner(msg.sender);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  PRIVATE FUNCTIONS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    function _decodeExtraData(uint96 slot) internal pure returns (uint40 unlockTime, uint16 feeLeverBIPS, CollectFeeOption collectFeeOption) {
        unlockTime = uint40(slot);
        feeLeverBIPS = uint16(slot >> 40);
        collectFeeOption = CollectFeeOption(uint8(slot >> 56));
    }

    function _encodeExtraData(uint40 unlockTime, uint16 feeLeverBIPS, CollectFeeOption collectFeeOption) internal pure returns (uint96 extraData) {
        extraData = uint96(unlockTime) | (uint96(feeLeverBIPS) << 40) | (uint96(uint8(collectFeeOption)) << 56);
    }

    function _decodeFeeSlot(uint256 slot) internal pure returns (uint256 mintFee, uint256 refMintFeeBIPS, uint256 refMintDiscountBIPS, uint256 refCollectFeeBIPS, uint256 mintDiscountBIPS, uint256 minProtocolCollectFeeBIPS) {
        uint256 bit16Mask = ((1 << 16) - 1);
        mintFee = uint160(slot);
        refMintFeeBIPS = (slot >> 160) & bit16Mask;
        refMintDiscountBIPS = (slot >> 176) & bit16Mask;
        refCollectFeeBIPS = (slot >> 192) & bit16Mask;
        mintDiscountBIPS = (slot >> 208) & bit16Mask;
        minProtocolCollectFeeBIPS = (slot >> 224) & bit16Mask;
    }

    function _encodeFeeSlot(uint256 mintFee, uint256 refMintFeeBIPS, uint256 refMintDiscountBIPS, uint256 refCollectFeeBIPS, uint256 mintDiscountBIPS, uint256 minProtocolCollectFeeBIPS) internal pure returns (uint256 slot) {
        slot = uint256(uint160(mintFee)) |
               (refMintFeeBIPS << 160) |
               (refMintDiscountBIPS << 176) |
               (refCollectFeeBIPS << 192) |
               (mintDiscountBIPS << 208) |
               (minProtocolCollectFeeBIPS << 224);
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
                snapshot.amountIn0,
                snapshot.amountIn1,
                snapshot.liquidity
            )
        )));
    }

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


    /////////////    Uniswap v2 related functions   /////////////////////////
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
        SafeTransferLib.safeTransfer(pool, pool, liquidity); // send liquidity to pair (caller -> pair)
        (amount0, amount1) = pair.burn(to); 
    }

    /// @dev  input assumptions, amounts non zero, token0 & token1 are valid to the pair
    function _addLiquidityV2(address pool, address token0, address token1, uint256 amount0, uint256 amount1, bool transferFrom0, bool transferFrom1) internal returns (uint256 liquidity, uint256 actualAmount0, uint256 actualAmount1, uint256 refundETH) {
        IUniswapV2Pair pair = IUniswapV2Pair(pool);

        (actualAmount0, actualAmount1) = (amount0, amount1);
        (uint reserve0, uint reserve1, ) = pair.getReserves();

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
        uint totalLiquidity = pair.totalSupply();
        actualAmount0 = liquidity * (reserve0 + actualAmount0) / totalLiquidity;
        actualAmount1 = liquidity * (reserve1 + actualAmount1) / totalLiquidity;
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


        // Inlined from UniswapV2Library
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

    function _payFeeCut(uint256 cut, address token, uint256 protocolBIPS, uint256 refBIPS, bool toReferrer) internal {
        if (cut == 0) return;

        uint refCut = cut * refBIPS / (protocolBIPS + refBIPS);
        if (token == WETH) payMaster.payFees{ value: cut }(toReferrer ? cut - refCut : cut);
        else {
            if (!toReferrer) SafeTransferLib.safeTransfer(token, payMaster.OWNER(), cut);
            else {
                if (refCut > 0) SafeTransferLib.safeTransfer(token, address(payMaster), refCut);
                if (cut - refCut> 0) SafeTransferLib.safeTransfer(token, address(payMaster), cut - refCut);
            }
        }
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

    //////////            GETTERS           //////////////
    function fees() external view returns (uint256 mintFee, uint256 refMintFeeBIPS, uint256 refMintDiscountBIPS, uint256 refCollectFeeBIPS, uint256 mintDiscountBIPS, uint256 minProtocolCollectFeeBIPS) { 
        (mintFee, refMintFeeBIPS, refMintDiscountBIPS, refCollectFeeBIPS, mintDiscountBIPS, minProtocolCollectFeeBIPS) = _decodeFeeSlot(_feeSlot);
    }

    function mintFee(bool isReferred, uint16 feeLevelBIPS) public returns (uint256 mintFee, uint256 refFeeCut) {
        (uint256 maxMintFee, uint256 refMintFeeBIPS, uint256 refMintDiscountBIPS, , uint256 mintDiscountBIPS, ) = _decodeFeeSlot(_feeSlot);
        if (isReferred) {
            mintFee = maxMintFee * refMintDiscountBIPS / FEE_DIVISOR;
            refFeeCut = maxMintFee * refMintFeeBIPS / FEE_DIVISOR;
        }
        else {
            uint256 discount = maxMintFee * mintDiscountBIPS / FEE_DIVISOR;
            mintFee = maxMintFee - discount * uint256(feeLevelBIPS) / FEE_DIVISOR;
        }

    }


    function unlockTime(uint256 id) view external returns (uint256) {
        return uint256(uint40(_getExtraData(id)));
    }

    //////////            SETTERS             //////////////
    function setFees(
        uint256 mintFee, 
        uint256 refMintFeeBIPS,
        uint256 refMintDiscountBIPS, 
        uint256 refCollectFeeBIPS, 
        uint256 mintDiscountBIPS, 
        uint256 minProtocolCollectFeeBIPS) external onlyOwner {
        (, , , , , uint256 _minProtocolCollectFeesBIPS) = _decodeFeeSlot(_feeSlot);
        if (minProtocolCollectFeeBIPS > _minProtocolCollectFeesBIPS) revert InvalidFee();
        if (refCollectFeeBIPS + minProtocolCollectFeeBIPS > FEE_DIVISOR) revert InvalidFee();
        if (refMintFeeBIPS > FEE_DIVISOR) revert InvalidFee();
        if (refMintDiscountBIPS > FEE_DIVISOR) revert InvalidFee();
        if (refCollectFeeBIPS > FEE_DIVISOR) revert InvalidFee();
        if (mintDiscountBIPS > FEE_DIVISOR) revert InvalidFee();

        _feeSlot = _encodeFeeSlot(mintFee, refMintFeeBIPS, refMintDiscountBIPS, refCollectFeeBIPS, mintDiscountBIPS, minProtocolCollectFeeBIPS);
    }

    function setSuccessor(address successor) external onlyOwner {
        _successor = ISuccessor(successor);
    }

    function setReferrer(address referrer, bool value) external onlyOwner {
        registeredReferrers[referrer] = value;
    }

    function setCollectFeeOptions(uint256 id, CollectFeeOption feeOption) external {
        (uint96 extraData, address owner) = _getAndValidateCertificateInfo(id);
        (uint40 unlockTime, uint16 feeLeverBIPS, ) = _decodeExtraData(extraData);

        _setOwnershipSlot(id, owner, _encodeExtraData(unlockTime, feeLeverBIPS, feeOption));
    }


    //////////            MIGRATION         //////////////
    function verifySnapshot(uint256 id, Snapshot calldata snapshot) public view returns (uint160 snapshotHash, uint96 referralHash) {
        (snapshotHash, referralHash) = _decodeHashInfo(hashInfoForCertificateID[id]);
        if (snapshotHash != _encodeSnapshotID(snapshot)) revert InvalidLiquiditySnapshot();
    }

    function resetReferralHash(uint256 id, address referrer) external {
        if (msg.sender != address(payMaster)) revert NotPayMaster();

        (uint160 snapshotHash, uint96 referralHash) = _decodeHashInfo(hashInfoForCertificateID[id]);
        referralHash = uint96(uint256(keccak256(abi.encodePacked(referrer, uint256(0)))));
        hashInfoForCertificateID[id] = _encodeHashInfo(
            snapshotHash,
            referralHash   
        );
    }


    /**
     * @notice Launches a v2 liquidity position that is locked and allows owners to collect their swap fees.
     * @dev Never transfer ERC20 tokens directly to this contract only native ETH.
     * @param recipient The recipient and owner of the resulting locked liquidity position.
     * @param referrer The recipient and owner of the resulting locked liquidity position.
     * @param params The required arguments within a struct needed to allow permit transfer, structured as follows:
     *        - address tokenA: The address of the first token.
     *        - address tokenB: The address of the second token.
     *        - Permit permitA: A struct containing the permit details for tokenA.
     *        - Permit permitB: A struct containing the permit details for tokenB.
     *        - uint256 amountA: The amount of tokenA to add to the pool.
     *        - uint256 amountB: The amount of tokenB to add to the pool.
     *        - uint32 lockDuration: The duration for which the liquidity should be locked.
     *        - uint16 feeDiscountLeverBIPS: The amount of discount the user choses for their mint fee (BIPS)
     *        - CollectFeeOption collectFeeOption: The amount of discount the user choses for their mint fee (BIPS)
     * @return id The ID of the minted liquidity position.
     * @return snapshot A data structure representing the snapshot of the users liquidity position 
    **/
    function mint(address recipient, address referrer, MintParams calldata params) public payable returns (uint256 id, Snapshot memory snapshot) {
        bool isReferred = referrer != address(0);
        if (isReferred && !registeredReferrers[referrer]) revert NotRegisteredRefferer();

        (uint256 mintFee, uint256 refMintFeeCut) = mintFee(isReferred, params.feeDiscountLeverBIPS);
        uint256 protocolMintFeeCut = mintFee - refMintFeeCut;
        uint96 referrerHash = isReferred ? uint96(uint256(keccak256(abi.encodePacked(referrer, refMintFeeCut)))) : 0;

        uint256 remainingBalance = _validateFunds(mintFee, _getWETHNeeded(params.tokenA, params.tokenB, params.amountA, params.amountB));
        uint40 unlockTime = params.lockDuration == LOCK_FOREVER || (block.timestamp + params.lockDuration) > type(uint40).max ? LOCKED_FOREVER : uint40(block.timestamp + uint256(params.lockDuration));

        // Pay Fee
        payMaster.payFees{ value: mintFee }(protocolMintFeeCut);

        // Token Validation & Address Resolvement
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
        uint256 refundETH;
        (snapshot.liquidity, snapshot.amountIn0, snapshot.amountIn1, refundETH) = _addLiquidityV2(
            pool, 
            snapshot.token0,
            snapshot.token1,
            desiredAmount0, 
            desiredAmount1, 
            !isNativeETH0, 
            !isNativeETH1
        );

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
            snapshot.liquidity, 
            snapshot.amountIn0,
            snapshot.amountIn1,
            isReferred ? abi.encode(uint256(refMintFeeCut)) : bytes("")
        );

        _setOwnershipSlot(_idTracker, recipient, _encodeExtraData(unlockTime, params.feeDiscountLeverBIPS, params.collectFeeOption));
        _incrementBalance(recipient, 1);
        _idTracker++;
    }

    function mint(MintParams calldata params) payable external returns (uint256 id, Snapshot memory snapshot) {
        return mint(msg.sender, address(0), params);
    }

    /**
     * @notice Collects owed fees from a Uniswap V2 liquidity pool without compromising the security and properties of the lock.
     * @dev Anyone can call this on behalf of a vaulted position, but fees will only be collected by the owner of the position.
     * @param id The ID of the vaulted liquidity position.
     * @param snapshot A struct containing the necessary data to collect fees from a Uniswap V2 liquidity pool:
     *        - address token0: The address of the first token in the liquidity pool.
     *        - address token1: The address of the second token in the liquidity pool.
     *        - uint256 amountIn0: The amount of the first token currently in the pool.
     *        - uint256 amountIn1: The amount of the second token currently in the pool.
     *        - uint256 liquidity: The total liquidity of the pool at the time of the snapshot.
     * @return fee0 The amount of fee collected in token0.
     * @return fee1 The amount of fee collected in token1.
    **/
    function collect(uint256 id, Snapshot calldata snapshot) external returns (uint256 fee0, uint256 fee1) {
        (, uint96 referralHash) = verifySnapshot(id, snapshot);
        (address owner, uint96 extraData) = _getOwnershipSlot(id);
        (, uint256 feeDiscountLeverBIPS, CollectFeeOption feeOptions) = _decodeExtraData(extraData);

        address pool = _pairFor(snapshot.token0, snapshot.token1);
        uint256 balance0 = IERC20(snapshot.token0).balanceOf(pool);
        uint256 balance1 = IERC20(snapshot.token1).balanceOf(pool);
        uint256 totalLiquidity = IERC20(pool).totalSupply();

        uint256 wouldBeRemoved0 = snapshot.liquidity * balance0 / totalLiquidity;
        uint256 wouldBeRemoved1 = snapshot.liquidity * balance1 / totalLiquidity;

        /// @dev link to calculation TODO
        uint256 feeLiquidity0 = totalLiquidity * wouldBeRemoved0 / balance0 - Math.mulDiv(totalLiquidity, Math.sqrt(Math.mulDiv(wouldBeRemoved0, snapshot.amountIn0 * snapshot.amountIn1, wouldBeRemoved1)), balance0);
        uint256 feeLiquidity1 = totalLiquidity * wouldBeRemoved1 / balance1 - Math.mulDiv(totalLiquidity, Math.sqrt(Math.mulDiv(wouldBeRemoved1, snapshot.amountIn0 * snapshot.amountIn1, wouldBeRemoved0)), balance1);

        /// @dev take the max of the liquidities
        uint256 feeLiquidity = feeLiquidity0 <= feeLiquidity1 ? feeLiquidity1 : feeLiquidity0;

        if (feeLiquidity == 0) revert InsufficientLiquidityBurned();
        (fee0, fee1) = _removeLiquidity(pool, feeLiquidity, address(this));

        uint256 liquidity = snapshot.liquidity - feeLiquidity;
        /// @dev Inlined amountsFromLiquidityV2
        totalLiquidity = IUniswapV2Pair(pool).totalSupply();
        uint256 amountIn0 = liquidity * (balance0 - fee0) / totalLiquidity;
        uint256 amountIn1 = liquidity * (balance1 - fee1) / totalLiquidity;

        /// @section Fee Breakdown
        ( , , , uint256 refCollectFeeBIPS, , uint256 minProtocolCollectFeeBIPS) = _decodeFeeSlot(_feeSlot);
        (uint256 cut0, uint256 cut1) = (0, 0);

        if (referralHash != 0) (cut0, cut1) = (
            fee0 * (refCollectFeeBIPS + minProtocolCollectFeeBIPS) / FEE_DIVISOR, 
            fee1 * (refCollectFeeBIPS + minProtocolCollectFeeBIPS) / FEE_DIVISOR);
        else {
            // if feeDiscountLeverBIPS max it was max discount, therefore smallest amount of fee and ther fore greatst amount to protcol
            uint256 lowFeeCut0 = fee0 * minProtocolCollectFeeBIPS / FEE_DIVISOR;
            uint256 lowFeeCut1 = fee1 * minProtocolCollectFeeBIPS / FEE_DIVISOR;

            /// @dev highest userFeeDiscountBIPS == 10_000 (100%) => gives protocol (fee0, fee1)
            ///      lowest  userFeeDiscountBIPS ==      0   (0%) => gives protocol (lowFeeCut0, lowFeeCut1)
            (cut0, cut1) = (
                lowFeeCut0 + (fee0 - lowFeeCut0) * feeDiscountLeverBIPS / FEE_DIVISOR,
                lowFeeCut1 + (fee1 - lowFeeCut1) * feeDiscountLeverBIPS / FEE_DIVISOR
            );
        }

        (uint256 ownerFee0, uint256 ownerFee1) = (fee0 - cut0, fee1 - cut1);

        /// @dev all cut fees will be given in ETH and need to be swapped
        uint256 swapCut0For1 = snapshot.token1 == WETH ? cut0 : 0;
        uint256 swapCut1For0 = snapshot.token0 == WETH ? cut1 : 0;

        uint256 ownerSwap0For1 = feeOptions == CollectFeeOption.TOKEN_1 ? ownerFee0 : 0;
        uint256 ownerSwap1For0 = feeOptions == CollectFeeOption.TOKEN_0 ? ownerFee1 : 0;

        /// @dev all fee cuts will be taken in SUPPORTED BASE TOKENS whenever possible
        (uint256 swapedCut0, uint256 swapedOwnerFees0) = _swapFeesIfNeccessary(pool, snapshot.token0, snapshot.token1, true, swapCut1For0, ownerSwap1For0);
        (uint256 swapedCut1, uint256 swapedOwnerFees1) = _swapFeesIfNeccessary(pool, snapshot.token1, snapshot.token1, false, swapCut0For1, ownerSwap0For1);
        ownerFee0 = ownerFee0 + swapedOwnerFees0 - ownerSwap0For1;
        ownerFee1 = ownerFee1 + swapedOwnerFees1 - ownerSwap1For0;
        cut0 = cut0 + swapedCut0 - swapCut0For1;
        cut1 = cut1 + swapedCut1 - swapCut1For0;

        // Prep: WETH -> ETH
        if (snapshot.token0 == WETH) IWETH9(WETH).withdraw(ownerFee0 + cut0);
        if (snapshot.token1 == WETH) IWETH9(WETH).withdraw(ownerFee1 + cut1);

        // Payout: referrer or protocol
        _payFeeCut(cut0, snapshot.token0, minProtocolCollectFeeBIPS, refCollectFeeBIPS, referralHash != 0);
        _payFeeCut(cut1, snapshot.token1, minProtocolCollectFeeBIPS, refCollectFeeBIPS, referralHash != 0);

        // Payout: owner
        if (snapshot.token0 == WETH) payable(owner).transfer(ownerFee0);
        else SafeTransferLib.safeTransfer(snapshot.token0, owner, ownerFee0);
        if (snapshot.token1 == WETH) payable(owner).transfer(ownerFee1);
        else SafeTransferLib.safeTransfer(snapshot.token1, owner, ownerFee1);

        // Update the Payout Merkle root
        if (referralHash != 0) {
            referralHash = uint96(uint256(keccak256(abi.encodePacked(
                uint96(uint256(keccak256(abi.encodePacked(referralHash, cut0)))),
                cut1 
            ))));
        }


        hashInfoForCertificateID[id] = _encodeHashInfo(
            _encodeSnapshotID(Snapshot({
                token0: snapshot.token0,
                token1: snapshot.token1,
                amountIn0: amountIn0,
                amountIn1: amountIn1,
                liquidity: liquidity
            })),
            referralHash
        );

        uint256 refCut0 = referralHash != 0 ? cut0 * refCollectFeeBIPS / (refCollectFeeBIPS + minProtocolCollectFeeBIPS) : 0;
        uint256 refCut1 = referralHash != 0 ? cut1 * refCollectFeeBIPS / (refCollectFeeBIPS + minProtocolCollectFeeBIPS) : 0;
        emit Collected(
            id, 
            fee0,
            fee1, 
            liquidity,
            amountIn0,
            amountIn1,
            referralHash != 0 ? abi.encode(refCut0) : bytes(""),
            referralHash != 0 ? abi.encode(refCut1) : bytes("")
        );
    }

    /**
     * @notice Redeems a locked liquidity position once its lock time is up.
     * @param id The ID of the liquidity position.
     * @param snapshot The required arguments within a struct needed to allow permit transfer, structured as follows:
     *        - address token0: The address of the first token.
     *        - address token1: The address of the second token.
     *        - uint256 amountIn0: The amount of the first token in the pool.
     *        - uint256 amountIn1: The amount of the second token in the pool.
     *        - uint256 liquidity: The current liquidity of the pool.
     * @param removeLP If true, sends underlying tokens of the pool to the owner; if false, liquidity tokens are sent.
    **/
    function redeem(uint256 id, Snapshot calldata snapshot, bool removeLP) external {
        verifySnapshot(id, snapshot);
        (uint96 extraData, address owner) = _getAndValidateCertificateInfo(id);
        (uint40 unlockTime, , ) = _decodeExtraData(extraData);
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
     * @param id The id of the liquidity position.
     * @param additionalTime The additional time to extend the lock duration. If set to LOCK_FOREVER, the position will be locked forever.
     */
    function extend(uint256 id, uint32 additionalTime) external {
        (uint96 extraData, ) = _getAndValidateCertificateInfo(id);
        (uint40 unlockTime, , ) = _decodeExtraData(extraData);
        if (unlockTime == LOCKED_FOREVER) return;
        if (additionalTime == LOCK_FOREVER || LOCKED_FOREVER - unlockTime <= additionalTime) unlockTime = LOCKED_FOREVER;
        else unlockTime += additionalTime;

        _setExtraData(id, uint96(unlockTime));
        emit Extended(id, additionalTime);
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
     *        - uint256 amountIn0: The amount of the first token in the pool.
     *        - uint256 amountIn1: The amount of the second token in the pool.
     *        - uint256 liquidity: The current liquidity of the pool.
     * @return added0 The amount of the first token added to the pool.
     * @return added1 The amount of the second token added to the pool.
    **/
    function increase(uint256 id, IncreaseParams calldata params, Snapshot calldata snapshot) payable external returns (uint256 added0, uint256 added1) {
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
        (uint256 additionalLiquidity, uint256 refundETH) = (0, 0);
        (additionalLiquidity, added0, added1, refundETH) = _addLiquidityV2(
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


        uint256 snapshotLiquidity = snapshot.liquidity + additionalLiquidity;

        // Inlined amountsFromLiquidityV2 since not used else where
        uint256 totalLiquidity = IUniswapV2Pair(pair).totalSupply();
        uint256 snapshotAmountIn0 = snapshotLiquidity * IERC20(snapshot.token0).balanceOf(pair) / totalLiquidity;
        uint256 snapshotAmountIn1 = snapshotLiquidity * IERC20(snapshot.token1).balanceOf(pair) / totalLiquidity;

        hashInfoForCertificateID[id] = _encodeHashInfo(
            _encodeSnapshotID(Snapshot({
                token0: snapshot.token0, 
                token1: snapshot.token1,
                amountIn0: snapshotAmountIn0,
                amountIn1: snapshotAmountIn1,
                liquidity: snapshotLiquidity
            })),
            referralHash
        );

        emit Increased(
            id, 
            snapshotLiquidity,
            snapshotAmountIn0,
            snapshotAmountIn1
        );
    }


    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          MIGRATION                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

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
     *        - uint256 amountIn0: The amount of the first token in the pool.
     *        - uint256 amountIn1: The amount of the second token in the pool.
     *        - uint256 liquidity: The current liquidity of the pool.
     * @param successorParams The encoded params to be sent to the new vault
    **/
    function migrate(uint256 id, Snapshot calldata snapshot, bytes calldata successorParams) external returns (address token) {
        if (address(_successor) == address(0)) revert MigrateNotAvailable();
        verifySnapshot(id, snapshot);
        (uint96 extraData, address owner) = _getAndValidateCertificateInfo(id);
        (uint40 unlockTime, , ) = _decodeExtraData(extraData);

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
        SafeTransferLib.safeTransfer(targetToken, 0x000000000000000000000000000000000000dEaD, tokenAmount);

        _successor.mint{ value: ethAmount }(msg.sender, _successor.encodeParams(unlockTime, successorParams));

        hashInfoForCertificateID[id] = 0;
        _burn(address(0), id, owner, true);
        emit Migrated(id, token);
    }
}