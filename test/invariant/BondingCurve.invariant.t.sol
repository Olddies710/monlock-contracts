// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";

import {Presets} from "../../script/config/Presets.sol";
import {CurveState, CurveStatus} from "../../src/types/LaunchpadTypes.sol";
import {LaunchpadTest} from "../utils/LaunchpadTest.sol";
import {CurveHandler} from "./CurveHandler.sol";

/// @notice Stateful invariants of one launch under arbitrary sequences of actions (ARCHITECTURE.md §4.4, §4.9).
contract BondingCurveInvariantTest is LaunchpadTest {
    CurveHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new CurveHandler(curve, migrator, creator, treasury);

        // Repeated selectors weight the campaign towards trading.
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = CurveHandler.buy.selector;
        selectors[1] = CurveHandler.buy.selector;
        selectors[2] = CurveHandler.buy.selector;
        selectors[3] = CurveHandler.sell.selector;
        selectors[4] = CurveHandler.sell.selector;
        selectors[5] = CurveHandler.transfer.selector;
        selectors[6] = CurveHandler.roll.selector;
        selectors[7] = CurveHandler.claimFees.selector;
        selectors[8] = CurveHandler.claimReferrerFees.selector;
        selectors[9] = CurveHandler.setMigratorFailing.selector;
        selectors[10] = CurveHandler.graduate.selector;
        selectors[11] = CurveHandler.buyOut.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Coverage report per run (`forge test -vv`): proves the campaign really trades, completes and graduates.
    function afterInvariant() external view {
        console.log("buys", handler.buys(), "sells", handler.sells());
        console.log("failed migrations", handler.completionsWithFailedMigration(), "graduations", handler.graduations());
    }

    /// @notice I1 + solvency: k never decreases, so the reserve can always pay every holder who sells back.
    function invariant_reserveAlwaysBacksAllSales() public view {
        CurveState memory s = curve.state();
        if (s.status != CurveStatus.Trading) return;
        assertGe(s.virtualMonReserve * s.virtualTokenReserve, Presets.EXPECTED_VM0 * Presets.EXPECTED_VT0, "k");
        assertLe(_grossToBuyBackCirculating(), s.realMonReserve, "insolvent");
    }

    /// @notice I2, exact: every wei held by the curve belongs to the reserve or to a fee recipient. No
    ///         unattributed dust ever accumulates (claimableFees would also revert on over-claiming).
    function invariant_everyWeiIsAttributed() public view {
        (uint256 toCreator, uint256 toProtocol) = curve.claimableFees();
        uint256 referrerOwed;
        for (uint256 i; i < handler.referrerCount(); ++i) {
            referrerOwed += curve.referrerFees(handler.referrers(i));
        }
        assertEq(address(curve).balance, curve.state().realMonReserve + toCreator + toProtocol + referrerOwed);
    }

    /// @notice MON conservation across the whole system: in - out == held + migrated + fees paid.
    function invariant_monIsConserved() public view {
        assertEq(
            handler.ghostMonIn() - handler.ghostMonToSellers(),
            address(curve).balance + migrator.monReceived() + handler.ghostFeesPaid()
        );
    }

    /// @notice I3 + supply: the curve holds exactly its unsold supply plus the LP reserve until graduation, and
    ///         tokens are only ever moved or burned.
    function invariant_tokenInventory() public view {
        CurveState memory s = curve.state();
        uint256 curveBalance = token.balanceOf(address(curve));
        if (s.status == CurveStatus.Graduated) {
            assertEq(curveBalance, 0, "all LP reserve migrated or burned");
        } else {
            assertEq(curveBalance, s.realTokenReserve + Presets.LP_SUPPLY);
            assertEq(token.totalSupply(), Presets.TOTAL_SUPPLY, "no burn before graduation");
        }
        uint256 held = curveBalance + token.balanceOf(address(migrator));
        for (uint256 i; i < handler.actorCount(); ++i) {
            held += token.balanceOf(handler.actors(i));
        }
        assertEq(held, token.totalSupply());
    }

    /// @notice I4: the lifecycle only moves forward.
    function invariant_statusNeverRegresses() public view {
        assertFalse(handler.ghostStatusRegressed());
    }

    /// @notice Sell-out implies the target raise, and the DEX never opens below the curve's final price.
    function invariant_graduationRaisesTargetAtContinuousPrice() public view {
        uint256 realMonAtCompletion = handler.ghostRealMonAtCompletion();
        if (realMonAtCompletion == 0) return;
        assertGe(realMonAtCompletion, Presets.TARGET_RAISE, "R not reached");
        if (curve.state().status != CurveStatus.Graduated) return;
        uint256 vTFinal = Presets.EXPECTED_VT0 - Presets.CURVE_SUPPLY;
        assertGe(
            migrator.monReceived() * vTFinal,
            migrator.tokensReceived() * (Presets.EXPECTED_VM0 + realMonAtCompletion),
            "DEX would open below the curve price"
        );
    }
}
