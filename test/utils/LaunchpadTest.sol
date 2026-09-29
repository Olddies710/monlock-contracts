// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {BondingCurveManager} from "../../src/BondingCurveManager.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {CurveState, LaunchPreset} from "../../src/types/LaunchpadTypes.sol";
import {LaunchHarness} from "./LaunchHarness.sol";
import {MockMigrator} from "./Mocks.sol";
import {Presets} from "./Presets.sol";

/// @notice Shared fixture: one default launch on a Monad-like chain (chain id 143).
abstract contract LaunchpadTest is Test {
    uint256 internal constant MONAD_CHAIN_ID = 143;

    LaunchHarness internal harness;
    MockMigrator internal migrator;
    LaunchToken internal token;
    BondingCurveManager internal curve;

    address internal treasury = makeAddr("treasury");
    address internal creator = makeAddr("creator");
    address internal referrer = makeAddr("referrer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public virtual {
        // Monad chain id matters: Solady's reentrancy guard would fall back to persistent storage off mainnet
        // unless overridden (see BondingCurveManager._useTransientReentrancyGuardOnlyOnMainnet).
        vm.chainId(MONAD_CHAIN_ID);
        vm.roll(1_000_000);
        vm.warp(1_750_000_000);

        migrator = new MockMigrator();
        harness = new LaunchHarness(treasury);
        (token, curve) = _launch(Presets.defaultPreset(address(migrator)), bytes32("default"));

        vm.deal(alice, 100_000 ether);
        vm.deal(bob, 100_000 ether);
        vm.deal(carol, 100_000 ether);
    }

    function _launch(LaunchPreset memory preset, bytes32 salt)
        internal
        returns (LaunchToken token_, BondingCurveManager curve_)
    {
        return harness.launch(preset, "Monad Cat", "MCAT", creator, salt, 0);
    }

    function _rollPastSnipeWindow() internal {
        vm.roll(curve.launchBlock() + Presets.SNIPE_DECAY_BLOCKS);
    }

    function _buy(address who, uint256 monIn) internal returns (uint256) {
        vm.prank(who);
        return curve.buy{value: monIn}(0, address(0));
    }

    function _sell(address who, uint256 amount) internal returns (uint256) {
        vm.prank(who);
        return curve.sell(amount, 0);
    }

    function _state() internal view returns (CurveState memory) {
        return curve.state();
    }

    /// @dev MON needed to buy back every token the curve has sold, in one sell (no fees). Must never exceed the
    ///      reserve: this is the solvency invariant.
    function _grossToBuyBackCirculating() internal view returns (uint256) {
        CurveState memory s = curve.state();
        uint256 circulating = Presets.CURVE_SUPPLY - s.realTokenReserve;
        return s.virtualMonReserve * circulating / (s.virtualTokenReserve + circulating);
    }
}
