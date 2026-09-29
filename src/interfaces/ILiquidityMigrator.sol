// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ILiquidityMigrator
/// @notice Graduates a sold-out curve into a Uniswap v4 pool (native MON / token) and locks the liquidity forever.
///         One contract plays three roles (ARCHITECTURE.md §2.3, flow in §6.4):
///         1. Migrator: initializes the pool at the curve's final price and adds full-range liquidity.
///         2. Hook: `beforeInitialize` accepts only this contract as initializer, so nobody can pre-create the
///            pool at a manipulated price (pool poisoning). It is the only hook flag: swaps and liquidity changes
///            run without hook calls.
///         3. Locker: it owns every position directly in the PoolManager and has no code path that removes
///            liquidity. It can only collect LP fees (modifyLiquidity with delta 0) and split them.
/// @dev Price continuity: the curve sends amounts such that the DEX opening price (MON per token) is >= the
///      curve's final price, so nobody can buy cheaper on the DEX than the last curve buyer.
interface ILiquidityMigrator {
    struct LockedPosition {
        bytes32 poolId; // Uniswap v4 PoolId
        address curve;
        uint128 liquidity; // full-range liquidity, locked forever
        uint64 graduationBlock;
    }

    event Migrated(
        address indexed token,
        address indexed curve,
        bytes32 indexed poolId,
        uint256 monAmount,
        uint256 tokenAmount,
        uint128 liquidity,
        uint160 sqrtPriceX96
    );

    event LpFeesCollected(address indexed token, uint256 monCollected, uint256 tokensCollected);

    error OnlyRegisteredCurve();
    error OnlyPoolManager();
    error AlreadyMigrated();
    error NotMigrated();
    error UnauthorizedPoolInitializer();
    error InsufficientTokens(uint256 received, uint256 expected);
    error InvalidConfig();
    error InvalidPrice();

    /// @notice Called by a registered curve inside its graduation. The curve transfers `tokenAmount` tokens to
    ///         this contract right before the call and sends the MON for liquidity as `msg.value`.
    ///         The opening sqrtPriceX96 is derived from the ratio tokenAmount / msg.value, rounded down.
    /// @dev Must never send MON back to the curve (it has no `receive`, by design every wei is accounted): MON
    ///      dust goes to the protocol treasury and token dust is burned here. `monAmount`/`tokenAmount` in
    ///      `Migrated` are what actually entered the pool.
    function migrate(address token, uint256 tokenAmount) external payable returns (bytes32 poolId, uint128 liquidity);

    /// @notice Collects the LP fees of `token`'s locked position and pays them out according to the curve's
    ///         `lpFeeSplit` (creator / protocol; the protocol is the residual claimant). Permissionless.
    function collectFees(address token) external returns (uint256 monCollected, uint256 tokensCollected);

    function positionOf(address token) external view returns (LockedPosition memory);

    /// @notice Pool key of `token`'s graduated pool: (native MON, token, lpFee, tickSpacing, this hook).
    function poolKeyOf(address token) external view returns (PoolKey memory);

    function factory() external view returns (address);

    function poolManager() external view returns (address);

    /// @notice Static LP fee of graduated pools, in hundredths of a bip (10_000 = 1%).
    function lpFee() external view returns (uint24);

    function tickSpacing() external view returns (int24);
}
