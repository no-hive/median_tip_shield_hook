// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// -----------------------------------------------
//  IMPORTS
// -----------------------------------------------

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FrugalMedianLibrary} from "./lib/FrugalMedianLibrary.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// -----------------------------------------------
//  CONTRACT
// -----------------------------------------------

// Uniswap v4 hook that tracks a running (approximate) median of the priority
// fee paid by swappers and penalizes swaps whose priority fee is
// significantly above that median. The idea is to discourage aggressive
// priority-fee bidding (e.g. sandwich/MEV-style behavior) by making
// "overpaying" swaps pay a higher dynamic LP fee.
contract MedianPriorityFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using SafeCast for uint256;

    // -----------------------------------------------
    // ERRORS
    // -----------------------------------------------

    // Thrown in _afterInitialize when a pool is created without the
    // dynamic-fee flag set. Without dynamic fees enabled, this hook's
    // whole fee-adjustment logic would have no effect on the pool, so we
    // reject such pools outright instead of silently doing nothing.
    error NotDynamicFee();

    // -----------------------------------------------
    // EVENTS
    // -----------------------------------------------

    // (none yet)

    // -----------------------------------------------
    // CONSTANTS
    // -----------------------------------------------

    // Fixed-point precision used for all ratio math below (3 decimal
    // places, e.g. a ratio of 1.000 is stored internally as 1000).
    uint256 public constant PRECISION = 1000;

    // Ratio (priorityFee / medianPriorityFee) above which the penalty
    // starts to kick in, expressed in PRECISION units.
    // 2700 / 1000 = 2.7x the current approximate median.
    uint256 public constant RATIO_THRESHOLD = 2700;

    // Once the "excess ratio" (see getDynamicFee) reaches this value the
    // penalty is already saturated at MAX_PENALTY_PERCENT, so anything
    // beyond this point is clamped instead of computed.
    // 7 * PRECISION = an excess of 7.0 ratio units above RATIO_THRESHOLD.
    uint256 public constant D_CAP = 7 * PRECISION;

    // Baseline LP fee applied to every swap before any penalty is added,
    // expressed in ppm (parts-per-million), where 1_000_000 = 100%.
    // 1000 ppm = 0.1%.
    uint24 public constant BASIC_FEE = 1000;

    // Upper bound on how large the penalty portion of the fee can ever
    // get, expressed as a plain percentage (e.g. 50 = 50%). This caps the
    // total fee so a single swap is never charged more than this share of
    // its notional amount as a penalty.
    uint256 public constant MAX_PENALTY_PERCENT = 50;

    // Conversion factor from "percent" to the ppm fee units used
    // internally: 1% == 10_000 ppm (since 1_000_000 ppm == 100%).
    uint256 public constant PENALTY_UNIT = 10000;

    // -----------------------------------------------
    // STORAGE VARIABLES
    // -----------------------------------------------

    // Running state for the approximate-median estimator (see
    // FrugalMedianLibrary). NOTE: this state is shared across all pools
    // that use this hook instance — there is a single global median, not
    // one per pool.
    struct MedianState {
        int256 approxMedian; // current estimate of the median priority fee
        int256 step; // current step size used by the frugal-median update rule
        bool positive; // direction of the last adjustment (increase vs decrease)
    }

    MedianState public medianState;

    // Bool creates a whitelist for pools.
    // It is needed to update Median only with those pools where
    // we can definitely know the exact swap amount in USD.
    // It is needed to get rid of dust swaps aimed at
    // destroying the Median value.
    mapping(PoolId => bool) public isRegisteredPool;

    // Mapping of nice and sound token addresses.
    // Only initialized in the constructor.
    // Chain-specific.
    mapping(address => bool) public isListed;

    // -----------------------------------------------
    // CONSTRUCTOR
    // -----------------------------------------------

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // -----------------------------------------------
    // EXTERNAL / PUBLIC FUNCTIONS
    // -----------------------------------------------

    // Declares which Uniswap v4 hook callbacks this contract implements.
    // We only need:
    //  - afterInitialize: to verify the newly created pool actually uses
    //    dynamic fees (otherwise our fee logic would never be applied).
    //  - beforeSwap: to compute and apply the penalized dynamic fee for
    //    every swap, and to update the running median estimate.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, // used to check pool has dynamic fees
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // used for custom fees logic
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -----------------------------------------------
    // INTERNAL / OVERRIDE FUNCTIONS
    // -----------------------------------------------

    // Called by the PoolManager right after a pool using this hook is
    // initialized. If the pool was NOT configured with the dynamic-fee
    // flag, this hook's fee-adjustment logic can never run, so we revert
    // to prevent creating a pool where the hook would be silently useless.
    // Otherwise, we set the pool's initial LP fee to BASIC_FEE.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24)
        internal
        virtual
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        poolManager.updateDynamicLPFee(key, BASIC_FEE);

        // Extra value assignment needed to depict
        // which pool we should trust and which we should not.
        PoolId id = key.toId();
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        isRegisteredPool[id] = isListed[token0] || isListed[token1];

        return this.afterInitialize.selector;
    }

    // Called by the PoolManager before every swap on a pool using this
    // hook. This is where the penalty logic is actually enforced:
    //   1. Read how much priority fee the current transaction is paying.
    //   2. Compute the dynamic LP fee for this swap based on how far its
    //      priority fee is above the running median (see getDynamicFee).
    //   3. Feed this swap's priority fee into the running median
    //      estimator so future swaps are compared against an up-to-date
    //      median.
    // The computed fee is returned with the OVERRIDE_FEE_FLAG set so the
    // PoolManager uses it instead of the pool's currently stored LP fee.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // 1. Read this transaction's EIP-1559 priority fee.
        uint256 currentPriorityFee = getPriorityFee_();
        // 2. Compute the penalized dynamic fee for this swap.
        uint24 dynamicFee = getDynamicFee_(currentPriorityFee);
        // 3. Feed this swap's priority fee into the running median estimate.
        updateMedian_(currentPriorityFee);

        return
            (
                BaseHook.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                dynamicFee | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
    }

    // Updates the running approximate median (medianState) with the
    // priority fee observed in the current swap. Delegates the actual
    // math to FrugalMedianLibrary and just persists whatever it returns.
    // This must run on every swap so the median stays representative of
    // recent priority-fee activity.
    function updateMedian_(uint256 _currentPriorityFee) internal {
        (int256 updatedMedian, int256 updatedStep, bool updatedDirectionIsPositive) = FrugalMedianLibrary.updateApproxMedian(
            int256(_currentPriorityFee), medianState.approxMedian, medianState.step, medianState.positive
        );
        medianState.approxMedian = updatedMedian;
        medianState.step = updatedStep;
        medianState.positive = updatedDirectionIsPositive;
    }

    // Returns the priority fee (tip above the base fee) paid by the
    // current transaction. This concept only exists for EIP-1559
    // transactions (tx.gasprice > block.basefee); for legacy transactions
    // or when tx.gasprice does not exceed the base fee, we treat the
    // priority fee as zero rather than reverting or underflowing.
    function getPriorityFee_() internal view returns (uint256) {
        uint256 priorityFee;
        // Priority fee = what the sender actually paid above the base fee.
        if (tx.gasprice <= block.basefee) {
            priorityFee = 0;
        } else {
            priorityFee = tx.gasprice - block.basefee;
        }
        return priorityFee;
    }

    // Computes the dynamic LP fee to charge for a swap, given its
    // priority fee, by comparing it against the current approximate
    // median priority fee:
    //   - If the pool has no median data yet (medianPriorityFee == 0),
    //     just charge the baseline fee.
    //   - Otherwise compute the ratio of this swap's priority fee to the
    //     median, scaled by PRECISION.
    //   - If that ratio is below RATIO_THRESHOLD (2.7x the median), no
    //     penalty is applied.
    //   - Above the threshold, the penalty grows quadratically with how
    //     far the ratio exceeds RATIO_THRESHOLD ("excess ratio"), up to
    //     D_CAP, beyond which the penalty is simply clamped at
    //     MAX_PENALTY_PERCENT. The quadratic growth means small overages
    //     are cheap but large overages get punished disproportionately.
    // The final fee is BASIC_FEE plus this penalty, expressed in ppm.
    function getDynamicFee_(uint256 priorityFee) internal virtual returns (uint24) {
        // Current approximate median priority fee across recent swaps.
        uint256 medianPriorityFee = uint256(medianState.approxMedian);

        // No median data yet — fall back to the baseline fee to avoid
        // dividing by zero.
        if (medianPriorityFee == 0) return BASIC_FEE;

        // How many times (scaled by PRECISION) this swap's priority fee
        // exceeds the current median. E.g. 2700 means "2.7x the median".
        uint256 priorityFeeRatioScaled = (priorityFee * PRECISION) / medianPriorityFee;

        uint256 penaltyPpm;
        if (priorityFeeRatioScaled < RATIO_THRESHOLD) {
            // Priority fee is within the tolerated range — no penalty.
            penaltyPpm = 0;
        } else {
            // How far above the threshold this swap's ratio is, scaled by
            // PRECISION (e.g. ratio 3.7 with threshold 2.7 gives an
            // excess of 1.0 * PRECISION).
            uint256 excessRatioScaled = priorityFeeRatioScaled - RATIO_THRESHOLD;

            if (excessRatioScaled >= D_CAP) {
                // Excess is at or beyond the cap — penalty is fully saturated.
                penaltyPpm = MAX_PENALTY_PERCENT * PENALTY_UNIT;
            } else {
                // Quadratic scaling: penalty grows with the square of the
                // excess ratio, normalized so it reaches
                // MAX_PENALTY_PERCENT exactly when excessRatioScaled == D_CAP.
                penaltyPpm =
                    (excessRatioScaled * excessRatioScaled * MAX_PENALTY_PERCENT * PENALTY_UNIT) / (D_CAP * D_CAP);
            }
        }

        // Final fee = baseline fee + penalty, in ppm.
        uint24 totalFee = BASIC_FEE + penaltyPpm.toUint24();

        return totalFee;
    }
}
