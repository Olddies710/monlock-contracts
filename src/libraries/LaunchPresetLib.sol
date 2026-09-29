// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FeeSplit, LaunchPreset} from "../types/LaunchpadTypes.sol";

/// @title LaunchPresetLib
/// @notice Validation of launch presets. Enforced by every curve at construction (and by the factory when a
///         preset is registered), so a curve can never be deployed with parameters that break its math.
library LaunchPresetLib {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_TRADE_FEE_BPS = 200; // 2%
    uint256 internal constant MAX_GRADUATION_FEE_BPS = 1000; // 10%
    uint256 internal constant MAX_SNIPE_FEE_BPS = 9000; // 90%

    error InvalidSupply();
    error InvalidVirtualReserves();
    error InvalidFees();
    error InvalidFeeSplit();
    error InvalidBuyLimits();
    error InvalidMigrator();

    function validate(LaunchPreset memory p) internal pure {
        uint256 totalSupply = uint256(p.curveSupply) + p.lpSupply;
        if (p.curveSupply == 0 || p.lpSupply == 0 || totalSupply > type(uint128).max) revert InvalidSupply();
        if (p.virtualTokenReserve0 <= p.curveSupply || p.virtualMonReserve0 == 0) revert InvalidVirtualReserves();
        if (
            p.tradeFeeBps > MAX_TRADE_FEE_BPS || p.graduationFeeBps > MAX_GRADUATION_FEE_BPS
                || p.snipeFeeBps < p.tradeFeeBps || p.snipeFeeBps > MAX_SNIPE_FEE_BPS
        ) revert InvalidFees();
        if (!_sumsToBps(p.curveFeeSplit) || !_sumsToBps(p.lpFeeSplit)) revert InvalidFeeSplit();
        // The dev buy must never sell out the curve: graduation always needs public buyers.
        if (
            p.maxBuyBps == 0 || p.maxBuyBps > BPS || p.maxDevBuyBps > BPS
                || totalSupply * p.maxDevBuyBps / BPS >= p.curveSupply
        ) revert InvalidBuyLimits();
        if (p.migrator == address(0)) revert InvalidMigrator();
    }

    function _sumsToBps(FeeSplit memory s) private pure returns (bool) {
        return uint256(s.creatorBps) + s.protocolBps + s.referrerBps == BPS;
    }
}
