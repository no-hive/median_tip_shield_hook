// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {MedianPriorityFeeHook} from "../src/MPFHook.sol";

address constant CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

// Exposes the internal pure-math pieces of MedianPriorityFeeHook so we can
// test the penalty curve directly, without going through PoolManager/swaps.
contract MedianPriorityFeeHookHarness is MedianPriorityFeeHook {
    constructor(IPoolManager _poolManager, address[] memory _listedTokens)
        MedianPriorityFeeHook(_poolManager, _listedTokens)
    {}

    function exposed_getDynamicFee(uint256 priorityFee, int256 referenceMedian) external returns (uint24) {
        return getDynamicFee_(priorityFee, referenceMedian);
    }
}

contract MedianPriorityFeeHookMathTest is Test {
    MedianPriorityFeeHookHarness hook;

    uint24 constant BASIC_FEE = 1000; // matches BASIC_FEE in the hook
    uint256 constant RATIO_THRESHOLD = 2700; // 2.7x, PRECISION = 1000

    function setUp() public {
        vm.startBroadcast();
        // Dummy pool manager address is fine here — the harness never
        // talks to it, we only exercise the pure fee-curve math.
        IPoolManager dummyPoolManager = IPoolManager(address(0xBEEF));
        address[] memory listedTokens = new address[](0);

        // Hook address must encode ALL flags the hook declares in
        // getHookPermissions(): afterInitialize, beforeSwap, afterSwap.
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

        bytes memory constructorArgs = abi.encode(dummyPoolManager, listedTokens);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(MedianPriorityFeeHookHarness).creationCode, constructorArgs);

        hook = new MedianPriorityFeeHookHarness{salt: salt}(dummyPoolManager, listedTokens);
        require(address(hook) == hookAddress, "harness address mismatch");
        vm.stopBroadcast();
    }

    function test_noReferenceYet_returnsBasicFee() public {
        // referenceMedian <= 0 means "no snapshot data yet"
        assertEq(hook.exposed_getDynamicFee(999_999, 0), BASIC_FEE);
        assertEq(hook.exposed_getDynamicFee(999_999, -1), BASIC_FEE);
    }

    function test_belowThreshold_noPenalty() public {
        int256 referenceMedian = 1_000_000; // 1 gwei-ish, arbitrary units
        // Priority fee exactly at the reference (ratio 1.0x) — well below 2.7x
        uint24 fee = hook.exposed_getDynamicFee(uint256(referenceMedian), referenceMedian);
        assertEq(fee, BASIC_FEE);

        // Just under the threshold (2.69x)
        uint256 justUnder = (uint256(referenceMedian) * 2699) / 1000;
        assertEq(hook.exposed_getDynamicFee(justUnder, referenceMedian), BASIC_FEE);
    }

    function test_atThreshold_zeroPenaltyStart() public {
        int256 referenceMedian = 1_000_000;
        // Exactly at 2.7x: excessRatioScaled == 0 -> fracWad == 0 -> penalty 0
        uint256 atThreshold = (uint256(referenceMedian) * RATIO_THRESHOLD) / 1000;
        assertEq(hook.exposed_getDynamicFee(atThreshold, referenceMedian), BASIC_FEE);
    }

    function test_penaltyIncreasesMonotonically() public {
        int256 referenceMedian = 1_000_000;

        uint24 feeAt3x = hook.exposed_getDynamicFee((uint256(referenceMedian) * 3000) / 1000, referenceMedian);
        uint24 feeAt5x = hook.exposed_getDynamicFee((uint256(referenceMedian) * 5000) / 1000, referenceMedian);
        uint24 feeAt7x = hook.exposed_getDynamicFee((uint256(referenceMedian) * 7000) / 1000, referenceMedian);
        uint24 feeAt10x = hook.exposed_getDynamicFee((uint256(referenceMedian) * 10_000) / 1000, referenceMedian);

        assertGt(feeAt3x, BASIC_FEE);
        assertGt(feeAt5x, feeAt3x);
        assertGt(feeAt7x, feeAt5x);
        assertGt(feeAt10x, feeAt7x);
    }

    function test_saturatesAtMaxPenaltyFrom10xOnward() public {
        int256 referenceMedian = 1_000_000;

        uint24 feeAt10x = hook.exposed_getDynamicFee((uint256(referenceMedian) * 10_000) / 1000, referenceMedian);
        uint24 feeAt50x = hook.exposed_getDynamicFee((uint256(referenceMedian) * 50_000) / 1000, referenceMedian);
        uint24 feeAt1000x = hook.exposed_getDynamicFee((uint256(referenceMedian) * 1_000_000) / 1000, referenceMedian);

        // Max penalty is 10% = 100_000 ppm, on top of BASIC_FEE (1000 ppm)
        uint24 expectedMaxFee = BASIC_FEE + uint24(10 * 10_000);

        assertEq(feeAt10x, expectedMaxFee);
        assertEq(feeAt50x, expectedMaxFee);
        assertEq(feeAt1000x, expectedMaxFee);
    }

    function testFuzz_feeNeverExceedsMax(uint256 priorityFee, uint256 referenceMedianRaw) public {
        uint256 boundedReferenceMedian = bound(referenceMedianRaw, 1, 1e30);

        int256 referenceMedian = int256(boundedReferenceMedian);

        priorityFee = bound(priorityFee, 0, type(uint128).max);

        uint24 expectedMaxFee = BASIC_FEE + uint24(10 * 10_000);

        uint24 fee = hook.exposed_getDynamicFee(priorityFee, referenceMedian);

        assertLe(fee, expectedMaxFee);
        assertGe(fee, BASIC_FEE);
    }
}
