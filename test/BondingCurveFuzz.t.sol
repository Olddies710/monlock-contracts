// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Presets} from "../script/config/Presets.sol";
import {CurveState, CurveStatus} from "../src/types/LaunchpadTypes.sol";
import {LaunchpadTest} from "./utils/LaunchpadTest.sol";

contract BondingCurveFuzzTest is LaunchpadTest {
    address internal referrer2 = makeAddr("referrer2");

    // ------------------------------------------------------------------ quotes are exact

    function testFuzz_buy_quoteMatchesExecution(uint256 monIn, uint256 blocks) public {
        vm.roll(curve.launchBlock() + bound(blocks, 0, 400));
        monIn = bound(monIn, 1e6, R * 3 / 4);
        (uint256 qOut, uint256 qFee,, uint256 qRefund) = curve.quoteBuy(monIn);
        vm.assume(qOut != 0 && qOut <= curve.maxBuyAmount());

        uint256 aliceMon = alice.balance;
        uint256 out = _buy(alice, monIn);

        assertEq(out, qOut);
        assertEq(qRefund, 0, "0.75 R never sells out the curve");
        assertEq(alice.balance, aliceMon - monIn);
        CurveState memory s = _state();
        assertEq(s.realMonReserve, monIn - qFee);
        assertEq(s.totalFeesAccrued, qFee);
        _assertSolvent();
    }

    function testFuzz_sell_quoteMatchesExecution(uint256 monIn, uint256 fraction, uint256 blocks) public {
        _rollPastSnipeWindow();
        monIn = bound(monIn, 0.001 ether, R * 3 / 4);
        uint256 bought = _buy(alice, monIn);
        vm.roll(vm.getBlockNumber() + 1 + bound(blocks, 0, 50));
        uint256 amount = bound(fraction, 1, bought);
        (uint256 qOut, uint256 qFee, uint256 qTax) = curve.quoteSell(amount);
        vm.assume(qOut != 0);

        CurveState memory before = _state();
        uint256 aliceMon = alice.balance;
        uint256 out = _sell(alice, amount);

        assertEq(out, qOut);
        assertEq(alice.balance, aliceMon + out);
        assertEq(before.realMonReserve - _state().realMonReserve, out + qFee, "reserve pays out + fee; tax stays");
        assertEq(qTax, 0, "after the window");
        _assertSolvent();
    }

    // ------------------------------------------------------------------ no free money

    /// @dev Buying and selling everything back (in a later block, as the guard requires) never returns more MON
    ///      than was paid, whatever the point in the anti-snipe schedule.
    function testFuzz_roundTripNeverProfits(uint256 monIn, uint256 buyBlock, uint256 gap) public {
        vm.roll(curve.launchBlock() + bound(buyBlock, 0, 300));
        monIn = bound(monIn, 1e9, R * 3 / 4);
        (uint256 q,,,) = curve.quoteBuy(monIn);
        vm.assume(q != 0 && q <= curve.maxBuyAmount());

        uint256 bought = _buy(alice, monIn);
        vm.roll(vm.getBlockNumber() + bound(gap, 1, 300));
        (uint256 qOut,,) = curve.quoteSell(bought);
        vm.assume(qOut != 0);
        assertLt(_sell(alice, bought), monIn);
        _assertSolvent();
    }

    /// @dev The buy that sells out the curve is clipped to the exact remaining supply and refunds the rest.
    function testFuzz_soldOutBuy_isClippedAndRefundedExactly(uint256 prior, uint256 whaleIn) public {
        _rollPastSnipeWindow();
        prior = bound(prior, 0, R * 95 / 100);
        if (prior >= 1 ether) _buy(bob, prior);
        uint256 remaining = _state().realTokenReserve;
        uint256 realMonBefore = _state().realMonReserve;

        whaleIn = bound(whaleIn, R * 105 / 100, 25 * R);
        vm.deal(carol, whaleIn);
        (uint256 qOut, uint256 qFee,, uint256 qRefund) = curve.quoteBuy(whaleIn);
        uint256 out = _buy(carol, whaleIn);

        assertEq(out, remaining, "exactly the remaining supply");
        assertEq(qOut, out);
        assertEq(carol.balance, qRefund, "refund == msg.value - MON used");
        uint256 realMonAtCompletion = realMonBefore + (whaleIn - qRefund) - qFee;
        assertGe(realMonAtCompletion, Presets.TARGET_RAISE, "sold out => R raised");
        assertEq(uint8(_state().status), uint8(CurveStatus.Graduated));
    }

    // ------------------------------------------------------------------ full lifecycle: no dust

    /// @dev Random trading (with and without referrers, across the snipe window), then sell-out, graduation and
    ///      every claim. Afterwards the curve holds exactly 0 wei and 0 tokens, and MON is conserved:
    ///      paid in - paid to sellers == liquidity + fees paid out.
    function testFuzz_lifecycle_everyWeiAccounted(uint256 seed) public {
        address[3] memory traders = [alice, bob, carol];
        address[3] memory refs = [address(0), referrer, referrer2];
        uint256 monIn;
        uint256 monOut;

        for (uint256 i; i < 12; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            vm.roll(vm.getBlockNumber() + r % 40);
            address who = traders[r % 3];
            if ((r >> 8) % 3 != 0) {
                uint256 amount = bound(r >> 16, 0.01 ether, R * 3 / 40);
                (uint256 q,,,) = curve.quoteBuy(amount);
                if (q == 0 || q > curve.maxBuyAmount() || q >= _state().realTokenReserve) continue;
                vm.prank(who);
                curve.buy{value: amount}(0, refs[(r >> 128) % 3]);
                monIn += amount;
            } else {
                uint256 balance = token.balanceOf(who);
                if (balance == 0) continue;
                if (token.lastBuyBlock(who) == vm.getBlockNumber()) vm.roll(vm.getBlockNumber() + 1);
                uint256 amount = bound(r >> 16, 1, balance);
                (uint256 q,,) = curve.quoteSell(amount);
                if (q == 0) continue;
                vm.prank(who);
                monOut += curve.sell(amount, 0);
            }
            _assertSolvent();
        }

        // Sell out after the window, then claim everything.
        uint256 afterWindow = curve.launchBlock() + Presets.SNIPE_DECAY_BLOCKS;
        if (vm.getBlockNumber() < afterWindow) vm.roll(afterWindow);
        address whale = makeAddr("whale");
        vm.deal(whale, 5 * R);
        vm.prank(whale);
        curve.buy{value: 5 * R}(0, referrer);
        monIn += 5 * R - whale.balance;
        assertEq(uint8(_state().status), uint8(CurveStatus.Graduated));

        curve.claimFees();
        curve.claimReferrerFees(referrer);
        curve.claimReferrerFees(referrer2);

        assertEq(address(curve).balance, 0, "no MON dust left in the curve");
        assertEq(token.balanceOf(address(curve)), 0, "no token dust left in the curve");
        assertEq(
            monIn - monOut,
            migrator.monReceived() + creator.balance + treasury.balance + referrer.balance + referrer2.balance,
            "MON conserved"
        );
    }

    // ------------------------------------------------------------------ helpers

    function _assertSolvent() internal view {
        CurveState memory s = _state();
        if (s.status != CurveStatus.Trading) return;
        assertGe(
            s.virtualMonReserve * s.virtualTokenReserve, Presets.EXPECTED_VM0 * Presets.EXPECTED_VT0, "k decreased"
        );
        assertLe(_grossToBuyBackCirculating(), s.realMonReserve, "reserve cannot pay every seller");
    }
}
