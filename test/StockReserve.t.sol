// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Vm} from "forge-std/Vm.sol";
import {FixedPointMathLib as FPML} from "solady/utils/FixedPointMathLib.sol";

import {Presets} from "../script/config/Presets.sol";
import {BondingCurveManager} from "../src/BondingCurveManager.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {StockReserve} from "../src/StockReserve.sol";
import {IBondingCurveManager} from "../src/interfaces/IBondingCurveManager.sol";
import {IStockReserve} from "../src/interfaces/IStockReserve.sol";
import {ITokenFactory} from "../src/interfaces/ITokenFactory.sol";
import {CloneWithArgs} from "../src/libraries/CloneWithArgs.sol";
import {
    CreateParams,
    CurveStatus,
    FeeSplit,
    LaunchPreset,
    StockListing,
    StockReserveConfig
} from "../src/types/LaunchpadTypes.sol";
import {LaunchpadTest} from "./utils/LaunchpadTest.sol";
import {MockPoolManager, MockStock} from "./utils/StockMocks.sol";

/// @notice Stock-reserve launches, Model A (ARCHITECTURE.md §7.4): the curve stays in MON, a slice of its fees goes
///         to a per-launch StockReserve, and a keeper converts it into an allowlisted stock through Uniswap v4.
///         Offline against a minimal PoolManager; the fork suite runs the same flow on the real one.
contract StockReserveTest is LaunchpadTest {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant BPS = 10_000;
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint16 internal constant MAX_SLIPPAGE_BPS = 300;
    uint160 internal constant SQRT_PRICE = uint160(1 << 90);
    uint256 internal constant TSLA_PER_MON = 0.05e18; // 18-decimal stock
    uint256 internal constant NVDA_PER_MON = 0.1e6; // 6-decimal stock

    MockPoolManager internal pm;
    MockStock internal tsla;
    MockStock internal nvda;
    address internal keeper = makeAddr("keeper");

    function setUp() public override {
        super.setUp();
        pm = new MockPoolManager();
        tsla = new MockStock("TSLAx", 18);
        nvda = new MockStock("NVDAx", 6);
        tsla.mint(address(pm), 1e30); // pool inventory
        nvda.mint(address(pm), 1e30);
        pm.setPool(_key(address(tsla)), SQRT_PRICE, 1e24, TSLA_PER_MON);
        pm.setPool(_key(address(nvda)), SQRT_PRICE, 1e24, NVDA_PER_MON);

        vm.startPrank(owner);
        factory.listStock(address(tsla), "TSLAx", address(pm), POOL_FEE, TICK_SPACING, MAX_SLIPPAGE_BPS);
        factory.listStock(address(nvda), "NVDAx", address(pm), POOL_FEE, TICK_SPACING, MAX_SLIPPAGE_BPS);
        factory.setStockKeeper(keeper);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ allowlist

    function test_listStock_recordsTheListingAndThePoolState() public {
        MockStock aapl = new MockStock("AAPLx", 8);
        pm.setPool(_key(address(aapl)), SQRT_PRICE, 5e20, 1e8);
        PoolKey memory key = _key(address(aapl));
        vm.expectEmit(address(factory));
        emit ITokenFactory.StockListed(
            address(aapl),
            "AAPLx",
            address(pm),
            PoolId.unwrap(PoolIdLibrary.toId(key)),
            POOL_FEE,
            TICK_SPACING,
            250,
            8,
            SQRT_PRICE,
            5e20
        );
        vm.prank(owner);
        factory.listStock(address(aapl), "AAPLx", address(pm), POOL_FEE, TICK_SPACING, 250);

        StockListing memory l = factory.stockListing(address(aapl));
        assertEq(l.symbol, "AAPLx");
        assertEq(l.poolManager, address(pm));
        assertEq(l.poolFee, POOL_FEE);
        assertEq(l.tickSpacing, TICK_SPACING);
        assertEq(l.maxSlippageBps, 250);
        assertEq(l.decimals, 8);
        assertTrue(l.listed);
    }

    function test_listStock_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        vm.prank(alice);
        factory.listStock(address(tsla), "TSLAx", address(pm), POOL_FEE, TICK_SPACING, MAX_SLIPPAGE_BPS);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        vm.prank(alice);
        factory.setStockKeeper(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        vm.prank(alice);
        factory.delistStock(address(tsla));
    }

    /// @notice No listing without a live v4 (native MON, stock) pool holding liquidity.
    function test_listStock_rejectsAPoolWithoutLiquidity() public {
        MockStock ghost = new MockStock("GHOST", 18);
        bytes32 poolId = PoolId.unwrap(PoolIdLibrary.toId(_key(address(ghost))));
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ITokenFactory.StockPoolWithoutLiquidity.selector, poolId));
        factory.listStock(address(ghost), "GHOST", address(pm), POOL_FEE, TICK_SPACING, MAX_SLIPPAGE_BPS); // no pool
        vm.stopPrank();

        pm.setPool(_key(address(ghost)), SQRT_PRICE, 0, 1e18); // initialized, empty
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ITokenFactory.StockPoolWithoutLiquidity.selector, poolId));
        factory.listStock(address(ghost), "GHOST", address(pm), POOL_FEE, TICK_SPACING, MAX_SLIPPAGE_BPS);

        // Same stock, other fee tier: a different pool, also missing.
        vm.prank(owner);
        vm.expectRevert(); // StockPoolWithoutLiquidity(<other pool id>)
        factory.listStock(address(tsla), "TSLAx", address(pm), 500, 10, MAX_SLIPPAGE_BPS);
    }

    function test_listStock_rejectsInvalidParameters() public {
        vm.startPrank(owner);
        _expectInvalidListing(address(0), "X", address(pm), MAX_SLIPPAGE_BPS);
        _expectInvalidListing(makeAddr("eoa"), "X", address(pm), MAX_SLIPPAGE_BPS);
        _expectInvalidListing(address(tsla), bytes32(0), address(pm), MAX_SLIPPAGE_BPS);
        _expectInvalidListing(address(tsla), "X", makeAddr("no pool manager"), MAX_SLIPPAGE_BPS);
        _expectInvalidListing(address(tsla), "X", address(pm), 0);
        _expectInvalidListing(address(tsla), "X", address(pm), factory.MAX_STOCK_SLIPPAGE_BPS() + 1);
        _expectInvalidListing(address(pm), "X", address(pm), MAX_SLIPPAGE_BPS); // no decimals()
        vm.stopPrank();
    }

    function test_delistStock_blocksNewLaunchesOnly() public {
        (,, StockReserve reserve) = _launchStock("before-delist", address(tsla));
        vm.expectEmit(address(factory));
        emit ITokenFactory.StockDelisted(address(tsla));
        vm.prank(owner);
        factory.delistStock(address(tsla));

        vm.expectRevert(abi.encodeWithSelector(ITokenFactory.StockNotListed.selector, address(tsla)));
        factory.createStockToken(_params("after-delist"), address(tsla));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ITokenFactory.StockNotListed.selector, address(tsla)));
        factory.delistStock(address(tsla));

        // The live reserve keeps its own copy of the listing and keeps buying.
        vm.deal(address(reserve), 1 ether);
        vm.prank(keeper);
        (, uint256 received) = reserve.claimAndBuyStock(type(uint256).max, 1);
        assertEq(received, TSLA_PER_MON);
    }

    // ------------------------------------------------------------------ creation

    function test_createStockToken_revertsForAnUnlistedStock() public {
        MockStock unlisted = new MockStock("NOPE", 18);
        vm.expectRevert(abi.encodeWithSelector(ITokenFactory.StockNotListed.selector, address(unlisted)));
        factory.createStockToken(_params("unlisted"), address(unlisted));
        vm.expectRevert(abi.encodeWithSelector(ITokenFactory.StockNotListed.selector, makeAddr("random")));
        factory.createStockToken(_params("random"), makeAddr("random"));
    }

    function test_createStockToken_deploysAnIsolatedReserveForTheLaunch() public {
        bytes32 salt = "stock-launch";
        (address predictedToken, address predictedCurve) = factory.predictAddresses(address(this), salt);
        address predictedReserve = factory.predictStockReserve(address(this), salt, address(tsla));
        bytes32 poolId = PoolId.unwrap(PoolIdLibrary.toId(_key(address(tsla))));

        vm.expectEmit(address(factory));
        emit ITokenFactory.StockReserveCreated(predictedToken, address(tsla), predictedReserve, 500, poolId);
        (address t, address c) = factory.createStockToken(_params(salt), address(tsla));
        assertEq(t, predictedToken, "same token address as a plain launch");
        assertEq(c, predictedCurve);

        BondingCurveManager launched = BondingCurveManager(payable(c));
        assertEq(launched.stockReserve(), predictedReserve);
        assertEq(launched.stockFeeBps(), 500);
        (,, FeeSplit memory split,) = launched.feeParams();
        assertEq(split.creatorBps, 3000);
        assertEq(split.protocolBps, 5500, "stock share comes out of the protocol share");
        assertEq(split.referrerBps, 1000);
        assertEq(uint256(split.creatorBps) + split.protocolBps + split.referrerBps + launched.stockFeeBps(), BPS);

        StockReserve reserve = StockReserve(payable(predictedReserve));
        StockReserveConfig memory cfg = reserve.config();
        assertEq(cfg.factory, address(factory));
        assertEq(cfg.token, t);
        assertEq(cfg.curve, c);
        assertEq(cfg.stock, address(tsla));
        assertEq(cfg.poolManager, address(pm));
        assertEq(cfg.poolFee, POOL_FEE);
        assertEq(cfg.tickSpacing, TICK_SPACING);
        assertEq(cfg.maxSlippageBps, MAX_SLIPPAGE_BPS);
        PoolKey memory key = reserve.poolKey();
        assertEq(Currency.unwrap(key.currency0), address(0), "native MON");
        assertEq(Currency.unwrap(key.currency1), address(tsla));
        assertEq(address(key.hooks), address(0));
        // A clone of the factory's implementation: its own account, 300 bytes of code.
        assertEq(address(reserve).code.length, CloneWithArgs.ARGS_OFFSET + 256);
    }

    /// @notice The default MON launch is untouched: no reserve, no stock share, protocol keeps 60 %.
    function test_createStockToken_withoutStockIsAPlainLaunch() public {
        vm.recordLogs();
        (, address c) = factory.createStockToken(_params("plain"), address(0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != ITokenFactory.StockReserveCreated.selector);
        }
        BondingCurveManager plain = BondingCurveManager(payable(c));
        assertEq(plain.stockReserve(), address(0));
        assertEq(plain.stockFeeBps(), 0);
        (,, FeeSplit memory split,) = plain.feeParams();
        assertEq(split.protocolBps, 6000);
        assertEq(curve.stockReserve(), address(0), "createToken launches have no reserve either");
    }

    function test_createStockToken_rejectsAPresetWithoutRoomForTheStockShare() public {
        LaunchPreset memory p = Presets.defaultPreset(address(migrator));
        p.curveFeeSplit = FeeSplit({creatorBps: 5600, protocolBps: 400, referrerBps: 4000});
        vm.prank(owner);
        factory.setPreset(3, p);
        CreateParams memory params = _params("thin protocol share");
        params.presetId = 3;
        vm.expectRevert(abi.encodeWithSelector(ITokenFactory.StockFeeExceedsProtocolShare.selector, uint32(3)));
        factory.createStockToken(params, address(tsla));
        factory.createToken(params); // fine without a stock
    }

    function test_createStockTokenWithSig_bindsTheStockChoice() public {
        (address signer, uint256 key) = makeAddrAndKey("stock-signer");
        address relayer = makeAddr("relayer");
        CreateParams memory p = _params("signed");
        p.creator = signer;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(key, factory.hashCreateStockToken(p, address(tsla), relayer, deadline));

        // The signature covers the stock: it does not authorize another stock, nor a plain launch.
        vm.startPrank(relayer);
        vm.expectRevert(ITokenFactory.InvalidSignature.selector);
        factory.createStockTokenWithSig(p, address(nvda), deadline, sig);
        vm.expectRevert(ITokenFactory.InvalidSignature.selector);
        factory.createTokenWithSig(p, deadline, sig);
        (, address c) = factory.createStockTokenWithSig(p, address(tsla), deadline, sig);
        vm.stopPrank();
        assertEq(BondingCurveManager(payable(c)).creator(), signer);
        assertEq(StockReserve(payable(BondingCurveManager(payable(c)).stockReserve())).config().stock, address(tsla));
    }

    /// @notice Curve-level guard, independent of the factory: the stock share must fit in the protocol share.
    function test_curve_rejectsInconsistentStockParams() public {
        LaunchPreset memory preset = Presets.defaultPreset(address(migrator));
        address anyReserve = makeAddr("reserve");
        _expectRawLaunchRevert(preset, address(0), 500, "bps without reserve");
        _expectRawLaunchRevert(preset, anyReserve, 0, "reserve without bps");
        _expectRawLaunchRevert(preset, anyReserve, 6001, "more than the protocol share");

        harness.setStockParams(anyReserve, 6000);
        (, BondingCurveManager c) = _launchRaw(preset, "all protocol");
        (,, FeeSplit memory split,) = c.feeParams();
        assertEq(split.protocolBps, 0);
        assertEq(c.stockFeeBps(), 6000);
    }

    // ------------------------------------------------------------------ fee accrual

    function test_buys_accrueTheStockShareAndClaimPaysTheReserve() public {
        (, BondingCurveManager c, StockReserve reserve) = _launchStock("accrual", address(tsla));
        vm.roll(c.launchBlock() + Presets.SNIPE_DECAY_BLOCKS);
        vm.prank(alice);
        c.buy{value: 100 ether}(0, referrer);
        vm.prank(bob);
        c.buy{value: 50 ether}(0, address(0));

        uint256 total = c.state().totalFeesAccrued;
        assertEq(total, 1.5 ether, "1% of 150 MON");
        assertEq(c.claimableStockFees(), total * 500 / BPS);
        (uint256 toCreator, uint256 toProtocol) = c.claimableFees();
        assertEq(toCreator, total * 3000 / BPS);
        uint256 toReferrer = c.referrerFees(referrer);
        assertEq(toReferrer, 1 ether * 1000 / BPS);
        assertEq(toCreator + toProtocol + c.claimableStockFees() + toReferrer, total, "every wei attributed");

        uint256 stockShare = c.claimableStockFees();
        vm.expectEmit(address(c));
        emit IBondingCurveManager.StockFeesClaimed(address(reserve), stockShare);
        c.claimFees();
        assertEq(address(reserve).balance, stockShare);
        assertEq(treasury.balance, toProtocol);
        assertEq(creator.balance, toCreator);
        assertEq(c.claimableStockFees(), 0);
    }

    // ------------------------------------------------------------------ purchases

    function test_claimAndBuyStock_happyPath() public {
        (, BondingCurveManager c, StockReserve reserve) = _launchStock("happy", address(tsla));
        vm.roll(c.launchBlock() + Presets.SNIPE_DECAY_BLOCKS);
        vm.prank(alice);
        c.buy{value: 200 ether}(0, address(0));
        uint256 stockShare = c.claimableStockFees(); // 0.1 MON
        uint256 expectedStock = stockShare * TSLA_PER_MON / 1e18;

        vm.expectEmit(address(reserve));
        emit IStockReserve.StockBuy(stockShare, expectedStock, 0, expectedStock, SQRT_PRICE);
        vm.prank(keeper);
        (uint256 spent, uint256 received) = reserve.claimAndBuyStock(type(uint256).max, expectedStock);

        assertEq(spent, stockShare, "pulled the curve's stock share and spent it");
        assertEq(received, expectedStock);
        assertEq(tsla.balanceOf(address(reserve)), expectedStock);
        assertEq(reserve.stockBalance(), expectedStock);
        assertEq(address(reserve).balance, 0);

        // Exact input with a price limit at the listing's impact cap: sqrt(limit / price) = sqrt(1 - 3 %).
        (bool zeroForOne, int256 amountSpecified, uint160 limit) = pm.lastSwap();
        assertTrue(zeroForOne);
        assertEq(amountSpecified, -int256(stockShare));
        assertLt(limit, SQRT_PRICE);
        uint256 ratio = FPML.fullMulDiv(limit, 1e18, SQRT_PRICE);
        assertApproxEqRel(ratio * ratio / 1e18, 0.97e18, 1e12);
    }

    function test_claimAndBuyStock_onlyTheKeeper() public {
        (,, StockReserve reserve) = _launchStock("keeper", address(tsla));
        vm.deal(address(reserve), 1 ether);
        address[3] memory others = [creator, owner, alice];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(IStockReserve.OnlyKeeper.selector);
            reserve.claimAndBuyStock(1 ether, 1);
        }
        vm.prank(owner);
        factory.setStockKeeper(address(0)); // pauses every purchase
        vm.prank(keeper);
        vm.expectRevert(IStockReserve.OnlyKeeper.selector);
        reserve.claimAndBuyStock(1 ether, 1);
    }

    function test_claimAndBuyStock_requiresAMinimumOutput() public {
        (,, StockReserve reserve) = _launchStock("min-out", address(tsla));
        vm.prank(keeper);
        vm.expectRevert(IStockReserve.ZeroMinStockOut.selector);
        reserve.claimAndBuyStock(1 ether, 0);
    }

    /// @notice A failing v4 swap is skipped: the MON stays, nothing reverts, and trading is unaffected.
    function test_claimAndBuyStock_swapFailureSkipsAndTradingContinues() public {
        (LaunchToken t, BondingCurveManager c, StockReserve reserve) = _launchStock("swap-fails", address(tsla));
        vm.roll(c.launchBlock() + Presets.SNIPE_DECAY_BLOCKS);
        vm.prank(alice);
        c.buy{value: 100 ether}(0, address(0));
        uint256 stockShare = c.claimableStockFees();
        pm.setRevertOnSwap(true);

        vm.expectEmit(address(reserve));
        emit IStockReserve.StockBuySkipped(stockShare, 0, abi.encodeWithSelector(MockPoolManager.SwapFailed.selector));
        vm.prank(keeper);
        (uint256 spent, uint256 received) = reserve.claimAndBuyStock(type(uint256).max, 1);
        assertEq(spent + received, 0);
        assertEq(address(reserve).balance, stockShare, "MON kept for a later attempt");

        // The trade path never touches the reserve: buys and sells keep working while purchases fail.
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(bob);
        c.buy{value: 10 ether}(0, address(0));
        vm.roll(vm.getBlockNumber() + 1);
        uint256 half = t.balanceOf(alice) / 2;
        vm.prank(alice);
        c.sell(half, 0);

        pm.setRevertOnSwap(false);
        vm.prank(keeper);
        (spent,) = reserve.claimAndBuyStock(type(uint256).max, 1);
        assertEq(spent, c.state().totalFeesAccrued * 500 / BPS, "everything accrued so far, in one purchase");
    }

    /// @notice Depeg or manipulated pool: less than the keeper's minimum -> skipped, MON kept.
    function test_claimAndBuyStock_belowMinimumOutputSkips() public {
        (,, StockReserve reserve) = _launchStock("depeg", address(tsla));
        vm.deal(address(reserve), 1 ether);
        pm.setPool(_key(address(tsla)), SQRT_PRICE, 1e24, TSLA_PER_MON / 2); // the pool now pays half
        uint256 expectedAtReference = TSLA_PER_MON;

        vm.expectEmit(address(reserve));
        emit IStockReserve.StockBuySkipped(
            1 ether,
            0,
            abi.encodeWithSelector(
                IStockReserve.InsufficientStockOut.selector, TSLA_PER_MON / 2, expectedAtReference * 99 / 100
            )
        );
        vm.prank(keeper);
        reserve.claimAndBuyStock(1 ether, expectedAtReference * 99 / 100);
        assertEq(address(reserve).balance, 1 ether);
        assertEq(tsla.balanceOf(address(reserve)), 0, "the swap was rolled back entirely");
    }

    /// @notice An RWA whose transfers revert (paused, restricted recipient) is skipped until it recovers.
    function test_claimAndBuyStock_revertingStockTransferSkips() public {
        (,, StockReserve reserve) = _launchStock("paused", address(tsla));
        vm.deal(address(reserve), 1 ether);
        tsla.setPaused(true);
        vm.expectEmit(address(reserve));
        emit IStockReserve.StockBuySkipped(1 ether, 0, abi.encodeWithSelector(MockStock.TransfersPaused.selector));
        vm.prank(keeper);
        reserve.claimAndBuyStock(1 ether, 1);
        assertEq(address(reserve).balance, 1 ether);

        tsla.setPaused(false);
        vm.prank(keeper);
        (, uint256 received) = reserve.claimAndBuyStock(1 ether, 1);
        assertEq(received, TSLA_PER_MON);
    }

    /// @notice Fee-on-transfer stock: the reserve checks and reports what it actually received.
    function test_claimAndBuyStock_measuresAFeeOnTransferStock() public {
        (,, StockReserve reserve) = _launchStock("fee-on-transfer", address(tsla));
        vm.deal(address(reserve), 2 ether);
        tsla.setTransferFeeBps(100); // 1 %
        uint256 net = TSLA_PER_MON * 99 / 100;

        vm.prank(keeper);
        vm.expectEmit(address(reserve));
        emit IStockReserve.StockBuySkipped(
            2 ether, 0, abi.encodeWithSelector(IStockReserve.InsufficientStockOut.selector, net, TSLA_PER_MON)
        );
        reserve.claimAndBuyStock(1 ether, TSLA_PER_MON); // gross amount as minimum: not met

        vm.prank(keeper);
        (, uint256 received) = reserve.claimAndBuyStock(1 ether, net);
        assertEq(received, net);
        assertEq(tsla.balanceOf(address(reserve)), net);
    }

    function test_claimAndBuyStock_poolGoneSkipsWithoutCallingIt() public {
        (,, StockReserve reserve) = _launchStock("pool-gone", address(tsla));
        vm.deal(address(reserve), 1 ether);
        pm.setPool(_key(address(tsla)), 0, 0, 0);
        vm.expectEmit(address(reserve));
        emit IStockReserve.StockBuySkipped(
            1 ether, 0, abi.encodeWithSelector(IStockReserve.PoolNotInitialized.selector)
        );
        vm.prank(keeper);
        reserve.claimAndBuyStock(1 ether, 1);
        assertEq(pm.swaps(), 0);
    }

    function test_claimAndBuyStock_spendsAtMostMaxMonIn() public {
        (,, StockReserve reserve) = _launchStock("chunks", address(tsla));
        vm.deal(address(reserve), 10 ether);
        vm.prank(keeper);
        (uint256 spent, uint256 received) = reserve.claimAndBuyStock(4 ether, 1);
        assertEq(spent, 4 ether);
        assertEq(received, 4 * TSLA_PER_MON);
        assertEq(address(reserve).balance, 6 ether);
    }

    /// @notice A price limit that stops the swap early spends only part of the input; the rest stays.
    function test_claimAndBuyStock_partialFillKeepsTheRest() public {
        (,, StockReserve reserve) = _launchStock("partial", address(tsla));
        vm.deal(address(reserve), 10 ether);
        pm.setFillBps(2500);
        vm.prank(keeper);
        (uint256 spent, uint256 received) = reserve.claimAndBuyStock(10 ether, 1);
        assertEq(spent, 2.5 ether);
        assertEq(received, 2.5 ether * TSLA_PER_MON / 1e18);
        assertEq(address(reserve).balance, 7.5 ether);
    }

    function test_claimAndBuyStock_nothingToBuyIsANoOp() public {
        (,, StockReserve reserve) = _launchStock("empty", address(tsla));
        vm.recordLogs();
        vm.prank(keeper);
        (uint256 spent, uint256 received) = reserve.claimAndBuyStock(1 ether, 1);
        assertEq(spent + received, 0);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_implementationIsNotAReserve() public {
        StockReserve implementation = StockReserve(payable(factory.stockReserveImplementation()));
        vm.expectRevert(CloneWithArgs.NotAClone.selector);
        implementation.config();
        vm.prank(keeper);
        vm.expectRevert(CloneWithArgs.NotAClone.selector);
        implementation.claimAndBuyStock(1 ether, 1);
    }

    function test_unlockCallback_onlyThePoolManager() public {
        (,, StockReserve reserve) = _launchStock("callback", address(tsla));
        vm.expectRevert(IStockReserve.OnlyPoolManager.selector);
        reserve.unlockCallback(abi.encode(uint256(1 ether), uint256(1), uint160(1)));
    }

    /// @notice Relisting with other parameters only affects future launches.
    function test_listingChangesDoNotReachALiveReserve() public {
        (,, StockReserve reserve) = _launchStock("snapshot", address(tsla));
        vm.prank(owner);
        factory.listStock(address(tsla), "TSLAx", address(pm), POOL_FEE, TICK_SPACING, 1000);
        assertEq(reserve.config().maxSlippageBps, MAX_SLIPPAGE_BPS);
        (,, StockReserve later) = _launchStock("after-relist", address(tsla));
        assertEq(later.config().maxSlippageBps, 1000);
    }

    // ------------------------------------------------------------------ isolation (Monad parallel execution)

    /// @notice Two launches paired with different stocks share no account: launch A's trade, fee claim and stock
    ///         purchase never read or write launch B's curve, token, reserve or stock, and never write the factory.
    ///         Each reserve holds its own MON; no contract pools the quote asset of several launches.
    function test_isolation_twoStockLaunchesShareNoAccount() public {
        (LaunchToken tA, BondingCurveManager cA, StockReserve rA) = _launchStock("iso-a", address(tsla));
        (LaunchToken tB, BondingCurveManager cB, StockReserve rB) = _launchStock("iso-b", address(nvda));
        assertTrue(address(rA) != address(rB));
        vm.roll(cA.launchBlock() + Presets.SNIPE_DECAY_BLOCKS);
        vm.prank(bob);
        cB.buy{value: 20 ether}(0, address(0));
        cB.claimFees();
        uint256 rBBalance = address(rB).balance;
        assertGt(rBBalance, 0);

        address[4] memory launchB = [address(cB), address(tB), address(rB), address(nvda)];
        vm.record();
        vm.startStateDiffRecording();
        vm.prank(alice);
        cA.buy{value: 20 ether}(0, referrer);
        vm.prank(keeper);
        rA.claimAndBuyStock(type(uint256).max, 1);
        Vm.AccountAccess[] memory diff = vm.stopAndReturnStateDiff();

        // Positive control: the recording sees launch A's own writes and calls.
        (, bytes32[] memory curveAWrites) = vm.accesses(address(cA));
        assertGt(curveAWrites.length, 0, "recording works");
        bool reserveASeen;
        for (uint256 i; i < diff.length; ++i) {
            if (diff[i].account == address(rA)) reserveASeen = true;
        }
        assertTrue(reserveASeen, "state diff sees reserve A");

        for (uint256 i; i < 4; ++i) {
            (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(launchB[i]);
            assertEq(reads.length + writes.length, 0, "launch B storage untouched");
        }
        (, bytes32[] memory factoryWrites) = vm.accesses(address(factory));
        assertEq(factoryWrites.length, 0, "the factory is only read (keeper)");
        for (uint256 i; i < diff.length; ++i) {
            for (uint256 j; j < 4; ++j) {
                assertTrue(diff[i].account != launchB[j], "no call, balance change or code access on launch B");
            }
        }
        assertEq(address(rB).balance, rBBalance, "B's MON never moved");
        assertEq(address(rA).balance, 0);
        assertGt(tsla.balanceOf(address(rA)), 0);
        assertEq(nvda.balanceOf(address(rA)), 0);
        assertEq(tA.balanceOf(address(rB)), 0);
    }

    // ------------------------------------------------------------------ after graduation

    /// @notice Post-graduation (optional): the creator routes its LP fees to the reserve. The MON is converted with
    ///         the same keeper call, launch tokens received are burned, and the LP itself stays locked.
    function test_postGraduation_creatorLpFeesOptIn() public {
        (LaunchToken t, BondingCurveManager c, StockReserve reserve) = _launchStock("graduated", address(tsla));
        vm.roll(c.launchBlock() + Presets.SNIPE_DECAY_BLOCKS);
        vm.prank(alice);
        c.buy{value: R * 5 / 2}(0, address(0));
        assertEq(uint8(c.state().status), uint8(CurveStatus.Graduated));
        vm.prank(creator);
        c.setCreatorFeeRecipient(address(reserve));

        // What LiquidityMigrator.collectFees pays the creator recipient: MON and launch tokens.
        vm.deal(address(this), 3 ether);
        (bool ok,) = address(reserve).call{value: 3 ether}("");
        assertTrue(ok);
        vm.prank(alice);
        t.transfer(address(reserve), 1000e18);
        uint256 supplyBefore = t.totalSupply();

        // Graduation fee included: the curve's stock share, plus the creator share now routed here.
        uint256 total = c.state().totalFeesAccrued;
        uint256 expectedMon = 3 ether + total * 500 / BPS + total * 3000 / BPS;
        vm.expectEmit(address(reserve));
        emit IStockReserve.LaunchTokensBurned(1000e18);
        vm.prank(keeper);
        (uint256 spent,) = reserve.claimAndBuyStock(type(uint256).max, 1);
        assertEq(spent, expectedMon);
        assertEq(t.totalSupply(), supplyBefore - 1000e18);
        assertEq(t.balanceOf(address(reserve)), 0);
    }

    // ------------------------------------------------------------------ fuzz: fee split conservation

    /// forge-config: default.fuzz.runs = 256
    /// forge-config: ci.fuzz.runs = 2000
    /// @notice Whatever the order of trades and claims, every fee wei goes to exactly one bucket and the stock
    ///         reserve gets exactly floor(total * 5 %).
    function testFuzz_stockFeeSplit_attributesEveryWei(uint256 seed) public {
        (LaunchToken t, BondingCurveManager c, StockReserve reserve) = _launchStock("fuzz", address(tsla));
        vm.roll(c.launchBlock() + Presets.SNIPE_DECAY_BLOCKS);
        uint256 creatorBefore = creator.balance;
        uint256 treasuryBefore = treasury.balance;

        for (uint256 i; i < 12; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            vm.roll(vm.getBlockNumber() + 1);
            uint256 action = r % 4;
            if (action == 0 || action == 1) {
                vm.prank(alice);
                c.buy{value: bound(r >> 8, 0.01 ether, 50 ether)}(0, action == 0 ? referrer : address(0));
            } else if (action == 2) {
                uint256 amount = t.balanceOf(alice) * bound(r >> 8, 1, 100) / 100;
                if (amount == 0) continue;
                vm.prank(alice);
                c.sellTo(alice, amount, 0, (r >> 16) % 2 == 0 ? referrer : address(0), block.timestamp);
            } else {
                c.claimFees();
            }
        }
        c.claimFees();

        uint256 total = c.state().totalFeesAccrued;
        uint256 stockPaid = address(reserve).balance;
        uint256 creatorPaid = creator.balance - creatorBefore;
        uint256 protocolPaid = treasury.balance - treasuryBefore;
        assertEq(stockPaid, total * 500 / BPS, "stock share");
        assertEq(creatorPaid, total * 3000 / BPS, "creator share");
        assertEq(creatorPaid + protocolPaid + stockPaid + c.state().referrerFeesAccrued, total, "no wei lost");
        (uint256 toCreator, uint256 toProtocol) = c.claimableFees();
        assertEq(toCreator + toProtocol + c.claimableStockFees(), 0);
    }

    // ------------------------------------------------------------------ helpers

    function _key(address stock) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(stock),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    function _launchStock(bytes32 salt, address stock)
        internal
        returns (LaunchToken t, BondingCurveManager c, StockReserve reserve)
    {
        (address tokenAddress, address curveAddress) = factory.createStockToken(_params(salt), stock);
        t = LaunchToken(tokenAddress);
        c = BondingCurveManager(payable(curveAddress));
        reserve = StockReserve(payable(c.stockReserve()));
    }

    function _expectInvalidListing(address stock, bytes32 symbol, address poolManager, uint16 maxSlippageBps) internal {
        vm.expectRevert(ITokenFactory.InvalidStockListing.selector);
        factory.listStock(stock, symbol, poolManager, POOL_FEE, TICK_SPACING, maxSlippageBps);
    }

    function _expectRawLaunchRevert(LaunchPreset memory preset, address reserve, uint16 bps, bytes32 salt) internal {
        harness.setStockParams(reserve, bps);
        vm.expectRevert(IBondingCurveManager.InvalidDeployParams.selector);
        this.rawLaunch(preset, salt);
    }

    /// @dev External so `expectRevert` sees the CREATE2 failure bubbling out of the harness.
    function rawLaunch(LaunchPreset memory preset, bytes32 salt) external {
        _launchRaw(preset, salt);
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
