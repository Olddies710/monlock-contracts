// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ILaunchToken
/// @notice Launch-specific extension of the LaunchToken. The token itself is a standard ERC-20 with EIP-2612
///         permit (Solady `ERC20`); use this interface together with `IERC20` / `IERC20Permit`.
///         Strict fair launch: the whole supply is minted once, in the constructor, to the token's bonding curve.
///         No mint function, no owner, no blacklist, no transfer tax, no pause.
/// @dev Two rules on top of ERC-20 (ARCHITECTURE.md §5.4 and §2.5):
///      1. Anti-sandwich round-trip guard: tokens that left the curve in block N, directly or through a chain of
///         transfers within block N, cannot be sold back to the curve in block N. The marker lives in the same
///         storage slot as the balance (uint216 balance | uint40 lastBuyBlock): zero extra SLOAD/SSTORE.
///      2. The curve has an implicit, non-revocable infinite allowance (`allowance(owner, curve)` returns
///         type(uint256).max). Selling needs no approve and touches no allowance slot. The curve only ever pulls
///         from `msg.sender` inside `sell`.
interface ILaunchToken {
    /// @notice The sender received curve tokens in this block and tried to sell to the curve in the same block.
    error SameBlockRoundTrip();

    /// @notice The factory returned unusable deployment parameters (empty or >31-byte name/symbol, zero curve,
    ///         zero or >uint216 supply).
    error InvalidDeployParams();

    /// @notice Bonding curve that received the whole supply at deployment.
    function curve() external view returns (address);

    /// @notice Factory that deployed this token.
    function factory() external view returns (address);

    /// @notice Last block in which `account` received tokens that left the curve in that same block.
    function lastBuyBlock(address account) external view returns (uint256);

    /// @notice Burns `amount` of the caller's tokens. The curve uses it to burn the unused LP reserve.
    function burn(uint256 amount) external;
}
