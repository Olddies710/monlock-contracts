// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Test} from "forge-std/Test.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {MigratorDefaults, MonadMainnet, MonadNetwork} from "../../script/config/MonadAddresses.sol";
import {Presets} from "../../script/config/Presets.sol";
import {DeployConfig, Deployment} from "../../script/utils/DeploymentLib.sol";
import {BondingCurveManager} from "../../src/BondingCurveManager.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {LiquidityMigrator} from "../../src/LiquidityMigrator.sol";
import {TokenFactory} from "../../src/TokenFactory.sol";
import {CreateParams} from "../../src/types/LaunchpadTypes.sol";
import {V4TestRouter} from "../utils/V4TestRouter.sol";

/// @notice Fork-first fixture (approved Phase 0 decision): the launchpad deployed by the production `Deploy` script
///         (CREATE2 factory, mined hook address, presets) on a fork of a Monad network (mainnet 143 or testnet
///         10143) at a pinned block, graduating into that network's real Uniswap v4 PoolManager. Needs the network's
///         RPC variable (`MONAD_RPC_URL` / `MONAD_TESTNET_RPC_URL`); without it every test of the suite is skipped.
abstract contract MonadForkTest is Test {
    uint32 internal constant PRESET_ID = Presets.DEFAULT_PRESET_ID;

    MonadNetwork internal network;
    IPoolManager internal poolManager;
    Deployment internal deployment;

    TokenFactory internal factory;
    LiquidityMigrator internal migrator;
    LaunchToken internal token;
    BondingCurveManager internal curve;
    V4TestRouter internal router;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal whale = makeAddr("whale");

    bool internal forked;

    /// @dev The Monad network this suite forks.
    function _network() internal pure virtual returns (MonadNetwork memory);

    function setUp() public virtual {
        network = _network();
        string memory rpc = vm.envOr(network.rpcEnv, string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, string.concat("set ", network.rpcEnv, " to run the ", network.name, " fork tests"));
            return;
        }
        vm.createSelectFork(rpc, network.forkBlock);
        assertEq(block.chainid, network.chainId);
        poolManager = IPoolManager(network.poolManager);
        forked = true;

        // The script contract embeds ~85 KB of creation code; its own deployment is not part of what we measure.
        vm.pauseGasMetering();
        Deploy script = Deploy(deployCode("Deploy.s.sol:Deploy"));
        vm.resumeGasMetering();
        deployment = script.deploy(_deployConfig(), owner);
        factory = TokenFactory(deployment.factory);
        migrator = LiquidityMigrator(payable(deployment.migrator));
        (address t, address c) = factory.createToken(_params(bytes32("fork")));
        token = LaunchToken(t);
        curve = BondingCurveManager(c);
        router = new V4TestRouter(poolManager);

        vm.deal(alice, 50 * Presets.TARGET_RAISE);
        vm.deal(bob, 50 * Presets.TARGET_RAISE);
        vm.deal(whale, 50 * Presets.TARGET_RAISE);
    }

    /// @dev Production parameters; `owner` deploys and keeps ownership (no Safe handoff in the fixture).
    function _deployConfig() internal view returns (DeployConfig memory cfg) {
        cfg.poolManager = network.poolManager;
        cfg.treasury = treasury;
        cfg.lpFee = MigratorDefaults.LP_FEE;
        cfg.tickSpacing = MigratorDefaults.TICK_SPACING;
        cfg.factorySalt = keccak256("launchpad.fork");
        cfg.smokePreset = network.chainId != MonadMainnet.CHAIN_ID;
    }

    function _params(bytes32 salt) internal view returns (CreateParams memory p) {
        p.name = "Monad Cat";
        p.symbol = "MCAT";
        p.metadataURI = "ipfs://bafy-monad-cat";
        p.creator = creator;
        p.presetId = PRESET_ID;
        p.salt = salt;
    }

    function _rollPastSnipeWindow() internal {
        uint256 end = curve.launchBlock() + Presets.SNIPE_DECAY_BLOCKS;
        if (vm.getBlockNumber() < end) vm.roll(end);
    }

    /// @dev Sells the curve out in one buy after the anti-snipe window; returns the reserve at completion.
    function _graduate() internal returns (uint256 realMonAtCompletion) {
        _rollPastSnipeWindow();
        uint256 realMonBefore = curve.state().realMonReserve;
        (, uint256 fee,, uint256 refund) = curve.quoteBuy(Presets.TARGET_RAISE * 5 / 2);
        vm.prank(whale);
        curve.buy{value: Presets.TARGET_RAISE * 5 / 2}(0, address(0));
        realMonAtCompletion = realMonBefore + (Presets.TARGET_RAISE * 5 / 2 - refund) - fee;
    }
}
