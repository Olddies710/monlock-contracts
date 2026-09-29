// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice Synthetic tokenized stock for tests. NOT a real asset: fork tests deploy it themselves instead of
///         pointing at an unverified address. Switches for the RWA failure modes: paused transfers, transfer fee,
///         non-18 decimals.
contract MockStock is ERC20 {
    string private _symbol;
    uint8 private immutable _decimals;
    bool public paused;
    uint16 public transferFeeBps;

    error TransfersPaused();

    constructor(string memory symbol_, uint8 decimals_) {
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function name() public view override returns (string memory) {
        return string.concat("Mock ", _symbol);
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setTransferFeeBps(uint16 value) external {
        transferFeeBps = value;
    }

    function _beforeTokenTransfer(address from, address to, uint256) internal view override {
        if (paused && from != address(0) && to != address(0)) revert TransfersPaused();
    }

    /// @dev Fee-on-transfer: the fee is burned from the recipient right after it is credited.
    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        if (transferFeeBps == 0 || from == address(0) || to == address(0)) return;
        _burn(to, amount * transferFeeBps / 10_000);
    }
}

/// @notice Minimal Uniswap v4 PoolManager for offline tests: `unlock` with the real callback flow, exact-input
///         MON -> stock swaps at a configurable price, native `settle`, `take`, and `extsload` laid out like v4 so
///         `StateLibrary` works unchanged. Like the real one, `unlock` reverts unless every delta was settled.
contract MockPoolManager {
    using PoolIdLibrary for PoolKey;

    address private _locker;
    int256 private _monDelta; // owed to the manager (> 0) after a swap, cleared by settle
    int256 private _stockDelta; // owed to the locker (> 0) after a swap, cleared by take

    mapping(bytes32 slot => bytes32) private _slots;
    mapping(PoolId => uint256) public stockPerMon; // stock units per 1e18 wei of MON
    bool public revertOnSwap;
    uint16 public fillBps = 10_000; // share of the input consumed (a price limit stops the swap early)
    IPoolManager.SwapParams public lastSwap;
    uint256 public swaps;

    error SwapFailed();
    error CurrencyNotSettled();
    error ManagerLocked();

    // ------------------------------------------------------------------ configuration

    function setPool(PoolKey memory key, uint160 sqrtPriceX96, uint128 liquidity, uint256 stockPerMon_) external {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), StateLibrary.POOLS_SLOT));
        _slots[stateSlot] = bytes32(uint256(sqrtPriceX96)); // tick, protocol fee, lp fee: 0
        _slots[bytes32(uint256(stateSlot) + StateLibrary.LIQUIDITY_OFFSET)] = bytes32(uint256(liquidity));
        stockPerMon[key.toId()] = stockPerMon_;
    }

    function setRevertOnSwap(bool value) external {
        revertOnSwap = value;
    }

    function setFillBps(uint16 value) external {
        fillBps = value;
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _slots[slot];
    }

    // ------------------------------------------------------------------ v4 surface used by StockReserve

    function unlock(bytes calldata data) external returns (bytes memory result) {
        if (_locker != address(0)) revert ManagerLocked();
        _locker = msg.sender;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        if (_monDelta != 0 || _stockDelta != 0) revert CurrencyNotSettled();
        _locker = address(0);
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params, bytes calldata)
        external
        returns (BalanceDelta)
    {
        require(msg.sender == _locker, "not locker");
        if (revertOnSwap) revert SwapFailed();
        require(params.zeroForOne && params.amountSpecified < 0, "only exact-in MON -> stock");
        lastSwap = params;
        swaps++;
        uint256 monIn = uint256(-params.amountSpecified) * fillBps / 10_000;
        uint256 stockOut = monIn * stockPerMon[key.toId()] / 1e18;
        _monDelta += int256(monIn);
        _stockDelta += int256(stockOut);
        return toBalanceDelta(-int128(int256(monIn)), int128(int256(stockOut)));
    }

    function settle() external payable returns (uint256) {
        _monDelta -= int256(msg.value);
        return msg.value;
    }

    /// @dev A real transfer out of the manager's inventory (tests fund it), so pauses and transfer fees apply.
    function take(Currency currency, address to, uint256 amount) external {
        _stockDelta -= int256(amount);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        ERC20(Currency.unwrap(currency)).transfer(to, amount);
    }
}
