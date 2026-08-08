// SPDX-License-Identifier: MIT
// This lib is part of https://github.com/saucepoint/median-oracles project. Thanks to its creator!
pragma solidity ^0.8.15;

library FrugalMedianLibrary {
    function frugalMedian(int256[] memory sequence) public pure returns (int256 approxMedian) {
        int256 step;
        uint256 i;
        bool positive;
        for (i; i < sequence.length;) {
            (approxMedian, step, positive) = updateApproxMedian(sequence[i], approxMedian, step, positive);
            unchecked {
                ++i;
            }
        }
    }

    function updateApproxMedian(int256 newNumber, int256 approxMedian, int256 step, bool positive)
        public
        pure
        returns (int256, int256, bool)
    {
        unchecked {
            if (newNumber > approxMedian) {
                step += positive ? stepIncrement(newNumber) : -stepIncrement(newNumber);
                // line 6: we cant do ceiling
                approxMedian += (step > 0) ? step : int256(1);
                if (approxMedian > newNumber) {
                    step += newNumber - approxMedian;
                    approxMedian = newNumber;
                }
                if (!positive && step > 1) {
                    step = 1;
                }
                positive = true;
            } else if (newNumber < approxMedian) {
                step += !positive ? stepIncrement(newNumber) : -stepIncrement(newNumber);
                approxMedian -= (step > 0) ? step : int256(1);
                // line 18
                if (approxMedian < newNumber) {
                    step += approxMedian - newNumber;
                    approxMedian = newNumber;
                }
                if (positive && step > 1) {
                    step = 1;
                }
                positive = false;
            }
        }
        return (approxMedian, step, positive);
    }

    // Per-iteration increment added to the (still accumulating) step:
    // ~1% of |newNumber|. Since `step` in updateApproxMedian is built up
    // via `step += stepIncrement(...)` across iterations rather than
    // reassigned, a sustained same-direction run of updates converges
    // quadratically (~sqrt(2*100) ≈ 14 iterations to fully catch up to a
    // new level), not linearly at ~100. Floors at 1 so the median can
    // still move by at least 1 unit even for very small values.
    uint256 private constant STEP_DIVISOR = 100;

    function stepIncrement(int256 newNumber) private pure returns (int256) {
        int256 magnitude = newNumber >= 0 ? newNumber : -newNumber;
        int256 inc = magnitude / int256(STEP_DIVISOR);
        return inc < 1 ? int256(1) : inc;
    }
}
