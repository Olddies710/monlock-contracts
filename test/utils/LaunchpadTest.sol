// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Presets} from "../../script/config/Presets.sol";
import {BondingCurveManager} from "../../src/BondingCurveManager.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {TokenFactory} from "../../src/TokenFactory.sol";
import {CreateParams, CurveState, LaunchPreset} from "../../src/types/LaunchpadTypes.sol";
import {LaunchHarness} from "./LaunchHarness.sol";
import {MockMigrator} from "./Mocks.sol";

/// @notice Shared fixture on a Monad-like chain (chain id 143): the real TokenFactory with the approved preset
///         registered, and one default launch created through it.
abstract contract LaunchpadTest is Test {
    uint256 internal constant MONAD_CHAIN_ID = 143;
    uint32 internal constant PRESET_ID = Presets.DEFAULT_PRESET_ID;

    TokenFactory internal factory;
    MockMigrator internal migrator;
    LaunchToken internal token;
    BondingCurveManager internal curve;
    /// @dev Test double that deploys curves without factory-side validation (raw constructor tests only).
    LaunchHarness internal harness;

    address internal owner = makeAddr("owner");
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
        factory = new TokenFactory(owner, treasury);
        vm.prank(owner);
        factory.setPreset(PRESET_ID, Presets.defaultPreset(address(migrator)));
        harness = new LaunchHarness(treasury);

        (token, curve) = _launch(bytes32("default"));

        vm.deal(alice, 100_000 ether);
        vm.deal(bob, 100_000 ether);
        vm.deal(carol, 100_000 ether);
    }

    function _params(bytes32 salt) internal view returns (CreateParams memory p) {
        p.name = "Monad Cat";
        p.symbol = "MCAT";
        p.metadataURI = "ipfs://bafy-monad-cat";
        p.creator = creator;
        p.presetId = PRESET_ID;
        p.salt = salt;
        p.context = abi.encodePacked("cast:0xabc");
    }

    /// @dev Launch through the real factory (deployer = this test contract).
    function _launch(bytes32 salt) internal returns (LaunchToken token_, BondingCurveManager curve_) {
        (address t, address c) = factory.createToken(_params(salt));
        return (LaunchToken(t), BondingCurveManager(c));
    }

    /// @dev Launch through the test double, bypassing factory validation (constructor-level tests).
    function _launchRaw(LaunchPreset memory preset, bytes32 salt)
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
