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

    uint24 public constant BASIC_FEE = 1000;

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
    // TEST 3: HIGH-FEE PRESSURE ACROSS MANY BLOCKS
    // ============================================================
    //
    // Simulates sustained high-fee pressure: 10 high-fee swaps per block,
    // repeated for 20+ consecutive blocks.
    // Goal: check how the rolling median behaves when "abnormal" behavior
    // becomes the NEW normal over a long enough window. Unlike Test 2
    // (a one-block spike), the median here should have time to adapt.
    function test_SustainedHighFeePressure_MedianShifts() public {
        _seedNormalSwaps(10);
        vm.roll(block.number + 1);
        uint24 penaltyBeforePressure = _swapWithHighPriorityFeeAndCaptureFee();
        for (uint256 b = 0; b < 20; b++) {
            vm.roll(block.number + 1);
            for (uint256 s = 0; s < 10; s++) {
                _helpSwapWithHighPriorityFee();
            }
        }
        (int256 medianAfterPressure,,) = hook.medianState();
        vm.roll(block.number + 1);
        uint24 penaltyAfterPressure = _swapWithHighPriorityFeeAndCaptureFee();
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

    // ============================================================
    // TEST 4: LOW-FEE PRESSURE ACROSS MANY BLOCKS
    // ============================================================
    //
    // (Optional) After a period of high pressure (Test 3), go back to
    // normal fees and check how quickly the median "cools down" back
    // toward baseline.
    // Symmetric case to Test 3 — relevant if the hook has a rolling
    // window with decay/expiry of old data.
    function test_MedianRecoversAfterPressureEnds() public {
        // 1. Seed baseline history
        _seedNormalSwaps(10);
        vm.roll(block.number + 1);

        // 2. Apply sustained HIGH-fee pressure, same as Test 3, until the
        //    median fully converges to the high value.
        for (uint256 b = 0; b < 20; b++) {
            vm.roll(block.number + 1);
            for (uint256 s = 0; s < 10; s++) {
                _helpSwapWithHighPriorityFee();
            }
        }

        (int256 medianAfterHighPressure,,) = hook.medianState();
        assertApproxEqAbs(
            medianAfterHighPressure,
            int256(50 gwei),
            1 gwei,
            "sanity check: median should have converged to the high fee before recovery starts"
        );

        // 3. Now apply sustained LOW-fee pressure for the same number of
        //    blocks, and see how far the median has moved back down.
        for (uint256 b = 0; b < 20; b++) {
            vm.roll(block.number + 1);
            for (uint256 s = 0; s < 10; s++) {
                _helpSwapWithLowPriorityFee();
            }
        }

        (int256 medianAfterRecovery,,) = hook.medianState();

        // 4. Assertions
        // The median should have moved down from the high-pressure value...
        assertLt(medianAfterRecovery, medianAfterHighPressure, "median should decrease once low-fee swaps dominate");

        // ...but recovery is NOT necessarily symmetric/instant: depending on
        // FrugalMedianLibrary's step logic, it may take a different number
        // of blocks to fall back down than it took to climb up. We only
        // assert the direction here, and log the actual value for inspection.
        emit log_named_int("medianAfterHighPressure", medianAfterHighPressure);
        emit log_named_int("medianAfterRecovery", medianAfterRecovery);
    }

    // ============================================================
    // TEST 5: COMPLEX SCENARIO: LOW-FEE -> HIGH-FEE -> LOW-FEE
    // ============================================================

    // Simulates a realistic market cycle: normal fee conditions, then a
    // sustained fee spike (e.g. a busy period / MEV attack), then a return
    // to normal. Checks that the hook's penalty logic tracks this whole
    // arc correctly, not just the individual up/down transitions tested in
    // isolation in Tests 3 and 4:
    //   - Phase A (low/normal): no penalty, baseline median forms.
    //   - Phase B (high, sustained): penalty starts high (fee is anomalous
    //     relative to Phase A's median), then decays toward zero as the
    //     median catches up and high fee becomes "the new normal".
    //   - Phase C (low again): the FIRST low-fee swap right after Phase B
    //     should NOT be penalized (paying less than the median is never
    //     penalized by design — see RATIO_THRESHOLD logic, which only
    //     fires when priorityFee is ABOVE the reference). But we track how
    //     the median itself decays back down over this phase.
    // This is the scenario the hook is actually designed for in practice —
    // fee conditions genuinely shifting over time — as opposed to a static
    // attack.
    function test_ComplexScenario_LowHighLow() public {
        // ---- Phase A: baseline low-fee conditions ----
        _seedNormalSwaps(10);
        vm.roll(block.number + 1);

        (int256 medianPhaseA,,) = hook.medianState();

        // ---- Phase B: sustained high-fee pressure ----
        // Capture the penalty of the FIRST high-fee swap in this phase —
        // this is the "anomaly" moment, should mirror Test 2's burst result.
        uint24 firstHighFeePenalty = _swapWithHighPriorityFeeAndCaptureFee();
        assertGt(
            firstHighFeePenalty,
            BASIC_FEE,
            "Phase B start: high fee should be penalized when it's still anomalous vs Phase A baseline"
        );

        for (uint256 b = 0; b < 19; b++) {
            vm.roll(block.number + 1);
            for (uint256 s = 0; s < 10; s++) {
                _helpSwapWithHighPriorityFee();
            }
        }
        vm.roll(block.number + 1);

        // Capture the penalty of a high-fee swap at the END of the sustained
        // pressure — should have decayed close to BASIC_FEE, since the high
        // fee is no longer anomalous relative to its own recent history.
        uint24 lastHighFeePenalty = _swapWithHighPriorityFeeAndCaptureFee();
        (int256 medianPhaseB,,) = hook.medianState();

        assertLt(
            lastHighFeePenalty,
            firstHighFeePenalty,
            "Phase B end: penalty should have decayed as the median caught up to the sustained high fee"
        );
        assertApproxEqAbs(
            medianPhaseB,
            int256(50 gwei),
            1 gwei,
            "Phase B end: median should have converged close to the sustained high priority fee"
        );

        // ---- Phase C: return to low fee ----
        // A swap paying LESS than the current (high) reference median is
        // never penalized by design — the hook only penalizes overpaying,
        // not underpaying. So the very first low-fee swap right after the
        // spike should pay only the base fee, immediately, with no "cliff".
        vm.recordLogs();
        _helpSwapWithLowPriorityFee();
        uint24 firstLowFeePenaltyAfterSpike = _extractSwapFeeFromLastLogs();

        assertEq(
            firstLowFeePenaltyAfterSpike,
            BASIC_FEE,
            "Phase C start: underpaying relative to the median should never be penalized, even right after a spike"
        );

        // Sustain low-fee conditions and check the median decays back down.
        for (uint256 b = 0; b < 19; b++) {
            vm.roll(block.number + 1);
            for (uint256 s = 0; s < 10; s++) {
                _helpSwapWithLowPriorityFee();
            }
        }
        vm.roll(block.number + 1);
        _helpSwapWithLowPriorityFee();

        (int256 medianPhaseC,,) = hook.medianState();

        assertLt(
            medianPhaseC,
            medianPhaseB,
            "Phase C end: median should have decayed back down after sustained low-fee conditions"
        );

        emit log_named_int("medianPhaseA (baseline)", medianPhaseA);
        emit log_named_int("medianPhaseB (after high pressure)", medianPhaseB);
        emit log_named_int("medianPhaseC (after recovery)", medianPhaseC);
        emit log_named_uint("firstHighFeePenalty", firstHighFeePenalty);
        emit log_named_uint("lastHighFeePenalty", lastHighFeePenalty);
    }

    // Helper: extracts the `fee` field from the most recently recorded
    // Swap event. Assumes vm.recordLogs() was called before the swap that
    // should be inspected. Factored out of
    // _swapWithHighPriorityFeeAndCaptureFee so Phase C can reuse the same
    // decoding logic for an arbitrary swap helper.
    function _extractSwapFeeFromLastLogs() internal returns (uint24 appliedFee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 swapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == swapTopic) {
                (,,,,, appliedFee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return appliedFee;
            }
        }
        revert("Swap event not found in recorded logs");
    }

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

    // ============================================================
    // HELPERS
    // ============================================================
    // ============================================================
    // HELPER 1: LOW FEE TRANSACTION
    // ============================================================
    // Helper: swap with a low priority fee, mirroring the seed/normal fee
    // used to build the baseline (kept separate from _seedNormalSwaps so
    // the "recovery" phase can be tuned independently if needed).
    function _helpSwapWithLowPriorityFee() internal {
        uint256 amountIn = 1e18;
        uint256 baseFee = 10 gwei;
        uint256 lowPriorityFee = 1 gwei;

        vm.fee(baseFee);
        vm.txGasPrice(baseFee + lowPriorityFee);

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
    // HELPER 2: HIGH FEE TRANSACTION + FEE CAPTURER.
    // ============================================================

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
        bytes32 swapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == swapTopic) {
                (,,,,, appliedFee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return appliedFee;
            }
        }
        revert("Swap event not found in recorded logs");
    }

    // ============================================================
    // HELPER 2.1: HIGH FEE TRANSACTION
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
}

