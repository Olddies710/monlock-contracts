// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CurveState, FeeSplit} from "../types/LaunchpadTypes.sol";

/// @title IBondingCurveManager
/// @notice Manages the bonding curve of exactly one token. It is NOT a singleton: the TokenFactory deploys one
///         instance per launch (CREATE2, full bytecode, parameters in immutables). Each instance owns its own
///         state and its own MON, so trades on different tokens touch disjoint accounts and storage. This is the
///         EVM analogue of a per-mint PDA on Solana and what lets Monad execute them in parallel (ARCHITECTURE.md §3).
///
///         Pricing: constant product over virtual reserves (ARCHITECTURE.md §4)
///             vM = vM0 + realMonReserve,  vT = vT0 - C + realTokenReserve,  vM * vT >= vM0 * vT0.
///         All rounding favors the curve. MON is the native asset; there is no WMON on the curve.
interface IBondingCurveManager {
    // ------------------------------------------------------------------ events

    /// @notice Emitted on every trade. Carries post-trade reserves so indexers can rebuild state from logs
    ///         alone (Monad full nodes do not serve arbitrary historical state).
    /// @param monAmount Buy: gross MON paid in. Sell: net MON paid out.
    /// @param fee Base fee accrued to the fee recipients.
    /// @param snipeTax Anti-snipe surcharge, donated to the curve reserve (never to the creator).
    event Trade(
        address indexed trader,
        address indexed recipient,
        bool indexed isBuy,
        uint256 monAmount,
        uint256 tokenAmount,
        uint256 fee,
        uint256 snipeTax,
        uint256 realMonReserve,
        uint256 realTokenReserve
    );

    /// @notice The curve sold out and trading halted. Graduation follows atomically or via `graduate()`.
    event CurveCompleted(uint256 realMonReserve);

    /// @notice Liquidity was migrated to the DEX and locked. `tokensBurned` is the unused LP reserve.
    event Graduated(uint256 monToLiquidity, uint256 tokensToLiquidity, uint256 tokensBurned, uint256 graduationFee);

    /// @notice The atomic migration attempt reverted. The curve stays Completed and `graduate()` can retry.
    event MigrationFailed(bytes reason);

    event FeesClaimed(uint256 toCreator, uint256 toProtocol, uint256 toInterface);
    event CreatorFeeRecipientUpdated(address indexed recipient);

    // ------------------------------------------------------------------ errors

    error DeadlineExpired();
    error ZeroAmount();
    error InvalidRecipient();
    error NotTrading();
    error NotCompleted();
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error ExcessiveInput(uint256 amountIn, uint256 maxAmountIn);
    error MaxBuyExceeded(uint256 amountOut, uint256 maxAmountOut);
    error OnlyFactory();
    error OnlyCreator();

    // ------------------------------------------------------------------ trading

    /// @notice Buys tokens with exactly `msg.value` MON. If the buy exceeds the remaining supply it is clipped,
    ///         the excess MON is refunded and the curve graduates in the same transaction.
    function buy(uint256 minTokensOut, address recipient, uint256 deadline) external payable returns (uint256 tokensOut);

    /// @notice Buys exactly `tokensOut` tokens; refunds `msg.value - monIn`. Useful for bots targeting size.
    function buyExactOut(uint256 tokensOut, address recipient, uint256 deadline)
        external
        payable
        returns (uint256 monIn);

    /// @notice Sells `tokensIn` from `msg.sender` and pays MON to `recipient`. No approve needed: the token grants
    ///         its curve an implicit allowance, so a sell is one transaction and touches no allowance slot.
    function sell(uint256 tokensIn, uint256 minMonOut, address recipient, uint256 deadline)
        external
        returns (uint256 monOut);

    /// @notice Creator's initial buy, executed by the factory inside the creation transaction. Nobody can
    ///         front-run it, so it pays the base fee only. Capped at `maxDevBuyBps` of the curve supply.
    function devBuy(uint256 minTokensOut, address recipient) external payable returns (uint256 tokensOut);

    // ------------------------------------------------------------------ quotes (same math as the trades)

    function quoteBuy(uint256 monIn) external view returns (uint256 tokensOut, uint256 fee, uint256 snipeTax);

    function quoteBuyExactOut(uint256 tokensOut) external view returns (uint256 monIn, uint256 fee, uint256 snipeTax);

    function quoteSell(uint256 tokensIn) external view returns (uint256 monOut, uint256 fee, uint256 snipeTax);

    /// @notice Total fee at the current block: base fee plus the decaying anti-snipe component.
    function currentFeeBps() external view returns (uint256);

    function state() external view returns (CurveState memory);

    // ------------------------------------------------------------------ graduation

    /// @notice Permissionless retry of the migration when the curve is Completed but not Graduated.
    function graduate() external;

    // ------------------------------------------------------------------ fees (pull accounting, push payout)

    /// @notice Fees owed to each recipient: split(totalFeesAccrued) - alreadyClaimed.
    function claimableFees() external view returns (uint256 toCreator, uint256 toProtocol, uint256 toInterface);

    /// @notice Pays every recipient what it is owed. Callable by anyone; a reverting recipient cannot block the
    ///         others (payouts use a forced transfer).
    function claimFees() external;

    /// @notice Creator-only: where creator fees go, for the curve phase and for post-graduation LP fees.
    function setCreatorFeeRecipient(address recipient) external;

    // ------------------------------------------------------------------ configuration (immutable per launch)

    function token() external view returns (address);

    function factory() external view returns (address);

    function migrator() external view returns (address);

    function creator() external view returns (address);

    function creatorFeeRecipient() external view returns (address);

    function interfaceRecipient() external view returns (address);

    /// @notice Block of the creation transaction. Anti-snipe decay is measured in blocks from here because
    ///         Monad's block.timestamp has 1 s resolution (3-4 blocks share the same timestamp).
    function launchBlock() external view returns (uint256);

    function curveParams()
        external
        view
        returns (uint256 virtualTokenReserve0, uint256 virtualMonReserve0, uint256 curveSupply, uint256 lpSupply);

    function feeParams()
        external
        view
        returns (
            uint256 tradeFeeBps,
            uint256 graduationFeeBps,
            FeeSplit memory curveFeeSplit,
            FeeSplit memory lpFeeSplit
        );

    function snipeParams() external view returns (uint256 snipeFeeBps, uint256 snipeDecayBlocks, uint256 maxBuyBps);
}
