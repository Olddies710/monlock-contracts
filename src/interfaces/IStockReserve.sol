// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {StockReserveConfig} from "../types/LaunchpadTypes.sol";

/// @title IStockReserve
/// @notice Stock reserve of ONE launch (ARCHITECTURE.md §7.4, Model A). The launch's curve pays it a share of its
///         fees in MON; the protocol's keeper converts that MON into the listed stock token through a Uniswap v4
///         (native MON, stock) pool. The stock stays in the reserve: there is no withdrawal path.
///         It gives the launch economic exposure to the stock, not ownership of the share.
///
///         Isolation: one instance per launch (an ERC-1167 clone with immutable arguments, CREATE2 from the
///         factory), so every reserve holds only its own launch's MON and stock. Nothing here is on the trade path:
///         buys and sells never call the reserve, and a failed purchase never reverts (StockBuySkipped).
interface IStockReserve {
    /// @notice MON converted into the stock. Balances are after the purchase (self-contained for indexers).
    event StockBuy(uint256 monIn, uint256 stockOut, uint256 monBalance, uint256 stockBalance, uint160 sqrtPriceX96);

    /// @notice A purchase was attempted and skipped (pool missing or empty, price outside bounds, stock transfer
    ///         failure...). The MON stays in the reserve. `reason` is the revert data of the failed attempt.
    event StockBuySkipped(uint256 monBalance, uint256 stockBalance, bytes reason);

    /// @notice Launch tokens received by the reserve (creator LP-fee opt-in, §7.4) and burned.
    event LaunchTokensBurned(uint256 amount);

    error OnlyKeeper();
    error OnlyPoolManager();
    error ZeroMinStockOut();
    error PoolNotInitialized();
    error InsufficientStockOut(uint256 received, uint256 minStockOut);

    /// @notice Keeper only. Pulls the curve's pending fees (`claimFees`), burns any launch tokens held here, then
    ///         swaps up to `maxMonIn` MON of the balance for the stock, requiring at least `minStockOut` received
    ///         and stopping at the listing's price-impact cap. Any failure of the swap emits StockBuySkipped and
    ///         keeps the MON; the call itself does not revert for it.
    /// @param minStockOut Minimum stock actually received (net of any transfer fee). The keeper derives it from an
    ///        external reference price, which is what detects a depegged or manipulated pool.
    function claimAndBuyStock(uint256 maxMonIn, uint256 minStockOut)
        external
        returns (uint256 monSpent, uint256 stockReceived);

    function config() external view returns (StockReserveConfig memory);

    /// @notice The (native MON, stock) pool this reserve buys from: no hooks.
    function poolKey() external view returns (PoolKey memory);

    function stockBalance() external view returns (uint256);
}
