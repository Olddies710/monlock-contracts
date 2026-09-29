// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {MigratorDefaults, MonadMainnet, MonadNetwork, MonadNetworks} from "../../script/config/MonadAddresses.sol";
import {Presets} from "../../script/config/Presets.sol";
import {HookMiner} from "../../script/utils/HookMiner.sol";
import {BondingCurveManager} from "../../src/BondingCurveManager.sol";
import {TokenFactory} from "../../src/TokenFactory.sol";
import {CreateParams, CurveStatus} from "../../src/types/LaunchpadTypes.sol";
import {MonadForkTest} from "./MonadForkTest.sol";

/// @notice Gas of every transaction the launchpad sends or receives, on a fork of each Monad network with Monad's gas
///         pricing (`network = "monad"`, cold account 10,100 / cold SLOAD 8,100). Each measured call runs as its own
///         transaction (`isolate = true`), so values include the 21,000 base cost and calldata.
///         Written to `snapshots/<network>.json` and reviewed in diffs: Monad bills the gas *limit*, so these values
///         set the SDK's per-operation gas limits (ARCHITECTURE.md §1, DEPLOYMENT.md §6).
abstract contract GasProfileForkTest is MonadForkTest {
    address internal constant CREATE2_DEPLOYER = MonadMainnet.CREATE2_DEPLOYER;
    address internal referrer = makeAddr("referrer");
    address internal relayer = makeAddr("relayer");

    /// @dev The three deployment transactions of `Deploy`, at fresh addresses.
    function test_gasProfile_deployment() public {
        string memory group = network.name;
        // Creation code from the artifacts: embedding it would make this test contract itself too large.
        bytes memory factoryInit =
            abi.encodePacked(vm.getCode("TokenFactory.sol:TokenFactory"), abi.encode(owner, treasury));
        vm.prank(owner);
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(keccak256("gas-profile"), factoryInit));
        vm.snapshotGasLastFrame(group, "deploy_TokenFactory");
        assertTrue(ok);
        TokenFactory newFactory = TokenFactory(address(bytes20(ret)));

        bytes memory migratorInit = abi.encodePacked(
            vm.getCode("LiquidityMigrator.sol:LiquidityMigrator"),
            abi.encode(poolManager, newFactory, MigratorDefaults.LP_FEE, MigratorDefaults.TICK_SPACING)
        );
        vm.pauseGasMetering();
        (bytes32 salt, address newMigrator) =
            HookMiner.find(CREATE2_DEPLOYER, Hooks.BEFORE_INITIALIZE_FLAG, migratorInit, 0);
        vm.resumeGasMetering();
        vm.prank(owner);
        (ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, migratorInit));
        vm.snapshotGasLastFrame(group, "deploy_LiquidityMigrator");
        assertTrue(ok);

        vm.prank(owner);
        newFactory.setPreset(Presets.DEFAULT_PRESET_ID, Presets.defaultPreset(newMigrator));
        vm.snapshotGasLastFrame(group, "setPreset");
        vm.prank(owner);
        newFactory.transferOwnership(makeAddr("safe"));
        vm.snapshotGasLastFrame(group, "transferOwnership");
    }

    function test_gasProfile_launch() public {
        string memory group = network.name;
        factory.createToken(_p("gas-plain"));
        vm.snapshotGasLastFrame(group, "createToken");

        CreateParams memory p = _p("gas-dev-buy");
        p.minDevBuyOut = 1;
        factory.createToken{value: 1 ether}(p);
        vm.snapshotGasLastFrame(group, "createToken_devBuy");

        (address signer, uint256 key) = makeAddrAndKey("gas-signer");
        p = _p("gas-signed");
        p.creator = signer;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, factory.hashCreateToken(p, relayer, deadline));
        bytes memory signature = abi.encodePacked(r, s, v);
        vm.prank(relayer);
        factory.createTokenWithSig(p, deadline, signature);
        vm.snapshotGasLastFrame(group, "createTokenWithSig");
    }

    function test_gasProfile_trading() public {
        string memory group = network.name;

        vm.roll(curve.launchBlock() + 1);
        vm.prank(alice);
        curve.buy{value: 1 ether}(0, address(0));
        vm.snapshotGasLastFrame(group, "buy_snipeWindow_firstBuy");

        _rollPastSnipeWindow();
        vm.prank(bob);
        curve.buy{value: 10 ether}(0, address(0));
        vm.snapshotGasLastFrame(group, "buy_newHolder");

        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(bob);
        curve.buy{value: 10 ether}(0, address(0));
        vm.snapshotGasLastFrame(group, "buy_existingHolder");

        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(bob);
        curve.buy{value: 10 ether}(0, referrer);
        vm.snapshotGasLastFrame(group, "buy_withReferrer");

        vm.roll(vm.getBlockNumber() + 1);
        uint256 half = token.balanceOf(bob) / 2;
        vm.prank(bob);
        curve.sell(half, 0);
        vm.snapshotGasLastFrame(group, "sell");

        vm.prank(bob);
        curve.sellTo(bob, half / 2, 0, referrer, block.timestamp);
        vm.snapshotGasLastFrame(group, "sellTo_withReferrer");

        vm.prank(alice);
        token.transfer(bob, 1e18);
        vm.snapshotGasLastFrame(group, "token_transfer");

        curve.claimFees();
        vm.snapshotGasLastFrame(group, "claimFees");
        curve.claimReferrerFees(referrer);
        vm.snapshotGasLastFrame(group, "claimReferrerFees");
    }

    function test_gasProfile_graduation() public {
        string memory group = network.name;
        _rollPastSnipeWindow();
        vm.prank(whale);
        curve.buy{value: 5000 ether}(0, address(0));
        vm.snapshotGasLastFrame(group, "buy_graduation");
        assertEq(uint8(curve.state().status), uint8(CurveStatus.Graduated));

        // After graduation: a swap in the v4 pool (test router, for scale) and the LP fee payout.
        PoolKey memory key = migrator.poolKeyOf(address(token));
        vm.prank(alice);
        router.swapExactIn{value: 10 ether}(key, true, 10 ether);
        vm.snapshotGasLastFrame(group, "v4_swap_testRouter");
        migrator.collectFees(address(token));
        vm.snapshotGasLastFrame(group, "collectFees");
    }

    /// @dev A graduating buy sent with too little gas completes the curve and defers the migration.
    function test_gasProfile_deferredGraduation() public {
        string memory group = network.name;
        _rollPastSnipeWindow();
        for (uint256 gasLimit = 200_000; curve.state().status != CurveStatus.Completed; gasLimit += 20_000) {
            assertLe(gasLimit, 1_000_000, "no gas limit defers the migration");
            uint256 snapshot = vm.snapshotState();
            vm.prank(whale);
            (bool ok,) = address(curve).call{value: 5000 ether, gas: gasLimit}(
                abi.encodeCall(BondingCurveManager.buy, (0, address(0)))
            );
            if (!ok || curve.state().status != CurveStatus.Completed) vm.revertToState(snapshot);
        }

        vm.prank(bob);
        curve.graduate();
        vm.snapshotGasLastFrame(group, "graduate_retry");
        assertEq(uint8(curve.state().status), uint8(CurveStatus.Graduated));
    }

    function _p(string memory salt) internal view returns (CreateParams memory) {
        return _params(keccak256(bytes(salt)));
    }
}

contract GasProfileMainnetForkTest is GasProfileForkTest {
    function _network() internal pure override returns (MonadNetwork memory) {
        return MonadNetworks.mainnet();
    }
}

contract GasProfileTestnetForkTest is GasProfileForkTest {
    function _network() internal pure override returns (MonadNetwork memory) {
        return MonadNetworks.testnet();
    }
}
