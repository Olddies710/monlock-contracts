// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Presets} from "../script/config/Presets.sol";
import {BondingCurveMath} from "../src/libraries/BondingCurveMath.sol";

/// @dev External wrapper so reverts of internal library functions can be asserted.
contract MathWrapper {
    function deriveVirtualReserves(uint256 c, uint256 l, uint256 r, uint256 g)
        external
        pure
        returns (uint256, uint256)
    {
        return BondingCurveMath.deriveVirtualReserves(c, l, r, g);
    }
}

contract BondingCurveMathTest is Test {
    uint256 internal constant BPS = 10_000;

    MathWrapper internal wrapper = new MathWrapper();

    // ------------------------------------------------------------------ parameter derivation (§4.5)

    function test_deriveVirtualReserves_approvedPreset() public pure {
        (uint256 vT0, uint256 vM0) = BondingCurveMath.deriveVirtualReserves(
            Presets.CURVE_SUPPLY, Presets.LP_SUPPLY, Presets.TARGET_RAISE, Presets.GRADUATION_FEE_BPS
        );
        assertEq(vT0, Presets.EXPECTED_VT0, "vT0 = 0.95 * C^2 / (0.95 * C - L)");
        assertEq(vM0, Presets.EXPECTED_VM0, "vM0 = R * (vT0 - C) / C = 5R/14");
    }

    /// @notice With rho = 1 the formula reproduces pump.fun's public parameters (1,073M tokens / 30 SOL).
    function test_deriveVirtualReserves_reproducesPumpFun() public pure {
        (uint256 vT0, uint256 vM0) = BondingCurveMath.deriveVirtualReserves(793_100_000e18, 206_900_000e18, 85 ether, 0);
        assertApproxEqRel(vT0, 1_073_000_000e18, 0.0001e18, "vT0 ~ 1,073M");
        assertApproxEqRel(vM0, 30 ether, 0.0001e18, "vM0 ~ 30");
    }

    function test_approvedPreset_sellingOutRaisesTarget() public pure {
        uint256 raised =
            BondingCurveMath.monInForTokens(Presets.EXPECTED_VM0, Presets.EXPECTED_VT0, Presets.CURVE_SUPPLY);
        assertGe(raised, Presets.TARGET_RAISE, "never below R");
        assertLe(raised, Presets.TARGET_RAISE + 10, "R plus rounding wei only");
    }

    function test_approvedPreset_graduationIsPriceContinuous() public pure {
        uint256 realMon =
            BondingCurveMath.monInForTokens(Presets.EXPECTED_VM0, Presets.EXPECTED_VT0, Presets.CURVE_SUPPLY);
        uint256 vTFinal = Presets.EXPECTED_VT0 - Presets.CURVE_SUPPLY;
        (uint256 fee, uint256 monLP, uint256 tokensLP) = BondingCurveMath.graduationAmounts(
            realMon, Presets.EXPECTED_VM0, vTFinal, Presets.LP_SUPPLY, Presets.GRADUATION_FEE_BPS
        );
        assertEq(fee + monLP, realMon, "MON fully allocated");
        assertApproxEqAbs(fee, 100 ether, 1, "5% of R");
        assertLe(tokensLP, Presets.LP_SUPPLY);
        assertLt(Presets.LP_SUPPLY - tokensLP, 1e6, "only rounding dust of L is burned");
        // DEX opening price monLP / tokensLP >= curve final price vM_f / vT_f.
        assertGe(monLP * vTFinal, tokensLP * (Presets.EXPECTED_VM0 + realMon));
    }

    function test_deriveVirtualReserves_revertsWhenLpTooLarge() public {
        // rho * C must exceed L: 0.95 * 800M = 760M <= 760M.
        vm.expectRevert(BondingCurveMath.InvalidCurveParameters.selector);
        wrapper.deriveVirtualReserves(800_000_000e18, 760_000_000e18, 2000 ether, 500);
        vm.expectRevert(BondingCurveMath.InvalidCurveParameters.selector);
        wrapper.deriveVirtualReserves(0, 1, 2000 ether, 500);
        vm.expectRevert(BondingCurveMath.InvalidCurveParameters.selector);
        wrapper.deriveVirtualReserves(800_000_000e18, 200_000_000e18, 0, 500);
        vm.expectRevert(BondingCurveMath.InvalidCurveParameters.selector);
        wrapper.deriveVirtualReserves(800_000_000e18, 200_000_000e18, 2000 ether, BPS);
    }

    // ------------------------------------------------------------------ anti-snipe schedule (§5.2)

    function test_feeBpsAt_approvedSchedule() public pure {
        uint256[7] memory blocks = [uint256(0), 20, 50, 100, 150, 199, 200];
        uint256[7] memory expected = [uint256(5000), 4069, 2856, 1325, 406, 100, 100];
        for (uint256 i; i < blocks.length; ++i) {
            assertEq(BondingCurveMath.feeBpsAt(blocks[i], 100, 5000, 200), expected[i]);
        }
        assertEq(BondingCurveMath.feeBpsAt(10_000, 100, 5000, 200), 100, "base forever after the window");
        assertEq(BondingCurveMath.feeBpsAt(0, 100, 5000, 0), 100, "no window");
    }

    function testFuzz_feeBpsAt_decaysMonotonically(uint256 b1, uint256 b2, uint16 base, uint16 max, uint32 decay)
        public
        pure
    {
        base = uint16(bound(base, 0, 200));
        max = uint16(bound(max, base, 9000));
        b1 = bound(b1, 0, uint256(decay) + 10);
        b2 = bound(b2, b1, uint256(decay) + 10);
        uint256 f1 = BondingCurveMath.feeBpsAt(b1, base, max, decay);
        uint256 f2 = BondingCurveMath.feeBpsAt(b2, base, max, decay);
        assertGe(f1, f2, "non-increasing");
        assertGe(f2, base);
        assertLe(f1, max);
    }

    // ------------------------------------------------------------------ swaps: k never decreases (I1)

    function testFuzz_tokensOut_neverDecreasesK(uint256 vM, uint256 vT, uint256 monIn) public pure {
        (vM, vT) = _boundReserves(vM, vT);
        monIn = bound(monIn, 1, 1e30);
        uint256 out = BondingCurveMath.tokensOut(vM, vT, monIn);
        assertLt(out, vT, "never drains the virtual reserve");
        assertGe((vM + monIn) * (vT - out), vM * vT);
    }

    function testFuzz_monOut_neverDecreasesK(uint256 vM, uint256 vT, uint256 amount) public pure {
        (vM, vT) = _boundReserves(vM, vT);
        amount = bound(amount, 1, 1e30);
        uint256 gross = BondingCurveMath.monOut(vM, vT, amount);
        assertLt(gross, vM);
        assertGe((vM - gross) * (vT + amount), vM * vT);
    }

    function testFuzz_monInForTokens_isTightInverse(uint256 vM, uint256 vT, uint256 amount) public pure {
        (vM, vT) = _boundReserves(vM, vT);
        amount = bound(amount, 1, vT - 1);
        uint256 monIn = BondingCurveMath.monInForTokens(vM, vT, amount);
        assertGe(BondingCurveMath.tokensOut(vM, vT, monIn), amount, "enough MON for the tokens");
        assertLt(BondingCurveMath.tokensOut(vM, vT, monIn - 1), amount, "one wei less is not enough");
        assertGe((vM + monIn) * (vT - amount), vM * vT, "k preserved");
    }

    /// @dev Splitting a sale never pays more than selling at once: no rounding arbitrage against the curve.
    function testFuzz_splitSellNeverBeatsSingleSell(uint256 vM, uint256 vT, uint256 a, uint256 b) public pure {
        (vM, vT) = _boundReserves(vM, vT);
        a = bound(a, 1, 1e28);
        b = bound(b, 1, 1e28);
        uint256 first = BondingCurveMath.monOut(vM, vT, a);
        uint256 second = BondingCurveMath.monOut(vM - first, vT + a, b);
        assertLe(first + second, BondingCurveMath.monOut(vM, vT, a + b));
    }

    // ------------------------------------------------------------------ fees

    function testFuzz_splitFees_roundsAgainstTheUser(uint256 gross, uint16 base, uint16 total) public pure {
        gross = bound(gross, 0, 1e30);
        base = uint16(bound(base, 0, 200));
        total = uint16(bound(total, base, 9000));
        (uint256 fee, uint256 tax) = BondingCurveMath.splitFees(gross, total, base);
        assertGe(fee * BPS, gross * base, "fee rounds up");
        assertGe((fee + tax) * BPS, gross * total, "total rounds up");
        assertLe(fee + tax, gross, "never more than the amount");
    }

    function testFuzz_grossUp_isMinimal(uint256 net, uint16 feeBps) public pure {
        net = bound(net, 1, 1e30);
        feeBps = uint16(bound(feeBps, 0, 9000));
        uint256 gross = BondingCurveMath.grossUp(net, feeBps);
        assertGe(_netOf(gross, feeBps), net, "covers net");
        assertLt(_netOf(gross - 1, feeBps), net, "smallest such gross");
    }

    // ------------------------------------------------------------------ graduation (§4.7)

    /// @dev For any raise >= R (donations included), the DEX never opens below the curve's final price.
    function testFuzz_graduationAmounts_neverOpensBelowCurvePrice(uint256 realMon) public pure {
        uint256 vTFinal = Presets.EXPECTED_VT0 - Presets.CURVE_SUPPLY;
        realMon = bound(realMon, Presets.TARGET_RAISE, 1_000_000 ether);
        (uint256 fee, uint256 monLP, uint256 tokensLP) = BondingCurveMath.graduationAmounts(
            realMon, Presets.EXPECTED_VM0, vTFinal, Presets.LP_SUPPLY, Presets.GRADUATION_FEE_BPS
        );
        assertEq(fee + monLP, realMon);
        assertLe(tokensLP, Presets.LP_SUPPLY);
        assertGe(monLP * vTFinal, tokensLP * (Presets.EXPECTED_VM0 + realMon));
    }

    // ------------------------------------------------------------------ helpers

    function _boundReserves(uint256 vM, uint256 vT) private pure returns (uint256, uint256) {
        return (bound(vM, 1e9, 1e30), bound(vT, 1e9, 1e30));
    }

    function _netOf(uint256 gross, uint256 feeBps) private pure returns (uint256) {
        return gross - (gross * feeBps + BPS - 1) / BPS;
    }
}
