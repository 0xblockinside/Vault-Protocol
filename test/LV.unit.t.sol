// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.26;

import {ILiquidityVault} from "../src/interfaces/ILiquidityVault.sol";
import "src/LiquidityVault.sol";
import "src/PayMaster.sol";
import "forge-std/Test.sol";
import {TestERC20} from "./tokens/TestERC20.sol";
import {TestTaxedERC20} from "./tokens/TestTaxedERC20.sol";
import {IUniswapV2Pair} from "v2-core/interfaces/IUniswapV2Pair.sol";
import {IMintableERC20} from "./interfaces/IMintableERC20.sol";
import {NoPermit} from "shared/structs/Permit.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IUniswapV2Router02} from "v2-periphery/interfaces/IUniswapV2Router02.sol";
import {ISwapRouter02} from "swap-router-contracts/interfaces/ISwapRouter02.sol";
import {IUniswapV2Factory} from "v2-core/interfaces/IUniswapV2Factory.sol";
import {MockMigrationContract} from "./MockMigrationContract.sol";
import {ISuccessor} from "../src/interfaces/ISuccessor.sol";

library LiquidityVaultLogDecoder {
    function decode(Vm.Log memory log) internal returns (ILiquidityVault.Snapshot memory snapshot, uint256 referralMintFee, uint256 referralFee0, uint256 referralFee1) {
        if (log.topics[0] == keccak256("Minted(uint256,address,address,address,uint40,uint256,uint256,uint256,bytes)")) {
            bytes memory referralFeeData;
            (, , , snapshot.liquidity, snapshot.amountIn0, snapshot.amountIn1, referralFeeData) = abi.decode(log.data, (address, address, uint40, uint256, uint256, uint256, bytes));
            console.log("LiquidityVaultLogDecoder[MINTED] referralFeeData:");
            console.log("                                 snapshot.liquidity: %d", snapshot.liquidity);
            console.log("                                 snapshot.amountIn0: %d", snapshot.amountIn0);
            console.log("                                 snapshot.amountIn1: %d", snapshot.amountIn1);
            console.logBytes(referralFeeData);
            if (referralFeeData.length > 0) referralMintFee = abi.decode(referralFeeData, (uint256));
        }
        else if (log.topics[0] == keccak256("Collected(uint256,uint256,uint256,uint256,uint256,uint256,bytes,bytes)")) {
            (bytes memory referralFeeData0, bytes memory referralFeeData1) = (bytes(""), bytes(""));
            (, , snapshot.liquidity, snapshot.amountIn0, snapshot.amountIn1, referralFeeData0, referralFeeData1) = abi.decode(log.data, (uint256, uint256, uint256, uint256, uint256, bytes, bytes));
            console.log("LiquidityVaultLogDecoder[COLLECTED] referralFeeData:");
            console.log("                                 snapshot.liquidity: %d", snapshot.liquidity);
            console.log("                                 snapshot.amountIn0: %d", snapshot.amountIn0);
            console.log("                                 snapshot.amountIn1: %d", snapshot.amountIn1);
            console.logBytes(referralFeeData0);
            console.logBytes(referralFeeData1);
            if (referralFeeData0.length > 0) referralFee0 = abi.decode(referralFeeData0, (uint256));
            if (referralFeeData1.length > 0) referralFee1 = abi.decode(referralFeeData1, (uint256));
        }
        else if (log.topics[0] == keccak256("Increased(uint256,uint256,uint256,uint256)")) {
            (snapshot.liquidity, snapshot.amountIn0, snapshot.amountIn1) = abi.decode(log.data, (uint256, uint256, uint256));
        }
    }
}

library FixedPoint {
    function addLeadingZeros(string memory numberStr, uint256 totalLength) public pure returns (string memory) {
        string memory zeros = "";
        for(uint i = 0; i < totalLength - bytes(numberStr).length; i++) {
            zeros = string(abi.encodePacked(zeros, "0"));
        }
        return string(abi.encodePacked(zeros, numberStr));
    }

    function toFPString(uint256 n, uint8 decimals, Vm vm) internal returns (string memory) {
        uint integerPart = n / 10 ** decimals;
        uint decimalPart = n % 10 ** decimals;
        return string(abi.encodePacked(vm.toString(integerPart), ".", addLeadingZeros(vm.toString(decimalPart), decimals)));
    }
}

struct Probability {
    uint seed;
    uint chance;
}
library ProbabilityUtils {
    function isLikely(Probability memory prob) internal returns (bool) {
        uint psuedoRandom = uint(keccak256(abi.encodePacked(block.timestamp, prob.seed, msg.sender))); 
        return (psuedoRandom < type(uint).max / 100 * prob.chance);
    }
}

library MemoryArrayResizer {
    function copy(uint[] memory bigArr, uint newSize) internal returns (uint[] memory) {
        uint[] memory newArr = new uint[](newSize);
        for (uint i; i < newSize; i++) newArr[i] = bigArr[i];
        return newArr;
    }
}

library ArrayUtils {
    function removeAt(address[] storage arr, uint256 idx) internal  {
        address val = arr[idx];
        for (uint i = idx; i < arr.length - 1; i++) arr[i] = arr[i + 1];
        arr.pop();
    }
}


contract LiquidityVaultUnitTests is Test {
    using FixedPoint for uint;
    using ProbabilityUtils for Probability;
    using MemoryArrayResizer for uint[];
    using ArrayUtils for address[];

    modifier logRecorder() {
        vm.recordLogs();
        _;
    }

    string constant NO_FEES_ERROR = 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED';
    ISwapRouter02 public constant SWAP_ROUTER = ISwapRouter02(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45/*0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E*/);
    IUniswapV2Factory public constant V2_FACTORY = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f/*0x7E0987E5b3a30e3f2828572Bb659A548460a3003 */);

    LiquidityVault lVault;
    LiquidityVaultPayMaster payMaster;
    address WETH;
    address ETH;
    uint BIP_DIVISOR;

    function setUp() external {
        payMaster = new LiquidityVaultPayMaster(address(this));
        lVault = new LiquidityVault(payMaster);
        payMaster.setLiquidityVault(address(lVault));
        WETH = lVault.WETH();
        ETH = lVault.ETH();
        BIP_DIVISOR = lVault.BIP_DIVISOR();
    }

    receive() external payable { }

    function swap(address poolAddr, address sender, uint amountSeed, bool zeroForOne) internal returns (uint amountIn, uint amountOut) {
        startHoax(sender);

        IUniswapV2Pair pair = IUniswapV2Pair(poolAddr);
        (address token0, address token1) = (pair.token0(), pair.token1());

        address[] memory path = new address[](2);
        path[0] = zeroForOne ? token0 : token1;
        path[1] = zeroForOne ? token1 : token0;

        address WETH = lVault.WETH();
        IWETH9 WETH9 = IWETH9(WETH);

        if (path[0] == WETH) {
            amountIn = _bound(amountSeed, 0.01 ether, 2 ether);
            WETH9.deposit{ value: amountIn }();
            WETH9.approve(address(SWAP_ROUTER), amountIn);
        }
        else {
            IERC20 token = IERC20(path[0]);
            amountIn = _bound(amountSeed, 0, token.balanceOf(sender));
            token.approve(address(SWAP_ROUTER), amountIn);
        }

        console.log("[swap] pool:      %s", poolAddr);
        console.log("[swap] amountIn:  %d", amountIn);
        (uint r0, uint r1, ) = IUniswapV2Pair(poolAddr).getReserves();
        console.log("[swap] r0:        %s", r0);
        console.log("[swap] r1:        %s", r1);
        try SWAP_ROUTER.swapExactTokensForTokens(
            amountIn, 
            0, 
            path, 
            sender 
        ) returns (uint _amountOut) {
            amountOut = _amountOut;
            console.log("[swap] amountOut: %d", amountOut);
        } catch Error(string memory reason) {
            console.log("[swap] Reverted with reason:", reason);
        } catch (bytes memory) {
            console.log("[swap] Reverted without a specific reason.");
        }


        // console.log("[Swap] r0: %s", r0.toFPString(18, vm));
        // console.log("[Swap] r1: %s", r1.toFPString(18, vm));
        // console.log("[Swap] Price: %d", r1 * 10 ** 18 / r0);
        // console.log("[Swap] amountIn:  %d", amountIn);
        // console.log("[Swap] amountOut: %d", amountOut);
        vm.stopPrank();
    }

    function _getLiquidityVaultLog(address tokenA, address tokenB) internal returns (ILiquidityVault.Snapshot memory snapshot, uint referralMintFee, uint referralFee0, uint referralFee1) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory log = logs[logs.length-1];
        (snapshot, referralMintFee, referralFee0, referralFee1) = LiquidityVaultLogDecoder.decode(log);
        (snapshot.token0, snapshot.token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }


    function _mintLockedLPPosition(address token, address referrer, uint amountTokenIn, uint amountETHIn, uint32 lockDuration, uint16 feeLevelBIPS, CollectFeeOption collectFeeOption, bytes4 expectedRevert) internal returns (uint id, address targetToken, address pool, ILiquidityVault.Snapshot memory snapshot, bool isToken0, uint mintFee, uint rMintFee, uint rMintPercent, uint collectPercent) {
        IERC20 tokenA = IERC20(token == address(0) ? address(new TestERC20()) : token);
        amountTokenIn = token == address(0) ? tokenA.totalSupply() : amountTokenIn;
        tokenA.approve(address(lVault), amountTokenIn);
        targetToken = address(tokenA);
        uint startDevBal = address(this).balance;
        
        (mintFee, refMintFeeCut) = lVault.mintFee(referrer != address(0), feeLevelBIPS);
        ILiquidityVault.Snapshot memory mintSnapshot;
        if (expectedRevert != 0) vm.expectRevert(expectedRevert);
        (id, mintSnapshot) = lVault.mint{ value: amountETHIn + mintFee }(msg.sender, referrer, ILiquidityVault.MintParams({
            tokenA: address(tokenA),
            tokenB: ETH,
            permitA: NoPermit(),
            permitB: NoPermit(),
            amountA: amountTokenIn,
            amountB: amountETHIn,
            lockDuration: lockDuration,
            feeDiscountLeverBIPS: feeLevelBIPS,
            collectFeeOption: collectFeeOption
        }));

        if (expectedRevert != 0) return (0, address(0), address(0), ILiquidityVault.Snapshot(address(0), address(0), 0, 0, 0), false, 0, 0, 0, 0);

        (snapshot, rMintFee, ,) = _getLiquidityVaultLog(address(tokenA), WETH);
        isToken0 = address(tokenA) == snapshot.token0;

        pool = V2_FACTORY.getPair(snapshot.token0, snapshot.token1);

        assertEq(mintSnapshot.amountIn0, snapshot.amountIn0);
        assertEq(mintSnapshot.amountIn1, snapshot.amountIn1);
        assertEq(mintSnapshot.liquidity, snapshot.liquidity);

        assertEq(mintFee - rMintFee, address(this).balance - startDevBal);
    }


    function test_fallback() external {
        vm.skip(false);
        vm.expectRevert();
        payable(lVault).transfer(1 ether);
    }

    function test_lockForever(uint seed, uint boolSeed) external logRecorder {
        vm.skip(false);
        startHoax(msg.sender);
        (uint id, , , ILiquidityVault.Snapshot memory snapshot, , , , , ) = _mintLockedLPPosition(
            address(0),
            address(0),
            0,
            _bound(seed, 0.1 ether, 70 ether),
            lVault.LOCK_FOREVER(),
            bytes4("")
        );

        // solhint-disable-next-line
        bytes4 NOT_UNLOCKED = bytes4(keccak256("NotUnlocked()"));

        vm.expectRevert(NOT_UNLOCKED);
        lVault.redeem(id, snapshot, Probability({ chance: 50, seed: boolSeed }).isLikely());

        vm.warp(type(uint).max);
        vm.expectRevert(NOT_UNLOCKED);
        lVault.redeem(id, snapshot, Probability({ chance: 50, seed: boolSeed }).isLikely());
    }

    function test_refundSurplusFundsETH(uint ethSeed, uint surplusSeed) external {
        vm.skip(false);
        startHoax(msg.sender);

        TestERC20 tokenA = new TestERC20();
        uint amountTokenIn = tokenA.totalSupply();
        tokenA.approve(address(lVault), amountTokenIn);
        uint amountETHIn = _bound(ethSeed, 0.1 ether, 70 ether);
        uint surplus = _bound(surplusSeed, 0, 70 ether);

        console.log("[TEST] surplus: %d", surplus);

        uint preBal = msg.sender.balance;

        (uint mintFee, , ) = lVault.fees();
        lVault.mint{ value: amountETHIn + mintFee + surplus }(msg.sender, address(0), ILiquidityVault.MintParams({
            tokenA: address(tokenA),
            tokenB: ETH,
            permitA: NoPermit(),
            permitB: NoPermit(),
            amountA: amountTokenIn,
            amountB: amountETHIn,
            lockDuration: lVault.LOCK_FOREVER()
        }));

        assertEq(preBal - msg.sender.balance, amountETHIn + mintFee);
    }

    // TODO: merge with above
    function test_refundSurplusToken(uint deficitSeed, uint ethSeed) external {
        vm.skip(false);
        startHoax(msg.sender);
        // solhint-disable-next-line
        bytes4 INSUFFICIENT_FUNDS = bytes4(keccak256("InsufficientFunds()"));

        TestERC20 tokenA = new TestERC20();
        uint amountTokenIn = 1 + (tokenA.totalSupply() - 1) * _bound(deficitSeed, 0, BIP_DIVISOR) / BIP_DIVISOR;
        tokenA.approve(address(lVault), amountTokenIn);
        uint amountETHIn = _bound(ethSeed, 0.1 ether, 70 ether);


        (uint mintFee, , ) = lVault.mintFee(false, 0);

        // solhint-disable-next-line
        uint32 LOCK_FOREVER = lVault.LOCK_FOREVER();
        lVault.mint{ value: amountETHIn + mintFee }(msg.sender, address(0), ILiquidityVault.MintParams({
            tokenA: address(tokenA),
            tokenB: ETH,
            permitA: NoPermit(),
            permitB: NoPermit(),
            amountA: amountTokenIn,
            amountB: amountETHIn,
            lockDuration: LOCK_FOREVER
        }));

        assertEq(tokenA.balanceOf(msg.sender), tokenA.totalSupply() - amountTokenIn);

    }

    function test_insufficintFundsETH(uint deficitSeed, uint ethSeed) external {
        vm.skip(false);
        startHoax(msg.sender);
        // solhint-disable-next-line
        bytes4 INSUFFICIENT_FUNDS = bytes4(keccak256("InsufficientFunds()"));

        TestERC20 tokenA = new TestERC20();
        uint amountTokenIn = tokenA.totalSupply();
        tokenA.approve(address(lVault), amountTokenIn);
        uint amountETHIn = _bound(ethSeed, 0.1 ether, 70 ether);


        (uint mintFee, , ) = lVault.fees();

        // solhint-disable-next-line
        uint32 LOCK_FOREVER = lVault.LOCK_FOREVER();
        vm.expectRevert(INSUFFICIENT_FUNDS);
        lVault.mint{ value: _bound(deficitSeed, 0, (amountETHIn + mintFee) - 1) }(msg.sender, address(0), ILiquidityVault.MintParams({
            tokenA: address(tokenA),
            tokenB: ETH,
            permitA: NoPermit(),
            permitB: NoPermit(),
            amountA: amountTokenIn,
            amountB: amountETHIn,
            lockDuration: LOCK_FOREVER
        }));
    }

    // This also tests that it gets burned and is unusable
    uint cachedTimestamp;
    function test_redeem(uint ethSeed, uint durationSeed, uint extendSeed, uint removeLPSeed) external logRecorder {
        vm.skip(false);
        cachedTimestamp = uint(block.timestamp);
        // uint cachedTimestamp = uint(block.timestamp); // BUG: strange bug, this doesnt get cached
        // solhint-disable-next-line
        bytes4 NOT_UNLOCKED = bytes4(keccak256("NotUnlocked()"));
        startHoax(msg.sender);
        uint32 duration = uint32(_bound(durationSeed, 0, lVault.LOCK_FOREVER() - 1)); // duration

        console.log("start WETH balance: %d", IERC20(WETH).balanceOf(msg.sender));
        (uint id, , address pool, LiquidityVault.Snapshot memory snapshot, , , , ,) = _mintLockedLPPosition(
            address(0), 
            address(0), 
            0, 
            _bound(ethSeed, 0.1 ether, 70 ether),
            duration,
            bytes4("")
        );
        uint startBal0 = IERC20(snapshot.token0).balanceOf(msg.sender);
        uint startBal1 = IERC20(snapshot.token1).balanceOf(msg.sender);

        bool removesLP = _bound(removeLPSeed, 0, 1) > 0;
        bool didExtend = Probability({ chance: 30, seed: extendSeed }).isLikely();
        uint32 extension = 365 * 1 days;

        if (duration > 0) {
            console.log("[pre extend]cachedTimestamp: %d", cachedTimestamp);
            vm.warp(cachedTimestamp + duration - 1);
            vm.expectRevert(NOT_UNLOCKED);
            lVault.redeem(id, snapshot, removesLP);

            if (didExtend) {
                lVault.extend(id, extension);
                console.log("[postExtend]cachedTimestamp: %d", cachedTimestamp);
                vm.warp(cachedTimestamp + duration + 1);

                vm.expectRevert(NOT_UNLOCKED);
                lVault.redeem(id, snapshot, removesLP);
            }
        }

        IERC20 pair = IERC20(pool);
        uint totalLiquidity = pair.totalSupply();
        uint balOwed0 = snapshot.liquidity * IERC20(snapshot.token0).balanceOf(pool) / totalLiquidity;
        uint balOwed1 = snapshot.liquidity * IERC20(snapshot.token1).balanceOf(pool) / totalLiquidity;

        vm.warp(cachedTimestamp + duration + 1 + (didExtend ? uint(extension) : 0));
        lVault.redeem(id, snapshot, removesLP);

        console.log("post redeem WETH balance: %d", IERC20(WETH).balanceOf(msg.sender));

        // Check balances
        if (removesLP) {
            assertEq(pair.balanceOf(msg.sender), 0);
            assertEq(IERC20(snapshot.token0).balanceOf(msg.sender) - startBal0, balOwed0);
            assertEq(IERC20(snapshot.token1).balanceOf(msg.sender) - startBal1, balOwed1);
        }
        else {
            assertEq(pair.balanceOf(msg.sender), snapshot.liquidity);
        }
    }

    function test_nonOwnerRedeem(uint ethSeed, address randomAddress) external logRecorder {
        vm.skip(false);
        vm.assume(randomAddress != address(0));
        startHoax(msg.sender);
        // solhint-disable-next-line
        bytes4 NOT_OWNER = bytes4(keccak256("NotOwnerNorApproved()"));

        uint32 duration = 300;
        (uint id, , , LiquidityVault.Snapshot memory snapshot, , , , ,) = _mintLockedLPPosition(
            address(0), 
            address(0), 
            0, 
            _bound(ethSeed, 0.1 ether, 70 ether),
            duration,
            bytes4("")
        );

        vm.warp(block.timestamp + duration + 1);

        startHoax(randomAddress);

        vm.expectRevert(NOT_OWNER);
        lVault.redeem(id, snapshot, false);
    }


    function test_increaseLiquidity(uint ethSeed, uint tokenSeed, uint addETHSeed, uint addTokenSeed, uint durationSeed) external logRecorder {
        vm.skip(false);
        // solhint-disable-next-line
        bytes4 INVALID_LIQUIDITY_AMOUNTS = bytes4(keccak256("InvalidLiquidityAdditionalAmounts()"));
        startHoax(msg.sender);
        uint32 duration = uint32(_bound(durationSeed, 0, lVault.LOCK_FOREVER() - 1)); // duration
        uint amountETHIn = _bound(ethSeed, 0.1 ether, 70 ether);

        TestERC20 tokenA = new TestERC20();
        uint amountTokenIn = _bound(tokenSeed, 1, tokenA.totalSupply() - 1);

        (uint id, , address pool, LiquidityVault.Snapshot memory snapshot, bool isToken0, , , ,) = _mintLockedLPPosition(
            address(tokenA), 
            address(0), 
            amountTokenIn, 
            amountETHIn,
            duration,
            bytes4("")
        );
        


        uint addETH = _bound(addETHSeed, 0.1 ether, 70 ether);
        uint addToken = _bound(addTokenSeed, 1, tokenA.totalSupply() - amountTokenIn);

        tokenA.approve(address(lVault), addToken);

        (uint add0, uint add1) = isToken0 ? (addToken, addETH) : (addETH, addToken);
        (uint r0, uint r1, ) = IUniswapV2Pair(pool).getReserves();

        (uint expAdd0, uint expAdd1) = (add0, add0 * r1 / r0);
        if (expAdd1 == 0 || expAdd1 > add1) (expAdd0, expAdd1) = (add1 * r0 / r1, add1);
        bool isInvalidLiquidity = expAdd0 == 0 || expAdd1 == 0 || expAdd0 > add0 || expAdd1 > add1;
        
        (uint preBal0, uint preBal1) = isToken0 ? (tokenA.balanceOf(msg.sender), msg.sender.balance) : (msg.sender.balance, tokenA.balanceOf(msg.sender));

        if (isInvalidLiquidity) vm.expectRevert(INVALID_LIQUIDITY_AMOUNTS);
        lVault.increase{ value: addETH } (
            id, 
            ILiquidityVault.IncreaseParams({
                additional0: add0,
                additional1: add1,
                permit0: NoPermit(),
                permit1: NoPermit()
            }),
            snapshot
        );


        if (!isInvalidLiquidity) {
            (uint postBal0, uint postBal1) = isToken0 ? (tokenA.balanceOf(msg.sender), msg.sender.balance) : (msg.sender.balance, tokenA.balanceOf(msg.sender));
            assertEq(preBal0 - postBal0, expAdd0);
            assertEq(preBal1 - postBal1, expAdd1);
        }

    }

    function test_feeChange(uint mintFeeSeed, uint mintPercentSeed, uint collectPercentSeed) external {
        vm.skip(false);
        // solhint-disable-next-line
        bytes4 INVALID_FEE = bytes4(keccak256("InvalidFee()"));
        (uint mintFee, uint rMintPercent, uint collectPercent) = lVault.fees();
        uint newMintFee = _bound(mintFeeSeed, 0, 2 ** 240 - 1);
        uint newMintPercent = _bound(mintPercentSeed, 0, BIP_DIVISOR);
        uint newInvalidMintPercent = _bound(mintPercentSeed, BIP_DIVISOR + 1, type(uint).max);
        uint newCollectPercent = _bound(mintPercentSeed, 0, collectPercent);
        uint newInvalidCollectPercent = _bound(collectPercentSeed, collectPercent + 1, BIP_DIVISOR);
        
        vm.expectRevert(INVALID_FEE);
        lVault.setFees(newMintFee, newInvalidMintPercent, newCollectPercent);

        vm.expectRevert(INVALID_FEE);
        lVault.setFees(newMintFee, newMintPercent, newInvalidCollectPercent);
        
        lVault.setFees(newMintFee, newMintPercent, newCollectPercent);

        (mintFee, rMintPercent, collectPercent) = lVault.fees();
        assertEq(newMintFee, mintFee);
        assertEq(newMintPercent, rMintPercent);
        assertEq(newCollectPercent, collectPercent);
    }

    function test_migration(uint ethSeed, uint durationSeed) external logRecorder {
        vm.skip(false);
        ISuccessor successor = new MockMigrationContract();
        lVault.setSuccessor(address(successor));

        startHoax(msg.sender);
        uint32 duration = uint32(_bound(durationSeed, 0, lVault.LOCK_FOREVER() - 1)); // duration
        uint amountETHIn = _bound(ethSeed, 0.1 ether, 70 ether);
        (uint id, address token, address pool, LiquidityVault.Snapshot memory snapshot, bool isToken0, , , ,) = _mintLockedLPPosition(
            address(0), 
            address(0), 
            0, 
            amountETHIn,
            duration,
            bytes4("")
        );

        IERC20 pair = IERC20(pool);
        uint totalLiquidity = pair.totalSupply();
        uint ethExpected = snapshot.liquidity * IERC20(!isToken0 ? snapshot.token0 : snapshot.token1).balanceOf(pool) / totalLiquidity;

        address newToken = lVault.migrate(id, snapshot, bytes(""));

        assertEq(IERC20(newToken).totalSupply(), IERC20(token).totalSupply());
        assertEq(IERC20(newToken).balanceOf(address(successor)), IERC20(token).balanceOf(address(0)));
        assertEq(IERC20(newToken).totalSupply() - IERC20(newToken).balanceOf(address(successor)), IERC20(newToken).balanceOf(newToken));
        assertEq(address(successor).balance, ethExpected);

    }

    function test_transfer(address reciever, uint durationSeed, uint ethSeed) external logRecorder {
        vm.skip(false);
        vm.assume(reciever != address(0));

        // solhint-disable-next-line
        bytes4 NOT_OWNER = bytes4(keccak256("NotOwnerNorApproved()"));


        startHoax(msg.sender);
        uint32 duration = uint32(_bound(durationSeed, 0, lVault.LOCK_FOREVER() - 1)); // duration
        uint amountETHIn = _bound(ethSeed, 0.1 ether, 70 ether);
        (uint id, , , LiquidityVault.Snapshot memory snapshot, , , , ,) = _mintLockedLPPosition(
            address(0), 
            address(0), 
            0, 
            amountETHIn,
            duration,
            bytes4("")
        );

        lVault.transferFrom(msg.sender, reciever, id);

        vm.warp(block.timestamp + duration + 1);

        vm.expectRevert(NOT_OWNER);
        lVault.redeem(id, snapshot, false);

        vm.stopPrank();

        startHoax(reciever);

        lVault.redeem(id, snapshot, false);
    }


    address[] wallets;
    function test_referral(uint seed, uint immediateCollectSeed, address referrer, uint claimSeed, uint collectSeed, uint buySeed, uint sellSeed) external logRecorder {
        vm.skip(false);
        // solhint-disable-next-line
        bytes4 NOT_REGISTERED = bytes4(keccak256("NotRegisteredRefferer()"));

        vm.assume(referrer > address(9));
        startHoax(msg.sender);

        uint32 LOCK_FOREVER = lVault.LOCK_FOREVER();
        (uint id, address token, address pool, ILiquidityVault.Snapshot memory snapshot, bool isToken0, uint mintFee, uint rMintFee, uint rMintPercent, ) = _mintLockedLPPosition(
            address(0),
            referrer,
            0,
            _bound(seed, 0.1 ether, 70 ether),
            LOCK_FOREVER,
            NOT_REGISTERED
        );

        vm.stopPrank();
        lVault.setReferrer(referrer, true);

        startHoax(msg.sender);
        (id, token, pool, snapshot, isToken0, mintFee, rMintFee, rMintPercent, ) = _mintLockedLPPosition(
            address(0),
            referrer,
            0,
            _bound(seed, 0.1 ether, 70 ether),
            LOCK_FOREVER,
            bytes4("")
        );
        

        if (Probability({ seed: immediateCollectSeed, chance: 50 }).isLikely()) {
            assertEq(rMintFee, mintFee * rMintPercent / BIP_DIVISOR);

            LiquidityVaultPayMaster.ClaimParams[] memory params = new LiquidityVaultPayMaster.ClaimParams[](1);
            params[0] = LiquidityVaultPayMaster.ClaimParams({
                id: id,
                referrer: referrer,
                snapshot: snapshot,
                mintFee: rMintFee,
                fee0s: new uint[](0),
                fee1s: new uint[](0)
            });
            payMaster.claimReferralFees(params);
            rMintFee = 0;
        }

        Probability memory claimProbability = Probability({ chance: 60, seed: claimSeed });
        Probability memory collectProbability = Probability({ chance: 60, seed: collectSeed });
        Probability memory buyProbability = Probability({ chance: 40, seed: buySeed });
        Probability memory sellProbability = Probability({ chance: 40, seed: sellSeed });
        uint[] memory fee0sBig = new uint[](256);
        uint[] memory fee1sBig = new uint[](256);
        uint feeCount = 0;
        uint N = 256;
        for (uint i; i < N; i++) {
            unchecked {
                collectProbability.seed += i;
                claimProbability.seed += i;
                buyProbability.seed += i;
                sellProbability.seed += i;
            }

            uint amountSeed = uint(keccak256(abi.encodePacked(block.timestamp, i, msg.sender))); 

            if (wallets.length == 0 || buyProbability.isLikely()) {
                swap(
                    pool,
                    vm.addr(3 + i),
                    amountSeed,
                    !isToken0
                );
            }

            if (wallets.length > 0 && sellProbability.isLikely()) {
                uint idx = _bound(amountSeed, 0, wallets.length-1);
                swap(
                    pool,
                    wallets[idx],
                    amountSeed,
                    isToken0
                );
            }

            if (collectProbability.isLikely() || i == N - 1) {
                try lVault.collect(id, snapshot) {
                    (uint rFee0, uint rFee1) = (0, 0);
                    (snapshot, , rFee0, rFee1) = _getLiquidityVaultLog(token, WETH);
                    fee0sBig[feeCount] = rFee0;
                    fee1sBig[feeCount] = rFee1;
                    feeCount += 1;

                    if (feeCount > 0 && (claimProbability.isLikely() || i == N - 1)) {
                        (uint startRBal0, uint startRBal1) = snapshot.token0 == WETH ? 
                            (address(referrer).balance, IERC20(snapshot.token1).balanceOf(referrer)) :
                            (IERC20(snapshot.token0).balanceOf(referrer), address(referrer).balance); 

                        LiquidityVaultPayMaster.ClaimParams[] memory params = new LiquidityVaultPayMaster.ClaimParams[](1);
                        params[0] = LiquidityVaultPayMaster.ClaimParams({
                            id: id,
                            referrer: referrer,
                            snapshot: snapshot,
                            mintFee: rMintFee,
                            fee0s: fee0sBig.copy(feeCount),
                            fee1s: fee1sBig.copy(feeCount)
                        });
                        payMaster.claimReferralFees(params);

                        (uint fee0Sum, uint fee1Sum) = (0, 0);
                        for (uint i; i < feeCount; i++) (fee0Sum, fee1Sum) = (fee0Sum + fee0sBig[i], fee1Sum + fee1sBig[i]);
                        if (snapshot.token0 == WETH) fee0Sum += rMintFee;
                        if (snapshot.token1 == WETH) fee1Sum += rMintFee;

                        rMintFee = 0;
                        fee0sBig = new uint[](256);
                        fee1sBig = new uint[](256);
                        feeCount = 0;

                        (uint endRBal0, uint endRBal1) = snapshot.token0 == WETH ? 
                            (address(referrer).balance, IERC20(snapshot.token1).balanceOf(referrer)) :
                            (IERC20(snapshot.token0).balanceOf(referrer), address(referrer).balance); 

                        assertEq(fee0Sum, endRBal0 - startRBal0);
                        assertEq(fee1Sum, endRBal1 - startRBal1);
                    }
                } catch {}
            }
        }
        delete wallets;
    }

    function test_collect(uint durationSeed, uint ethSeed, uint preMintSeed, uint collectSeed, uint buySeed, uint sellSeed, uint advanceSeed) external logRecorder {
        startHoax(msg.sender);

        uint BIP_DIVISOR = 10_000;
        uint BIP_K_TOLERANCE = 80;
        uint BIP_PRICE_TOLERANCE = 5;

        uint256 amountInETH = _bound(ethSeed, 0.1 ether, 70 ether);
        uint32 duration = uint32(_bound(durationSeed, 0, uint(lVault.LOCK_FOREVER())));

        uint id;
        address token;
        address pool; 
        bool isToken0;
        ILiquidityVault.Snapshot memory snapshot;

        uint preSeedCount = _bound(preMintSeed, 0, 256);

        for (uint i; i < preSeedCount; i++) {
            (id, , pool, snapshot, isToken0, , , , ) = _mintLockedLPPosition(
                address(0),
                address(0),
                0,
                amountInETH,
                duration,
                bytes4("")
            );
        }

        (id, token, pool, snapshot, isToken0, , , , ) = _mintLockedLPPosition(
            address(0),
            address(0),
            0,
            amountInETH,
            duration,
            bytes4("")
        );

        assertEq(id, preSeedCount);


        (uint r0, uint r1, ) = IUniswapV2Pair(pool).getReserves();
        uint last_k = r0 * r1;
        uint last_price = snapshot.token0 == WETH ? r0 * 10 ** 18 / r1 : r1 * 10 ** 18 / r0;

        console.log("first last k and price");

        Probability memory collectProbability = Probability({ chance: 60, seed: collectSeed });
        Probability memory buyProbability = Probability({ chance: 40, seed: buySeed });
        Probability memory sellProbability = Probability({ chance: 40, seed: sellSeed });
        Probability memory advanceTimeProbability = Probability({ chance: 80, seed: advanceSeed });

        uint N = 256;
        console.log("pre skiptTime");
        uint skipTime = (uint(duration) + uint(duration) * 3 / 10) / N;
        console.log("post skiptTime: %d", skipTime);
        uint unlockTime = lVault.unlockTime(id);
        console.log("unlockTime");
        for (uint i; i < N; i++) {
            unchecked {
                collectProbability.seed += i;
                buyProbability.seed += i;
                sellProbability.seed += i;
                advanceTimeProbability.seed += i;
            }

            uint amountSeed = uint(keccak256(abi.encodePacked(block.timestamp, i, msg.sender))); 

            if (advanceTimeProbability.isLikely()) skip(skipTime);

            if (wallets.length == 0 || buyProbability.isLikely()) {
                address buyer = vm.addr(3 + i);
                swap(
                    pool,
                    buyer,
                    amountSeed,
                    !isToken0
                );
                wallets.push(buyer);

                (r0, r1, ) = IUniswapV2Pair(pool).getReserves();
                last_k = r0 * r1;
                last_price = snapshot.token0 == WETH ? r0 * 10 ** 18 / r1 : r1 * 10 ** 18 / r0;
            }

            if (wallets.length > 0 && sellProbability.isLikely()) {
                uint idx = _bound(amountSeed, 0, wallets.length-1);
                swap(
                    pool,
                    wallets[idx],
                    amountSeed,
                    isToken0
                );
                if (IERC20(token).balanceOf(wallets[idx]) == 0) wallets.removeAt(idx);
                (r0, r1, ) = IUniswapV2Pair(pool).getReserves();
                last_k = r0 * r1;
                last_price = snapshot.token0 == WETH ? r0 * 10 ** 18 / r1 : r1 * 10 ** 18 / r0;
            }

            if (collectProbability.isLikely() || i == N - 1) {
                try lVault.collect(id, snapshot) {
                    (snapshot, , , ) = _getLiquidityVaultLog(snapshot.token0, snapshot.token1);
                    (r0, r1, ) = IUniswapV2Pair(pool).getReserves();
                    uint k = r0 * r1;
                    uint price = snapshot.token0 == WETH ? r0 * 10 ** 18 / r1 : r1 * 10 ** 18 / r0;

                    uint priceDiffNumerator = price > last_price ? price - last_price : last_price - price;
                    uint kDiffNumerator = k > last_k ? k - last_k : last_k - k;

                    console.log("Price Check");
                    assertLe(priceDiffNumerator * BIP_DIVISOR / last_price, BIP_PRICE_TOLERANCE);
                    console.log("K Check");
                    assertLe(kDiffNumerator * BIP_DIVISOR / last_k, BIP_K_TOLERANCE);

                    last_k = k;
                    last_price = price;
                }
                catch {}
            }

            if (block.timestamp > unlockTime) {
                startHoax(msg.sender);
                lVault.redeem(id, snapshot, true);
                vm.stopPrank();
                break;
            }

        }

        delete wallets;

    }
}