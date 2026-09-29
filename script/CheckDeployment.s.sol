// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Script, console} from "forge-std/Script.sol";

import {BondingCurveManager} from "../src/BondingCurveManager.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LiquidityMigrator} from "../src/LiquidityMigrator.sol";
import {TokenFactory} from "../src/TokenFactory.sol";
import {LaunchPreset} from "../src/types/LaunchpadTypes.sol";
import {MonadMainnet, MonadNetwork, MonadNetworks} from "./config/MonadAddresses.sol";
import {Presets} from "./config/Presets.sol";
import {Deployment, DeploymentLib} from "./utils/DeploymentLib.sol";

/// @notice Read-only audit of a deployment against `deployments/<chainId>.json` and this source tree. Reverts if
///         any check fails; warnings (e.g. ownership handoff still pending) are printed but do not fail.
/// @dev    forge script script/CheckDeployment.s.sol --rpc-url monad_testnet
contract CheckDeployment is Script {
    error DeploymentCheckFailed(uint256 failures);

    struct Result {
        uint256 failures;
        uint256 warnings;
    }

    function run() external view {
        Result memory r = check(DeploymentLib.read(DeploymentLib.path(block.chainid)));
        console.log("== %s failures, %s warnings", r.failures, r.warnings);
        if (r.failures != 0) revert DeploymentCheckFailed(r.failures);
    }

    function check(Deployment memory d) public view returns (Result memory r) {
        TokenFactory factory = TokenFactory(d.factory);
        LiquidityMigrator migrator = LiquidityMigrator(payable(d.migrator));

        console.log("== Provenance (CREATE2 address = this source tree's init code)");
        _expect(r, block.chainid == d.chainId, "record belongs to this chain");
        _expect(
            r,
            d.factory.code.length != 0
                && DeploymentLib.create2Address(
                        d.factorySalt, DeploymentLib.factoryInitCode(d.deployer, d.initialTreasury)
                    ) == d.factory,
            "TokenFactory"
        );
        _expect(
            r,
            d.migrator.code.length != 0
                && DeploymentLib.create2Address(
                    d.migratorSalt, DeploymentLib.migratorInitCode(d.poolManager, d.factory, d.lpFee, d.tickSpacing)
                ) == d.migrator,
            "LiquidityMigrator"
        );
        // Without code, every call below would revert instead of reporting.
        if (d.factory.code.length == 0 || d.migrator.code.length == 0) return r;

        bytes32 tokenHash = keccak256(type(LaunchToken).creationCode);
        bytes32 curveHash = keccak256(type(BondingCurveManager).creationCode);
        _expect(
            r,
            factory.tokenInitCodeHash() == tokenHash && d.tokenInitCodeHash == tokenHash,
            "token init code hash (factory = record = build)"
        );
        _expect(
            r,
            factory.curveInitCodeHash() == curveHash && d.curveInitCodeHash == curveHash,
            "curve init code hash (factory = record = build)"
        );

        console.log("== Uniswap v4 wiring");
        (MonadNetwork memory network, bool known) = MonadNetworks.byChainId(block.chainid);
        if (known) _expect(r, d.poolManager == network.poolManager, "PoolManager is the network's canonical one");
        _expect(r, d.poolManager.code.length != 0, "PoolManager has code");
        _expect(r, migrator.poolManager() == d.poolManager, "migrator.poolManager()");
        _expect(r, migrator.factory() == d.factory, "migrator.factory()");
        _expect(
            r,
            uint160(d.migrator) & Hooks.ALL_HOOK_MASK == Hooks.BEFORE_INITIALIZE_FLAG,
            "hook address flags: BEFORE_INITIALIZE only"
        );
        _expect(r, migrator.lpFee() == d.lpFee && migrator.tickSpacing() == d.tickSpacing, "LP fee and tick spacing");
        PoolKey memory key = migrator.poolKeyOf(address(1));
        _expect(
            r,
            Currency.unwrap(key.currency0) == address(0) && address(key.hooks) == d.migrator,
            "pool key: native MON / token, migrator as hook"
        );
        _warn(r, d.migrator.balance == 0, "migrator holds no MON");

        console.log("== Factory configuration");
        _expect(r, _samePreset(factory, Presets.DEFAULT_PRESET_ID, Presets.defaultPreset(d.migrator)), "preset 1");
        if (d.smokePreset) {
            _expect(
                r, _samePreset(factory, Presets.SMOKE_PRESET_ID, Presets.smokePreset(d.migrator)), "preset 2 (smoke)"
            );
        }
        if (block.chainid == MonadMainnet.CHAIN_ID) {
            _expect(r, !factory.preset(Presets.SMOKE_PRESET_ID).enabled, "no smoke preset on mainnet");
        }
        _expect(r, factory.protocolTreasury() == d.initialTreasury, "protocol treasury");
        _expect(r, !factory.creationPaused(), "creation not paused");

        console.log("== Ownership");
        address owner = factory.owner();
        if (d.finalOwner == address(0) || d.finalOwner == d.deployer) {
            _expect(r, owner == d.deployer, "owner is the deployer");
            _warn(r, block.chainid != MonadMainnet.CHAIN_ID, "mainnet factory should be owned by a Safe");
        } else if (owner == d.finalOwner) {
            _expect(r, true, "owner is the final owner");
        } else {
            _expect(
                r, owner == d.deployer && factory.pendingOwner() == d.finalOwner, "handoff to the final owner started"
            );
            _warn(r, false, "final owner has not called acceptOwnership() yet");
        }
        _warn(r, d.finalOwner == address(0) || d.finalOwner.code.length != 0, "final owner is a contract (Safe)");
    }

    // ------------------------------------------------------------------ helpers

    function _samePreset(TokenFactory factory, uint32 presetId, LaunchPreset memory expected)
        private
        view
        returns (bool)
    {
        return keccak256(abi.encode(factory.preset(presetId))) == keccak256(abi.encode(expected));
    }

    function _expect(Result memory r, bool ok, string memory label) private pure {
        if (ok) {
            console.log("  [ok]   %s", label);
        } else {
            ++r.failures;
            console.log("  [FAIL] %s", label);
        }
    }

    function _warn(Result memory r, bool ok, string memory label) private pure {
        if (ok) return;
        ++r.warnings;
        console.log("  [WARN] %s", label);
    }
}
