// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FixedPointMathLib as FPML} from "solady/utils/FixedPointMathLib.sol";

import {MonadNetwork, MonadNetworks} from "../../script/config/MonadAddresses.sol";
import {Presets} from "../../script/config/Presets.sol";
import {BondingCurveManager} from "../../src/BondingCurveManager.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {StockReserve} from "../../src/StockReserve.sol";
import {CurveStatus} from "../../src/types/LaunchpadTypes.sol";
import {MockStock} from "../utils/StockMocks.sol";
import {V4LiquidityProvider} from "../utils/V4TestRouter.sol";
import {MonadForkTest} from "./MonadForkTest.sol";

/// @notice Stock-reserve launches (ARCHITECTURE.md §7.4) against the real Uniswap v4 PoolManager of each Monad
///         network. No tokenized stock with a v4 (native MON, stock) pool could be verified on Monad (DEPLOYMENT.md
///         §11), so the stock here is a synthetic token this test deploys, with a pool it creates: the PoolManager,
///         the swap, settlement and price limits are real. `test_realStock_fromEnvironment` runs the same purchase on
///         a real stock when one is supplied, and skips otherwise.
abstract contract StockReserveForkTest is MonadForkTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    uint24 internal constant POOL_FEE = 3000; // 0.3 %
    int24 internal constant TICK_SPACING = 60;
    uint16 internal constant MAX_SLIPPAGE_BPS = 300;
    uint256 internal constant STOCK_PER_MON = 0.05e18; // opening price of the synthetic pool

    MockStock internal stock;
    PoolKey internal stockKey;
    address internal keeper = makeAddr("keeper");

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        stock = new MockStock("SYNTHx", 18);
        stockKey = _stockKey(address(stock));
        // sqrtPriceX96 = sqrt(stock per MON) * 2^96, then ~4,500 MON and ~220 SYNTHx of full-range liquidity.
        uint160 sqrtPriceX96 = uint160(FPML.sqrt(FPML.fullMulDiv(STOCK_PER_MON, 1 << 192, 1e18)));
        // forge-lint: disable-next-line(unused-return)
        poolManager.initialize(stockKey, sqrtPriceX96);
        V4LiquidityProvider provider = new V4LiquidityProvider(poolManager);
        vm.deal(address(provider), 10_000 ether);
        stock.mint(address(provider), 1000e18);
        provider.addLiquidity(
            stockKey, TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), 1e21
        );

        vm.startPrank(owner); // the fixture's deployer, still the factory owner
        factory.listStock(address(stock), "SYNTHx", address(poolManager), POOL_FEE, TICK_SPACING, MAX_SLIPPAGE_BPS);
        factory.setStockKeeper(keeper);
        vm.stopPrank();
    }

    function test_stockLaunch_buysTheStockThroughTheRealPoolManager() public {
        string memory group = string.concat(network.name, "-stock");
        (address t, address c) = factory.createStockToken(_params("stock-fork"), address(stock));
        vm.snapshotGasLastFrame(group, "createStockToken");
        BondingCurveManager launched = BondingCurveManager(payable(c));
        StockReserve reserve = StockReserve(payable(launched.stockReserve()));
        assertGt(LaunchToken(t).totalSupply(), 0);

        vm.roll(launched.launchBlock() + Presets.SNIPE_DECAY_BLOCKS);
        vm.prank(alice);
        launched.buy{value: 500 ether}(0, address(0));
        uint256 stockShare = launched.claimableStockFees();
        assertEq(stockShare, 5 ether * 500 / 10_000, "5 % of the 1 % fee");

        (uint160 priceBefore,,,) = poolManager.getSlot0(stockKey.toId());
        // Keeper's minimum: the reference price minus the pool fee and 1 % tolerance.
        uint256 minOut = stockShare * STOCK_PER_MON / 1e18 * 99 / 100;
        vm.prank(keeper);
        (uint256 spent, uint256 received) = reserve.claimAndBuyStock(type(uint256).max, minOut);
        vm.snapshotGasLastFrame(group, "claimAndBuyStock");

        assertEq(spent, stockShare);
        assertGe(received, minOut);
        assertEq(stock.balanceOf(address(reserve)), received);
        assertEq(address(reserve).balance, 0);
        (uint160 priceAfter,,,) = poolManager.getSlot0(stockKey.toId());
        assertLt(priceAfter, priceBefore, "bought stock: price in stock per MON went down");
    }

    /// @notice The listing's impact cap is a real v4 price limit: a purchase too large for the pool fills partially,
    ///         stops at the cap, and keeps the rest of the MON.
    function test_stockLaunch_priceImpactCapStopsALargePurchase() public {
        (, address c) = factory.createStockToken(_params("impact"), address(stock));
        StockReserve reserve = StockReserve(payable(BondingCurveManager(payable(c)).stockReserve()));
        vm.deal(address(reserve), 1000 ether); // ~20 % of the pool's MON side
        (uint160 priceBefore,,,) = poolManager.getSlot0(stockKey.toId());

        vm.prank(keeper);
        (uint256 spent, uint256 received) = reserve.claimAndBuyStock(type(uint256).max, 1);
        assertGt(received, 0);
        assertLt(spent, 1000 ether, "partial fill");
        assertEq(address(reserve).balance, 1000 ether - spent);
        (uint160 priceAfter,,,) = poolManager.getSlot0(stockKey.toId());
        // Price (stock per MON) fell by at most the 3 % cap.
        uint256 ratio = FPML.fullMulDiv(priceAfter, 1e18, priceBefore);
        assertGe(ratio * ratio / 1e18, 0.97e18 - 1e12);
    }

    /// @notice Post-graduation opt-in on the real v4 stack: the creator's LP fees from the graduated pool go to the
    ///         reserve, which burns the launch tokens and converts the MON. The LP position is untouched.
    function test_stockLaunch_graduatedCreatorLpFeesBuyStock() public {
        (address t, address c) = factory.createStockToken(_params("graduated"), address(stock));
        BondingCurveManager launched = BondingCurveManager(payable(c));
        StockReserve reserve = StockReserve(payable(launched.stockReserve()));
        vm.roll(launched.launchBlock() + Presets.SNIPE_DECAY_BLOCKS);
        vm.prank(whale);
        launched.buy{value: 5000 ether}(0, address(0));
        assertEq(uint8(launched.state().status), uint8(CurveStatus.Graduated));
        uint128 lockedLiquidity = migrator.positionOf(t).liquidity;

        vm.prank(creator);
        launched.setCreatorFeeRecipient(address(reserve));
        PoolKey memory launchKey = migrator.poolKeyOf(t);
        vm.prank(alice);
        uint256 bought = router.swapExactIn{value: 50 ether}(launchKey, true, 50 ether);
        vm.startPrank(alice);
        LaunchToken(t).approve(address(router), bought);
        router.swapExactIn(launchKey, false, bought);
        vm.stopPrank();
        migrator.collectFees(t); // creator share (MON + tokens) lands in the reserve

        uint256 tokensInReserve = LaunchToken(t).balanceOf(address(reserve));
        assertGt(tokensInReserve, 0);
        uint256 supplyBefore = LaunchToken(t).totalSupply();
        vm.prank(keeper);
        (uint256 spent, uint256 received) = reserve.claimAndBuyStock(type(uint256).max, 1);
        assertGt(spent, 0);
        assertGt(received, 0);
        assertEq(LaunchToken(t).balanceOf(address(reserve)), 0);
        assertEq(LaunchToken(t).totalSupply(), supplyBefore - tokensInReserve, "launch tokens burned");
        assertEq(migrator.positionOf(t).liquidity, lockedLiquidity, "LP stays locked");
    }

    /// @notice Same purchase against a real tokenized stock, when one is supplied (STOCK_TOKEN, STOCK_POOL_FEE,
    ///         STOCK_TICK_SPACING). Skips unless the token exists and its v4 pool holds liquidity at the pinned block.
    function test_realStock_fromEnvironment() public {
        address real = vm.envOr("STOCK_TOKEN", address(0));
        if (real == address(0)) {
            vm.skip(true, "no verified tokenized stock with a v4 (MON, stock) pool on Monad: set STOCK_TOKEN");
            return;
        }
        if (real.code.length == 0) {
            vm.skip(true, "STOCK_TOKEN has no code at the pinned fork block");
            return;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        uint24 fee = uint24(vm.envOr("STOCK_POOL_FEE", uint256(POOL_FEE))); // test input, v4 bounds the fee itself
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 spacing = int24(vm.envOr("STOCK_TICK_SPACING", int256(TICK_SPACING))); // test input
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(_stockKey(real, fee, spacing).toId());
        if (sqrtPriceX96 == 0 || poolManager.getLiquidity(_stockKey(real, fee, spacing).toId()) == 0) {
            vm.skip(true, "STOCK_TOKEN has no (MON, stock) v4 pool with liquidity at the pinned fork block");
            return;
        }
        vm.prank(owner);
        factory.listStock(real, "REAL", address(poolManager), fee, spacing, MAX_SLIPPAGE_BPS);
        (, address c) = factory.createStockToken(_params("real-stock"), real);
        StockReserve reserve = StockReserve(payable(BondingCurveManager(payable(c)).stockReserve()));
        vm.deal(address(reserve), 1 ether);
        vm.prank(keeper);
        (, uint256 received) = reserve.claimAndBuyStock(1 ether, 1);
        // Received, or skipped (e.g. market closed, transfer restrictions): either way nothing reverted.
        assertEq(received, stockBalanceOf(real, address(reserve)));
    }

    // ------------------------------------------------------------------ helpers

    function _stockKey(address token) internal pure returns (PoolKey memory) {
        return _stockKey(token, POOL_FEE, TICK_SPACING);
    }

    function _stockKey(address token, uint24 fee, int24 spacing) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(address(0))
        });
    }

    function stockBalanceOf(address token, address account) internal view returns (uint256) {
        return MockStock(token).balanceOf(account);
    }
}

contract StockReserveMainnetForkTest is StockReserveForkTest {
    function _network() internal pure override returns (MonadNetwork memory) {
        return MonadNetworks.mainnet();
    }
}

contract StockReserveTestnetForkTest is StockReserveForkTest {
    function _network() internal pure override returns (MonadNetwork memory) {
        return MonadNetworks.testnet();
    }
}
