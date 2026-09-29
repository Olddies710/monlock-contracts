// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FixedPointMathLib as FPML} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IBondingCurveManager} from "./interfaces/IBondingCurveManager.sol";
import {ILaunchToken} from "./interfaces/ILaunchToken.sol";
import {ILiquidityMigrator} from "./interfaces/ILiquidityMigrator.sol";
import {ITokenFactory} from "./interfaces/ITokenFactory.sol";
import {FeeSplit} from "./types/LaunchpadTypes.sol";

/// @title LiquidityMigrator
/// @notice Uniswap v4 graduation for launchpad curves: migrator + `beforeInitialize` hook + permanent LP locker
///         (ARCHITECTURE.md §2.3, §4.8, §6.4, §6.6).
/// @dev Deployment: the address must carry exactly the BEFORE_INITIALIZE hook flag (bits 0-13 == 1 << 13), so it is
///      mined with CREATE2 (`script/utils/HookMiner.sol`); the constructor enforces it.
///      Positions are owned directly in the PoolManager (owner = this, salt = token): no position NFT, no Permit2,
///      and no code path that decreases liquidity.
contract LiquidityMigrator is ILiquidityMigrator, IUnlockCallback, ReentrancyGuardTransient {
    using PoolIdLibrary for PoolKey;
    using SafeCastLib for uint256;
    using SafeCastLib for int256;
    using SafeTransferLib for address;

    uint256 private constant BPS = 10_000;
    uint256 private constant Q96 = 1 << 96;
    uint8 private constant ACTION_ADD_LIQUIDITY = 1;
    uint8 private constant ACTION_COLLECT_FEES = 2;

    IPoolManager private immutable _poolManager;
    /// @inheritdoc ILiquidityMigrator
    address public immutable factory;
    /// @inheritdoc ILiquidityMigrator
    uint24 public immutable lpFee;
    /// @inheritdoc ILiquidityMigrator
    int24 public immutable tickSpacing;
    int24 private immutable _tickLower;
    int24 private immutable _tickUpper;
    uint160 private immutable _sqrtPriceLower;
    uint160 private immutable _sqrtPriceUpper;

    mapping(address token => LockedPosition) private _positions;

    constructor(IPoolManager poolManager_, address factory_, uint24 lpFee_, int24 tickSpacing_) {
        if (address(poolManager_) == address(0) || factory_ == address(0)) revert InvalidConfig();
        // Static fee only (the dynamic-fee flag is above MAX_LP_FEE) and a spacing the PoolManager accepts.
        if (lpFee_ > LPFeeLibrary.MAX_LP_FEE) revert InvalidConfig();
        if (tickSpacing_ < TickMath.MIN_TICK_SPACING || tickSpacing_ > TickMath.MAX_TICK_SPACING) {
            revert InvalidConfig();
        }
        Hooks.Permissions memory permissions;
        permissions.beforeInitialize = true;
        Hooks.validateHookPermissions(IHooks(address(this)), permissions);

        _poolManager = poolManager_;
        factory = factory_;
        lpFee = lpFee_;
        tickSpacing = tickSpacing_;
        _tickLower = TickMath.minUsableTick(tickSpacing_);
        _tickUpper = TickMath.maxUsableTick(tickSpacing_);
        _sqrtPriceLower = TickMath.getSqrtPriceAtTick(_tickLower);
        _sqrtPriceUpper = TickMath.getSqrtPriceAtTick(_tickUpper);
    }

    // ------------------------------------------------------------------ migration

    /// @inheritdoc ILiquidityMigrator
    function migrate(address token, uint256 tokenAmount)
        external
        payable
        nonReentrant
        returns (bytes32 poolId, uint128 liquidity)
    {
        if (ITokenFactory(factory).curveOf(token) != msg.sender) revert OnlyRegisteredCurve();
        if (_positions[token].liquidity != 0) revert AlreadyMigrated();
        uint256 received = SafeTransferLib.balanceOf(token, address(this));
        if (received < tokenAmount) revert InsufficientTokens(received, tokenAmount);

        uint160 sqrtPriceX96 = _openingSqrtPrice(tokenAmount, msg.value);
        liquidity = _liquidityForAmounts(sqrtPriceX96, msg.value, tokenAmount);
        PoolKey memory key = _poolKey(token);
        poolId = PoolId.unwrap(key.toId());
        // Effects before interactions: the position is fully known before the pool exists.
        _positions[token] = LockedPosition({
            poolId: poolId, curve: msg.sender, liquidity: liquidity, graduationBlock: block.number.toUint64()
        });

        // forge-lint: disable-next-line(unused-return)
        _poolManager.initialize(key, sqrtPriceX96); // the opening tick is implied by sqrtPriceX96
        (uint256 monPaid, uint256 tokensPaid) = abi.decode(
            _poolManager.unlock(abi.encode(ACTION_ADD_LIQUIDITY, token, msg.value, tokenAmount, liquidity)),
            (uint256, uint256)
        );
        emit Migrated(token, msg.sender, poolId, monPaid, tokensPaid, liquidity, sqrtPriceX96);

        // Rounding dust of the liquidity math (plus anything sent here beforehand): MON to the protocol, tokens
        // burned. The migrator never keeps a balance between calls.
        uint256 monDust = address(this).balance;
        // forge-lint: disable-next-line(arbitrary-send-eth)
        if (monDust != 0) ITokenFactory(factory).protocolTreasury().forceSafeTransferETH(monDust);
        uint256 tokenDust = SafeTransferLib.balanceOf(token, address(this));
        if (tokenDust != 0) ILaunchToken(token).burn(tokenDust);
    }

    /// @notice Pool-poisoning guard: only this contract may initialize pools that use it as their hook.
    function beforeInitialize(address sender, PoolKey calldata, uint160) external view returns (bytes4) {
        if (msg.sender != address(_poolManager)) revert OnlyPoolManager();
        if (sender != address(this)) revert UnauthorizedPoolInitializer();
        return IHooks.beforeInitialize.selector;
    }

    // ------------------------------------------------------------------ LP fees

    /// @inheritdoc ILiquidityMigrator
    function collectFees(address token) external nonReentrant returns (uint256 monCollected, uint256 tokensCollected) {
        LockedPosition memory position = _positions[token];
        if (position.liquidity == 0) revert NotMigrated();

        (monCollected, tokensCollected) =
            abi.decode(_poolManager.unlock(abi.encode(ACTION_COLLECT_FEES, token, 0, 0, 0)), (uint256, uint256));
        emit LpFeesCollected(token, monCollected, tokensCollected);

        IBondingCurveManager curve = IBondingCurveManager(position.curve);
        // Only the post-graduation split is relevant here.
        // forge-lint: disable-next-line(unused-return)
        (,,, FeeSplit memory split) = curve.feeParams();
        address creatorRecipient = curve.creatorFeeRecipient();
        address treasury = ITokenFactory(factory).protocolTreasury();

        // The creator gets its share rounded down; the protocol is the residual claimant (no dust left here).
        uint256 monToCreator = monCollected * split.creatorBps / BPS;
        uint256 tokensToCreator = tokensCollected * split.creatorBps / BPS;
        // Forced sends: a recipient that rejects MON cannot block the other or the collection itself.
        // forge-lint: disable-next-line(arbitrary-send-eth)
        if (monToCreator != 0) creatorRecipient.forceSafeTransferETH(monToCreator);
        // forge-lint: disable-next-line(arbitrary-send-eth)
        if (monCollected != monToCreator) treasury.forceSafeTransferETH(monCollected - monToCreator);
        if (tokensToCreator != 0) token.safeTransfer(creatorRecipient, tokensToCreator);
        if (tokensCollected != tokensToCreator) token.safeTransfer(treasury, tokensCollected - tokensToCreator);
    }

    // ------------------------------------------------------------------ PoolManager callback

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(_poolManager)) revert OnlyPoolManager();
        (uint8 action, address token, uint256 monAmount, uint256 tokenAmount, uint128 liquidity) =
            abi.decode(data, (uint8, address, uint256, uint256, uint128));
        return
            action == ACTION_ADD_LIQUIDITY
                ? _addLiquidity(token, monAmount, tokenAmount, liquidity)
                : _collectFees(token);
    }

    function _addLiquidity(address token, uint256 monAmount, uint256 tokenAmount, uint128 liquidity)
        private
        returns (bytes memory)
    {
        // A fresh position accrues no fees, so the second return value (feesAccrued) is always zero.
        // forge-lint: disable-start(unused-return)
        (BalanceDelta delta,) = _poolManager.modifyLiquidity(
            _poolKey(token),
            IPoolManager.ModifyLiquidityParams({
                tickLower: _tickLower,
                tickUpper: _tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: _positionSalt(token)
            }),
            ""
        );
        // forge-lint: disable-end(unused-return)
        // Adding liquidity yields non-positive deltas: what this contract owes the PoolManager.
        uint256 monOwed = _owed(delta.amount0());
        uint256 tokensOwed = _owed(delta.amount1());
        if (monOwed > monAmount || tokensOwed > tokenAmount) revert InvalidPrice();

        // Settlements are exact (native value / fee-less token), so the returned `paid` amounts are not needed.
        // forge-lint: disable-next-line(unused-return)
        _poolManager.settle{value: monOwed}();
        _poolManager.sync(Currency.wrap(token));
        token.safeTransfer(address(_poolManager), tokensOwed);
        // forge-lint: disable-next-line(unused-return)
        _poolManager.settle();
        return abi.encode(monOwed, tokensOwed);
    }

    /// @dev A zero-liquidity modification credits the position's accrued fees without touching principal.
    function _collectFees(address token) private returns (bytes memory) {
        // With liquidityDelta == 0 the caller delta *is* the accrued fees; the second return value repeats it.
        // forge-lint: disable-start(unused-return)
        (BalanceDelta delta,) = _poolManager.modifyLiquidity(
            _poolKey(token),
            IPoolManager.ModifyLiquidityParams({
                tickLower: _tickLower, tickUpper: _tickUpper, liquidityDelta: 0, salt: _positionSalt(token)
            }),
            ""
        );
        // forge-lint: disable-end(unused-return)
        uint256 mon = _credited(delta.amount0());
        uint256 tokens = _credited(delta.amount1());
        if (mon != 0) _poolManager.take(Currency.wrap(address(0)), address(this), mon);
        if (tokens != 0) _poolManager.take(Currency.wrap(token), address(this), tokens);
        return abi.encode(mon, tokens);
    }

    // ------------------------------------------------------------------ views

    /// @inheritdoc ILiquidityMigrator
    function positionOf(address token) external view returns (LockedPosition memory) {
        return _positions[token];
    }

    /// @inheritdoc ILiquidityMigrator
    function poolKeyOf(address token) external view returns (PoolKey memory) {
        return _poolKey(token);
    }

    /// @inheritdoc ILiquidityMigrator
    function poolManager() external view returns (address) {
        return address(_poolManager);
    }

    // ------------------------------------------------------------------ internals

    function _poolKey(address token) private view returns (PoolKey memory) {
        // Native MON (address(0)) always sorts first.
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(this))
        });
    }

    /// @dev Amount owed for a non-positive delta.
    function _owed(int128 delta) private pure returns (uint256) {
        if (delta > 0) revert InvalidPrice();
        return (-int256(delta)).toUint256();
    }

    /// @dev Amount credited for a non-negative delta.
    function _credited(int128 delta) private pure returns (uint256) {
        if (delta < 0) revert InvalidPrice();
        return int256(delta).toUint256();
    }

    function _positionSalt(address token) private pure returns (bytes32) {
        return bytes32(uint256(uint160(token)));
    }

    /// @dev v4 prices are currency1 per currency0 (tokens per MON): sqrtPriceX96 = floor(sqrt(tokens * 2^192 / mon)).
    ///      Rounding down gives fewer tokens per MON, i.e. a MON price >= the curve's (ARCHITECTURE.md §4.8).
    function _openingSqrtPrice(uint256 tokenAmount, uint256 monAmount) private view returns (uint160) {
        if (tokenAmount == 0 || monAmount == 0) revert InvalidPrice();
        uint256 sqrtPriceX96 = FPML.sqrt(FPML.fullMulDiv(tokenAmount, 1 << 192, monAmount));
        // Strictly inside the full-range position, which is itself inside [MIN_SQRT_PRICE, MAX_SQRT_PRICE).
        if (sqrtPriceX96 <= _sqrtPriceLower || sqrtPriceX96 >= _sqrtPriceUpper) revert InvalidPrice();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(sqrtPriceX96); // < _sqrtPriceUpper < 2^160
    }

    /// @dev Full-range liquidity for the given amounts at the current price (both amounts round down).
    function _liquidityForAmounts(uint160 sqrtPriceX96, uint256 monAmount, uint256 tokenAmount)
        private
        view
        returns (uint128)
    {
        // MON (currency0) is provided on [price, upper]; tokens (currency1) on [lower, price].
        uint256 fromMon = FPML.fullMulDiv(
            monAmount, FPML.fullMulDiv(sqrtPriceX96, _sqrtPriceUpper, Q96), _sqrtPriceUpper - sqrtPriceX96
        );
        uint256 fromTokens = FPML.fullMulDiv(tokenAmount, Q96, sqrtPriceX96 - _sqrtPriceLower);
        uint256 liquidity = FPML.min(fromMon, fromTokens);
        if (liquidity == 0 || liquidity > type(uint128).max) revert InvalidPrice();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(liquidity); // checked above
    }

    /// @dev Only the PoolManager sends MON here (LP fees taken in `_collectFees`).
    receive() external payable {
        if (msg.sender != address(_poolManager)) revert OnlyPoolManager();
    }

    /// @dev Transient lock on Monad too (see BondingCurveManager for the rationale).
    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }
}
