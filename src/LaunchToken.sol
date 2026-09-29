// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";
import {LibString} from "solady/utils/LibString.sol";

import {ILaunchToken} from "./interfaces/ILaunchToken.sol";
import {ITokenFactory} from "./interfaces/ITokenFactory.sol";

/// @title LaunchToken
/// @notice Fixed-supply ERC-20 of one launch. The entire supply is minted once, in the constructor, to the
///         token's BondingCurveManager. There is no mint function, owner, blacklist, pause or transfer tax.
/// @dev Built on Solady `ERC20`, which provides allowances, EIP-2612 permit and the Permit2 infinite allowance.
///      Balance accounting is overridden so each account lives in ONE packed slot:
///          bits [0, 216)   balance
///          bits [216, 256) lastBuyBlock (anti-sandwich marker, ARCHITECTURE.md §5.4)
///      Every transfer does exactly one SLOAD and one SSTORE per party, the same as a plain ERC-20: the
///      round-trip guard costs no extra storage access. On Monad each account is also a single storage page.
contract LaunchToken is ERC20, ILaunchToken {
    uint256 private constant _BALANCE_MASK = (1 << 216) - 1;
    uint256 private constant _MARKER_SHIFT = 216;

    /// @inheritdoc ILaunchToken
    address public immutable curve;
    /// @inheritdoc ILaunchToken
    address public immutable factory;

    bytes32 private immutable _packedName;
    bytes32 private immutable _packedSymbol;
    bytes32 private immutable _nameHash;

    uint256 private _totalSupply;
    /// @dev account => balance (low 216 bits) | lastBuyBlock (high 40 bits).
    mapping(address account => uint256 packed) private _accounts;

    /// @dev Parameters are read back from the deploying factory (transient storage), so the init code has no
    ///      arguments and every token shares one init-code hash (ARCHITECTURE.md §2.4).
    constructor() {
        (bytes32 packedName, bytes32 packedSymbol, address curve_, uint256 supply) =
            ITokenFactory(msg.sender).tokenDeployParams();
        if (
            packedName == bytes32(0) || packedSymbol == bytes32(0) || curve_ == address(0) || supply == 0
                || supply > _BALANCE_MASK
        ) revert InvalidDeployParams();

        factory = msg.sender;
        curve = curve_;
        _packedName = packedName;
        _packedSymbol = packedSymbol;
        _nameHash = keccak256(bytes(LibString.unpackOne(packedName)));

        _totalSupply = supply;
        _accounts[curve_] = supply;
        emit Transfer(address(0), curve_, supply);
    }

    // ------------------------------------------------------------------ metadata

    function name() public view override returns (string memory) {
        return LibString.unpackOne(_packedName);
    }

    function symbol() public view override returns (string memory) {
        return LibString.unpackOne(_packedSymbol);
    }

    /// @dev Precomputed for Solady's EIP-2612 domain separator: saves hashing the name on every permit.
    function _constantNameHash() internal view override returns (bytes32) {
        return _nameHash;
    }

    // ------------------------------------------------------------------ balances

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _accounts[account] & _BALANCE_MASK;
    }

    /// @inheritdoc ILaunchToken
    function lastBuyBlock(address account) external view returns (uint256) {
        return _accounts[account] >> _MARKER_SHIFT;
    }

    // ------------------------------------------------------------------ allowances

    /// @dev The curve has an implicit, non-revocable infinite allowance (ARCHITECTURE.md §2.5).
    function allowance(address owner, address spender) public view override returns (uint256) {
        if (spender == curve) return type(uint256).max;
        return super.allowance(owner, spender);
    }

    // ------------------------------------------------------------------ transfers

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        // Solady's `_spendAllowance` keeps the Permit2 infinite allowance; the curve needs no allowance at all.
        if (msg.sender != curve) _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /// @inheritdoc ILaunchToken
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @dev Moves `amount` and enforces the round-trip guard:
    ///      - selling to the curve reverts if `from` received curve tokens in this block;
    ///      - tokens leaving the curve mark the recipient with the current block;
    ///      - a marked sender propagates the mark to the recipient within the same block (closes the
    ///        "buy with A, transfer to B, sell with B" bypass). Zero-amount transfers never mark anyone.
    function _transfer(address from, address to, uint256 amount) internal override {
        uint256 fromPacked = _accounts[from];
        bool fromMarked = fromPacked >> _MARKER_SHIFT == block.number;
        if (fromMarked && to == curve) revert SameBlockRoundTrip();
        if (amount > fromPacked & _BALANCE_MASK) revert InsufficientBalance();

        unchecked {
            // No borrow into the marker bits: amount <= balance.
            _accounts[from] = fromPacked - amount;
            // No carry into the marker bits: every balance is <= totalSupply <= _BALANCE_MASK.
            uint256 toPacked = _accounts[to] + amount;
            if ((fromMarked || from == curve) && amount != 0) {
                toPacked = (toPacked & _BALANCE_MASK) | (block.number << _MARKER_SHIFT);
            }
            _accounts[to] = toPacked;
        }
        emit Transfer(from, to, amount);
    }

    /// @dev Only reachable through `burn`. Supply never increases after construction.
    function _burn(address from, uint256 amount) internal override {
        uint256 packed = _accounts[from];
        if (amount > packed & _BALANCE_MASK) revert InsufficientBalance();
        unchecked {
            _accounts[from] = packed - amount;
            _totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    /// @dev Disabled: the supply is minted exactly once, in the constructor.
    function _mint(address, uint256) internal pure override {
        revert TotalSupplyOverflow();
    }
}
