// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// -----------------------------------------------
//  IMPORTS
// -----------------------------------------------

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FrugalMedianLibrary} from "./lib/FrugalMedianLibrary.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

// -----------------------------------------------
//  CONTRACT
// -----------------------------------------------

// Uniswap v4 hook that tracks a running (approximate) median of the priority
// fee paid by swappers and penalizes swaps whose priority fee is
// significantly above that median. The idea is to discourage aggressive
// priority-fee bidding (e.g. sandwich/MEV-style behavior) by making
// "overpaying" swaps pay a higher dynamic LP fee.
//
// To resist single-block / short-burst manipulation of the running median
// (an attacker flooding many swaps into one or a few blocks to yank the
// median toward a value that benefits them), the fee decision is NOT based
// on the live, per-swap-updated median directly. Instead, the live median
// is snapshotted once per block into a rolling window (SNAPSHOT_WINDOW
// blocks), and the fee is computed against the AVERAGE of that window.
// This mirrors the design of Uniswap's own Truncated Oracle hook
// (https://blog.uniswap.org/uniswap-v4-truncated-oracle-hook), which
// smooths its recorded tick over ~15 blocks so that manipulating it
// requires sustaining the attack over multiple blocks, not just one.
// The live median itself still updates on every swap in a registered
// pool, exactly as before — only the value used for the *fee decision*
// is smoothed.
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

    // Fixed-point precision used for the fractional-exponent (frac^1.5)
    // computation in getDynamicFee_. 1e18 = "1.0" in WAD terms.
    uint256 public constant WAD = 1e18;

    // Ratio (priorityFee / medianPriorityFee) above which the penalty
    // starts to kick in, expressed in PRECISION units.
    // 2700 / 1000 = 2.7x the current approximate median.
    uint256 public constant RATIO_THRESHOLD = 2700;

    // Once the "excess ratio" (see getDynamicFee_) reaches this value the
    // penalty is already saturated at MAX_PENALTY_PERCENT, so anything
    // beyond this point is clamped instead of computed.
    // 7.3 * PRECISION = an excess of 7.3 ratio units above RATIO_THRESHOLD,
    // i.e. the penalty saturates at a priority fee of ~10x the median
    // (RATIO_THRESHOLD + D_CAP = 10.0x).
    uint256 public constant D_CAP = 7300;

    // Baseline LP fee applied to every swap before any penalty is added,
    // expressed in ppm (parts-per-million), where 1_000_000 = 100%.
    // 1000 ppm = 0.1%.
    uint24 public constant BASIC_FEE = 1000;

    // Upper bound on how large the penalty portion of the fee can ever
    // get, expressed as a plain percentage (e.g. 10 = 10%). This caps the
    // total fee so a single swap is never charged more than this share of
    // its notional amount as a penalty. Reached exactly at a 10x ratio.
    uint256 public constant MAX_PENALTY_PERCENT = 10;

    // Conversion factor from "percent" to the ppm fee units used
    // internally: 1% == 10_000 ppm (since 1_000_000 ppm == 100%).
    uint256 public constant PENALTY_UNIT = 10000;

    // How many past blocks' median snapshots are averaged together to
    // form the reference value that penalties are computed against.
    // 15 blocks was chosen to mirror Uniswap's Truncated Oracle hook
    // (~15 blocks / ~3 minutes on L1), long enough that sustaining a
    // manipulation of the reference is costly (arbitrage / competing
    // flow works against the attacker the whole time), short enough
    // that the reference still tracks genuine shifts in network fee
    // conditions at a reasonable pace.
    uint256 public constant SNAPSHOT_WINDOW = 15;

    // -----------------------------------------------
    // STORAGE VARIABLES
    // -----------------------------------------------

    // Running state for the approximate-median estimator (see
    // FrugalMedianLibrary). NOTE: this state is shared across all pools
    // that use this hook instance — there is a single global median, not
    // one per pool. This value updates on EVERY swap in a registered
    // pool (see updateMedian_) — it is not itself rate-limited by block.
    struct MedianState {
        int256 approxMedian; // current estimate of the median priority fee
        int256 step; // current step size used by the frugal-median update rule
        bool positive; // direction of the last adjustment (increase vs decrease)
    }

    MedianState public medianState;

    // Rolling window of per-block snapshots of medianState.approxMedian.
    // One snapshot is recorded per block (on the first swap that touches
    // a registered pool in that block); the average of this window is
    // what getDynamicFee_ actually compares priority fees against.
    int256[SNAPSHOT_WINDOW] public blockMedianSnapshots;

    // How many slots of blockMedianSnapshots are populated so far.
    // Saturates at SNAPSHOT_WINDOW once the window has filled up.
    uint256 public snapshotCount;

    // Next write position in the circular blockMedianSnapshots buffer.
    uint256 public snapshotIndex;

    // Block number of the last recorded snapshot, used to detect when a
    // new block has started and a fresh snapshot is due.
    uint256 public lastSnapshotBlock;

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
    //   1. If a new block has started, snapshot the (pre-swap) live
    //      median into the rolling window before anything else changes
    //      it this block.
    //   2. Compute the smoothed reference value (average of the window)
    //      that penalties will be judged against.
    //   3. Read how much priority fee the current transaction is paying.
    //   4. Compute the dynamic LP fee for this swap based on how far its
    //      priority fee is above the smoothed reference (see
    //      getDynamicFee_).
    //   5. Feed this swap's priority fee into the running median
    //      estimator so future snapshots stay up to date. This still
    //      happens on every swap, same as before — only the fee
    //      *decision* uses the smoothed reference instead of the live
    //      value.
    // The computed fee is returned with the OVERRIDE_FEE_FLAG set so the
    // PoolManager uses it instead of the pool's currently stored LP fee.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // 1. Snapshot the live median once per block, before this
        //    swap's own update touches it.
        _recordSnapshotIfNewBlock();

        // 2. Smoothed reference value used for the fee decision.
        int256 referenceMedian = _averageSnapshot();

        // 3. Read this transaction's EIP-1559 priority fee.
        uint256 currentPriorityFee = getPriorityFee_();

        // 4. Compute the penalized dynamic fee for this swap.
        uint24 dynamicFee = getDynamicFee_(currentPriorityFee, referenceMedian);

        // 5. Feed this swap's priority fee into the running median estimate.
        PoolId id = key.toId();
        if (isRegisteredPool[id]) {
            updateMedian_(currentPriorityFee);
        }

        return
            (
                BaseHook.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                dynamicFee | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
    }

    // Records a snapshot of the current (pre-update) live median into
    // the rolling window, but at most once per block. Subsequent swaps
    // within the same block are no-ops here, so a burst of swaps in a
    // single block cannot inject more than one data point into the
    // window no matter how many times the live median itself moves
    // during that block.
    function _recordSnapshotIfNewBlock() internal {
        if (block.number == lastSnapshotBlock) return;

        blockMedianSnapshots[snapshotIndex] = medianState.approxMedian;
        snapshotIndex = (snapshotIndex + 1) % SNAPSHOT_WINDOW;
        if (snapshotCount < SNAPSHOT_WINDOW) {
            snapshotCount++;
        }
        lastSnapshotBlock = block.number;
    }

    // Averages the populated slots of the snapshot window. Returns 0 if
    // no snapshot has been recorded yet (e.g. the very first block the
    // hook is ever used in), which getDynamicFee_ treats the same way
    // the old code treated an empty medianState — fall back to
    // BASIC_FEE rather than dividing by zero.
    function _averageSnapshot() internal view returns (int256) {
        if (snapshotCount == 0) return 0;
        int256 sum;
        for (uint256 i; i < snapshotCount;) {
            sum += blockMedianSnapshots[i];
            unchecked {
                ++i;
            }
        }
        return sum / int256(snapshotCount);
    }

    // Updates the running approximate median (medianState) with the
    // priority fee observed in the current swap. Delegates the actual
    // math to FrugalMedianLibrary and just persists whatever it returns.
    // This must run on every swap so the median stays representative of
    // recent priority-fee activity — the block-level rate limiting lives
    // in the snapshot layer above, not here.
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
    // priority fee, by comparing it against the smoothed reference
    // median (the average of the last SNAPSHOT_WINDOW per-block
    // snapshots — see _averageSnapshot), NOT the live medianState
    // directly:
    //   - If there is no reference data yet (referenceMedian <= 0), just
    //     charge the baseline fee.
    //   - Otherwise compute the ratio of this swap's priority fee to the
    //     reference, scaled by PRECISION.
    //   - If that ratio is below RATIO_THRESHOLD (2.7x the reference), no
    //     penalty is applied.
    //   - Above the threshold, the penalty grows along a single power-1.5
    //     curve (frac^1.5, where frac is how far the excess ratio is
    //     through the 2.7x -> 10.0x range), up to D_CAP, beyond which the
    //     penalty is simply clamped at MAX_PENALTY_PERCENT. Power-1.5
    //     growth (steeper than linear, gentler than quadratic at first)
    //     was chosen so the curve passes close to three calibration
    //     points at once: ~1-2% around 4-5x, ~3-5% around 7x, and exactly
    //     10% (the hard cap) at 10x. Using an integer exponent alone
    //     (e.g. plain quadratic) cannot hit all three points; frac^1.5 is
    //     computed cheaply on-chain via Math.sqrt (frac^1.5 = frac *
    //     sqrt(frac)), avoiding a full fixed-point pow/ln/exp library.
    // The final fee is BASIC_FEE plus this penalty, expressed in ppm.
    function getDynamicFee_(uint256 priorityFee, int256 referenceMedian) internal virtual returns (uint24) {
        // No reference data yet — fall back to the baseline fee to avoid
        // dividing by zero (mirrors the old medianPriorityFee == 0 check).
        if (referenceMedian <= 0) return BASIC_FEE;

        uint256 medianPriorityFee = uint256(referenceMedian);

        // How many times (scaled by PRECISION) this swap's priority fee
        // exceeds the smoothed reference. E.g. 2700 means "2.7x the
        // reference".
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

            // Fraction of the way through the penalty range [0, D_CAP],
            // expressed in WAD (1e18 = "fully saturated"). Clamped to
            // WAD instead of computed further once excess reaches D_CAP,
            // both to save gas and to guarantee no overflow regardless
            // of how large priorityFeeRatioScaled is.
            uint256 fracWad = excessRatioScaled >= D_CAP ? WAD : (excessRatioScaled * WAD) / D_CAP;

            // frac^1.5 = frac * sqrt(frac), computed in WAD fixed point.
            // Math.sqrt(fracWad * WAD) rescales sqrt(x/1e18) back to a
            // 1e18-scaled result (sqrt(1e36) == 1e18).
            uint256 sqrtFracWad = Math.sqrt(fracWad * WAD);
            uint256 frac1_5Wad = (fracWad * sqrtFracWad) / WAD;

            penaltyPpm = (frac1_5Wad * MAX_PENALTY_PERCENT * PENALTY_UNIT) / WAD;
        }

        // Final fee = baseline fee + penalty, in ppm.
        uint24 totalFee = BASIC_FEE + penaltyPpm.toUint24();

        return totalFee;
    }
}
