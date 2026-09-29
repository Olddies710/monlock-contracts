// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Vm} from "forge-std/Vm.sol";

import {BondingCurveManager} from "../../src/BondingCurveManager.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {LiquidityMigrator} from "../../src/LiquidityMigrator.sol";
import {TokenFactory} from "../../src/TokenFactory.sol";
import {MonadMainnet} from "../config/MonadAddresses.sol";
import {HookMiner} from "./HookMiner.sol";

/// @notice Inputs of a launchpad deployment (`Deploy.configFromEnv` reads them from the environment).
struct DeployConfig {
    address poolManager; // Uniswap v4 PoolManager of the target chain
    address treasury; // initial protocol treasury (part of the factory's init code)
    address finalOwner; // Safe that takes the factory over (Ownable2Step); address(0) keeps the deployer
    uint24 lpFee; // static LP fee of graduated pools, hundredths of a bip
    int24 tickSpacing;
    bytes32 factorySalt; // CREATE2 salt of the factory
    uint256 migratorSaltStart; // first salt of the hook-address search
    bool smokePreset; // also register the testnet smoke preset (refused on mainnet)
}

/// @notice A deployment as recorded in `deployments/<chainId>.json`. With the source tree it is enough to re-derive
///         both addresses (CREATE2 provenance) and to audit the on-chain configuration (`CheckDeployment`).
struct Deployment {
    uint256 chainId;
    address deployer; // initial owner of the factory (part of its init code)
    address factory;
    bytes32 factorySalt;
    address initialTreasury;
    address migrator;
    bytes32 migratorSalt;
    address poolManager;
    uint24 lpFee;
    int24 tickSpacing;
    address finalOwner;
    bool smokePreset;
    bytes32 tokenInitCodeHash; // SDK constants for token/curve address prediction
    bytes32 curveInitCodeHash;
    uint256 startBlock; // block the script ran against: lower bound of the deployment block, for indexers
}

/// @notice Deterministic addressing and the JSON record shared by `Deploy`, `CheckDeployment`, `SmokeLaunch` and the
///         fork tests. Both contracts are created through the Arachnid CREATE2 deployer (present on every Monad
///         network), called explicitly: addresses are the same in tests, dry runs and broadcasts, and do not depend
///         on the deployer's nonce.
library DeploymentLib {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant CREATE2_DEPLOYER = MonadMainnet.CREATE2_DEPLOYER;

    error CorruptRecord(string file);

    function factoryInitCode(address initialOwner, address treasury) internal pure returns (bytes memory) {
        return abi.encodePacked(type(TokenFactory).creationCode, abi.encode(initialOwner, treasury));
    }

    function migratorInitCode(address poolManager, address factory, uint24 lpFee, int24 tickSpacing)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            type(LiquidityMigrator).creationCode, abi.encode(poolManager, factory, lpFee, tickSpacing)
        );
    }

    function create2Address(bytes32 salt, bytes memory initCode) internal pure returns (address) {
        return HookMiner.computeAddress(CREATE2_DEPLOYER, salt, keccak256(initCode));
    }

    /// @notice Resolves every address of a deployment without sending anything. The migrator salt is the first one
    ///         from `migratorSaltStart` giving an address with exactly the BEFORE_INITIALIZE flag (~16k tries on
    ///         average, run with gas metering paused), so the same inputs always plan the same deployment.
    function plan(DeployConfig memory cfg, address deployer) internal returns (Deployment memory d) {
        d.chainId = block.chainid;
        d.deployer = deployer;
        d.factorySalt = cfg.factorySalt;
        d.initialTreasury = cfg.treasury;
        d.factory = create2Address(cfg.factorySalt, factoryInitCode(deployer, cfg.treasury));
        d.poolManager = cfg.poolManager;
        d.lpFee = cfg.lpFee;
        d.tickSpacing = cfg.tickSpacing;

        bytes memory initCode = migratorInitCode(cfg.poolManager, d.factory, cfg.lpFee, cfg.tickSpacing);
        VM.pauseGasMetering();
        (d.migratorSalt, d.migrator) =
            HookMiner.find(CREATE2_DEPLOYER, Hooks.BEFORE_INITIALIZE_FLAG, initCode, cfg.migratorSaltStart);
        VM.resumeGasMetering();

        d.finalOwner = cfg.finalOwner;
        d.smokePreset = cfg.smokePreset;
        d.tokenInitCodeHash = keccak256(type(LaunchToken).creationCode);
        d.curveInitCodeHash = keccak256(type(BondingCurveManager).creationCode);
        d.startBlock = VM.getBlockNumber();
    }

    /// @notice The address `forge script` broadcasts from: `--sender`, the only `--account`/`--private-key` signer,
    ///         or Foundry's default sender in a simulation without signer.
    function broadcaster() internal returns (address sender) {
        VM.startBroadcast();
        (, sender,) = VM.readCallers();
        VM.stopBroadcast();
    }

    // ------------------------------------------------------------------ strict environment
    // `vm.envOr` silently returns the default when a value does not parse (a typo in FINAL_OWNER would skip the
    // Safe handoff). These return the default only when the variable is unset or empty, and revert otherwise.

    function envAddress(string memory name, address defaultValue) internal view returns (address) {
        return _isSet(name) ? VM.envAddress(name) : defaultValue;
    }

    function envUint(string memory name, uint256 defaultValue) internal view returns (uint256) {
        return _isSet(name) ? VM.envUint(name) : defaultValue;
    }

    function envInt(string memory name, int256 defaultValue) internal view returns (int256) {
        return _isSet(name) ? VM.envInt(name) : defaultValue;
    }

    function envBytes32(string memory name, bytes32 defaultValue) internal view returns (bytes32) {
        return _isSet(name) ? VM.envBytes32(name) : defaultValue;
    }

    function envBool(string memory name, bool defaultValue) internal view returns (bool) {
        return _isSet(name) ? VM.envBool(name) : defaultValue;
    }

    function _isSet(string memory name) private view returns (bool) {
        return bytes(VM.envOr(name, string(""))).length != 0;
    }

    // ------------------------------------------------------------------ JSON record

    function path(uint256 chainId) internal view returns (string memory) {
        return string.concat(VM.projectRoot(), "/deployments/", VM.toString(chainId), ".json");
    }

    /// @dev Dry runs write here (gitignored): the committed record only ever describes broadcast deployments.
    function dryRunPath(uint256 chainId) internal view returns (string memory) {
        return string.concat(VM.projectRoot(), "/deployments/dry-run/", VM.toString(chainId), ".json");
    }

    function write(Deployment memory d, string memory file) internal {
        string memory o = "deployment";
        VM.serializeUint(o, "chainId", d.chainId);
        VM.serializeAddress(o, "deployer", d.deployer);
        VM.serializeAddress(o, "factory", d.factory);
        VM.serializeBytes32(o, "factorySalt", d.factorySalt);
        VM.serializeAddress(o, "initialTreasury", d.initialTreasury);
        VM.serializeAddress(o, "migrator", d.migrator);
        VM.serializeBytes32(o, "migratorSalt", d.migratorSalt);
        VM.serializeAddress(o, "poolManager", d.poolManager);
        VM.serializeUint(o, "lpFee", d.lpFee);
        VM.serializeInt(o, "tickSpacing", d.tickSpacing);
        VM.serializeAddress(o, "finalOwner", d.finalOwner);
        VM.serializeBool(o, "smokePreset", d.smokePreset);
        VM.serializeBytes32(o, "tokenInitCodeHash", d.tokenInitCodeHash);
        VM.serializeBytes32(o, "curveInitCodeHash", d.curveInitCodeHash);
        VM.serializeAddress(o, "create2Deployer", CREATE2_DEPLOYER);
        string memory json = VM.serializeUint(o, "startBlock", d.startBlock);
        VM.writeJson(json, file);
    }

    function read(string memory file) internal view returns (Deployment memory d) {
        string memory json = VM.readFile(file);
        d.chainId = VM.parseJsonUint(json, ".chainId");
        d.deployer = VM.parseJsonAddress(json, ".deployer");
        d.factory = VM.parseJsonAddress(json, ".factory");
        d.factorySalt = VM.parseJsonBytes32(json, ".factorySalt");
        d.initialTreasury = VM.parseJsonAddress(json, ".initialTreasury");
        d.migrator = VM.parseJsonAddress(json, ".migrator");
        d.migratorSalt = VM.parseJsonBytes32(json, ".migratorSalt");
        d.poolManager = VM.parseJsonAddress(json, ".poolManager");
        uint256 lpFee = VM.parseJsonUint(json, ".lpFee");
        int256 tickSpacing = VM.parseJsonInt(json, ".tickSpacing");
        if (lpFee > type(uint24).max || tickSpacing < type(int24).min || tickSpacing > type(int24).max) {
            revert CorruptRecord(file);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        d.lpFee = uint24(lpFee); // range checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        d.tickSpacing = int24(tickSpacing); // range checked above
        d.finalOwner = VM.parseJsonAddress(json, ".finalOwner");
        d.smokePreset = VM.parseJsonBool(json, ".smokePreset");
        d.tokenInitCodeHash = VM.parseJsonBytes32(json, ".tokenInitCodeHash");
        d.curveInitCodeHash = VM.parseJsonBytes32(json, ".curveInitCodeHash");
        d.startBlock = VM.parseJsonUint(json, ".startBlock");
    }
}
