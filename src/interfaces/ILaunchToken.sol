// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title ILaunchToken
/// @notice Fixed-supply ERC-20 deployed by the TokenFactory. Strict fair launch:
///         - the entire supply is minted once, in the constructor, to the token's bonding curve;
///         - no mint function, no owner, no blacklist, no transfer tax, no pause;
///         - EIP-2612 permit for DEX routers and bots after graduation.
/// @dev Two rules on top of ERC-20 (ARCHITECTURE.md §5.4 and §2.5):
///      1. Anti-sandwich round-trip guard: tokens that left the curve in block N, directly or through a chain of
///         transfers within block N, cannot be sold back to the curve in block N. The marker is packed with the
///         balance in one slot (uint216 balance | uint40 lastBuyBlock): zero extra SLOAD/SSTORE per transfer.
///      2. The curve has an implicit, non-revocable infinite allowance (`allowance(owner, curve)` returns
///         type(uint256).max). Selling needs no approve and touches no allowance slot. The curve only ever pulls
///         from `msg.sender` inside `sell`.
interface ILaunchToken is IERC20Metadata, IERC20Permit {
    /// @notice The sender received curve tokens in this block and tried to sell to the curve in the same block.
    error SameBlockRoundTrip();

    /// @notice Bonding curve that received the whole supply at deployment.
    function curve() external view returns (address);

    /// @notice Factory that deployed this token.
    function factory() external view returns (address);

    /// @notice Last block in which `account` received tokens that came from the curve in that same block.
    function lastBuyBlock(address account) external view returns (uint256);

    /// @notice Burns `amount` of the caller's tokens. The curve uses it to burn the unused LP reserve.
    function burn(uint256 amount) external;
}
