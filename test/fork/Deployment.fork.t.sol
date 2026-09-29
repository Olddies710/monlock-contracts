// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CheckDeployment} from "../../script/CheckDeployment.s.sol";
import {SmokeLaunch} from "../../script/SmokeLaunch.s.sol";
import {MonadMainnet, MonadNetwork, MonadNetworks} from "../../script/config/MonadAddresses.sol";
import {Presets} from "../../script/config/Presets.sol";
import {BondingCurveManager} from "../../src/BondingCurveManager.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {CurveStatus} from "../../src/types/LaunchpadTypes.sol";
import {MonadForkTest} from "./MonadForkTest.sol";

/// @notice The deployment scripts against the real networks: the checker passes on the production deployment wired to
///         the real PoolManager, and the smoke script runs its whole lifecycle on testnet.
abstract contract DeploymentForkTest is MonadForkTest {
    function test_checkDeployment_passesOnTheRealPoolManager() public {
        vm.pauseGasMetering(); // script contract size, not under test
        CheckDeployment checker = CheckDeployment(deployCode("CheckDeployment.s.sol:CheckDeployment"));
        vm.resumeGasMetering();
        CheckDeployment.Result memory r = checker.check(deployment);
        assertEq(r.failures, 0);
        // The fixture keeps the deployer as owner: only mainnet asks for a Safe.
        assertEq(r.warnings, network.chainId == MonadMainnet.CHAIN_ID ? 1 : 0);
    }

    function test_smokePreset_onlyOffMainnet() public view {
        assertEq(factory.preset(Presets.SMOKE_PRESET_ID).enabled, network.chainId != MonadMainnet.CHAIN_ID);
    }

    // ------------------------------------------------------------------ helpers

    function _smokeScript() internal returns (SmokeLaunch smoke) {
        vm.pauseGasMetering();
        smoke = SmokeLaunch(deployCode("SmokeLaunch.s.sol:SmokeLaunch"));
        vm.resumeGasMetering();
    }
}

contract DeploymentMainnetForkTest is DeploymentForkTest {
    function _network() internal pure override returns (MonadNetwork memory) {
        return MonadNetworks.mainnet();
    }

    function test_smokeLaunch_refusesMainnet() public {
        SmokeLaunch smoke = _smokeScript();
        vm.expectRevert(SmokeLaunch.MainnetNotAllowed.selector);
        smoke.launch();
    }
}

contract DeploymentTestnetForkTest is DeploymentForkTest {
    function _network() internal pure override returns (MonadNetwork memory) {
        return MonadNetworks.testnet();
    }

    /// @notice DEPLOYMENT.md §5 end to end: launch with dev buy, trade inside the anti-snipe window, buy out the curve
    ///         after it (graduation into the real v4 PoolManager for ~1 MON), then pay out the fees.
    function test_smokeLaunch_fullLifecycle() public {
        SmokeLaunch smoke = _smokeScript();
        // The script broadcasts from Foundry's default sender when no signer is given, as in a signer-less dry run.
        vm.deal(DEFAULT_SENDER, 10 ether);
        vm.setEnv("FACTORY", vm.toString(address(factory)));

        (address t, address c) = smoke.launch();
        LaunchToken launched = LaunchToken(t);
        BondingCurveManager launchedCurve = BondingCurveManager(payable(c));
        assertEq(launchedCurve.creator(), DEFAULT_SENDER);
        uint256 devTokens = launched.balanceOf(DEFAULT_SENDER);
        assertGt(devTokens, 0, "dev buy");

        vm.roll(vm.getBlockNumber() + 1);
        smoke.trade(t);
        assertGt(launched.balanceOf(DEFAULT_SENDER), devTokens / 2, "sold half, bought some");

        vm.expectRevert(abi.encodeWithSelector(SmokeLaunch.SnipeWindowOpen.selector, Presets.SNIPE_DECAY_BLOCKS - 1));
        smoke.graduate(t);

        vm.roll(launchedCurve.launchBlock() + Presets.SNIPE_DECAY_BLOCKS);
        uint256 balanceBefore = DEFAULT_SENDER.balance;
        smoke.graduate(t);
        assertEq(uint8(launchedCurve.state().status), uint8(CurveStatus.Graduated));
        assertGt(migrator.positionOf(t).liquidity, 0);
        assertLt(balanceBefore - DEFAULT_SENDER.balance, 1.1 ether, "graduation fits a faucet budget");

        (uint256 toCreator, uint256 toProtocol) = launchedCurve.claimableFees();
        assertGt(toCreator + toProtocol, 0);
        smoke.claim(t);
        (toCreator, toProtocol) = launchedCurve.claimableFees();
        assertEq(toCreator + toProtocol, 0);
        vm.setEnv("FACTORY", "");
    }
}
