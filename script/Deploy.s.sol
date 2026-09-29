// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {TokenFactory} from "../src/TokenFactory.sol";
import {LaunchPreset} from "../src/types/LaunchpadTypes.sol";
import {MigratorDefaults, MonadMainnet, MonadNetwork, MonadNetworks} from "./config/MonadAddresses.sol";
import {Presets} from "./config/Presets.sol";
import {DeployConfig, Deployment, DeploymentLib} from "./utils/DeploymentLib.sol";

/// @notice Deploys the launchpad on a Monad network (runbook: DEPLOYMENT.md):
///           1. TokenFactory through the CREATE2 deployer (address fixed by salt, deployer and initial treasury);
///           2. LiquidityMigrator through the same deployer, at a mined address carrying only the
///              BEFORE_INITIALIZE hook flag (ARCHITECTURE.md §2.3);
///           3. preset 1 (approved economics) and, off mainnet, the smoke preset 2;
///           4. optional handoff to a Safe: `transferOwnership(FINAL_OWNER)`; the Safe must `acceptOwnership()`.
///         Idempotent: steps already on-chain are skipped, so a run that failed halfway can simply be repeated.
///
///         Environment: PROTOCOL_TREASURY (required), FINAL_OWNER, POOL_MANAGER (defaults to the network's),
///         LP_FEE, TICK_SPACING, FACTORY_SALT, MIGRATOR_SALT_START, SMOKE_PRESET (defaults to true off mainnet),
///         CONTRACTS_ONLY.
///
///         Live networks: two broadcasts. Against a Monad RPC, forge's gas estimate for a call into a contract
///         created earlier in the same run is taken as if that contract did not exist yet (setPreset estimated at
///         ~30k for ~175k used), so those transactions would run out of gas. Phase 1 (CONTRACTS_ONLY=true) creates
///         the contracts; phase 2 (the same command without it) finds them on-chain, skips their creation and
///         configures them with correct estimates.
/// @dev    forge script script/Deploy.s.sol --rpc-url monad_testnet --account deployer            # simulation
///         CONTRACTS_ONLY=true forge script script/Deploy.s.sol --rpc-url monad_testnet --account deployer \
///           --broadcast --slow                                                                  # phase 1
///         forge script script/Deploy.s.sol --rpc-url monad_testnet --account deployer --broadcast --slow # 2
///      A broadcast writes `deployments/<chainId>.json`; a simulation writes `deployments/dry-run/` (gitignored).
contract Deploy is Script {
    bytes32 public constant DEFAULT_FACTORY_SALT = keccak256("monad-launchpad.factory.v1");

    error UnknownNetwork(uint256 chainId);
    error MissingTreasury();
    error NoPoolManagerCode(address poolManager);
    error SmokePresetOnMainnet();
    error InvalidLpFee(uint256 lpFee);
    error InvalidTickSpacing(int256 tickSpacing);
    error Create2Failed(address expected);

    function run() external returns (Deployment memory d) {
        d = deploy(configFromEnv(), DeploymentLib.broadcaster());
        _report(d);
        _record(d);
    }

    /// @notice Deployment inputs for the current chain; unset variables take the documented defaults.
    function configFromEnv() public view returns (DeployConfig memory cfg) {
        (MonadNetwork memory network,) = MonadNetworks.byChainId(block.chainid);
        cfg.poolManager = DeploymentLib.envAddress("POOL_MANAGER", network.poolManager);
        if (cfg.poolManager == address(0)) revert UnknownNetwork(block.chainid);
        cfg.treasury = DeploymentLib.envAddress("PROTOCOL_TREASURY", address(0));
        cfg.finalOwner = DeploymentLib.envAddress("FINAL_OWNER", address(0));

        uint256 lpFee = DeploymentLib.envUint("LP_FEE", uint256(MigratorDefaults.LP_FEE));
        if (lpFee > type(uint24).max) revert InvalidLpFee(lpFee);
        // forge-lint: disable-next-line(unsafe-typecast)
        cfg.lpFee = uint24(lpFee); // range checked above; the migrator validates the value itself
        int256 tickSpacing = DeploymentLib.envInt("TICK_SPACING", int256(MigratorDefaults.TICK_SPACING));
        if (tickSpacing < type(int24).min || tickSpacing > type(int24).max) revert InvalidTickSpacing(tickSpacing);
        // forge-lint: disable-next-line(unsafe-typecast)
        cfg.tickSpacing = int24(tickSpacing); // range checked above

        cfg.factorySalt = DeploymentLib.envBytes32("FACTORY_SALT", DEFAULT_FACTORY_SALT);
        cfg.migratorSaltStart = DeploymentLib.envUint("MIGRATOR_SALT_START", uint256(0));
        cfg.smokePreset = DeploymentLib.envBool("SMOKE_PRESET", block.chainid != MonadMainnet.CHAIN_ID);
        cfg.contractsOnly = DeploymentLib.envBool("CONTRACTS_ONLY", false);
    }

    /// @notice Deploys (or completes) the deployment described by `cfg`, broadcasting from `deployer`.
    ///         Also the entry point of the fork tests, which call it without environment variables.
    function deploy(DeployConfig memory cfg, address deployer) public returns (Deployment memory d) {
        if (cfg.treasury == address(0)) revert MissingTreasury();
        if (cfg.poolManager.code.length == 0) revert NoPoolManagerCode(cfg.poolManager);
        if (cfg.smokePreset && block.chainid == MonadMainnet.CHAIN_ID) revert SmokePresetOnMainnet();

        d = DeploymentLib.plan(cfg, deployer);

        vm.startBroadcast(deployer);
        _create2(d.factorySalt, DeploymentLib.factoryInitCode(deployer, cfg.treasury), d.factory);
        _create2(
            d.migratorSalt,
            DeploymentLib.migratorInitCode(cfg.poolManager, d.factory, cfg.lpFee, cfg.tickSpacing),
            d.migrator
        );

        TokenFactory factory = TokenFactory(d.factory);
        if (cfg.contractsOnly) {
            console.log("CONTRACTS_ONLY: presets and ownership are configured by the next run");
        } else if (factory.owner() == deployer) {
            _setPreset(factory, Presets.DEFAULT_PRESET_ID, Presets.defaultPreset(d.migrator));
            if (cfg.smokePreset) _setPreset(factory, Presets.SMOKE_PRESET_ID, Presets.smokePreset(d.migrator));
            if (cfg.finalOwner != address(0) && cfg.finalOwner != deployer && factory.pendingOwner() != cfg.finalOwner)
            {
                factory.transferOwnership(cfg.finalOwner);
            }
        } else {
            // Already handed over: configuration changes belong to the owner now. CheckDeployment reports drift.
            console.log("factory owned by %s: presets and ownership left untouched", factory.owner());
        }
        vm.stopBroadcast();
    }

    // ------------------------------------------------------------------ steps

    /// @dev Skips the deployment when the address already has code: a CREATE2 address commits to salt and init
    ///      code, so whatever lives there is this exact contract.
    function _create2(bytes32 salt, bytes memory initCode, address expected) private {
        if (expected.code.length != 0) return;
        (bool ok, bytes memory ret) = DeploymentLib.CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        if (!ok || ret.length != 20 || address(bytes20(ret)) != expected) revert Create2Failed(expected);
    }

    function _setPreset(TokenFactory factory, uint32 presetId, LaunchPreset memory preset) private {
        if (keccak256(abi.encode(factory.preset(presetId))) != keccak256(abi.encode(preset))) {
            factory.setPreset(presetId, preset);
        }
    }

    // ------------------------------------------------------------------ output

    function _record(Deployment memory d) private {
        string memory file;
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
            file = DeploymentLib.path(d.chainId);
        } else if (vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) {
            file = DeploymentLib.dryRunPath(d.chainId);
            vm.createDir(string.concat(vm.projectRoot(), "/deployments/dry-run"), true);
        } else {
            return; // tests: no files
        }
        DeploymentLib.write(d, file);
        console.log("record: %s", file);
    }

    function _report(Deployment memory d) private view {
        TokenFactory factory = TokenFactory(d.factory);
        console.log("== Launchpad deployment on chain %s", d.chainId);
        console.log("  deployer            %s", d.deployer);
        console.log("  TokenFactory        %s", d.factory);
        console.log("  LiquidityMigrator   %s (salt %s)", d.migrator, vm.toString(d.migratorSalt));
        console.log("  PoolManager         %s", d.poolManager);
        console.log("  protocol treasury   %s", factory.protocolTreasury());
        console.log("  owner               %s", factory.owner());
        console.log("  pending owner       %s", factory.pendingOwner());
        console.log("  presets             1%s", d.smokePreset ? " + 2 (smoke)" : "");
        console.log("  token init hash     %s", vm.toString(d.tokenInitCodeHash));
        console.log("  curve init hash     %s", vm.toString(d.curveInitCodeHash));
        if (factory.pendingOwner() != address(0)) {
            console.log("next: %s must call acceptOwnership() on the factory", factory.pendingOwner());
        }
    }
}
