// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

contract Counter is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    // NOTE: ---------------------------------------------------------
    // state variables should typically be uniffe to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false, // used to check pool has dymanic fees
            afterInitialize: true,
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
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------
    error NotDynamicFee();

    uint24 immutable INIT_FEE = 1;

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

    function getFee_() internal virtual returns (uint24) {
        // Calculate priority fee

        uint256 priorityFee;

        uint256 effectiveGasPrice = tx.gasprice;

        uint256 baseFee = block.basefee;

        if (effectiveGasPrice <= baseFee) priorityFee = 0;

        priorityFee = effectiveGasPrice - baseFee;

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

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 fee_ = getFee_();
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee_ | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }
}
