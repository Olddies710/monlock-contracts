// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Test} from "forge-std/Test.sol";

import {CheckDeployment} from "../script/CheckDeployment.s.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {MigratorDefaults, MonadMainnet, MonadTestnet} from "../script/config/MonadAddresses.sol";
import {Presets} from "../script/config/Presets.sol";
import {DeployConfig, Deployment, DeploymentLib} from "../script/utils/DeploymentLib.sol";
import {LiquidityMigrator} from "../src/LiquidityMigrator.sol";
import {TokenFactory} from "../src/TokenFactory.sol";
import {LaunchPreset} from "../src/types/LaunchpadTypes.sol";

/// @notice Offline tests of the deployment scripts (no RPC): deterministic addresses, idempotency, resumption after a
///         partial run, the ownership handoff, strict environment parsing and the checker's own failure detection.
///         The PoolManager only needs code here (deployment never calls it); the fork suites use the real one.
contract DeployScriptTest is Test {
    Deploy internal script;
    CheckDeployment internal checker;

    address internal deployer = makeAddr("deployer");
    address internal treasury = makeAddr("treasury");
    address internal safe = makeAddr("safe");

    function setUp() public {
        vm.chainId(MonadTestnet.CHAIN_ID);
        vm.etch(MonadTestnet.POOL_MANAGER, hex"00");
        vm.etch(safe, hex"00"); // stands in for a Safe: the final owner is a contract
        // Script contracts embed ~85 KB of creation code; their own deployment is not under test.
        vm.pauseGasMetering();
        script = Deploy(deployCode("Deploy.s.sol:Deploy"));
        checker = CheckDeployment(deployCode("CheckDeployment.s.sol:CheckDeployment"));
        vm.resumeGasMetering();
    }

    // ------------------------------------------------------------------ deployment

    function test_deploy_fullDeploymentPassesEveryCheck() public {
        Deployment memory d = script.deploy(_config(), deployer);
        TokenFactory factory = TokenFactory(d.factory);
        LiquidityMigrator migrator = LiquidityMigrator(payable(d.migrator));

        assertEq(uint160(d.migrator) & Hooks.ALL_HOOK_MASK, Hooks.BEFORE_INITIALIZE_FLAG);
        assertEq(migrator.factory(), d.factory);
        assertEq(migrator.poolManager(), MonadTestnet.POOL_MANAGER);
        _assertPreset(factory, Presets.DEFAULT_PRESET_ID, Presets.defaultPreset(d.migrator));
        _assertPreset(factory, Presets.SMOKE_PRESET_ID, Presets.smokePreset(d.migrator));
        assertEq(factory.protocolTreasury(), treasury);
        assertEq(factory.tokenInitCodeHash(), d.tokenInitCodeHash);
        assertEq(factory.curveInitCodeHash(), d.curveInitCodeHash);

        // Handoff started, not finished: the Safe still has to accept.
        assertEq(factory.owner(), deployer);
        assertEq(factory.pendingOwner(), safe);
        CheckDeployment.Result memory r = checker.check(d);
        assertEq(r.failures, 0);
        assertEq(r.warnings, 1, "acceptOwnership pending");

        vm.prank(safe);
        factory.acceptOwnership();
        r = checker.check(d);
        assertEq(r.failures, 0);
        assertEq(r.warnings, 0);
    }

    function test_deploy_addressesAreDeterministic() public {
        DeployConfig memory cfg = _config();
        vm.setNonce(deployer, 42); // CREATE2 through the deployer: the EOA nonce plays no part
        Deployment memory d = script.deploy(cfg, deployer);

        assertEq(
            d.factory, DeploymentLib.create2Address(cfg.factorySalt, DeploymentLib.factoryInitCode(deployer, treasury))
        );
        assertEq(
            d.migrator,
            DeploymentLib.create2Address(
                d.migratorSalt, DeploymentLib.migratorInitCode(cfg.poolManager, d.factory, cfg.lpFee, cfg.tickSpacing)
            )
        );
        // The mined salt is the first valid one from the start: every run plans the same deployment.
        assertEq(d.migratorSalt, _minedSalt(cfg, d.factory, cfg.migratorSaltStart));
        cfg.migratorSaltStart = uint256(d.migratorSalt) + 1;
        assertGt(uint256(_minedSalt(cfg, d.factory, cfg.migratorSaltStart)), uint256(d.migratorSalt));
    }

    function test_deploy_isIdempotent() public {
        Deployment memory first = script.deploy(_config(), deployer);
        vm.recordLogs();
        Deployment memory second = script.deploy(_config(), deployer);
        assertEq(vm.getRecordedLogs().length, 0, "nothing deployed, set or transferred twice");
        assertEq(second.factory, first.factory);
        assertEq(second.migrator, first.migrator);
    }

    /// @notice A broadcast that died after the factory transaction: re-running the script finishes the job.
    function test_deploy_resumesAfterPartialRun() public {
        DeployConfig memory cfg = _config();
        vm.prank(deployer);
        (bool ok,) = DeploymentLib.CREATE2_DEPLOYER
            .call(abi.encodePacked(cfg.factorySalt, DeploymentLib.factoryInitCode(deployer, treasury)));
        assertTrue(ok);

        Deployment memory d = script.deploy(cfg, deployer);
        assertGt(d.migrator.code.length, 0);
        assertEq(checker.check(d).failures, 0);
    }

    function test_deploy_afterHandoffLeavesConfigurationToTheOwner() public {
        Deployment memory d = script.deploy(_config(), deployer);
        vm.prank(safe);
        TokenFactory(d.factory).acceptOwnership();
        vm.prank(safe);
        TokenFactory(d.factory).setCreationPaused(true);

        vm.recordLogs();
        script.deploy(_config(), deployer); // must neither revert nor try to reconfigure
        assertEq(vm.getRecordedLogs().length, 0);
        assertTrue(TokenFactory(d.factory).creationPaused());
    }

    function test_deploy_withoutFinalOwnerKeepsTheDeployer() public {
        DeployConfig memory cfg = _config();
        cfg.finalOwner = address(0);
        Deployment memory d = script.deploy(cfg, deployer);
        assertEq(TokenFactory(d.factory).owner(), deployer);
        assertEq(TokenFactory(d.factory).pendingOwner(), address(0));
        CheckDeployment.Result memory r = checker.check(d);
        assertEq(r.failures + r.warnings, 0, "fine on testnet");
    }

    function test_deploy_rejectsInvalidConfig() public {
        DeployConfig memory cfg = _config();
        cfg.treasury = address(0);
        vm.expectRevert(Deploy.MissingTreasury.selector);
        script.deploy(cfg, deployer);

        cfg = _config();
        cfg.poolManager = makeAddr("no code");
        vm.expectRevert(abi.encodeWithSelector(Deploy.NoPoolManagerCode.selector, cfg.poolManager));
        script.deploy(cfg, deployer);

        cfg = _config();
        cfg.lpFee = 0x800000; // dynamic-fee flag: the migrator's constructor refuses it
        vm.expectRevert(); // Create2Failed(<mined address>)
        script.deploy(cfg, deployer);

        vm.chainId(MonadMainnet.CHAIN_ID);
        cfg = _config();
        cfg.poolManager = MonadTestnet.POOL_MANAGER; // has code in this test
        vm.expectRevert(Deploy.SmokePresetOnMainnet.selector);
        script.deploy(cfg, deployer);
    }

    // ------------------------------------------------------------------ checker

    function test_check_reportsEveryDrift() public {
        Deployment memory d = script.deploy(_config(), deployer);
        vm.prank(safe);
        TokenFactory(d.factory).acceptOwnership();
        TokenFactory factory = TokenFactory(d.factory);

        vm.startPrank(safe);
        factory.setProtocolTreasury(makeAddr("other treasury"));
        factory.setCreationPaused(true);
        LaunchPreset memory p = Presets.defaultPreset(d.migrator);
        p.tradeFeeBps = 150;
        factory.setPreset(Presets.DEFAULT_PRESET_ID, p);
        vm.stopPrank();
        assertEq(checker.check(d).failures, 3, "treasury, pause, preset 1");

        Deployment memory tampered = d;
        tampered.migratorSalt = bytes32(uint256(d.migratorSalt) + 1);
        tampered.tokenInitCodeHash = keccak256("other build");
        assertEq(checker.check(tampered).failures, 5, "+ migrator provenance, token init code hash");
    }

    function test_check_stopsEarlyWhenNothingIsDeployed() public {
        Deployment memory d = script.deploy(_config(), deployer);
        vm.etch(d.migrator, "");
        assertEq(checker.check(d).failures, 1, "only provenance: nothing to query");
    }

    function test_check_flagsSmokePresetAndMissingSafeOnMainnet() public {
        DeployConfig memory cfg = _config();
        cfg.finalOwner = address(0);
        Deployment memory d = script.deploy(cfg, deployer);
        vm.chainId(MonadMainnet.CHAIN_ID);
        vm.etch(MonadMainnet.POOL_MANAGER, hex"00");
        d.chainId = MonadMainnet.CHAIN_ID;
        CheckDeployment.Result memory r = checker.check(d);
        // PoolManager is not mainnet's canonical one, and preset 2 is enabled.
        assertEq(r.failures, 2);
        assertEq(r.warnings, 1, "mainnet owner should be a Safe");
    }

    // ------------------------------------------------------------------ environment and record

    function test_configFromEnv_defaultsOverridesAndStrictParsing() public {
        _clearEnv();
        DeployConfig memory cfg = script.configFromEnv();
        assertEq(cfg.poolManager, MonadTestnet.POOL_MANAGER);
        assertEq(cfg.treasury, address(0));
        assertEq(cfg.finalOwner, address(0));
        assertEq(cfg.lpFee, MigratorDefaults.LP_FEE);
        assertEq(cfg.tickSpacing, MigratorDefaults.TICK_SPACING);
        assertEq(cfg.factorySalt, script.DEFAULT_FACTORY_SALT());
        assertEq(cfg.migratorSaltStart, 0);
        assertTrue(cfg.smokePreset, "on by default off mainnet");

        vm.setEnv("PROTOCOL_TREASURY", vm.toString(treasury));
        vm.setEnv("FINAL_OWNER", vm.toString(safe));
        vm.setEnv("LP_FEE", "3000");
        vm.setEnv("TICK_SPACING", "60");
        vm.setEnv("FACTORY_SALT", vm.toString(bytes32(uint256(7))));
        vm.setEnv("MIGRATOR_SALT_START", "1000");
        vm.setEnv("SMOKE_PRESET", "false");
        cfg = script.configFromEnv();
        assertEq(cfg.treasury, treasury);
        assertEq(cfg.finalOwner, safe);
        assertEq(cfg.lpFee, 3000);
        assertEq(cfg.tickSpacing, 60);
        assertEq(cfg.factorySalt, bytes32(uint256(7)));
        assertEq(cfg.migratorSaltStart, 1000);
        assertFalse(cfg.smokePreset);

        vm.setEnv("FINAL_OWNER", "0x1234"); // vm.envOr would silently fall back to address(0)
        vm.expectRevert();
        script.configFromEnv();
        vm.setEnv("FINAL_OWNER", "");

        vm.setEnv("LP_FEE", vm.toString(uint256(type(uint24).max) + 1));
        vm.expectRevert(abi.encodeWithSelector(Deploy.InvalidLpFee.selector, uint256(type(uint24).max) + 1));
        script.configFromEnv();
        vm.setEnv("LP_FEE", "");

        vm.chainId(31_337);
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnknownNetwork.selector, 31_337));
        script.configFromEnv();
        _clearEnv();
    }

    function test_record_roundTrips() public {
        Deployment memory d = script.deploy(_config(), deployer);
        string memory file = string.concat(vm.projectRoot(), "/deployments/dry-run/test-roundtrip.json");
        vm.createDir(string.concat(vm.projectRoot(), "/deployments/dry-run"), true);
        DeploymentLib.write(d, file);
        Deployment memory back = DeploymentLib.read(file);
        vm.removeFile(file);
        assertEq(keccak256(abi.encode(back)), keccak256(abi.encode(d)));
    }

    // ------------------------------------------------------------------ helpers

    function _config() internal view returns (DeployConfig memory cfg) {
        cfg.poolManager = MonadTestnet.POOL_MANAGER;
        cfg.treasury = treasury;
        cfg.finalOwner = safe;
        cfg.lpFee = MigratorDefaults.LP_FEE;
        cfg.tickSpacing = MigratorDefaults.TICK_SPACING;
        cfg.factorySalt = script.DEFAULT_FACTORY_SALT();
        cfg.smokePreset = true;
    }

    function _minedSalt(DeployConfig memory cfg, address factory, uint256 start) internal returns (bytes32 salt) {
        bytes memory initCode = DeploymentLib.migratorInitCode(cfg.poolManager, factory, cfg.lpFee, cfg.tickSpacing);
        vm.pauseGasMetering();
        for (uint256 s = start;; ++s) {
            address a = DeploymentLib.create2Address(bytes32(s), initCode);
            if (uint160(a) & Hooks.ALL_HOOK_MASK == Hooks.BEFORE_INITIALIZE_FLAG) {
                salt = bytes32(s);
                break;
            }
        }
        vm.resumeGasMetering();
    }

    function _assertPreset(TokenFactory factory, uint32 id, LaunchPreset memory expected) internal view {
        assertEq(keccak256(abi.encode(factory.preset(id))), keccak256(abi.encode(expected)));
    }

    function _clearEnv() internal {
        string[8] memory names = [
            "POOL_MANAGER",
            "PROTOCOL_TREASURY",
            "FINAL_OWNER",
            "LP_FEE",
            "TICK_SPACING",
            "FACTORY_SALT",
            "MIGRATOR_SALT_START",
            "SMOKE_PRESET"
        ];
        for (uint256 i; i < names.length; ++i) {
            vm.setEnv(names[i], "");
        }
    }
}
