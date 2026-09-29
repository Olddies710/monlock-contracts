// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FixedPointMathLib as FPML} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IBondingCurveManager} from "./interfaces/IBondingCurveManager.sol";
import {ILaunchToken} from "./interfaces/ILaunchToken.sol";
import {IStockReserve} from "./interfaces/IStockReserve.sol";
import {ITokenFactory} from "./interfaces/ITokenFactory.sol";
import {CloneWithArgs} from "./libraries/CloneWithArgs.sol";
import {StockReserveConfig} from "./types/LaunchpadTypes.sol";

/// @title StockReserve
/// @notice Implementation behind the per-launch stock reserves (ARCHITECTURE.md §7.4, Model A). Each launch gets
///         its own ERC-1167 clone whose immutable arguments are its `StockReserveConfig`, so no two launches ever
///         share a MON or stock balance. The implementation itself is never used directly.
/// @dev Holds MON (the curve's stock share of fees, plus anything sent to it) and the stock bought with it. The stock
///      has no way out: exposure, not a withdrawable treasury. Purchases are keeper-only because the pool price can be
///      moved within a transaction: the keeper's `minStockOut` comes from an external reference price, and the
///      listing's `maxSlippageBps` caps the price impact of each purchase on top of it.
contract StockReserve is IStockReserve, IUnlockCallback, ReentrancyGuardTransient {
    using PoolIdLibrary for PoolKey;
    using SafeCastLib for uint256;
    using SafeCastLib for int256;
    using SafeTransferLib for address;

    uint256 private constant BPS = 10_000;
    uint256 private constant WAD = 1e18;
    /// @dev `abi.encode(StockReserveConfig)`: eight static words.
    uint256 private constant CONFIG_LENGTH = 8 * 32;

    /// @notice Curve fees and creator LP fees (opt-in) arrive here. Accepted from anyone: a donation only adds to
    ///         this launch's reserve.
    receive() external payable {}

    // ------------------------------------------------------------------ purchase

    /// @inheritdoc IStockReserve
    function claimAndBuyStock(uint256 maxMonIn, uint256 minStockOut)
        external
        nonReentrant
        returns (uint256 monSpent, uint256 stockReceived)
    {
        StockReserveConfig memory c = config();
        if (msg.sender != ITokenFactory(c.factory).stockKeeper()) revert OnlyKeeper();
        if (minStockOut == 0) revert ZeroMinStockOut();

        IBondingCurveManager(c.curve).claimFees();
        _burnLaunchTokens(c.token);

        uint256 monIn = FPML.min(maxMonIn, address(this).balance);
        if (monIn == 0) return (0, 0);

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(IPoolManager(c.poolManager), _poolKey(c).toId());
        if (sqrtPriceX96 == 0) {
            _skip(c.stock, abi.encodeWithSelector(PoolNotInitialized.selector));
            return (0, 0);
        }

        // All-or-nothing inside the PoolManager lock: a revert anywhere (swap, settlement, stock transfer, minimum
        // output) rolls the whole purchase back and only the skip event remains.
        try IPoolManager(c.poolManager).unlock(abi.encode(monIn, minStockOut, _priceLimit(sqrtPriceX96, c))) returns (
            bytes memory result
        ) {
            (monSpent, stockReceived) = abi.decode(result, (uint256, uint256));
        } catch (bytes memory reason) {
            _skip(c.stock, reason);
            return (0, 0);
        }

        (uint160 sqrtPriceAfter,,,) = StateLibrary.getSlot0(IPoolManager(c.poolManager), _poolKey(c).toId());
        emit StockBuy(monSpent, stockReceived, address(this).balance, stockBalance(), sqrtPriceAfter);
    }

    /// @notice PoolManager callback of `claimAndBuyStock`: exact-input swap of native MON for the stock, bounded by
    ///         the price limit, then settle the MON and take the stock.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        StockReserveConfig memory c = config();
        if (msg.sender != c.poolManager) revert OnlyPoolManager();
        (uint256 monIn, uint256 minStockOut, uint160 sqrtPriceLimitX96) = abi.decode(data, (uint256, uint256, uint160));

        IPoolManager manager = IPoolManager(c.poolManager);
        BalanceDelta delta = manager.swap(
            _poolKey(c),
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -monIn.toInt256(), sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            ""
        );
        // Exact input, MON (currency0) in: amount0 <= 0 is what we owe, amount1 >= 0 what we receive. A sign
        // violation reverts the cast, i.e. the purchase is skipped.
        uint256 monSpent = (-int256(delta.amount0())).toUint256();
        uint256 stockOut = int256(delta.amount1()).toUint256();
        // Pays the PoolManager (the caller, checked above) exactly the MON it accounted for.
        // forge-lint: disable-next-line(arbitrary-send-eth, unused-return)
        manager.settle{value: monSpent}();

        // Measured, not trusted: a stock with a transfer fee delivers less than the pool accounts for.
        uint256 before = SafeTransferLib.balanceOf(c.stock, address(this));
        manager.take(Currency.wrap(c.stock), address(this), stockOut);
        uint256 received = SafeTransferLib.balanceOf(c.stock, address(this)) - before;
        if (received < minStockOut) revert InsufficientStockOut(received, minStockOut);
        return abi.encode(monSpent, received);
    }

    // ------------------------------------------------------------------ views

    /// @inheritdoc IStockReserve
    function config() public view returns (StockReserveConfig memory) {
        return abi.decode(CloneWithArgs.argsOfSelf(CONFIG_LENGTH), (StockReserveConfig));
    }

    /// @inheritdoc IStockReserve
    function poolKey() external view returns (PoolKey memory) {
        return _poolKey(config());
    }

    /// @inheritdoc IStockReserve
    function stockBalance() public view returns (uint256) {
        return SafeTransferLib.balanceOf(config().stock, address(this));
    }

    // ------------------------------------------------------------------ internals

    function _poolKey(StockReserveConfig memory c) private pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(c.stock),
            fee: c.poolFee,
            tickSpacing: c.tickSpacing,
            hooks: IHooks(address(0))
        });
    }

    /// @dev Selling MON (currency0) moves the price (stock per MON, sqrtPrice^2) down. Capping it at
    ///      (1 - maxSlippageBps) of the pre-trade price means sqrtLimit = sqrtPrice * sqrt(1 - maxSlippageBps).
    function _priceLimit(uint160 sqrtPriceX96, StockReserveConfig memory c) private pure returns (uint160) {
        uint256 factor = FPML.sqrt((BPS - c.maxSlippageBps) * WAD * WAD / BPS); // sqrt(1 - s), 1e18 fixed point
        uint256 limit = FPML.fullMulDiv(sqrtPriceX96, factor, WAD);
        // forge-lint: disable-next-line(unsafe-typecast)
        return limit <= TickMath.MIN_SQRT_PRICE ? TickMath.MIN_SQRT_PRICE + 1 : uint160(limit); // below sqrtPriceX96
    }

    /// @dev Creator LP fees in launch tokens (opt-in, §7.4) have no use here and cannot be sold without adding sell
    ///      pressure to the launch: they are burned.
    function _burnLaunchTokens(address token) private {
        uint256 amount = SafeTransferLib.balanceOf(token, address(this));
        if (amount == 0) return;
        ILaunchToken(token).burn(amount);
        emit LaunchTokensBurned(amount);
    }

    function _skip(address stock, bytes memory reason) private {
        emit StockBuySkipped(address(this).balance, SafeTransferLib.balanceOf(stock, address(this)), reason);
    }

    /// @dev Same reason as in the curve: Solady's persistent-storage lock off Ethereum mainnet is not wanted.
    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }
}
