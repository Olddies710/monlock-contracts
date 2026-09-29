// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BondingCurveManager} from "../src/BondingCurveManager.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {IBondingCurveManager} from "../src/interfaces/IBondingCurveManager.sol";
import {BondingCurveMath} from "../src/libraries/BondingCurveMath.sol";
import {LaunchPresetLib} from "../src/libraries/LaunchPresetLib.sol";
import {CurveState, CurveStatus, FeeSplit, LaunchPreset} from "../src/types/LaunchpadTypes.sol";
import {LaunchpadTest} from "./utils/LaunchpadTest.sol";
import {MockMigrator, RejectingRecipient} from "./utils/Mocks.sol";
import {Presets} from "./utils/Presets.sol";

contract BondingCurveManagerTest is LaunchpadTest {
    uint256 internal constant REENTRANCY_GUARD_SLOT = 0x8000000000ab143c06; // Solady's lock slot
    uint256 internal constant REFERRER_FEES_SLOT = 4; // `referrerFees` mapping root

    // ------------------------------------------------------------------ deployment

    function test_initialState() public view {
        CurveState memory s = _state();
        assertEq(uint8(s.status), uint8(CurveStatus.Trading));
        assertEq(s.realMonReserve, 0);
        assertEq(s.realTokenReserve, Presets.CURVE_SUPPLY);
        assertEq(s.virtualMonReserve, Presets.EXPECTED_VM0);
        assertEq(s.virtualTokenReserve, Presets.EXPECTED_VT0);
        assertEq(s.currentFeeBps, Presets.SNIPE_FEE_BPS, "50% at the launch block");
        assertEq(curve.maxBuyAmount(), Presets.TOTAL_SUPPLY / 100, "1% of total supply per tx");
        assertEq(curve.creatorFeeRecipient(), creator);
        assertEq(curve.token(), address(token));
        assertEq(curve.factory(), address(harness));
        assertEq(curve.migrator(), address(migrator));
        assertEq(curve.launchBlock(), block.number);

        (uint256 vT0, uint256 vM0, uint256 c, uint256 l) = curve.curveParams();
        assertEq(vT0, Presets.EXPECTED_VT0);
        assertEq(vM0, Presets.EXPECTED_VM0);
        assertEq(c, Presets.CURVE_SUPPLY);
        assertEq(l, Presets.LP_SUPPLY);
        (uint256 tradeFee, uint256 gradFee, FeeSplit memory split,) = curve.feeParams();
        assertEq(tradeFee, 100);
        assertEq(gradFee, 500);
        assertEq(split.creatorBps, 3000);
        assertEq(split.protocolBps, 6000);
        assertEq(split.referrerBps, 1000);
        (uint256 snipeFee, uint256 decay, uint256 maxBuyBps, uint256 maxDevBuyBps) = curve.snipeParams();
        assertEq(snipeFee, 5000);
        assertEq(decay, 200);
        assertEq(maxBuyBps, 100);
        assertEq(maxDevBuyBps, 500);
    }

    function test_constructor_rejectsInvalidPresets() public {
        LaunchPreset memory p = Presets.defaultPreset(address(migrator));
        p.curveFeeSplit.referrerBps = 999;
        vm.expectRevert(LaunchPresetLib.InvalidFeeSplit.selector);
        _launch(p, bytes32("bad-split"));

        p = Presets.defaultPreset(address(0));
        vm.expectRevert(LaunchPresetLib.InvalidMigrator.selector);
        _launch(p, bytes32("bad-migrator"));

        p = Presets.defaultPreset(address(migrator));
        p.maxDevBuyBps = 8000; // dev buy could sell out the curve
        vm.expectRevert(LaunchPresetLib.InvalidBuyLimits.selector);
        _launch(p, bytes32("bad-devbuy"));

        p = Presets.defaultPreset(address(migrator));
        p.virtualTokenReserve0 = p.curveSupply;
        vm.expectRevert(LaunchPresetLib.InvalidVirtualReserves.selector);
        _launch(p, bytes32("bad-vt0"));

        p = Presets.defaultPreset(address(migrator));
        p.snipeFeeBps = 50; // below the base fee
        vm.expectRevert(LaunchPresetLib.InvalidFees.selector);
        _launch(p, bytes32("bad-fees"));
    }

    function test_rejectsPlainMonTransfers() public {
        vm.prank(alice);
        (bool ok,) = address(curve).call{value: 1 ether}("");
        assertFalse(ok, "no receive: every wei must be accounted");
    }

    // ------------------------------------------------------------------ buy

    function test_buy_matchesQuoteAndMath() public {
        _rollPastSnipeWindow();
        uint256 monIn = 10 ether;
        (uint256 qOut, uint256 qFee, uint256 qTax, uint256 qRefund) = curve.quoteBuy(monIn);
        assertEq(qFee, 0.1 ether, "1% base fee");
        assertEq(qTax, 0, "no tax after the window");
        assertEq(qRefund, 0);
        assertEq(qOut, BondingCurveMath.tokensOut(Presets.EXPECTED_VM0, Presets.EXPECTED_VT0, monIn - qFee));

        uint256 aliceMon = alice.balance;
        uint256 out = _buy(alice, monIn);

        assertEq(out, qOut, "quote == execution");
        assertEq(token.balanceOf(alice), out);
        assertEq(alice.balance, aliceMon - monIn);
        CurveState memory s = _state();
        assertEq(s.realMonReserve, monIn - qFee);
        assertEq(s.realTokenReserve, Presets.CURVE_SUPPLY - out);
        assertEq(s.totalFeesAccrued, qFee);
        assertEq(address(curve).balance, monIn, "every wei accounted: reserve + fees");
    }

    function test_buy_emitsTradeWithPostTradeReserves() public {
        _rollPastSnipeWindow();
        (uint256 out, uint256 fee,,) = curve.quoteBuy(10 ether);
        vm.expectEmit(address(curve));
        emit IBondingCurveManager.Trade(
            alice, alice, referrer, true, 10 ether, out, fee, 0, 10 ether - fee, Presets.CURVE_SUPPLY - out
        );
        vm.prank(alice);
        curve.buy{value: 10 ether}(out, referrer);
    }

    function test_buy_revertsOnSlippage() public {
        _rollPastSnipeWindow();
        (uint256 out,,,) = curve.quoteBuy(1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBondingCurveManager.InsufficientOutput.selector, out, out + 1));
        curve.buy{value: 1 ether}(out + 1, address(0));
    }

    function test_buy_revertsOnBadInputs() public {
        vm.startPrank(alice);
        vm.expectRevert(IBondingCurveManager.ZeroAmount.selector);
        curve.buy(0, address(0));
        vm.expectRevert(IBondingCurveManager.InvalidReferrer.selector);
        curve.buy{value: 1 ether}(0, address(curve));
        vm.expectRevert(IBondingCurveManager.InvalidRecipient.selector);
        curve.buyTo{value: 1 ether}(address(0), 0, address(0), block.timestamp);
        vm.expectRevert(IBondingCurveManager.InvalidRecipient.selector);
        curve.buyTo{value: 1 ether}(address(curve), 0, address(0), block.timestamp);
        vm.expectRevert(IBondingCurveManager.DeadlineExpired.selector);
        curve.buyTo{value: 1 ether}(bob, 0, address(0), block.timestamp - 1);
        vm.stopPrank();
    }

    function test_buyTo_sendsTokensToRecipient() public {
        _rollPastSnipeWindow();
        vm.prank(alice);
        uint256 out = curve.buyTo{value: 1 ether}(bob, 0, address(0), block.timestamp);
        assertEq(token.balanceOf(bob), out);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.lastBuyBlock(bob), vm.getBlockNumber(), "recipient is marked");
    }

    // ------------------------------------------------------------------ anti-snipe (§5.2, §5.3)

    function test_snipeFee_decaysByBlock() public {
        uint256 launch = curve.launchBlock();
        uint256[6] memory offsets = [uint256(0), 20, 50, 100, 150, 200];
        uint256[6] memory expected = [uint256(5000), 4069, 2856, 1325, 406, 100];
        for (uint256 i; i < offsets.length; ++i) {
            vm.roll(launch + offsets[i]);
            assertEq(curve.currentFeeBps(), expected[i]);
        }
    }

    function test_snipeTax_isDonatedToTheReserve() public {
        uint256 monIn = 5 ether;
        (, uint256 fee, uint256 tax,) = curve.quoteBuy(monIn);
        assertEq(fee, 0.05 ether, "recipients only get the 1% base fee");
        assertEq(tax, 2.45 ether, "50% total minus the base fee");

        _buy(alice, monIn);
        CurveState memory s = _state();
        assertEq(s.totalFeesAccrued, fee, "tax never reaches fee recipients");
        assertEq(s.realMonReserve, monIn - fee, "tax stays in the reserve");
        // The donation raised k by at least tax * vT: every holder's tokens are backed by more MON.
        assertGe(
            s.virtualMonReserve * s.virtualTokenReserve,
            Presets.EXPECTED_VM0 * Presets.EXPECTED_VT0 + tax * s.virtualTokenReserve
        );
    }

    function test_snipeTax_appliesToSells() public {
        uint256 bought = _buy(alice, 5 ether);
        vm.roll(vm.getBlockNumber() + 10); // still inside the window
        (uint256 monOut, uint256 fee, uint256 tax) = curve.quoteSell(bought);
        assertGt(tax, 0);
        CurveState memory before = _state();
        uint256 received = _sell(alice, bought);
        assertEq(received, monOut);
        assertEq(before.realMonReserve - _state().realMonReserve, monOut + fee, "tax stays in the reserve");
    }

    function test_maxBuy_enforcedOnlyDuringDecay() public {
        uint256 maxBuy = curve.maxBuyAmount();
        (uint256 out,,,) = curve.quoteBuy(20 ether);
        assertGt(out, maxBuy);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBondingCurveManager.MaxBuyExceeded.selector, out, maxBuy));
        curve.buy{value: 20 ether}(0, address(0));

        _rollPastSnipeWindow();
        assertEq(curve.maxBuyAmount(), type(uint256).max);
        assertGt(_buy(alice, 20 ether), maxBuy, "no cap after the window");
    }

    // ------------------------------------------------------------------ sell

    function test_sell_matchesQuoteAndPaysSeller() public {
        _rollPastSnipeWindow();
        uint256 bought = _buy(alice, 10 ether);
        vm.roll(vm.getBlockNumber() + 1);

        CurveState memory before = _state();
        (uint256 qOut, uint256 qFee, uint256 qTax) = curve.quoteSell(bought);
        assertEq(qTax, 0);
        uint256 aliceMon = alice.balance;
        uint256 out = _sell(alice, bought);

        assertEq(out, qOut);
        assertEq(alice.balance, aliceMon + out);
        assertEq(token.balanceOf(alice), 0);
        CurveState memory s = _state();
        assertEq(s.realTokenReserve, Presets.CURVE_SUPPLY);
        assertEq(before.realMonReserve - s.realMonReserve, out + qFee);
        assertEq(s.totalFeesAccrued, before.totalFeesAccrued + qFee);
        assertEq(address(curve).balance, s.realMonReserve + s.totalFeesAccrued, "every wei accounted");
    }

    function test_sell_revertsOnSlippageAndBadInputs() public {
        _rollPastSnipeWindow();
        uint256 bought = _buy(alice, 1 ether);
        vm.roll(vm.getBlockNumber() + 1);
        (uint256 out,,) = curve.quoteSell(bought);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBondingCurveManager.InsufficientOutput.selector, out, out + 1));
        curve.sell(bought, out + 1);
        vm.expectRevert(IBondingCurveManager.ZeroAmount.selector);
        curve.sell(0, 0);
        vm.expectRevert(IBondingCurveManager.InvalidRecipient.selector);
        curve.sellTo(address(curve), bought, 0, address(0), block.timestamp);
        vm.expectRevert(IBondingCurveManager.DeadlineExpired.selector);
        curve.sellTo(alice, bought, 0, address(0), block.timestamp - 1);
        vm.stopPrank();
    }

    function test_sellTo_paysRecipientAndCreditsReferrer() public {
        _rollPastSnipeWindow();
        uint256 bought = _buy(alice, 10 ether);
        vm.roll(vm.getBlockNumber() + 1);
        (uint256 out, uint256 fee,) = curve.quoteSell(bought);
        uint256 bobMon = bob.balance;
        vm.prank(alice);
        curve.sellTo(bob, bought, out, referrer, block.timestamp);
        assertEq(bob.balance, bobMon + out);
        assertEq(curve.referrerFees(referrer), fee / 10);
    }

    // ------------------------------------------------------------------ fees

    function test_fees_splitWithReferrerAndProtocolAsResidual() public {
        _rollPastSnipeWindow();
        vm.prank(alice);
        curve.buy{value: 10 ether}(0, referrer); // fee 0.1: referrer 0.01
        _buy(bob, 10 ether); // fee 0.1: no referrer

        assertEq(curve.referrerFees(referrer), 0.01 ether);
        (uint256 toCreator, uint256 toProtocol) = curve.claimableFees();
        assertEq(toCreator, 0.06 ether, "30% of 0.2");
        assertEq(toProtocol, 0.13 ether, "60% of 0.2 + the unreferred 10%");

        uint256 creatorMon = creator.balance;
        uint256 treasuryMon = treasury.balance;
        vm.expectEmit(address(curve));
        emit IBondingCurveManager.FeesClaimed(toCreator, toProtocol);
        curve.claimFees();
        assertEq(creator.balance, creatorMon + toCreator);
        assertEq(treasury.balance, treasuryMon + toProtocol);

        uint256 refMon = referrer.balance;
        assertEq(curve.claimReferrerFees(referrer), 0.01 ether);
        assertEq(referrer.balance, refMon + 0.01 ether);
        assertEq(curve.claimReferrerFees(referrer), 0, "nothing left");

        (toCreator, toProtocol) = curve.claimableFees();
        assertEq(toCreator + toProtocol, 0);
        assertEq(address(curve).balance, _state().realMonReserve, "only the reserve remains");
    }

    function test_claimFees_forcesPaymentToRejectingRecipient() public {
        _rollPastSnipeWindow();
        _buy(alice, 10 ether);
        RejectingRecipient rejecting = new RejectingRecipient();
        vm.prank(creator);
        curve.setCreatorFeeRecipient(address(rejecting));
        (uint256 toCreator,) = curve.claimableFees();
        curve.claimFees();
        assertEq(address(rejecting).balance, toCreator, "a reverting recipient cannot block claims");
    }

    function test_claimFees_keepsProtocolShareWhileTreasuryUnset() public {
        _rollPastSnipeWindow();
        _buy(alice, 10 ether);
        (uint256 toCreator, uint256 toProtocol) = curve.claimableFees();
        harness.setProtocolTreasury(address(0));
        curve.claimFees();
        assertEq(creator.balance, toCreator);
        (, uint256 stillOwed) = curve.claimableFees();
        assertEq(stillOwed, toProtocol, "not burned");

        harness.setProtocolTreasury(treasury);
        curve.claimFees();
        assertEq(treasury.balance, toProtocol);
    }

    function test_setCreatorFeeRecipient_access() public {
        vm.prank(alice);
        vm.expectRevert(IBondingCurveManager.OnlyCreator.selector);
        curve.setCreatorFeeRecipient(alice);

        vm.startPrank(creator);
        vm.expectRevert(IBondingCurveManager.InvalidRecipient.selector);
        curve.setCreatorFeeRecipient(address(0));
        vm.expectEmit(address(curve));
        emit IBondingCurveManager.CreatorFeeRecipientUpdated(bob);
        curve.setCreatorFeeRecipient(bob);
        vm.stopPrank();
        assertEq(curve.creatorFeeRecipient(), bob);
    }

    // ------------------------------------------------------------------ dev buy

    function test_devBuy_atomicWithCreationAtBaseFee() public {
        vm.deal(address(this), 10 ether);
        (LaunchToken t, BondingCurveManager c) = harness.launch{value: 10 ether}(
            Presets.defaultPreset(address(migrator)), "Dev Cat", "DCAT", creator, bytes32("dev"), 0
        );
        CurveState memory s = c.state();
        assertEq(s.totalFeesAccrued, 0.1 ether, "base fee only, no snipe tax");
        assertEq(s.realMonReserve, 9.9 ether);
        assertEq(t.balanceOf(creator), Presets.CURVE_SUPPLY - s.realTokenReserve);
    }

    function test_devBuy_isCapped() public {
        vm.deal(address(this), 100 ether);
        uint256 out = BondingCurveMath.tokensOut(Presets.EXPECTED_VM0, Presets.EXPECTED_VT0, 99 ether);
        uint256 cap = Presets.TOTAL_SUPPLY * Presets.MAX_DEV_BUY_BPS / 10_000;
        vm.expectRevert(abi.encodeWithSelector(IBondingCurveManager.MaxBuyExceeded.selector, out, cap));
        harness.launch{value: 100 ether}(
            Presets.defaultPreset(address(migrator)), "Dev Cat", "DCAT", creator, bytes32("dev-cap"), 0
        );
    }

    function test_devBuy_onlyFactoryAndOnlyFirst() public {
        vm.prank(alice);
        vm.expectRevert(IBondingCurveManager.OnlyFactory.selector);
        curve.devBuy{value: 1 ether}(0, alice);

        _buy(alice, 1 ether);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(IBondingCurveManager.DevBuyUnavailable.selector);
        harness.callDevBuy{value: 1 ether}(curve, 0, creator);
    }

    // ------------------------------------------------------------------ completion and graduation

    function test_soldOut_clipsRefundsFreezesAndGraduates() public {
        _rollPastSnipeWindow();
        uint256 monIn = 2500 ether;
        (uint256 qOut, uint256 qFee,, uint256 qRefund) = curve.quoteBuy(monIn);
        assertEq(qOut, Presets.CURVE_SUPPLY, "clipped to the remaining supply");
        uint256 monUsed = monIn - qRefund;
        uint256 realMonAtCompletion = monUsed - qFee;
        assertGe(realMonAtCompletion, Presets.TARGET_RAISE, "R = 2,000 MON reached");

        uint256 vTFinal = Presets.EXPECTED_VT0 - Presets.CURVE_SUPPLY;
        (uint256 gradFee, uint256 monLP, uint256 tokensLP) = BondingCurveMath.graduationAmounts(
            realMonAtCompletion, Presets.EXPECTED_VM0, vTFinal, Presets.LP_SUPPLY, Presets.GRADUATION_FEE_BPS
        );

        uint256 bobMon = bob.balance;
        vm.expectEmit(address(curve));
        emit IBondingCurveManager.CurveCompleted(realMonAtCompletion);
        vm.expectEmit(address(curve));
        emit IBondingCurveManager.Graduated(monLP, tokensLP, Presets.LP_SUPPLY - tokensLP, gradFee);
        _buy(bob, monIn);

        assertEq(bob.balance, bobMon - monUsed, "excess refunded");
        assertEq(token.balanceOf(bob), Presets.CURVE_SUPPLY);
        CurveState memory s = _state();
        assertEq(uint8(s.status), uint8(CurveStatus.Graduated));
        assertEq(s.realMonReserve, 0);
        assertEq(migrator.monReceived(), monLP);
        assertEq(migrator.tokensReceived(), tokensLP);
        assertEq(migrator.lastCurve(), address(curve));
        assertEq(token.balanceOf(address(curve)), 0, "unused LP reserve burned");
        assertEq(token.totalSupply(), Presets.TOTAL_SUPPLY - (Presets.LP_SUPPLY - tokensLP));
        assertGe(monLP * vTFinal, tokensLP * (Presets.EXPECTED_VM0 + realMonAtCompletion), "price continuity");

        (uint256 toCreator, uint256 toProtocol) = curve.claimableFees();
        assertEq(address(curve).balance, toCreator + toProtocol, "only fees remain");

        vm.prank(alice);
        vm.expectRevert(IBondingCurveManager.NotTrading.selector);
        curve.buy{value: 1 ether}(0, address(0));
        vm.expectRevert(IBondingCurveManager.NotTrading.selector);
        curve.quoteSell(1);
    }

    function test_soldOut_migrationFailureFreezesAndGraduateRetries() public {
        _rollPastSnipeWindow();
        migrator.setShouldRevert(true);

        vm.expectEmit(address(curve));
        emit IBondingCurveManager.MigrationFailed(abi.encodeWithSelector(MockMigrator.MockMigrationFailed.selector));
        _buy(bob, 2500 ether);

        assertEq(uint8(_state().status), uint8(CurveStatus.Completed), "frozen, awaiting graduation");
        assertGe(_state().realMonReserve, Presets.TARGET_RAISE);
        assertEq(token.balanceOf(address(curve)), Presets.LP_SUPPLY, "LP reserve untouched");

        vm.prank(alice);
        vm.expectRevert(IBondingCurveManager.NotTrading.selector);
        curve.buy{value: 1 ether}(0, address(0));
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(bob);
        vm.expectRevert(IBondingCurveManager.NotTrading.selector);
        curve.sell(1 ether, 0);

        vm.expectRevert(MockMigrator.MockMigrationFailed.selector);
        curve.graduate();

        migrator.setShouldRevert(false);
        vm.prank(carol); // permissionless
        curve.graduate();
        assertEq(uint8(_state().status), uint8(CurveStatus.Graduated));
        assertEq(migrator.calls(), 1);
    }

    function test_graduation_guards() public {
        vm.expectRevert(IBondingCurveManager.NotCompleted.selector);
        curve.graduate();
        vm.expectRevert(IBondingCurveManager.OnlySelf.selector);
        curve.executeGraduation();
    }

    // ------------------------------------------------------------------ Monad: storage isolation (§3)

    function test_unreferredBuyTouchesOnlyStoragePage0() public {
        _rollPastSnipeWindow();
        vm.record();
        _buy(alice, 1 ether);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(curve));
        assertGt(writes.length, 0);
        for (uint256 i; i < reads.length; ++i) {
            assertLt(uint256(reads[i]) >> 7, 1, "read outside page 0");
        }
        for (uint256 i; i < writes.length; ++i) {
            assertLt(uint256(writes[i]) >> 7, 1, "write outside page 0");
        }
        assertEq(vm.load(address(curve), bytes32(REENTRANCY_GUARD_SLOT)), bytes32(0), "lock is transient");
    }

    function test_referredBuyWritesOnlyTheReferrerLedgerOutsidePage0() public {
        _rollPastSnipeWindow();
        bytes32 ledgerSlot = keccak256(abi.encode(referrer, REFERRER_FEES_SLOT));
        vm.record();
        vm.prank(alice);
        curve.buy{value: 1 ether}(0, referrer);
        (, bytes32[] memory writes) = vm.accesses(address(curve));
        for (uint256 i; i < writes.length; ++i) {
            assertTrue(uint256(writes[i]) < 128 || writes[i] == ledgerSlot, "unexpected slot");
        }
    }

    function test_tradesOnDifferentLaunchesShareNoState() public {
        (LaunchToken otherToken, BondingCurveManager otherCurve) =
            _launch(Presets.defaultPreset(address(migrator)), bytes32("other"));
        vm.record();
        _buy(alice, 1 ether);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(otherCurve));
        assertEq(reads.length + writes.length, 0, "other curve untouched");
        (reads, writes) = vm.accesses(address(otherToken));
        assertEq(reads.length + writes.length, 0, "other token untouched");
    }
}
