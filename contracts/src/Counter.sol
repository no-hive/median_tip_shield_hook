// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FrugalMedianLibrary} from "./lib/FrugalMedianLibrary.sol";

contract Counter is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

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

    error NotDynamicFee(); // used in _afterInitialize to singal new pool has no dynamic fee.

    uint24 immutable INIT_FEE = 1;

    //  If pool has no dynamic fee marker while being created, it means hook's logic will be useless.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24)
        internal
        virtual
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        poolManager.updateDynamicLPFee(key, INIT_FEE);
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

        // 2. get median_priority_fee

        // 3. uint24 fee_ = getFee_();

        // 4. update median_prority_fee
        UpdateMedian(1);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0); //fee_ | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // struct that stores data on Median - one struct for all pools btw.
    struct MedianState {
        int120 approxMedian;
        int120 step;
        bool positive;
    }

    MedianState public medianState;

    // this function is important to keep the Median up to date after each swap. Uses
    // FrugalMedianLIbrary for Math. Just passes all the data and update what library tells to update.
    function UpdateMedian(uint256 _priorityFee) internal {
        (int256 newMedian, int256 newStep, bool newPositive) = FrugalMedianLibrary.updateApproxMedian(
            int256(_priorityFee), medianState.approxMedian, medianState.step, medianState.positive
        );
        medianState.approxMedian = int120(newMedian);
        medianState.step = int120(newStep);
        medianState.positive = newPositive;
    }

    // will only work in EIP-1559 transactions because priority fee only exists there
    // so in all other cases just pass zero priority fee value.
    function getPriorityFee() internal returns (uint256) {
        // Calculate priority fee
        uint256 priorityFee;

        uint256 effectiveGasPrice = tx.gasprice;

        uint256 baseFee = block.basefee;

        if (effectiveGasPrice <= baseFee) priorityFee = 0;

        priorityFee = effectiveGasPrice - baseFee;

        return priorityFee;
    }

    // the Math for dynamic fee punishment
    function getFee_(uint256 priorityFee) internal virtual returns (uint24) {
        // Find out ratio

        uint256 PRECISION = 1000; // ratio precision (3 decimal places)
        uint256 RATIO_THRESHOLD = 2700; // 2.7 * PRECISION
        uint256 D_CAP = 7 * PRECISION; // with d >= 7, penalty is already at max (see below)
        uint256 BASIC_FEE = 1000; // 0.1% in ppm (1_000_000 = 100%)
        uint256 MAX_PENALTY_PERCENT = 50;
        uint256 PENALTY_UNIT = 10000; // 1% => 10_000 in fee units
        uint256 medianFee = 1; // CHANGE LATER

        //  if (medianFee == 0) return BASIC_FEE;  // check that basic fee is not zero

        // Find out scaled ratio

        uint256 ratioScaled = (priorityFee * PRECISION) / medianFee;

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

        uint256 fee_ = BASIC_FEE + penalty;
    }
}
