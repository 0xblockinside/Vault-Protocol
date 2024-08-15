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
    function decode(Vm.Log memory log) internal returns (ILiquidityVault.Snapshot memory snapshot, uint256 referralMintFee, uint256 referralFee0, uint256 referralFee1, uint256 ownerFee0, uint256 ownerFee1) {
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
            console.log("LiquidityVaultLogDecoder[COLLECTED] pre:");
            (ownerFee0, ownerFee1, snapshot.liquidity, snapshot.amountIn0, snapshot.amountIn1, referralFeeData0, referralFeeData1) = abi.decode(log.data, (uint256, uint256, uint256, uint256, uint256, bytes, bytes));
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
        else if (log.topics[0] == keccak256("Redeemed(uint256)")) {
            // (snapshot.liquidity, snapshot.amountIn0, snapshot.amountIn1) = abi.decode(log.data, (uint256, uint256, uint256));
        }
        else if (log.topics[0] == keccak256("Extended(uint256,uint32)")) {
            // (snapshot.liquidity, snapshot.amountIn0, snapshot.amountIn1) = abi.decode(log.data, (uint256, uint256, uint256));
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
    IUniswapV2Router02 public constant V2_ROUTER = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    LiquidityVault lVault;
    LiquidityVaultPayMaster payMaster;
    address WETH;
    address ETH = address(0);
    uint BIP_DIVISOR = 10_000;
    address constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint32 MIN_LOCK_DURATION = 7 days;

    function setUp() external {
        payMaster = new LiquidityVaultPayMaster(address(this));
        lVault = new LiquidityVault(payMaster);
        payMaster.setLiquidityVault(address(lVault));
        WETH = lVault.WETH();
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

    function _getLiquidityVaultLog(address tokenA, address tokenB) internal returns (ILiquidityVault.Snapshot memory snapshot, uint referralMintFee, uint referralFee0, uint referralFee1, uint ownerFee0, uint ownerFee1) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory log = logs[logs.length-1];
        console.log("[getLiquidityVaultLog] log:");
        (snapshot, referralMintFee, referralFee0, referralFee1, ownerFee0, ownerFee1) = LiquidityVaultLogDecoder.decode(log);
        console.log("post decode");
        (snapshot.token0, snapshot.token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }


    function _mintLockedLPPosition(bool isLPToken, address token, address referrer, uint amountTokenIn, uint amountETHIn, uint32 lockDuration, uint16 feeLevelBIPS, ILiquidityVault.CollectFeeOption collectFeeOption, bytes4 expectedRevert) internal returns (uint id, address targetToken, address pool, ILiquidityVault.Snapshot memory snapshot, bool isToken0, uint mintFee, uint rMintFeeCut, ILiquidityVault.FeeInfo memory feeInfo) {
        IERC20 tokenA = IERC20(token == address(0) ? address(new TestERC20()) : token);
        amountTokenIn = token == address(0) ? tokenA.totalSupply() : amountTokenIn;
        targetToken = address(tokenA);
        uint startDevBal = address(this).balance;

        uint lpTokenBalance;
        if (isLPToken) {
            tokenA.approve(address(V2_ROUTER), amountTokenIn);
            V2_ROUTER.addLiquidityETH{ value: amountETHIn }(address(tokenA), amountTokenIn, 0, 0, msg.sender, block.timestamp);
            pool = V2_FACTORY.getPair(address(tokenA), WETH);
            lpTokenBalance = IERC20(pool).balanceOf(msg.sender);
            IERC20(pool).approve(address(lVault), lpTokenBalance);
        }
        else {
            tokenA.approve(address(lVault), amountTokenIn);
        }

        (mintFee, rMintFeeCut, feeInfo) = lVault.mintFee(referrer != address(0), feeLevelBIPS);
        ILiquidityVault.Snapshot memory mintSnapshot;
        if (expectedRevert != 0) vm.expectRevert(expectedRevert);
        (id, mintSnapshot) = lVault.mint{ value: (isLPToken ? 0 : amountETHIn) + mintFee }(msg.sender, referrer, ILiquidityVault.MintParams({
            tokenA: isLPToken ? pool : address(tokenA),
            tokenB: ETH,
            permitA: NoPermit(),
            permitB: NoPermit(),
            amountA: isLPToken ? lpTokenBalance : amountTokenIn,
            amountB: amountETHIn,
            isLPToken: isLPToken,
            lockDuration: lockDuration,
            feeLevelBIPS: feeLevelBIPS,
            collectFeeOption: collectFeeOption
        }));

        if (expectedRevert != 0) return (0, address(0), address(0), ILiquidityVault.Snapshot(address(0), address(0), 0, 0, 0), false, 0, 0, ILiquidityVault.FeeInfo(0, 0, 0, 0, 0, 0));

        uint _rMintFeeCut;
        (snapshot, _rMintFeeCut, , , , ) = _getLiquidityVaultLog(address(tokenA), WETH);
        assertEq(_rMintFeeCut, rMintFeeCut);

        isToken0 = address(tokenA) == snapshot.token0;

        pool = V2_FACTORY.getPair(snapshot.token0, snapshot.token1);

        assertEq(mintSnapshot.amountIn0, snapshot.amountIn0);
        assertEq(mintSnapshot.amountIn1, snapshot.amountIn1);
        assertEq(mintSnapshot.liquidity, snapshot.liquidity);

        console.log("mintFee: %d", mintFee);
        console.log("rMintFeeCut: %d", rMintFeeCut);
        console.log("startDevBal: %d", startDevBal);
        console.log("address(this).balance: %d", address(this).balance);

        assertEq(mintFee - rMintFeeCut, address(this).balance - startDevBal);
    }

    function _verifyReferralFees(uint id, address referrer, ILiquidityVault.Snapshot memory snapshot, address buyer, bool isToken0, address pool, uint seed) internal returns (ILiquidityVault.Snapshot memory) {
         swap(
            pool,
            buyer,
            _bound(seed, 5 ether, 70 ether),
            !isToken0
        );

        startHoax(msg.sender);
        LiquidityVault.Fees memory fees = lVault.collect(id, snapshot);
        (snapshot, , , , , ) = _getLiquidityVaultLog(isToken0 ? snapshot.token0 : snapshot.token1, WETH);

        if (referrer == address(0)) {
            assertEq(fees.referralCut0, 0);
            assertEq(fees.referralCut1, 0);
            return snapshot;
        }

        if (snapshot.token0 == WETH) assertGt(fees.referralCut0, 0);
        if (snapshot.token1 == WETH) assertGt(fees.referralCut1, 0);


        (uint startRefBal0, uint startRefBal1) = snapshot.token0 == WETH ? 
            (address(referrer).balance, IERC20(snapshot.token1).balanceOf(address(referrer))) :
            (IERC20(snapshot.token0).balanceOf(address(referrer)), address(referrer).balance); 

        LiquidityVaultPayMaster.ClaimParams[] memory params = new LiquidityVaultPayMaster.ClaimParams[](1);
        uint[] memory fee0s = new uint[](1);
        uint[] memory fee1s = new uint[](1);
        fee0s[0] = fees.referralCut0;
        fee1s[0] = fees.referralCut1;

        params[0] = LiquidityVaultPayMaster.ClaimParams({
            id: id,
            referrer: referrer,
            snapshot: snapshot,
            mintFee: 0,
            fee0s: fee0s,
            fee1s: fee1s
        });
        payMaster.claimReferralFees(params); 

        (uint lastRefBal0, uint lastRefBal1) = snapshot.token0 == WETH ? 
            (address(referrer).balance, IERC20(snapshot.token1).balanceOf(address(referrer))) :
            (IERC20(snapshot.token0).balanceOf(address(referrer)), address(referrer).balance); 
        
        assertEq(fees.referralCut0, lastRefBal0 - startRefBal0);
        assertEq(fees.referralCut1, lastRefBal1 - startRefBal1);
        return snapshot;
    }


    function test_fallback() external {
        vm.skip(true);
        vm.expectRevert();
        payable(lVault).transfer(1 ether);
    }

    function test_lockForever(uint seed, uint boolSeed, uint feeLevelSeed, uint collectFeeOptionSeed, bool isLPToken) external logRecorder {
        vm.skip(true);
        startHoax(msg.sender);
        (uint id, , , ILiquidityVault.Snapshot memory snapshot, , , , ) = _mintLockedLPPosition(
            isLPToken,
            address(0),
            address(0),
            0,
            _bound(seed, 0.1 ether, 70 ether),
            lVault.LOCK_FOREVER(),
            uint16(_bound(feeLevelSeed, 0, BIP_DIVISOR)),
            ILiquidityVault.CollectFeeOption(_bound(collectFeeOptionSeed, 0, 2)),
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

    function test_refundSurplusFundsETH(uint ethSeed, uint surplusSeed, uint feeLevelSeed, uint collectFeeSeed) external {
        vm.skip(true);
        startHoax(msg.sender);

        TestERC20 tokenA = new TestERC20();
        uint amountTokenIn = tokenA.totalSupply();
        tokenA.approve(address(lVault), amountTokenIn);
        uint amountETHIn = _bound(ethSeed, 0.1 ether, 70 ether);
        uint surplus = _bound(surplusSeed, 0, 70 ether);

        console.log("[TEST] surplus: %d", surplus);

        uint preBal = msg.sender.balance;

        uint16 feeLevelBIPS = uint16(_bound(feeLevelSeed, 0, BIP_DIVISOR));
        ILiquidityVault.CollectFeeOption collectFeeOption = ILiquidityVault.CollectFeeOption(_bound(collectFeeSeed, 0, 2));
        (uint mintFee, ,) = lVault.mintFee(false, feeLevelBIPS);
        lVault.mint{ value: amountETHIn + mintFee + surplus }(msg.sender, address(0), ILiquidityVault.MintParams({
            tokenA: address(tokenA),
            tokenB: ETH,
            permitA: NoPermit(),
            permitB: NoPermit(),
            amountA: amountTokenIn,
            amountB: amountETHIn,
            isLPToken: false,
            lockDuration: lVault.LOCK_FOREVER(),
            feeLevelBIPS: feeLevelBIPS,
            collectFeeOption: collectFeeOption
        }));

        assertEq(preBal - msg.sender.balance, amountETHIn + mintFee);
    }

    // TODO: merge with above
    function test_refundSurplusToken(uint deficitSeed, uint ethSeed, uint feeLevelSeed, uint collectFeeSeed) external {
        vm.skip(true);
        startHoax(msg.sender);
        // solhint-disable-next-line
        bytes4 INSUFFICIENT_FUNDS = bytes4(keccak256("InsufficientFunds()"));

        TestERC20 tokenA = new TestERC20();
        uint amountTokenIn = 1 + (tokenA.totalSupply() - 1) * _bound(deficitSeed, 0, BIP_DIVISOR) / BIP_DIVISOR;
        tokenA.approve(address(lVault), amountTokenIn);
        uint amountETHIn = _bound(ethSeed, 0.1 ether, 70 ether);


        uint16 feeLevelBIPS = uint16(_bound(feeLevelSeed, 0, BIP_DIVISOR));
        (uint mintFee, ,) = lVault.mintFee(false, feeLevelBIPS);
        ILiquidityVault.CollectFeeOption collectFeeOption = ILiquidityVault.CollectFeeOption(_bound(collectFeeSeed, 0, 2));

        // solhint-disable-next-line
        uint32 LOCK_FOREVER = lVault.LOCK_FOREVER();
        lVault.mint{ value: amountETHIn + mintFee }(msg.sender, address(0), ILiquidityVault.MintParams({
            tokenA: address(tokenA),
            tokenB: ETH,
            permitA: NoPermit(),
            permitB: NoPermit(),
            amountA: amountTokenIn,
            amountB: amountETHIn,
            isLPToken: false,
            lockDuration: LOCK_FOREVER,
            feeLevelBIPS: feeLevelBIPS,
            collectFeeOption: collectFeeOption
        }));

        assertEq(tokenA.balanceOf(msg.sender), tokenA.totalSupply() - amountTokenIn);

    }

    function test_insufficintFundsETH(uint deficitSeed, uint ethSeed, uint feeLevelSeed, uint collectFeeSeed) external {
        vm.skip(true);
        startHoax(msg.sender);
        // solhint-disable-next-line
        bytes4 INSUFFICIENT_FUNDS = bytes4(keccak256("InsufficientFunds()"));

        TestERC20 tokenA = new TestERC20();
        uint amountTokenIn = tokenA.totalSupply();
        tokenA.approve(address(lVault), amountTokenIn);
        uint amountETHIn = _bound(ethSeed, 0.1 ether, 70 ether);


        uint16 feeLevelBIPS = uint16(_bound(feeLevelSeed, 0, BIP_DIVISOR));
        ILiquidityVault.CollectFeeOption collectFeeOption = ILiquidityVault.CollectFeeOption(_bound(collectFeeSeed, 0, 2));
        (uint mintFee, ,) = lVault.mintFee(false, feeLevelBIPS);

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
            isLPToken: false,
            lockDuration: LOCK_FOREVER,
            feeLevelBIPS: feeLevelBIPS,
            collectFeeOption: collectFeeOption
        }));
    }

    // This also tests that it gets burned and is unusable
    uint cachedTimestamp;
    function test_redeem(uint ethSeed, uint durationSeed, uint extendSeed, uint removeLPSeed, uint feeLevelSeed, uint collectFeeOptionSeed, bool isLPToken) external logRecorder {
        vm.skip(true);
        cachedTimestamp = uint(block.timestamp);
        // uint cachedTimestamp = uint(block.timestamp); // BUG: strange bug, this doesnt get cached
        // solhint-disable-next-line
        bytes4 NOT_UNLOCKED = bytes4(keccak256("NotUnlocked()"));
        startHoax(msg.sender);
        uint32 duration = uint32(_bound(durationSeed, MIN_LOCK_DURATION, lVault.LOCK_FOREVER() - 1)); // duration

        console.log("start WETH balance: %d", IERC20(WETH).balanceOf(msg.sender));
        (uint id, , address pool, LiquidityVault.Snapshot memory snapshot, , , ,) = _mintLockedLPPosition(
            isLPToken,
            address(0), 
            address(0), 
            0, 
            _bound(ethSeed, 0.1 ether, 70 ether),
            duration,
            uint16(_bound(feeLevelSeed, 0, BIP_DIVISOR)),
            ILiquidityVault.CollectFeeOption(_bound(collectFeeOptionSeed, 0, 2)),
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
                // This tests simple extend for us
                lVault.extend(id, extension, uint16(BIP_DIVISOR), address(0), address(0));
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

    function test_nonOwnerRedeem(uint ethSeed, address randomAddress, uint feeLevelSeed, uint collectFeeOptionSeed, bool isLPToken) external logRecorder {
        vm.skip(true);
        vm.assume(randomAddress != address(0));
        startHoax(msg.sender);
        // solhint-disable-next-line
        bytes4 NOT_OWNER = bytes4(keccak256("NotOwnerNorApproved()"));

        uint32 duration = MIN_LOCK_DURATION;
        (uint id, , , LiquidityVault.Snapshot memory snapshot, , , ,) = _mintLockedLPPosition(
            isLPToken,
            address(0), 
            address(0), 
            0, 
            _bound(ethSeed, 0.1 ether, 70 ether),
            duration,
            uint16(_bound(feeLevelSeed, 0, BIP_DIVISOR)),
            ILiquidityVault.CollectFeeOption(_bound(collectFeeOptionSeed, 0, 2)),
            bytes4("")
        );

        vm.warp(block.timestamp + duration + 1);

        startHoax(randomAddress);

        vm.expectRevert(NOT_OWNER);
        lVault.redeem(id, snapshot, false);
    }


    function test_increaseLiquidity(uint ethSeed, uint tokenSeed, uint addETHSeed, uint addTokenSeed, uint durationSeed, uint feeLevelSeed, uint collectFeeOptionSeed, bool isLPToken) external logRecorder {
        vm.skip(false);
        // solhint-disable-next-line
        bytes4 INVALID_LIQUIDITY_AMOUNTS = bytes4(keccak256("InvalidLiquidityAdditionalAmounts()"));
        startHoax(msg.sender);
        uint32 duration = uint32(_bound(durationSeed, MIN_LOCK_DURATION, lVault.LOCK_FOREVER() - 1)); // duration
        uint amountETHIn = _bound(ethSeed, 0.1 ether, 70 ether);

        TestERC20 tokenA = new TestERC20();
        uint amountTokenIn = _bound(tokenSeed, 1, tokenA.totalSupply() - 1);

        (uint id, , address pool, LiquidityVault.Snapshot memory snapshot, bool isToken0, , ,) = _mintLockedLPPosition(
            isLPToken,
            address(tokenA), 
            address(0), 
            amountTokenIn, 
            amountETHIn,
            duration,
            uint16(_bound(feeLevelSeed, 0, BIP_DIVISOR)),
            ILiquidityVault.CollectFeeOption(_bound(collectFeeOptionSeed, 0, 2)),
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

    function test_feeChange(ILiquidityVault.FeeInfo memory feeSeeds, uint16 feeLevelSeed) external {
        vm.skip(true);
        // solhint-disable-next-line
        bytes4 INVALID_FEE = bytes4(keccak256("InvalidFee()"));
        // solhint-disable-next-line
        bytes4 INVALID_FEE_LEVEL = bytes4(keccak256("InvalidFeeLevel()"));

        ILiquidityVault.FeeInfo memory oldFeeInfo;
        (, , oldFeeInfo) = lVault.mintFee(false, 0);

        uint160 mintMaxFee = uint160(_bound(feeSeeds.mintMaxFee, 0, type(uint144).max));
        uint16 refCollectFeeCutBIPS = uint16(_bound(feeSeeds.refCollectFeeCutBIPS, 0, BIP_DIVISOR));
        uint16 upperLimitProtCollectFee = uint16((BIP_DIVISOR - refCollectFeeCutBIPS) < oldFeeInfo.procotolCollectMinFeeCutBIPS ? (BIP_DIVISOR - refCollectFeeCutBIPS) : oldFeeInfo.procotolCollectMinFeeCutBIPS);
        uint16 procotolCollectMinFeeCutBIPS = uint16(_bound(feeSeeds.refCollectFeeCutBIPS, 0, upperLimitProtCollectFee));

        ILiquidityVault.FeeInfo memory invalidFeeInfo = ILiquidityVault.FeeInfo({
            mintMaxFee: mintMaxFee,
            refMintFeeCutBIPS: uint16(_bound(feeSeeds.refMintFeeCutBIPS, BIP_DIVISOR + 1, type(uint16).max)),
            refCollectFeeCutBIPS: refCollectFeeCutBIPS,
            refMintDiscountBIPS: uint16(_bound(feeSeeds.refMintDiscountBIPS, 0, BIP_DIVISOR)),
            mintMaxDiscountBIPS: uint16(_bound(feeSeeds.mintMaxDiscountBIPS, 0, BIP_DIVISOR)),
            procotolCollectMinFeeCutBIPS: procotolCollectMinFeeCutBIPS
        });
        
        vm.expectRevert(INVALID_FEE);
        lVault.setFees(invalidFeeInfo);

        ILiquidityVault.FeeInfo memory invalidFeeInfo1 = ILiquidityVault.FeeInfo({
            mintMaxFee: mintMaxFee,
            refMintFeeCutBIPS: uint16(_bound(feeSeeds.refMintFeeCutBIPS, 0, BIP_DIVISOR)),
            refCollectFeeCutBIPS: uint16(_bound(feeSeeds.refCollectFeeCutBIPS, BIP_DIVISOR + 1, type(uint16).max)),
            refMintDiscountBIPS: uint16(_bound(feeSeeds.refMintDiscountBIPS, 0, BIP_DIVISOR)),
            mintMaxDiscountBIPS: uint16(_bound(feeSeeds.mintMaxDiscountBIPS, 0, BIP_DIVISOR)),
            procotolCollectMinFeeCutBIPS: procotolCollectMinFeeCutBIPS
        });
        vm.expectRevert(INVALID_FEE);
        lVault.setFees(invalidFeeInfo1);
        
        ILiquidityVault.FeeInfo memory invalidFeeInfo2 = ILiquidityVault.FeeInfo({
            mintMaxFee: mintMaxFee,
            refMintFeeCutBIPS: uint16(_bound(feeSeeds.refMintFeeCutBIPS, 0, BIP_DIVISOR)),
            refCollectFeeCutBIPS: refCollectFeeCutBIPS,
            refMintDiscountBIPS: uint16(_bound(feeSeeds.refMintDiscountBIPS, BIP_DIVISOR + 1, type(uint16).max)),
            mintMaxDiscountBIPS: uint16(_bound(feeSeeds.mintMaxDiscountBIPS, 0, BIP_DIVISOR)),
            procotolCollectMinFeeCutBIPS: procotolCollectMinFeeCutBIPS
        });
        vm.expectRevert(INVALID_FEE);
        lVault.setFees(invalidFeeInfo2);

        ILiquidityVault.FeeInfo memory invalidFeeInfo3 = ILiquidityVault.FeeInfo({
            mintMaxFee: mintMaxFee,
            refMintFeeCutBIPS: uint16(_bound(feeSeeds.refMintFeeCutBIPS, 0, BIP_DIVISOR)),
            refCollectFeeCutBIPS: refCollectFeeCutBIPS,
            refMintDiscountBIPS: uint16(_bound(feeSeeds.refMintDiscountBIPS, 0, BIP_DIVISOR)),
            mintMaxDiscountBIPS: uint16(_bound(feeSeeds.mintMaxDiscountBIPS, BIP_DIVISOR + 1, type(uint16).max)),
            procotolCollectMinFeeCutBIPS: procotolCollectMinFeeCutBIPS
        });
        vm.expectRevert(INVALID_FEE);
        lVault.setFees(invalidFeeInfo3);


        ILiquidityVault.FeeInfo memory invalidFeeInfo4 = ILiquidityVault.FeeInfo({
            mintMaxFee: mintMaxFee,
            refMintFeeCutBIPS: uint16(_bound(feeSeeds.refMintFeeCutBIPS, 0, BIP_DIVISOR)),
            refCollectFeeCutBIPS: refCollectFeeCutBIPS,
            refMintDiscountBIPS: uint16(_bound(feeSeeds.refMintDiscountBIPS, 0, BIP_DIVISOR)),
            mintMaxDiscountBIPS: uint16(_bound(feeSeeds.mintMaxDiscountBIPS, 0, BIP_DIVISOR)),
            procotolCollectMinFeeCutBIPS: uint16(_bound(feeSeeds.procotolCollectMinFeeCutBIPS, oldFeeInfo.procotolCollectMinFeeCutBIPS + 1, type(uint16).max))
        });
        vm.expectRevert(INVALID_FEE);
        lVault.setFees(invalidFeeInfo4);

        ILiquidityVault.FeeInfo memory validFeeInfo = ILiquidityVault.FeeInfo({
            mintMaxFee: mintMaxFee,
            refMintFeeCutBIPS: uint16(_bound(feeSeeds.refMintFeeCutBIPS, 0, BIP_DIVISOR)),
            refCollectFeeCutBIPS: refCollectFeeCutBIPS,
            refMintDiscountBIPS: uint16(_bound(feeSeeds.refMintDiscountBIPS, 0, BIP_DIVISOR)),
            mintMaxDiscountBIPS: uint16(_bound(feeSeeds.mintMaxDiscountBIPS, 0, BIP_DIVISOR)),
            procotolCollectMinFeeCutBIPS: procotolCollectMinFeeCutBIPS
        });
        lVault.setFees(validFeeInfo);

        console.log("validFeeInfo.mintMaxFee:                   %d", validFeeInfo.mintMaxFee);
        console.log("validFeeInfo.refMintFeeCutBIPS:            %d", validFeeInfo.refMintFeeCutBIPS);
        console.log("validFeeInfo.refCollectFeeCutBIPS:         %d", validFeeInfo.refCollectFeeCutBIPS);
        console.log("validFeeInfo.refMintDiscountBIPS:          %d", validFeeInfo.refMintDiscountBIPS);
        console.log("validFeeInfo.mintMaxDiscountBIPS:          %d", validFeeInfo.mintMaxDiscountBIPS);
        console.log("validFeeInfo.procotolCollectMinFeeCutBIPS: %d", validFeeInfo.procotolCollectMinFeeCutBIPS);

        (uint256 mintFee, uint256 refMintFeeCut) = (0, 0);
        uint16 feeLevelBIPS = uint16(_bound(feeLevelSeed, 0, BIP_DIVISOR));
        vm.expectRevert(INVALID_FEE_LEVEL);
        (mintFee, refMintFeeCut, ) = lVault.mintFee(false, uint16(_bound(feeLevelBIPS, BIP_DIVISOR + 1, type(uint16).max)));

        (uint minFee, uint maxFee) = (validFeeInfo.mintMaxFee - validFeeInfo.mintMaxFee * uint(validFeeInfo.mintMaxDiscountBIPS) / BIP_DIVISOR, validFeeInfo.mintMaxFee);
        uint refMintFee = validFeeInfo.mintMaxFee - validFeeInfo.mintMaxFee * uint(validFeeInfo.refMintDiscountBIPS) / BIP_DIVISOR;
        console.log("minFee, maxFee: %d, %d", minFee, maxFee);
        (mintFee, refMintFeeCut, ) = lVault.mintFee(false, 0);
        assertEq(mintFee, maxFee);
        assertEq(refMintFeeCut, 0);

        (mintFee, refMintFeeCut, ) = lVault.mintFee(true, 0);
        assertEq(mintFee, refMintFee);
        assertEq(refMintFeeCut, refMintFee * validFeeInfo.refMintFeeCutBIPS / BIP_DIVISOR);

        (mintFee, refMintFeeCut, ) = lVault.mintFee(false, uint16(BIP_DIVISOR));
        assertEq(mintFee, minFee);
        assertEq(refMintFeeCut, 0);

        (mintFee, refMintFeeCut, ) = lVault.mintFee(true, uint16(BIP_DIVISOR));
        assertEq(mintFee, refMintFee);
        assertEq(refMintFeeCut, mintFee * validFeeInfo.refMintFeeCutBIPS / BIP_DIVISOR);

        console.log("feeLevel: %d", uint16(_bound(feeLevelBIPS, 1, BIP_DIVISOR-1)));
        (mintFee, refMintFeeCut, ) = lVault.mintFee(false, uint16(_bound(feeLevelBIPS, 1, BIP_DIVISOR-1)));
        assertLe(mintFee, maxFee);
        assertGe(mintFee, minFee);
    }

    function test_migration(uint ethSeed, uint durationSeed, uint feeLevelSeed, uint collectFeeOptionSeed, bool isLPToken) external logRecorder {
        vm.skip(true);
        ISuccessor successor = new MockMigrationContract();
        lVault.setSuccessor(address(successor));

        startHoax(msg.sender);
        uint32 duration = uint32(_bound(durationSeed, MIN_LOCK_DURATION, lVault.LOCK_FOREVER() - 1)); // duration
        uint amountETHIn = _bound(ethSeed, 0.1 ether, 70 ether);
        (uint id, address token, address pool, LiquidityVault.Snapshot memory snapshot, bool isToken0, , ,) = _mintLockedLPPosition(
            isLPToken,
            address(0), 
            address(0), 
            0, 
            amountETHIn,
            duration,
            uint16(_bound(feeLevelSeed, 0, BIP_DIVISOR)),
            ILiquidityVault.CollectFeeOption(_bound(collectFeeOptionSeed, 0, 2)),
            bytes4("")
        );

        IERC20 pair = IERC20(pool);
        uint totalLiquidity = pair.totalSupply();
        uint ethExpected = snapshot.liquidity * IERC20(!isToken0 ? snapshot.token0 : snapshot.token1).balanceOf(pool) / totalLiquidity;

        address newToken = lVault.migrate(id, snapshot, bytes(""));

        assertEq(IERC20(newToken).totalSupply(), IERC20(token).totalSupply());
        assertEq(IERC20(newToken).balanceOf(address(successor)), IERC20(token).balanceOf(DEAD_ADDRESS));
        assertEq(IERC20(newToken).totalSupply() - IERC20(newToken).balanceOf(address(successor)), IERC20(newToken).balanceOf(newToken));
        assertEq(address(successor).balance, ethExpected);

    }

    function test_transfer(address reciever, uint durationSeed, uint ethSeed, uint feeLevelSeed, uint collectFeeOptionSeed, bool isLPToken) external logRecorder {
        vm.skip(true);
        vm.assume(reciever != address(0));

        // solhint-disable-next-line
        bytes4 NOT_OWNER = bytes4(keccak256("NotOwnerNorApproved()"));


        startHoax(msg.sender);
        uint32 duration = uint32(_bound(durationSeed, MIN_LOCK_DURATION, lVault.LOCK_FOREVER() - 1)); // duration
        uint amountETHIn = _bound(ethSeed, 0.1 ether, 70 ether);
        (uint id, , , LiquidityVault.Snapshot memory snapshot, , , ,) = _mintLockedLPPosition(
            isLPToken,
            address(0), 
            address(0), 
            0, 
            amountETHIn,
            duration,
            uint16(_bound(feeLevelSeed, 0, BIP_DIVISOR)),
            ILiquidityVault.CollectFeeOption(_bound(collectFeeOptionSeed, 0, 2)),
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

    function test_extendAfterGracePeriod(uint durationSeed, uint feeLevelSeed, uint newDurationSeed, uint newFeeLevelSeed, uint collectFeeOptionSeed, uint advanceSeed, bool isLPToken) external logRecorder {
        vm.skip(true);
        // solhint-disable-next-line
        bytes4 INSUFFICIENT_FUNDS = bytes4(keccak256("InsufficientFunds()"));

        cachedTimestamp = uint(block.timestamp);
        uint GRACE_PERIOD = MIN_LOCK_DURATION * 4 / 10;

        uint32 LOCK_FOREVER = lVault.LOCK_FOREVER();
        uint32 duration = uint32(_bound(durationSeed, MIN_LOCK_DURATION, LOCK_FOREVER - 1)); // duration
        uint16 feeLevelBIPS = uint16(_bound(feeLevelSeed, 1, BIP_DIVISOR));

        startHoax(msg.sender);

        (uint id, , , LiquidityVault.Snapshot memory snapshot, , , , LiquidityVault.FeeInfo memory feeInfo) = _mintLockedLPPosition(
            isLPToken,
            address(0), 
            address(0), 
            0, 
            1 ether,
            duration,
            feeLevelBIPS,
            ILiquidityVault.CollectFeeOption(_bound(collectFeeOptionSeed, 0, 2)),
            bytes4("")
        );

        vm.warp(_bound(advanceSeed, cachedTimestamp + duration - GRACE_PERIOD, cachedTimestamp + duration + MIN_LOCK_DURATION));

        uint16 newFeeLevelBIPS = uint16(_bound(newFeeLevelSeed, 0, feeLevelBIPS - 1));
        vm.expectRevert(INSUFFICIENT_FUNDS);
        lVault.extend(id, uint32(_bound(newDurationSeed, MIN_LOCK_DURATION, LOCK_FOREVER - 1)), newFeeLevelBIPS, address(0), address(0));

        uint feeOwed = feeInfo.mintMaxFee * (feeLevelBIPS - newFeeLevelBIPS) / BIP_DIVISOR;
        lVault.extend{ value: feeOwed }(id, uint32(_bound(newDurationSeed, MIN_LOCK_DURATION, LOCK_FOREVER - 1)), newFeeLevelBIPS, address(0), address(0));
        
    }

     function test_extendFirstTimeReferrer(address referrer, address buyer, uint buySeed, uint durationSeed, uint newDurationSeed, uint feeLevelSeed, uint newFeeLevelSeed, uint collectFeeOptionSeed, uint advanceSeed, bool isLPToken) external logRecorder {
        vm.skip(true);

        vm.assume(referrer > address(9));
        lVault.setReferrer(referrer, true);

        cachedTimestamp = uint(block.timestamp);
        uint GRACE_PERIOD = MIN_LOCK_DURATION * 4 / 10;

        uint32 LOCK_FOREVER = lVault.LOCK_FOREVER();
        uint32 duration = uint32(_bound(durationSeed, MIN_LOCK_DURATION, LOCK_FOREVER - 1)); // duration
        uint16 feeLevelBIPS = uint16(_bound(feeLevelSeed, 0, BIP_DIVISOR));

        startHoax(msg.sender);

        (uint id, address token, address pool, LiquidityVault.Snapshot memory snapshot, bool isToken0, , , LiquidityVault.FeeInfo memory feeInfo) = _mintLockedLPPosition(
            isLPToken,
            address(0), 
            address(0), 
            0, 
            1 ether,
            duration,
            feeLevelBIPS,
            ILiquidityVault.CollectFeeOption(_bound(collectFeeOptionSeed, 0, 2)),
            bytes4("")
        );

        vm.stopPrank();

        snapshot = _verifyReferralFees(id, address(0), snapshot, buyer, isToken0, pool, buySeed);

        vm.warp(_bound(advanceSeed, cachedTimestamp + duration - GRACE_PERIOD, cachedTimestamp + duration + GRACE_PERIOD));

        uint32 extendedDuration = uint32(_bound(newDurationSeed, MIN_LOCK_DURATION, LOCK_FOREVER - 1));
        lVault.extend(id, extendedDuration, uint16(BIP_DIVISOR), address(0), referrer);

        _verifyReferralFees(id, referrer, snapshot, buyer, isToken0, pool, buySeed);
    }

    function test_extendIgnoredReferrerToNewReferrer(address referrer, address newReferrer, address buyer, uint buySeed, uint durationSeed, uint feeLevelSeed, bool technicallyCorrectOldReferrer, uint newFeeLevelSeed, uint collectFeeOptionSeed, uint advanceSeed, uint newRefFeeCutSeed, bool isLPToken) external logRecorder {
        vm.skip(true);

        vm.assume(referrer > address(9));
        vm.assume(newReferrer > address(9) && newReferrer != referrer);
        vm.assume(referrer.code.length == 0);
        vm.assume(newReferrer.code.length == 0);
        lVault.setReferrer(referrer, true);
        lVault.setReferrer(newReferrer, true);

        cachedTimestamp = uint(block.timestamp);
        uint GRACE_PERIOD = MIN_LOCK_DURATION * 4 / 10;

        uint32 LOCK_FOREVER = lVault.LOCK_FOREVER();
        uint32 duration = uint32(_bound(durationSeed, MIN_LOCK_DURATION, LOCK_FOREVER - 1)); // duration
        uint16 feeLevelBIPS = uint16(_bound(feeLevelSeed, 0, BIP_DIVISOR));

        (, uint refMintFeeCut, LiquidityVault.FeeInfo memory _feeInfo) = lVault.mintFee(true, feeLevelBIPS);
        _feeInfo.refMintFeeCutBIPS = uint16(_bound(newRefFeeCutSeed, 0, BIP_DIVISOR));
        lVault.setFees(_feeInfo);
        (, refMintFeeCut, ) = lVault.mintFee(true, feeLevelBIPS);

        startHoax(msg.sender);

        (uint id, , address pool, LiquidityVault.Snapshot memory snapshot, bool isToken0, , , LiquidityVault.FeeInfo memory feeInfo) = _mintLockedLPPosition(
            isLPToken,
            address(0), 
            referrer, 
            0, 
            1 ether,
            duration,
            feeLevelBIPS,
            ILiquidityVault.CollectFeeOption(_bound(collectFeeOptionSeed, 0, 2)),
            bytes4("")
        );

        console.log("cachedTimestamp: %d", cachedTimestamp);
        console.log("duration: %d", duration);
        console.log("GRACE_PERIOD: %d", GRACE_PERIOD);

        uint newTime = _bound(advanceSeed, cachedTimestamp + duration - GRACE_PERIOD, cachedTimestamp + duration + GRACE_PERIOD);
        console.log("newTime: %d", newTime);
        vm.warp(newTime);
        lVault.extend(id, MIN_LOCK_DURATION, uint16(BIP_DIVISOR), referrer, address(0));

        snapshot = _verifyReferralFees(id, address(0), snapshot, buyer, isToken0, pool, buySeed);

        vm.warp(newTime + MIN_LOCK_DURATION);

        vm.expectRevert();
        lVault.extend(id, MIN_LOCK_DURATION, uint16(BIP_DIVISOR), address(0), newReferrer);

        if (refMintFeeCut > 0) vm.expectRevert();
        lVault.extend(id, MIN_LOCK_DURATION, uint16(BIP_DIVISOR), referrer, newReferrer);

        if (refMintFeeCut > 0) {
            LiquidityVaultPayMaster.ClaimParams[] memory params = new LiquidityVaultPayMaster.ClaimParams[](1);
            uint[] memory fee0s = new uint[](0);
            uint[] memory fee1s = new uint[](0);

            params[0] = LiquidityVaultPayMaster.ClaimParams({
                id: id,
                referrer: referrer,
                snapshot: snapshot,
                mintFee: refMintFeeCut,
                fee0s: fee0s,
                fee1s: fee1s
            });
            payMaster.claimReferralFees(params); 

            lVault.extend(id, MIN_LOCK_DURATION, uint16(BIP_DIVISOR), referrer, newReferrer);
        }

        _verifyReferralFees(id, newReferrer, snapshot, buyer, isToken0, pool, buySeed);
        
    }

    function test_extendReferrerToNewReferrer(address referrer, address newReferrer, address buyer, uint buySeed, uint durationSeed, uint feeLevelSeed, uint newFeeLevelSeed, uint collectFeeOptionSeed, uint advanceSeed, uint newRefFeeCutSeed, bool isLPToken) external logRecorder {
        vm.skip(false);

        vm.assume(referrer > address(9));
        vm.assume(newReferrer > address(9) && newReferrer != referrer);
        vm.assume(referrer.code.length == 0);
        vm.assume(newReferrer.code.length == 0);
        vm.assume(referrer != 0x000000000000000000636F6e736F6c652e6c6f67);
        vm.assume(newReferrer != 0x000000000000000000636F6e736F6c652e6c6f67);

        lVault.setReferrer(referrer, true);
        lVault.setReferrer(newReferrer, true);

        cachedTimestamp = uint(block.timestamp);
        uint GRACE_PERIOD = MIN_LOCK_DURATION * 4 / 10;

        uint32 LOCK_FOREVER = lVault.LOCK_FOREVER();
        uint32 duration = uint32(_bound(durationSeed, MIN_LOCK_DURATION, LOCK_FOREVER - 1)); // duration
        uint16 feeLevelBIPS = uint16(_bound(feeLevelSeed, 0, BIP_DIVISOR));

        (, uint refMintFeeCut, LiquidityVault.FeeInfo memory _feeInfo) = lVault.mintFee(true, feeLevelBIPS);
        _feeInfo.refMintFeeCutBIPS = uint16(_bound(newRefFeeCutSeed, 0, BIP_DIVISOR));
        lVault.setFees(_feeInfo);
        (, refMintFeeCut, ) = lVault.mintFee(true, feeLevelBIPS);

        startHoax(msg.sender);
        (uint id, , address pool, LiquidityVault.Snapshot memory snapshot, bool isToken0, , , LiquidityVault.FeeInfo memory feeInfo) = _mintLockedLPPosition(
            isLPToken,
            address(0), 
            referrer, 
            0, 
            1 ether,
            duration,
            feeLevelBIPS,
            ILiquidityVault.CollectFeeOption(_bound(collectFeeOptionSeed, 0, 2)),
            bytes4("")
        );

        uint newTime = _bound(advanceSeed, cachedTimestamp + duration - GRACE_PERIOD, cachedTimestamp + duration + GRACE_PERIOD);
        vm.warp(newTime);

        if (refMintFeeCut > 0) vm.expectRevert();
        lVault.extend(id, MIN_LOCK_DURATION, uint16(BIP_DIVISOR), referrer, newReferrer);

        if (refMintFeeCut > 0) {
            LiquidityVaultPayMaster.ClaimParams[] memory params = new LiquidityVaultPayMaster.ClaimParams[](1);
            uint[] memory fee0s = new uint[](0);
            uint[] memory fee1s = new uint[](0);

            params[0] = LiquidityVaultPayMaster.ClaimParams({
                id: id,
                referrer: referrer,
                snapshot: snapshot,
                mintFee: refMintFeeCut,
                fee0s: fee0s,
                fee1s: fee1s
            });
            payMaster.claimReferralFees(params); 

            lVault.extend(id, MIN_LOCK_DURATION, uint16(BIP_DIVISOR), referrer, newReferrer);
        }

        _verifyReferralFees(id, newReferrer, snapshot, buyer, isToken0, pool, buySeed);
    }

    function test_extendBeforeGracePeriod(uint durationSeed, uint feeLevelSeed, uint newFeeLevelSeed, uint collectFeeOptionSeed, bool isLPToken) external logRecorder {
        vm.skip(true);
        cachedTimestamp = uint(block.timestamp);
        uint GRACE_PERIOD = MIN_LOCK_DURATION * 4 / 10;

        uint32 duration = uint32(_bound(durationSeed, MIN_LOCK_DURATION, lVault.LOCK_FOREVER() - 1)); // duration
        uint16 feeLevelBIPS = uint16(_bound(feeLevelSeed, 1, BIP_DIVISOR));

        startHoax(msg.sender);
        (uint id, , , LiquidityVault.Snapshot memory snapshot, , , ,) = _mintLockedLPPosition(
            isLPToken,
            address(0), 
            address(0), 
            0, 
            1 ether,
            duration,
            feeLevelBIPS,
            ILiquidityVault.CollectFeeOption(_bound(collectFeeOptionSeed, 0, 2)),
            bytes4("")
        );

        vm.warp(cachedTimestamp + duration - (GRACE_PERIOD + 1));

        lVault.extend(id, MIN_LOCK_DURATION, uint16(_bound(newFeeLevelSeed, 0, feeLevelBIPS-1)), address(0), address(0));

        /*
            Scenerios to test
            early extend

            paying off feeLevel delta

            1. referrer to no referrer.. if referrer is no longer registered, then the referrer should be set to address(0)
            2. referrer to new referrer.. if referrer is registered, then the referrer should be set to the new referrer
            3. referrer to same referrer.. if referrer is the same as the current referrer, then the referrer should not be changed 
            4. referrer to no referrer to referrer.. if referrer is the same as the current referrer, then the referrer should not be changed 
            5. no referrer to new referrer.. if referrer is not registered, then the referrer should be set to the new referrer

            grace period and minimun duration
        */
    }

    address[] wallets;
    function test_referral(uint seed, uint immediateCollectSeed, address referrer, uint claimSeed, uint collectSeed, uint buySeed, uint sellSeed, uint feeLevelSeed, uint collectFeeOptionSeed, uint changeFeeOptionSeed, ILiquidityVault.FeeInfo memory feeInfoSeed, bool isLPToken) external logRecorder {
        vm.skip(true);
        // solhint-disable-next-line
        bytes4 NOT_REGISTERED = bytes4(keccak256("NotRegisteredRefferer()"));

        uint16 feeLevelBIPS = uint16(_bound(feeLevelSeed, 0, BIP_DIVISOR));
        ILiquidityVault.CollectFeeOption collectFeeOption = ILiquidityVault.CollectFeeOption(_bound(collectFeeOptionSeed, 0, 2));



        vm.assume(referrer > address(9));
        startHoax(msg.sender);

        uint32 LOCK_FOREVER = lVault.LOCK_FOREVER();
        (uint id, address token, address pool, ILiquidityVault.Snapshot memory snapshot, bool isToken0, uint mintFee, uint rMintFee, ILiquidityVault.FeeInfo memory feeInfo) = _mintLockedLPPosition(
            isLPToken,
            address(0),
            referrer,
            0,
            _bound(seed, 0.1 ether, 70 ether),
            LOCK_FOREVER,
            feeLevelBIPS,
            collectFeeOption,
            NOT_REGISTERED
        );

        vm.stopPrank();

        feeInfo.mintMaxFee = uint160(_bound(feeInfoSeed.mintMaxFee, 0, 70 ether));
        feeInfo.refMintFeeCutBIPS = uint16(_bound(feeInfoSeed.refMintFeeCutBIPS, 0, BIP_DIVISOR));
        feeInfo.refCollectFeeCutBIPS = uint16(_bound(feeInfoSeed.refCollectFeeCutBIPS, 0, BIP_DIVISOR));
        feeInfo.refMintDiscountBIPS = uint16(_bound(feeInfoSeed.refMintDiscountBIPS, 0, BIP_DIVISOR));
        feeInfo.mintMaxDiscountBIPS = uint16(_bound(feeInfoSeed.mintMaxDiscountBIPS, 0, BIP_DIVISOR));
        feeInfo.procotolCollectMinFeeCutBIPS = uint16(_bound(feeInfoSeed.procotolCollectMinFeeCutBIPS, 0, feeInfo.procotolCollectMinFeeCutBIPS));

        lVault.setFees(feeInfo);        
        lVault.setReferrer(referrer, true);

        startHoax(msg.sender);
        (id, token, pool, snapshot, isToken0, mintFee, rMintFee, feeInfo) = _mintLockedLPPosition(
            isLPToken,
            address(0),
            referrer,
            0,
            _bound(seed, 0.1 ether, 70 ether),
            LOCK_FOREVER,
            feeLevelBIPS,
            collectFeeOption,
            bytes4("")
        );
        

        if (Probability({ seed: immediateCollectSeed, chance: 50 }).isLikely()) {
            assertEq(rMintFee, mintFee * feeInfo.refMintFeeCutBIPS / BIP_DIVISOR);
            uint refStartBal = address(referrer).balance;

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
            assertEq(rMintFee, address(referrer).balance - refStartBal);
            rMintFee = 0;
        }

        Probability memory changeFeeOptionProbability = Probability({ chance: 20, seed: changeFeeOptionSeed });
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
                changeFeeOptionProbability.seed += i;
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

            
            if (changeFeeOptionProbability.isLikely()) {
                uint _dynamicFeeOptionSeed;
                unchecked { _dynamicFeeOptionSeed = collectFeeOptionSeed + i; }
                collectFeeOption = ILiquidityVault.CollectFeeOption(_bound(_dynamicFeeOptionSeed, 0, 2));
                startHoax(msg.sender);
                lVault.setCollectFeeOption(id, collectFeeOption);
                vm.stopPrank();
            }

            if (collectProbability.isLikely() || i == N - 1) {
                (uint startBal0, uint startBal1) = snapshot.token0 == WETH ? 
                    (address(msg.sender).balance, IERC20(snapshot.token1).balanceOf(msg.sender)) :
                    (IERC20(snapshot.token0).balanceOf(msg.sender), address(msg.sender).balance); 

                (uint startRefBal0, uint startRefBal1) = snapshot.token0 == WETH ? 
                    (address(payMaster).balance, IERC20(snapshot.token1).balanceOf(address(payMaster))) :
                    (IERC20(snapshot.token0).balanceOf(address(payMaster)), address(payMaster).balance); 

                (uint startPBal0, uint startPBal1) = snapshot.token0 == WETH ? 
                    (address(this).balance, IERC20(snapshot.token1).balanceOf(address(this))) :
                    (IERC20(snapshot.token0).balanceOf(address(this)), address(this).balance); 

                try lVault.collect(id, snapshot) returns (ILiquidityVault.Fees memory fees) {
                    (uint rFee0, uint rFee1) = (0, 0);
                    (uint ownerFee0, uint ownerFee1) = (0, 0);
                    (snapshot, , rFee0, rFee1, ownerFee0, ownerFee1) = _getLiquidityVaultLog(token, WETH);
                    assertEq(fees.ownerFee0, ownerFee0);
                    assertEq(fees.ownerFee1, ownerFee1);
                    assertEq(fees.referralCut0, rFee0);
                    assertEq(fees.referralCut1, rFee1);

                    fee0sBig[feeCount] = rFee0;
                    fee1sBig[feeCount] = rFee1;
                    feeCount += 1;

                    console.log("collect feeCount: %d", feeCount);


                    (uint lastBal0, uint lastBal1) = snapshot.token0 == WETH ? 
                        (address(msg.sender).balance, IERC20(snapshot.token1).balanceOf(msg.sender)) :
                        (IERC20(snapshot.token0).balanceOf(msg.sender), address(msg.sender).balance); 

                    (uint lastRefBal0, uint lastRefBal1) = snapshot.token0 == WETH ? 
                        (address(payMaster).balance, IERC20(snapshot.token1).balanceOf(address(payMaster))) :
                        (IERC20(snapshot.token0).balanceOf(address(payMaster)), address(payMaster).balance); 

                    (uint lastPBal0, uint lastPBal1) = snapshot.token0 == WETH ? 
                        (address(this).balance, IERC20(snapshot.token1).balanceOf(address(this))) :
                        (IERC20(snapshot.token0).balanceOf(address(this)), address(this).balance); 
                    
                    assertEq(ownerFee0, lastBal0 - startBal0);
                    assertEq(ownerFee1, lastBal1 - startBal1);

                    assertEq(fees.referralCut0, lastRefBal0 - startRefBal0);
                    assertEq(fees.referralCut1, lastRefBal1 - startRefBal1);

                    assertEq(fees.cut0 - fees.referralCut0, lastPBal0 - startPBal0);
                    assertEq(fees.cut1 - fees.referralCut1, lastPBal1 - startPBal1);

                    if (collectFeeOption == ILiquidityVault.CollectFeeOption.BOTH) {
                        assertGt(ownerFee0, 0);
                        assertGt(ownerFee1, 0);
                    }
                    if (collectFeeOption == ILiquidityVault.CollectFeeOption.TOKEN_0) {
                        assertGt(ownerFee0, 0);
                        assertEq(ownerFee1, 0);
                    }
                    if (collectFeeOption == ILiquidityVault.CollectFeeOption.TOKEN_1) {
                        assertEq(ownerFee0, 0);
                        assertGt(ownerFee1, 0);
                    }

                    if (snapshot.token0 == WETH) {
                        if (feeInfo.refCollectFeeCutBIPS + feeInfo.procotolCollectMinFeeCutBIPS > 0) assertGt(fees.cut0, 0);
                        assertEq(fees.cut1, 0);
                        if (feeInfo.refCollectFeeCutBIPS == 0) assertEq(lastRefBal0 - startRefBal0, 0);
                        if (feeInfo.procotolCollectMinFeeCutBIPS == 0) assertEq(lastPBal0 - startPBal0, 0);
                    }
                    if (snapshot.token1 == WETH) {
                        if (feeInfo.refCollectFeeCutBIPS + feeInfo.procotolCollectMinFeeCutBIPS > 0) assertGt(fees.cut1, 0);
                        assertEq(fees.cut0, 0);
                        if (feeInfo.refCollectFeeCutBIPS == 0) assertEq(lastRefBal1 - startRefBal1, 0);
                        if (feeInfo.procotolCollectMinFeeCutBIPS == 0) assertEq(lastPBal1 - startPBal1, 0);
                    }

                    console.log("fees.cut0:      %d", fees.cut0);
                    console.log("fees.ownerFee0: %d", fees.ownerFee0);

                    console.log("fees.cut1:      %d", fees.cut1);
                    console.log("fees.ownerFee1: %d", fees.ownerFee1);
                    
                    console.log("feeInfo.refCollectFeeCutBIPS:         %d", feeInfo.refCollectFeeCutBIPS);
                    console.log("feeInfo.procotolCollectMinFeeCutBIPS: %d", feeInfo.procotolCollectMinFeeCutBIPS);


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

                        // Refs should only take fees in ETH
                        if (snapshot.token0 == WETH) assertEq(fee1Sum, 0);
                        if (snapshot.token1 == WETH) assertEq(fee0Sum, 0);

                        assertEq(fee0Sum, endRBal0 - startRBal0);
                        assertEq(fee1Sum, endRBal1 - startRBal1);
                    }
                } catch Error(string memory reason) {
                    // This catch block will only catch errors with a string reason
                    if (keccak256(bytes(reason)) == keccak256(bytes("InsufficientLiquidityBurned()"))) {
                        // Handle the specific error
                        console.log("Caught specific error:", reason);
                    } else {
                        // Optionally, rethrow other errors
                        revert(reason);
                    }
                } catch (bytes memory lowLevelData) {
                    // This catch block will catch any other errors (like assert failures or out-of-gas errors)
                    console.log("Caught low-level error");
                    revert();
                    // Optionally, you can decode the lowLevelData if needed
                }
            }
        }
        delete wallets;
    }

    function test_collect(uint durationSeed, uint ethSeed, uint preMintSeed, uint collectSeed, uint buySeed, uint sellSeed, uint advanceSeed, uint feeLevelSeed, uint collectFeeOptionSeed, bool isLPToken) external logRecorder {
        vm.skip(true);
        lVault.setFees(ILiquidityVault.FeeInfo({
            mintMaxFee: 0.1 ether,
            refMintFeeCutBIPS: 0,
            refCollectFeeCutBIPS: 0,
            refMintDiscountBIPS: uint16(BIP_DIVISOR),
            mintMaxDiscountBIPS: uint16(BIP_DIVISOR),
            procotolCollectMinFeeCutBIPS: 0
        }));

        startHoax(msg.sender);

        uint BIP_K_TOLERANCE = 5;
        uint BIP_PRICE_TOLERANCE = 5;

        uint256 amountInETH = _bound(ethSeed, 0.1 ether, 70 ether);
        uint32 duration = uint32(_bound(durationSeed, MIN_LOCK_DURATION, uint(lVault.LOCK_FOREVER())));
        uint unlockTime = block.timestamp + duration;
        console.log("block.timestamp: %d", block.timestamp);
        console.log("unlockTime: %d", unlockTime);

        uint id;
        address token;
        address pool; 
        bool isToken0;
        ILiquidityVault.Snapshot memory snapshot;

        uint preSeedCount = _bound(preMintSeed, 0, 256);

        for (uint i; i < preSeedCount; i++) {
            (id, , pool, snapshot, isToken0, , ,) = _mintLockedLPPosition(
                isLPToken,
                address(0),
                address(0),
                0,
                amountInETH,
                duration,
                uint16(_bound(feeLevelSeed, 0, BIP_DIVISOR)),
                ILiquidityVault.CollectFeeOption.BOTH,
                bytes4("")
            );
        }

        (id, token, pool, snapshot, isToken0, , ,) = _mintLockedLPPosition(
            isLPToken,
            address(0),
            address(0),
            0,
            amountInETH,
            duration,
            0,
            ILiquidityVault.CollectFeeOption.BOTH,
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
                last_price = snapshot.token0 == WETH ? r0 * 10 ** 18 / r1 : r1 * 10 ** 18 / r0;
            }

            if (collectProbability.isLikely() || i == N - 1) {
                try lVault.collect(id, snapshot) {
                    (snapshot, , , , ,) = _getLiquidityVaultLog(snapshot.token0, snapshot.token1);
                    (r0, r1, ) = IUniswapV2Pair(pool).getReserves();
                    uint k = r0 * r1;
                    uint price = snapshot.token0 == WETH ? r0 * 10 ** 18 / r1 : r1 * 10 ** 18 / r0;

                    uint priceDiffNumerator = price > last_price ? price - last_price : last_price - price;
                    uint kDiffNumerator = k > last_k ? k - last_k : last_k - k;

                    console.log("Price Check");
                    console.log("price:      %d", price);
                    console.log("last price: %d", last_price);
                    console.log("price diff: %d", priceDiffNumerator);
                    console.log("diffBIPS:   %d", priceDiffNumerator * BIP_DIVISOR / last_price);

                    console.log("K Check");
                    console.log("k:         %d", k);
                    console.log("last k:    %d", last_k);
                    console.log("k diff:    %d", kDiffNumerator);
                    console.log("diffBIPS:  %d", kDiffNumerator * BIP_DIVISOR / last_k);
                    assertLe(priceDiffNumerator * BIP_DIVISOR / last_price, BIP_PRICE_TOLERANCE);
                    assertLe(kDiffNumerator * BIP_DIVISOR / last_k, BIP_K_TOLERANCE);

                    last_k = k;
                    last_price = price;
                }
                catch {}
            }

            if (block.timestamp > unlockTime && duration != lVault.LOCK_FOREVER()) {
                startHoax(msg.sender);
                console.log("block.timestamp: %d", block.timestamp);
                console.log("unlockTime:      %d", unlockTime);
                lVault.redeem(id, snapshot, true);
                vm.stopPrank();
                break;
            }

        }

        delete wallets;

    }

    function test_mintBringLP() external {

    }
}