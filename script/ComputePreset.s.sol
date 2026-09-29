// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LibString} from "solady/utils/LibString.sol";

import {BondingCurveMath} from "../src/libraries/BondingCurveMath.sol";
import {Presets} from "./config/Presets.sol";

/// @notice Preset calculator (ARCHITECTURE.md §4.5-§4.6). Derives the virtual reserves from the launch economics
///         and prints the price path and the graduation outcome, so a preset can be reviewed before `setPreset`.
/// @dev Pure simulation, no RPC and no broadcast:
///        forge script script/ComputePreset.s.sol                                   # approved preset
///        forge script script/ComputePreset.s.sol --sig "compute(uint256,uint256,uint256,uint16)" \
///          800000000000000000000000000 200000000000000000000000000 3000000000000000000000 500
///      Arguments: curveSupply, lpSupply, targetRaise (all in wei), graduationFeeBps.
contract ComputePreset is Script {
    uint256 private constant BPS = 10_000;

    function run() external pure {
        compute(Presets.CURVE_SUPPLY, Presets.LP_SUPPLY, Presets.TARGET_RAISE, Presets.GRADUATION_FEE_BPS);
    }

    function compute(uint256 curveSupply, uint256 lpSupply, uint256 targetRaise, uint16 graduationFeeBps) public pure {
        (uint256 vT0, uint256 vM0) =
            BondingCurveMath.deriveVirtualReserves(curveSupply, lpSupply, targetRaise, graduationFeeBps);
        uint256 supply = curveSupply + lpSupply;

        console.log("== Inputs");
        console.log(string.concat("  total supply        ", _fmt(supply, 0), " tokens"));
        console.log(string.concat("  curve supply (C)    ", _fmt(curveSupply, 0), " tokens"));
        console.log(string.concat("  LP supply (L)       ", _fmt(lpSupply, 0), " tokens"));
        console.log(string.concat("  target raise (R)    ", _fmt(targetRaise, 4), " MON"));
        console.log(string.concat("  graduation fee      ", LibString.toString(graduationFeeBps), " bps"));

        console.log("== LaunchPreset fields (wei)");
        console.log(string.concat("  virtualTokenReserve0 ", LibString.toString(vT0)));
        console.log(string.concat("  virtualMonReserve0   ", LibString.toString(vM0)));

        console.log("== Price path: sold % | MON raised | MON per 1M tokens | market cap (MON)");
        uint8[7] memory steps = [0, 10, 25, 50, 75, 90, 100];
        for (uint256 i; i < steps.length; ++i) {
            uint256 sold = curveSupply * steps[i] / 100;
            uint256 raised = sold == 0 ? 0 : BondingCurveMath.monInForTokens(vM0, vT0, sold);
            uint256 vM = vM0 + raised;
            uint256 vT = vT0 - sold;
            console.log(
                string.concat(
                    "  ",
                    LibString.toString(steps[i]),
                    "% | ",
                    _fmt(raised, 4),
                    " | ",
                    _fmt(vM * 1e6 * 1e18 / vT, 8),
                    " | ",
                    _fmt(supply * vM / vT, 2)
                )
            );
        }

        uint256 realMon = BondingCurveMath.monInForTokens(vM0, vT0, curveSupply);
        (uint256 fee, uint256 monLP, uint256 tokensLP) =
            BondingCurveMath.graduationAmounts(realMon, vM0, vT0 - curveSupply, lpSupply, graduationFeeBps);
        console.log("== Graduation (sold out in one buy, no anti-snipe donations)");
        console.log(
            string.concat(
                "  raised              ",
                _fmt(realMon, 4),
                " MON (R + ",
                LibString.toString(realMon - targetRaise),
                " wei)"
            )
        );
        console.log(string.concat("  graduation fee      ", _fmt(fee, 4), " MON"));
        console.log(string.concat("  liquidity           ", _fmt(monLP, 4), " MON + ", _fmt(tokensLP, 0), " tokens"));
        console.log(string.concat("  LP reserve burned   ", LibString.toString(lpSupply - tokensLP), " wei"));
        console.log(
            string.concat("  price multiple      x", _fmt((vM0 + realMon) * vT0 * 1e18 / (vT0 - curveSupply) / vM0, 2))
        );
    }

    /// @dev Formats an 18-decimal amount with `shown` decimals (truncated).
    function _fmt(uint256 wad, uint256 shown) private pure returns (string memory) {
        string memory whole = LibString.toString(wad / 1e18);
        if (shown == 0) return whole;
        string memory frac = LibString.toString((wad % 1e18) / 10 ** (18 - shown));
        while (bytes(frac).length < shown) {
            frac = string.concat("0", frac);
        }
        return string.concat(whole, ".", frac);
    }
}
