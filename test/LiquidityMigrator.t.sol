// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test} from "forge-std/Test.sol";

import {MigratorDefaults, MonadMainnet} from "../script/config/MonadAddresses.sol";
import {HookMiner} from "../script/utils/HookMiner.sol";
import {LiquidityMigrator} from "../src/LiquidityMigrator.sol";
import {TokenFactory} from "../src/TokenFactory.sol";
import {ILiquidityMigrator} from "../src/interfaces/ILiquidityMigrator.sol";

/// @notice Offline checks of the migrator (no RPC): configuration, access control and the CREATE2 hook-address
///         mining used in production. Pool behaviour is covered by the Monad fork suite.
contract LiquidityMigratorTest is Test {
    address internal constant POOL_MANAGER = MonadMainnet.POOL_MANAGER; // only an address here: never called
    TokenFactory internal factory;
    LiquidityMigrator internal migrator;

    function setUp() public {
        vm.chainId(MonadMainnet.CHAIN_ID);
        factory = new TokenFactory(makeAddr("owner"), makeAddr("treasury"));
        migrator = LiquidityMigrator(payable(_hookAddress("offline")));
        deployCodeTo("LiquidityMigrator.sol:LiquidityMigrator", _args(MigratorDefaults.LP_FEE), address(migrator));
    }

    // ------------------------------------------------------------------ configuration

    function test_config() public {
        assertEq(migrator.poolManager(), POOL_MANAGER);
        assertEq(migrator.factory(), address(factory));
        assertEq(migrator.lpFee(), MigratorDefaults.LP_FEE);
        assertEq(migrator.tickSpacing(), MigratorDefaults.TICK_SPACING);
        assertEq(uint160(address(migrator)) & Hooks.ALL_HOOK_MASK, Hooks.BEFORE_INITIALIZE_FLAG, "only that flag");

        address token = makeAddr("token");
        PoolKey memory key = migrator.poolKeyOf(token);
        assertEq(Currency.unwrap(key.currency0), address(0), "native MON is currency0");
        assertEq(Currency.unwrap(key.currency1), token);
        assertEq(key.fee, MigratorDefaults.LP_FEE);
        assertEq(key.tickSpacing, MigratorDefaults.TICK_SPACING);
        assertEq(address(key.hooks), address(migrator));
    }

    function test_constructor_requiresTheHookFlagAddress() public {
        address plain = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.assume(uint160(plain) & Hooks.ALL_HOOK_MASK != Hooks.BEFORE_INITIALIZE_FLAG);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, plain));
        new LiquidityMigrator(IPoolManager(POOL_MANAGER), address(factory), MigratorDefaults.LP_FEE, 200);
    }

    function test_constructor_rejectsInvalidConfig() public {
        _expectInvalid(address(0), address(factory), MigratorDefaults.LP_FEE, 200);
        _expectInvalid(POOL_MANAGER, address(0), MigratorDefaults.LP_FEE, 200);
        _expectInvalid(POOL_MANAGER, address(factory), 1_000_001, 200); // above MAX_LP_FEE
        _expectInvalid(POOL_MANAGER, address(factory), 0x800000, 200); // dynamic-fee flag
        _expectInvalid(POOL_MANAGER, address(factory), MigratorDefaults.LP_FEE, 0);
        _expectInvalid(POOL_MANAGER, address(factory), MigratorDefaults.LP_FEE, int24(type(int16).max) + 1);
    }

    // ------------------------------------------------------------------ access control

    function test_callbacksOnlyFromPoolManager() public {
        PoolKey memory key = migrator.poolKeyOf(makeAddr("token"));
        vm.expectRevert(ILiquidityMigrator.OnlyPoolManager.selector);
        migrator.beforeInitialize(address(migrator), key, 1 << 96);
        vm.expectRevert(ILiquidityMigrator.OnlyPoolManager.selector);
        migrator.unlockCallback(abi.encode(uint8(1), address(0), 0, 0, uint128(0)));

        vm.deal(address(this), 1 ether);
        (bool ok,) = address(migrator).call{value: 1 ether}("");
        assertFalse(ok, "only the PoolManager may send MON");
    }

    function test_beforeInitialize_onlyAcceptsItselfAsInitializer() public {
        PoolKey memory key = migrator.poolKeyOf(makeAddr("token"));
        vm.startPrank(POOL_MANAGER);
        vm.expectRevert(ILiquidityMigrator.UnauthorizedPoolInitializer.selector);
        migrator.beforeInitialize(makeAddr("attacker"), key, 1 << 96);
        assertEq(migrator.beforeInitialize(address(migrator), key, 1 << 96), IHooks.beforeInitialize.selector);
        vm.stopPrank();
    }

    function test_migrate_onlyRegisteredCurve() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(ILiquidityMigrator.OnlyRegisteredCurve.selector);
        migrator.migrate{value: 1 ether}(makeAddr("token"), 1);
    }

    function test_collectFees_requiresMigration() public {
        vm.expectRevert(ILiquidityMigrator.NotMigrated.selector);
        migrator.collectFees(makeAddr("token"));
    }

    // ------------------------------------------------------------------ production deployment path

    /// @notice Mines a salt for the Arachnid CREATE2 deployer (the one `forge script` uses, also on Monad) and
    ///         deploys through it: the address carries exactly the BEFORE_INITIALIZE flag.
    function test_hookMiner_deploysThroughCreate2Deployer() public {
        bytes memory initCode = abi.encodePacked(type(LiquidityMigrator).creationCode, _args(MigratorDefaults.LP_FEE));
        vm.pauseGasMetering();
        (bytes32 salt, address predicted) =
            HookMiner.find(MonadMainnet.CREATE2_DEPLOYER, Hooks.BEFORE_INITIALIZE_FLAG, initCode, 0);
        vm.resumeGasMetering();

        (bool ok, bytes memory ret) = MonadMainnet.CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        assertTrue(ok);
        assertEq(address(bytes20(ret)), predicted);
        assertEq(uint160(predicted) & Hooks.ALL_HOOK_MASK, Hooks.BEFORE_INITIALIZE_FLAG);
        assertEq(LiquidityMigrator(payable(predicted)).factory(), address(factory));
    }

    function testFuzz_hookMiner_computeAddressMatchesCreate2(bytes32 salt) public {
        bytes memory initCode = type(Dummy).creationCode;
        address expected = HookMiner.computeAddress(MonadMainnet.CREATE2_DEPLOYER, salt, keccak256(initCode));
        (bool ok, bytes memory ret) = MonadMainnet.CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        assertTrue(ok);
        assertEq(address(bytes20(ret)), expected);
    }

    // ------------------------------------------------------------------ helpers

    function _args(uint24 fee) internal view returns (bytes memory) {
        return abi.encode(POOL_MANAGER, address(factory), fee, MigratorDefaults.TICK_SPACING);
    }

    function _hookAddress(string memory label) internal pure returns (address) {
        return
            address((uint160(uint256(keccak256(bytes(label)))) & ~Hooks.ALL_HOOK_MASK) | Hooks.BEFORE_INITIALIZE_FLAG);
    }

    function _expectInvalid(address pm, address fac, uint24 fee, int24 spacing) internal {
        address target = _hookAddress(string(abi.encode(pm, fac, fee, spacing)));
        vm.expectRevert(ILiquidityMigrator.InvalidConfig.selector);
        this.deployAt(abi.encode(pm, fac, fee, spacing), target);
    }

    /// @dev deployCodeTo with the constructor's revert data bubbled up (external, so expectRevert can see it).
    function deployAt(bytes memory args, address target) external {
        vm.etch(target, abi.encodePacked(type(LiquidityMigrator).creationCode, args));
        (bool success, bytes memory runtime) = target.call("");
        if (!success) {
            assembly ("memory-safe") {
                revert(add(runtime, 0x20), mload(runtime))
            }
        }
        vm.etch(target, runtime);
    }
}

contract Dummy {}
