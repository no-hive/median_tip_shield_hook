// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {MedianPriorityFeeHook} from "../src/MPFHook.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract MPFHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;

    MedianPriorityFeeHook hook;
    PoolId poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    // ============================================================
    // SETUP
    // ============================================================

    function setUp() public {
        // Deploys all required artifacts.
        deployArtifactsAndLabel();

    MockERC20 token0;
    MockERC20 token1;

        (currency0, currency1) = deployCurrencyPair();

    token0 = MockERC20(Currency.unwrap(currency0));
    token1 = MockERC20(Currency.unwrap(currency1));


        address[] memory listedTokens = new address[](1);
        listedTokens[0] = address(token0);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x4444 << 144)
        );
        bytes memory constructorArgs = abi.encode(poolManager, listedTokens); // Add all the necessary constructor arguments from the hook
        deployCodeTo("MPFHook.sol:MedianPriorityFeeHook", constructorArgs, flags);
        hook = MedianPriorityFeeHook(flags);

        // Create the pool
        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        (tokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    // ============================================================
    // TEST 1: BASELINE SWAP - ONE FIRST SWAP
    // ============================================================

    // this function tests if the swap really occuries
    // while interacting with the pool woth hook connected.
    function testFirstSwap() public {
        uint256 amountIn = 1e18;

        uint256 balance0Before = currency0.balanceOf(address(this));
        uint256 balance1Before = currency1.balanceOf(address(this));

        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0, // Very bad, but we want to allow for unlimited price impact
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        uint256 balance0After = currency0.balanceOf(address(this));
        uint256 balance1After = currency1.balanceOf(address(this));

        assertEq(balance0Before - balance0After, amountIn, "token0 balance change != amountIn");
        assertGt(balance1After, balance1Before, "token1 balance did not increase");

        assertEq(swapDelta.amount0(), -int128(int256(amountIn)), "swapDelta.amount0 mismatch");
        assertGt(swapDelta.amount1(), 0, "swapDelta.amount1 should be positive");

        assertEq(
            balance1After - balance1Before,
            uint256(int256(swapDelta.amount1())),
            "actual balance delta != swapDelta.amount1"
        );
    }

    // ============================================================
    // TEST 2: 10 SWAPS WITH HIGH PRIORITY FEE INSIDE ONE BLOCK
    // ============================================================

    function testSwapWithHighPriorityFee() public {
        for (uint256 i = 0; i < 100; i++) {
            _helpSwapWithHighPriorityFee();
        }

        (int256 approxMedian,,) = hook.medianState();

        assertGt(approxMedian, 10, "approxMedian should be > 10 gwei");
    }

    // ============================================================
    // HELPER 1: HIGH FEE TRANSACTION
    // ============================================================

    function _helpSwapWithHighPriorityFee() internal {
        uint256 amountIn = 1e18;
        uint256 baseFee = 10 gwei;
        uint256 priorityFee = 50 gwei;

        vm.fee(baseFee);
        vm.txGasPrice(baseFee + priorityFee);

        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    // ============================================================
    // TEST 3: HIGH-FEE PRESSURE ACROSS MANY BLOCKS
    // ============================================================

    // Simulates sustained high-fee pressure: 10 high-fee swaps per block,
    // repeated for 20+ consecutive blocks.
    // Goal: check how the rolling median behaves when "abnormal" behavior
    // becomes the NEW normal over a long enough window. Unlike Test 2
    // (a one-block spike), the median here should have time to adapt.
    //
    // Key questions to check:
    // - What does the median end up being after N blocks of high fees?
    //   (should shift toward high values if the median window is
    //   shorter than the number of elapsed blocks)
    // - At which block does the median stop treating the high fee
    //   as an "anomaly" and start treating it as the norm?
    // - What penalty does a transaction with the SAME high fee get
    //   AFTER the median has shifted — should it be lower than the
    //   penalty from Test 2?
    //
    // Assertions:
    // - medianPriorityFee after 20+ blocks ≈ the high value
    //   (not still stuck at the "normal" baseline)
    // - penalty at block 21 for a high-fee swap < penalty at block 1
    //   of the burst (Test 2), since it's no longer an anomaly
    // - (optional) is there a "transition zone" — blocks where the
    //   penalty gradually decreases as the median shifts?
    function test_SustainedHighFeePressure_MedianShifts() public {
        // 1. _seedNormalSwaps(...)
        // 2. loop: for (block = 1..20+) { vm.roll(next); 10 high-fee swaps }
        // 3. read the final median from the hook
        // 4. do one more swap with the same high fee
        // 5. assert: this swap's penalty < penalty from test_HighFeeBurst_SingleBlock
        // 6. assert: median has shifted toward the high value
    }

    // ============================================================
    // TEST 4: LOW-FEE PRESSURE ACROSS MANY BLOCKS
    // ============================================================

    // (Optional) After a period of high pressure (Test 3), go back to
    // normal fees and check how quickly the median "cools down" back
    // toward baseline.
    // Symmetric case to Test 3 — relevant if the hook has a rolling
    // window with decay/expiry of old data.
    function test_MedianRecoversAfterPressureEnds() public {
        // TODO
    }

    // ============================================================
    // TEST 5: COMPLEX SCENARIO: LOW-FEE -> HIGH-FEE --> LOW-FEE
    // ============================================================

    // ============================================================
    // TEST 6: FUZZ-TESTING
    // ============================================================


    // ============================================================
    // TEST 7: CREATE SEVERAL POOLS AND CHECK MULTI-POOL ORACLE WORKS RIGHT
    // ============================================================

    // ============================================================
// HELPERS
// ============================================================

// Runs `count` swaps with a small "normal" priority fee to build
// up a baseline median before the burst / sustained pressure tests.
function _seedNormalSwaps(uint256 count) internal {
    uint256 amountIn = 1e18;
    uint256 baseFee = 10 gwei;
    uint256 normalPriorityFee = 1 gwei; // small relative to the 50 gwei "attack" fee

    for (uint256 i = 0; i < count; i++) {
        vm.fee(baseFee);
        vm.txGasPrice(baseFee + normalPriorityFee);

        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }
}

// Runs the existing high-priority-fee swap helper, but also captures
// the actual `fee` value applied by the pool (emitted in the Swap event),
// so we can directly compare penalties between different points in time.
function _swapWithHighPriorityFeeAndCaptureFee() internal returns (uint24 appliedFee) {
    vm.recordLogs();
    _helpSwapWithHighPriorityFee();
    Vm.Log[] memory logs = vm.getRecordedLogs();

    // event Swap(PoolId indexed id, address indexed sender, int128 amount0,
    //            int128 amount1, uint160 sqrtPriceX96, uint128 liquidity,
    //            int24 tick, uint24 fee);
    bytes32 swapTopic = keccak256(
        "Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"
    );

    for (uint256 i = 0; i < logs.length; i++) {
        if (logs[i].topics[0] == swapTopic) {
            (, , , , , appliedFee) =
                abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            return appliedFee;
        }
    }
    revert("Swap event not found in recorded logs");
}

// ============================================================
// TEST 3: HIGH-FEE PRESSURE ACROSS MANY BLOCKS
// ============================================================

function test_SustainedHighFeePressure_MedianShifts_2() public {
    _seedNormalSwaps(10);

    // важно: продвинуть блок, чтобы снапшот от seed-фазы попал в окно
    vm.roll(block.number + 1);

    uint24 penaltyBeforePressure = _swapWithHighPriorityFeeAndCaptureFee();

    for (uint256 b = 0; b < 20; b++) {
        vm.roll(block.number + 1);
        for (uint256 s = 0; s < 10; s++) {
            _helpSwapWithHighPriorityFee();
        }
    }

    (int256 medianAfterPressure, , ) = hook.medianState();

    vm.roll(block.number + 1);
    uint24 penaltyAfterPressure = _swapWithHighPriorityFeeAndCaptureFee();

    // 6. Assertions
    assertLt(
        penaltyAfterPressure,
        penaltyBeforePressure,
        "penalty should drop once the high fee has become the new normal"
    );

    assertApproxEqAbs(
        medianAfterPressure,
        int256(50 gwei),
        1 gwei,
        "median should have converged close to the sustained high priority fee"
    );
}
}

