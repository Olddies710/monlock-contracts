// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FixedPointMathLib as FPML} from "solady/utils/FixedPointMathLib.sol";

import {MigratorDefaults, MonadNetwork, MonadNetworks} from "../../script/config/MonadAddresses.sol";
import {Presets} from "../../script/config/Presets.sol";
import {BondingCurveManager} from "../../src/BondingCurveManager.sol";
import {ILiquidityMigrator} from "../../src/interfaces/ILiquidityMigrator.sol";
import {BondingCurveMath} from "../../src/libraries/BondingCurveMath.sol";
import {CurveStatus} from "../../src/types/LaunchpadTypes.sol";
import {RejectingRecipient} from "../utils/Mocks.sol";
import {MonadForkTest} from "./MonadForkTest.sol";

/// @notice Graduation into the real Uniswap v4 PoolManager on a Monad fork (ARCHITECTURE.md §2.3, §4.8). Runs against
///         mainnet and testnet: their PoolManagers are different builds of v4.
abstract contract LiquidityMigratorForkTest is MonadForkTest {
    using StateLibrary for *;

    uint256 internal constant Q192 = 1 << 192;
    uint256 internal constant MONAD_TX_GAS_LIMIT = 30_000_000;

    // ------------------------------------------------------------------ graduation

    function test_graduation_locksFullRangeLiquidityAtTheCurvePrice() public {
        uint256 pmMonBefore = address(poolManager).balance;
        uint256 realMon = _graduate();

        uint256 vTFinal = Presets.EXPECTED_VT0 - Presets.CURVE_SUPPLY;
        uint256 vMFinal = Presets.EXPECTED_VM0 + realMon;
        (, uint256 monLP, uint256 tokensLP) = BondingCurveMath.graduationAmounts(
            realMon, Presets.EXPECTED_VM0, vTFinal, Presets.LP_SUPPLY, Presets.GRADUATION_FEE_BPS
        );
        assertEq(uint8(curve.state().status), uint8(CurveStatus.Graduated));

        // Pool opened at floor(sqrt(tokens / MON)) and never below the curve's final MON price.
        ILiquidityMigrator.LockedPosition memory position = migrator.positionOf(address(token));
        PoolId poolId = PoolId.wrap(position.poolId);
        (uint160 sqrtPriceX96,,, uint24 fee) = poolManager.getSlot0(poolId);
        assertEq(sqrtPriceX96, FPML.sqrt(FPML.fullMulDiv(tokensLP, Q192, monLP)), "opening price");
        assertLe(sqrtPriceX96, FPML.sqrt(FPML.fullMulDiv(vTFinal, Q192, vMFinal)), "DEX price >= curve price");
        assertEq(fee, MigratorDefaults.LP_FEE);

        // The migrator owns the full-range position directly in the PoolManager.
        (uint128 liquidity,,) = poolManager.getPositionInfo(
            poolId,
            address(migrator),
            TickMath.minUsableTick(MigratorDefaults.TICK_SPACING),
            TickMath.maxUsableTick(MigratorDefaults.TICK_SPACING),
            bytes32(uint256(uint160(address(token))))
        );
        assertGt(liquidity, 0);
        assertEq(liquidity, position.liquidity);
        assertEq(poolManager.getLiquidity(poolId), liquidity, "sole LP at launch");
        assertEq(position.curve, address(curve));
        assertEq(position.graduationBlock, block.number);

        // Nothing stays in the curve or the migrator; dust goes to the treasury (MON) or is burned (tokens).
        uint256 monInPool = address(poolManager).balance - pmMonBefore;
        assertEq(monInPool + treasury.balance, monLP, "MON: pool + dust");
        assertLt(treasury.balance, 1e9, "only rounding dust");
        assertEq(address(migrator).balance, 0);
        assertEq(token.balanceOf(address(migrator)), 0);
        assertEq(token.balanceOf(address(curve)), 0);
        uint256 tokensInPool = token.balanceOf(address(poolManager));
        assertLe(tokensInPool, tokensLP);
        assertEq(token.totalSupply(), Presets.CURVE_SUPPLY + tokensInPool, "unused LP reserve and dust burned");
    }

    /// @notice Tokens or MON pushed to the migrator before graduation never get stuck there: tokens are burned
    ///         and MON goes to the treasury together with the rounding dust.
    function test_graduation_sweepsAnythingSentBeforehand() public {
        _rollPastSnipeWindow();
        vm.prank(alice);
        uint256 bought = curve.buy{value: 10 ether}(0, address(0));
        vm.prank(alice);
        token.transfer(address(migrator), bought);
        vm.deal(address(migrator), 3 ether); // as if force-sent (the migrator has no open receive)

        uint256 supplyBefore = token.totalSupply();
        _graduate();
        assertEq(token.balanceOf(address(migrator)), 0, "donated tokens burned");
        assertEq(address(migrator).balance, 0, "stray MON swept");
        assertGe(treasury.balance, 3 ether, "swept to the treasury");
        assertLe(token.totalSupply(), supplyBefore - bought, "burn includes the donation");
    }

    function test_graduation_gasFitsMonadTransactionLimit() public {
        _rollPastSnipeWindow();
        vm.prank(whale);
        uint256 before = gasleft();
        curve.buy{value: 5000 ether}(0, address(0));
        uint256 used = before - gasleft();
        emit log_named_uint("graduating buy gas (Monad pricing)", used);
        assertEq(uint8(curve.state().status), uint8(CurveStatus.Graduated));
        assertLt(used, MONAD_TX_GAS_LIMIT / 10, "well under 10% of Monad's per-tx limit");
    }

    /// @notice A buyer with too little gas still completes the curve; migration is deferred (Completed) and anyone
    ///         graduates it later against the real PoolManager.
    function test_graduation_lowGasDefersMigrationAndAnyoneRetries() public {
        _rollPastSnipeWindow();
        uint256 gasLimitFound;
        for (uint256 gasLimit = 200_000; gasLimit <= 1_000_000; gasLimit += 20_000) {
            uint256 snapshot = vm.snapshotState();
            vm.prank(whale);
            (bool ok,) = address(curve).call{value: 5000 ether, gas: gasLimit}(
                abi.encodeCall(BondingCurveManager.buy, (0, address(0)))
            );
            if (ok && curve.state().status == CurveStatus.Completed) {
                gasLimitFound = gasLimit;
                break;
            }
            vm.revertToState(snapshot);
        }
        assertGt(gasLimitFound, 0, "a gas limit exists that completes the curve but not the migration");
        emit log_named_uint("gas limit that deferred migration", gasLimitFound);
        assertEq(migrator.positionOf(address(token)).liquidity, 0, "no pool yet");

        vm.prank(bob);
        curve.graduate();
        assertEq(uint8(curve.state().status), uint8(CurveStatus.Graduated));
        assertGt(migrator.positionOf(address(token)).liquidity, 0);
    }

    // ------------------------------------------------------------------ pool poisoning (§5.6)

    function test_poolPoisoning_nobodyElseCanInitializeThePool() public {
        PoolKey memory key = migrator.poolKeyOf(address(token));
        bytes memory wrapped = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(migrator),
            IHooks.beforeInitialize.selector,
            abi.encodeWithSelector(ILiquidityMigrator.UnauthorizedPoolInitializer.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        vm.prank(alice);
        vm.expectRevert(wrapped);
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        // Any other pool using this hook is blocked too (different fee tier).
        key.fee = 500;
        key.tickSpacing = 10;
        vm.prank(alice);
        vm.expectRevert();
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));
    }

    function test_poolPoisoning_siblingPoolsCannotDerailGraduation() public {
        // An attacker opens hook-less pools for the same pair at absurd prices before graduation.
        PoolKey memory sibling = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vm.prank(alice);
        poolManager.initialize(sibling, TickMath.getSqrtPriceAtTick(0));

        _graduate();
        assertEq(uint8(curve.state().status), uint8(CurveStatus.Graduated), "canonical pool is ours");
        assertGt(migrator.positionOf(address(token)).liquidity, 0);
    }

    // ------------------------------------------------------------------ access control

    function test_migrate_onlyTheRegisteredCurveAndOnlyOnce() public {
        vm.prank(alice);
        vm.expectRevert(ILiquidityMigrator.OnlyRegisteredCurve.selector);
        migrator.migrate{value: 1 ether}(address(token), 1);

        vm.deal(address(curve), 1 ether);
        vm.prank(address(curve));
        vm.expectRevert(ILiquidityMigrator.InvalidPrice.selector);
        migrator.migrate{value: 1 ether}(address(token), 0);

        _graduate();
        vm.deal(address(curve), 1 ether);
        vm.prank(address(curve));
        vm.expectRevert(ILiquidityMigrator.AlreadyMigrated.selector);
        migrator.migrate{value: 1 ether}(address(token), 1);
    }

    // ------------------------------------------------------------------ LP fees (§6.6, §7.1)

    function test_lpFees_areCollectedAndSplitWhileLiquidityStaysLocked() public {
        _graduate();
        PoolKey memory key = migrator.poolKeyOf(address(token));
        uint128 lockedLiquidity = migrator.positionOf(address(token)).liquidity;

        // Buy with 100 MON, then sell half of the tokens back.
        vm.prank(alice);
        uint256 tokensBought = router.swapExactIn{value: 100 ether}(key, true, 100 ether);
        uint256 tokensSold = tokensBought / 2;
        vm.startPrank(alice);
        token.approve(address(router), tokensSold);
        router.swapExactIn(key, false, tokensSold);
        vm.stopPrank();

        uint256 creatorMon = creator.balance;
        uint256 treasuryMon = treasury.balance;
        (uint256 mon, uint256 tokens) = migrator.collectFees(address(token));

        // The locked position is the only LP, so it earns the whole 1% fee on each input.
        assertApproxEqRel(mon, 1 ether, 1e12, "1% of the MON input");
        assertApproxEqRel(tokens, tokensSold / 100, 1e12, "1% of the token input");
        uint256 monToCreator = mon * 7000 / 10_000;
        uint256 tokensToCreator = tokens * 7000 / 10_000;
        assertEq(creator.balance - creatorMon, monToCreator, "70% to the creator");
        assertEq(treasury.balance - treasuryMon, mon - monToCreator, "rest to the protocol");
        assertEq(token.balanceOf(creator), tokensToCreator);
        assertEq(token.balanceOf(treasury), tokens - tokensToCreator);
        assertEq(address(migrator).balance, 0);
        assertEq(token.balanceOf(address(migrator)), 0);

        (mon, tokens) = migrator.collectFees(address(token));
        assertEq(mon + tokens, 0, "nothing accrued since");
        assertEq(migrator.positionOf(address(token)).liquidity, lockedLiquidity, "principal untouched");
    }

    function test_lpFees_rejectingCreatorRecipientCannotBlockCollection() public {
        _graduate();
        RejectingRecipient rejecting = new RejectingRecipient();
        vm.prank(creator);
        curve.setCreatorFeeRecipient(address(rejecting));

        PoolKey memory key = migrator.poolKeyOf(address(token));
        vm.prank(alice);
        router.swapExactIn{value: 50 ether}(key, true, 50 ether);
        (uint256 mon,) = migrator.collectFees(address(token));
        assertEq(address(rejecting).balance, mon * 7000 / 10_000, "forced payment");
    }

    // ------------------------------------------------------------------ fuzz: donations keep price continuity

    /// @dev Body of the per-network fuzz test (inline fuzz config only applies where the test is declared).
    function _checkPriceContinuityWithSnipeDonations(uint256 seed) internal {
        // Taxed buys inside the anti-snipe window donate MON to the reserve before the sell-out.
        for (uint256 i; i < 6; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            vm.roll(vm.getBlockNumber() + r % 30);
            uint256 amount = bound(r >> 8, 0.1 ether, 12 ether);
            (uint256 out,,,) = curve.quoteBuy(amount);
            if (out == 0 || out > curve.maxBuyAmount()) continue;
            vm.prank(alice);
            curve.buy{value: amount}(0, address(0));
        }
        uint256 realMon = _graduate();
        assertGe(realMon, Presets.TARGET_RAISE);

        uint256 vTFinal = Presets.EXPECTED_VT0 - Presets.CURVE_SUPPLY;
        uint256 vMFinal = Presets.EXPECTED_VM0 + realMon;
        PoolId poolId = PoolId.wrap(migrator.positionOf(address(token)).poolId);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        assertLe(sqrtPriceX96, FPML.sqrt(FPML.fullMulDiv(vTFinal, Q192, vMFinal)), "DEX price >= curve price");
        assertEq(address(migrator).balance, 0);
        assertEq(token.balanceOf(address(migrator)), 0);
        assertEq(token.balanceOf(address(curve)), 0);
    }
}

contract LiquidityMigratorMainnetForkTest is LiquidityMigratorForkTest {
    function _network() internal pure override returns (MonadNetwork memory) {
        return MonadNetworks.mainnet();
    }

    /// forge-config: default.fuzz.runs = 32
    /// forge-config: ci.fuzz.runs = 256
    function testFuzz_graduation_priceContinuousWithSnipeDonations(uint256 seed) public {
        _checkPriceContinuityWithSnipeDonations(seed);
    }
}

contract LiquidityMigratorTestnetForkTest is LiquidityMigratorForkTest {
    function _network() internal pure override returns (MonadNetwork memory) {
        return MonadNetworks.testnet();
    }

    /// forge-config: default.fuzz.runs = 32
    /// forge-config: ci.fuzz.runs = 256
    function testFuzz_graduation_priceContinuousWithSnipeDonations(uint256 seed) public {
        _checkPriceContinuityWithSnipeDonations(seed);
    }
}
