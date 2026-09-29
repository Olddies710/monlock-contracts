// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Minimal exact-input swap router for Uniswap v4 fork tests (our own MIT code; v4-core's test routers
///         are UNLICENSED). ERC-20 input is pulled from the caller, who must approve this router first.
contract V4TestRouter is IUnlockCallback {
    using SafeTransferLib for address;

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swapExactIn(PoolKey memory key, bool zeroForOne, uint256 amountIn)
        external
        payable
        returns (uint256 amountOut)
    {
        amountOut = abi.decode(manager.unlock(abi.encode(msg.sender, key, zeroForOne, amountIn)), (uint256));
        if (address(this).balance != 0) msg.sender.safeTransferETH(address(this).balance);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (address payer, PoolKey memory key, bool zeroForOne, uint256 amountIn) =
            abi.decode(data, (address, PoolKey, bool, uint256));

        BalanceDelta delta = manager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (Currency input, Currency output) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        int128 inDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outDelta = zeroForOne ? delta.amount1() : delta.amount0();
        uint256 pay = uint256(-int256(inDelta));
        uint256 amountOut = uint256(int256(outDelta));

        if (input.isAddressZero()) {
            manager.settle{value: pay}();
        } else {
            manager.sync(input);
            Currency.unwrap(input).safeTransferFrom(payer, address(manager), pay);
            manager.settle();
        }
        manager.take(output, payer, amountOut);
        return abi.encode(amountOut);
    }

    receive() external payable {}
}

/// @notice Adds liquidity to a (native MON, ERC-20) Uniswap v4 pool for fork tests: pays exactly what the PoolManager
///         asks for, MON from this contract's balance and the ERC-20 from its own inventory.
contract V4LiquidityProvider is IUnlockCallback {
    using SafeTransferLib for address;

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function addLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity) external {
        manager.unlock(abi.encode(key, tickLower, tickUpper, liquidity));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity) =
            abi.decode(data, (PoolKey, int24, int24, uint256));
        (BalanceDelta delta,) = manager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(liquidity), salt: bytes32(0)
            }),
            ""
        );
        manager.settle{value: uint256(-int256(delta.amount0()))}();
        manager.sync(key.currency1);
        Currency.unwrap(key.currency1).safeTransfer(address(manager), uint256(-int256(delta.amount1())));
        manager.settle();
        return "";
    }

    receive() external payable {}
}
