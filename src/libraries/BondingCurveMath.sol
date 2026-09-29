// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPointMathLib as FPML} from "solady/utils/FixedPointMathLib.sol";

/// @title BondingCurveMath
/// @notice Pure math of the virtual constant-product bonding curve (ARCHITECTURE.md §4).
///             vM = vM0 + realMon,   vT = vT0 - C + realTokens,   vM * vT >= vM0 * vT0.
/// @dev Rounding rule: whatever the user receives rounds down, whatever the user pays rounds up, so every
///      operation can only increase k = vM * vT. Products use 512-bit intermediates (Solady `fullMulDiv`).
library BondingCurveMath {
    uint256 internal constant BPS = 10_000;

    /// @dev (BPS - graduationFeeBps) * C must exceed L * BPS (ARCHITECTURE.md §4.5: requires ρC > L).
    error InvalidCurveParameters();

    // ------------------------------------------------------------------ swaps

    /// @notice Tokens bought with `monIn` net MON: floor(vT * monIn / (vM + monIn)).
    function tokensOut(uint256 vM, uint256 vT, uint256 monIn) internal pure returns (uint256) {
        return FPML.fullMulDiv(vT, monIn, vM + monIn);
    }

    /// @notice Net MON required to buy exactly `amount` tokens: ceil(vM * amount / (vT - amount)).
    /// @dev Requires amount < vT, which always holds on the curve because vT0 > C.
    function monInForTokens(uint256 vM, uint256 vT, uint256 amount) internal pure returns (uint256) {
        return FPML.fullMulDivUp(vM, amount, vT - amount);
    }

    /// @notice Gross MON paid for selling `amount` tokens: floor(vM * amount / (vT + amount)).
    function monOut(uint256 vM, uint256 vT, uint256 amount) internal pure returns (uint256) {
        return FPML.fullMulDiv(vM, amount, vT + amount);
    }

    // ------------------------------------------------------------------ fees

    /// @notice Total fee at `elapsedBlocks` after launch (ARCHITECTURE.md §5.2):
    ///         f(b) = base + (max - base) * ((D - b) / D)^2 for b < D, and base afterwards. Rounded down.
    function feeBpsAt(uint256 elapsedBlocks, uint256 baseFeeBps, uint256 maxFeeBps, uint256 decayBlocks)
        internal
        pure
        returns (uint256)
    {
        if (elapsedBlocks >= decayBlocks) return baseFeeBps;
        uint256 remaining = decayBlocks - elapsedBlocks;
        return baseFeeBps + FPML.mulDiv(maxFeeBps - baseFeeBps, remaining * remaining, decayBlocks * decayBlocks);
    }

    /// @notice Splits the fee charged on a `gross` MON amount.
    ///         total = ceil(gross * feeBps / BPS), fee = ceil(gross * baseFeeBps / BPS), tax = total - fee.
    /// @dev `fee` accrues to the fee recipients; `tax` (anti-snipe surcharge) is donated to the curve reserve.
    ///      Requires baseFeeBps <= feeBps < BPS, guaranteed by preset validation and `feeBpsAt`.
    function splitFees(uint256 gross, uint256 feeBps, uint256 baseFeeBps)
        internal
        pure
        returns (uint256 fee, uint256 tax)
    {
        fee = FPML.mulDivUp(gross, baseFeeBps, BPS);
        tax = FPML.mulDivUp(gross, feeBps, BPS) - fee;
    }

    /// @notice Smallest gross amount whose net (after `splitFees` at `feeBps`) is at least `net`:
    ///         ceil(net * BPS / (BPS - feeBps)).
    function grossUp(uint256 net, uint256 feeBps) internal pure returns (uint256) {
        return FPML.mulDivUp(net, BPS, BPS - feeBps);
    }

    // ------------------------------------------------------------------ graduation

    /// @notice Split of the curve's MON at graduation (ARCHITECTURE.md §4.7).
    ///         fee = ceil(realMon * g), monLP = realMon - fee,
    ///         tokensLP = min(L, floor(monLP * vT_f / vM_f)) with vT_f = vT0 - C, vM_f = vM0 + realMon.
    /// @dev Rounding keeps the DEX opening price (monLP / tokensLP) >= the curve's final price (vM_f / vT_f).
    function graduationAmounts(
        uint256 realMon,
        uint256 vM0,
        uint256 finalVirtualTokenReserve,
        uint256 lpSupply,
        uint256 graduationFeeBps
    ) internal pure returns (uint256 fee, uint256 monForLiquidity, uint256 tokensForLiquidity) {
        fee = FPML.mulDivUp(realMon, graduationFeeBps, BPS);
        monForLiquidity = realMon - fee;
        tokensForLiquidity =
            FPML.min(lpSupply, FPML.fullMulDiv(monForLiquidity, finalVirtualTokenReserve, vM0 + realMon));
    }

    // ------------------------------------------------------------------ parameter derivation

    /// @notice Virtual reserves that make the curve (i) raise at least `targetRaise` when `curveSupply` is sold
    ///         out and (ii) end at the price of the DEX pool seeded with ((1 - g) * targetRaise, lpSupply).
    ///         vT0 = ceil(ρ * C^2 / (ρ * C - L)),  vM0 = ceil(R * (vT0 - C) / C),  ρ = 1 - g.
    /// @dev Rounding both values up guarantees the sold-out raise is >= targetRaise (ARCHITECTURE.md §4.5).
    function deriveVirtualReserves(uint256 curveSupply, uint256 lpSupply, uint256 targetRaise, uint256 graduationFeeBps)
        internal
        pure
        returns (uint256 virtualTokenReserve0, uint256 virtualMonReserve0)
    {
        if (graduationFeeBps >= BPS) revert InvalidCurveParameters();
        uint256 rhoC = (BPS - graduationFeeBps) * curveSupply; // ρ * C, scaled by BPS
        uint256 scaledLp = lpSupply * BPS;
        if (curveSupply == 0 || targetRaise == 0 || rhoC <= scaledLp) revert InvalidCurveParameters();
        virtualTokenReserve0 = FPML.fullMulDivUp(rhoC, curveSupply, rhoC - scaledLp);
        virtualMonReserve0 = FPML.fullMulDivUp(targetRaise, virtualTokenReserve0 - curveSupply, curveSupply);
    }
}
