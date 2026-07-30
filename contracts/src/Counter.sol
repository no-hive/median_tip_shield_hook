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

contract Counter is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using SafeCast for uint256;

    // -----------------------------------------------
    // CONSTRUCTOR
    // -----------------------------------------------

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // -----------------------------------------------
    // HOOK PERMISSIONS
    // -----------------------------------------------

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, // used to check pool has dymanic fees
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
    // ERRORS
    // -----------------------------------------------

    // used in _afterInitialize to singal new pool has no dynamic fee.
    error NotDynamicFee();

    // -----------------------------------------------
    // EVENTS
    // -----------------------------------------------

    // -----------------------------------------------
    // IMMUNTALE VARIABLES
    // -----------------------------------------------

    // ratio precision (3 decimal places)
    uint256 public immutable PRECISION = 1000;
    // 2.7 * PRECISION
    uint256 public immutable RATIO_THRESHOLD = 2700;
    // with d >= 7, penalty is already at max (see below)
    uint256 public immutable D_CAP = 7 * PRECISION;
    // 0.1% in ppm (1_000_000 = 100%)
    uint24 public immutable BASIC_FEE = 1000;
    // max penality is created to keep punishment up to 50% of the swap amount
    uint256 public immutable MAX_PENALTY_PERCENT = 50;
    // 1% => 10_000 in fee units
    uint256 public immutable PENALTY_UNIT = 10000;

    // -----------------------------------------------
    // MUTABLE VARIABLES
    // -----------------------------------------------

    // struct that stores data on Median - one struct for all pools btw.
    struct MedianState {
        int256 approxMedian;
        int256 step;
        bool positive;
    }

    MedianState public medianState;

    // -----------------------------------------------
    // OVERRIDE FUNCTOINS
    // -----------------------------------------------

    //  If pool has no dynamic fee marker while being created, it means hook's logic will be useless.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24)
        internal
        virtual
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        poolManager.updateDynamicLPFee(key, BASIC_FEE);
        return this.afterInitialize.selector;
    }

    // the function to ve used every swap to detect those who overuse priority fee and
    // change fees to punish them accordingly.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // 1. get tx_priority_fee
        uint256 priorityFee_ = getPriorityFee();
        // 2. dynamic fee punishment;
        uint24 fee_ = getDynamicFee(priorityFee_);
        // 3. update median_prority_fee
        UpdateMedian(priorityFee_);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee_ | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // -----------------------------------------------
    //  ADDITIONAL FUNCTIONS
    // -----------------------------------------------

    // this function is important to keep the Median up to date after each swap. Uses
    // FrugalMedianLIbrary for Math. Just passes all the data and update what library tells to update.
    function UpdateMedian(uint256 _priorityFee) internal {
        (int256 newMedian, int256 newStep, bool newPositive) = FrugalMedianLibrary.updateApproxMedian(
            int256(_priorityFee), medianState.approxMedian, medianState.step, medianState.positive
        );
        medianState.approxMedian = newMedian;
        medianState.step = newStep;
        medianState.positive = newPositive;
    }

    // will only work in EIP-1559 transactions because priority fee only exists there
    // so in all other cases just pass zero priority fee value.
    function getPriorityFee() internal returns (uint256) {
        uint256 priorityFee;
        // Calculate priority fee
        if (tx.gasprice <= block.basefee) {
            priorityFee = 0;
        } else {
            priorityFee = tx.gasprice - block.basefee;
        }
        return priorityFee;
    }

    // the Math for dynamic fee punishment
    function getDynamicFee(uint256 priorityFee) internal virtual returns (uint24) {
        // Find out ratio
        // 2. get median_priority_fee
        uint256 medianPriorityFee_ = uint256(medianState.approxMedian);
        // Find out scaled ratio
        if (medianPriorityFee_ == 0) return BASIC_FEE; // check that basic fee is not zero

        uint256 ratioScaled = (priorityFee * PRECISION) / medianPriorityFee_;

        uint256 penalty;
        if (ratioScaled < RATIO_THRESHOLD) {
            penalty = 0;
        } else {
            uint256 dScaled = ratioScaled - RATIO_THRESHOLD; // (ratio - 2.7) * PRECISION

            if (dScaled >= D_CAP) {
                penalty = MAX_PENALTY_PERCENT * PENALTY_UNIT;
            } else {
                uint256 x = (dScaled * dScaled * 100) / (98 * PRECISION * PRECISION);
                penalty = x * PENALTY_UNIT;
            }
        }

        uint24 fee_ = BASIC_FEE + penalty.toUint24();

        return fee_;
    }
}
