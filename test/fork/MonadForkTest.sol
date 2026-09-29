// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Test} from "forge-std/Test.sol";

import {MigratorDefaults, MonadNetwork} from "../../script/config/MonadAddresses.sol";
import {Presets} from "../../script/config/Presets.sol";
import {BondingCurveManager} from "../../src/BondingCurveManager.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {LiquidityMigrator} from "../../src/LiquidityMigrator.sol";
import {TokenFactory} from "../../src/TokenFactory.sol";
import {CreateParams} from "../../src/types/LaunchpadTypes.sol";
import {V4TestRouter} from "../utils/V4TestRouter.sol";

/// @notice Fork-first fixture (approved Phase 0 decision): the full launchpad deployed on a fork of a Monad network
///         (mainnet 143 or testnet 10143) at a pinned block, graduating into that network's real Uniswap v4
///         PoolManager. Needs the network's RPC variable (`MONAD_RPC_URL` / `MONAD_TESTNET_RPC_URL`); without it
///         every test of the suite is skipped.
abstract contract MonadForkTest is Test {
    uint32 internal constant PRESET_ID = Presets.DEFAULT_PRESET_ID;

    MonadNetwork internal network;
    IPoolManager internal poolManager;

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

        factory = new TokenFactory(owner, treasury);
        migrator = _deployMigrator(hookAddress("launchpad.migrator"));
        vm.prank(owner);
        factory.setPreset(PRESET_ID, Presets.defaultPreset(address(migrator)));
        (address t, address c) = factory.createToken(_params(bytes32("fork")));
        token = LaunchToken(t);
        curve = BondingCurveManager(c);
        router = new V4TestRouter(poolManager);

        vm.deal(alice, 100_000 ether);
        vm.deal(bob, 100_000 ether);
        vm.deal(whale, 100_000 ether);
    }

    /// @dev An address carrying exactly the BEFORE_INITIALIZE flag, derived from `label`.
    function hookAddress(string memory label) internal pure returns (address) {
        return
            address((uint160(uint256(keccak256(bytes(label)))) & ~Hooks.ALL_HOOK_MASK) | Hooks.BEFORE_INITIALIZE_FLAG);
    }

    function _deployMigrator(address target) internal returns (LiquidityMigrator) {
        deployCodeTo(
            "LiquidityMigrator.sol:LiquidityMigrator",
            abi.encode(poolManager, address(factory), MigratorDefaults.LP_FEE, MigratorDefaults.TICK_SPACING),
            target
        );
        return LiquidityMigrator(payable(target));
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
        (, uint256 fee,, uint256 refund) = curve.quoteBuy(5000 ether);
        vm.prank(whale);
        curve.buy{value: 5000 ether}(0, address(0));
        realMonAtCompletion = realMonBefore + (5000 ether - refund) - fee;
    }
}
