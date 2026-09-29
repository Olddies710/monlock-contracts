// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BondingCurveMath} from "../../src/libraries/BondingCurveMath.sol";
import {FeeSplit, LaunchPreset} from "../../src/types/LaunchpadTypes.sol";

/// @notice Approved Phase 0 parameters (ARCHITECTURE.md §4.6, §5.2, §7.1).
library Presets {
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 internal constant CURVE_SUPPLY = 800_000_000e18;
    uint256 internal constant LP_SUPPLY = 200_000_000e18;
    uint256 internal constant TARGET_RAISE = 2000 ether;
    uint16 internal constant TRADE_FEE_BPS = 100;
    uint16 internal constant GRADUATION_FEE_BPS = 500;
    uint16 internal constant SNIPE_FEE_BPS = 5000;
    uint32 internal constant SNIPE_DECAY_BLOCKS = 200;
    uint16 internal constant MAX_BUY_BPS = 100; // 1% of total supply per tx while decaying
    uint16 internal constant MAX_DEV_BUY_BPS = 500; // 5% of total supply

    /// @dev Exact values from `deriveVirtualReserves` (cross-checked with rational arithmetic off-chain).
    uint256 internal constant EXPECTED_VT0 = 1_085_714_285_714_285_714_285_714_286;
    uint256 internal constant EXPECTED_VM0 = 714_285_714_285_714_285_715;

    function defaultPreset(address migrator) internal pure returns (LaunchPreset memory p) {
        (uint256 vT0, uint256 vM0) =
            BondingCurveMath.deriveVirtualReserves(CURVE_SUPPLY, LP_SUPPLY, TARGET_RAISE, GRADUATION_FEE_BPS);
        p.virtualTokenReserve0 = uint128(vT0);
        p.virtualMonReserve0 = uint128(vM0);
        p.curveSupply = uint128(CURVE_SUPPLY);
        p.lpSupply = uint128(LP_SUPPLY);
        p.tradeFeeBps = TRADE_FEE_BPS;
        p.graduationFeeBps = GRADUATION_FEE_BPS;
        p.curveFeeSplit = FeeSplit({creatorBps: 3000, protocolBps: 6000, referrerBps: 1000});
        // Post-graduation split is a Phase 3 decision; placeholder without referrer share.
        p.lpFeeSplit = FeeSplit({creatorBps: 7000, protocolBps: 3000, referrerBps: 0});
        p.snipeFeeBps = SNIPE_FEE_BPS;
        p.snipeDecayBlocks = SNIPE_DECAY_BLOCKS;
        p.maxBuyBps = MAX_BUY_BPS;
        p.maxDevBuyBps = MAX_DEV_BUY_BPS;
        p.migrator = migrator;
        p.enabled = true;
    }
}
