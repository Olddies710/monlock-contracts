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
    /// @param monAmount Buy: gross MON charged (after any refund). Sell: net MON paid out.
    /// @param fee Base fee accrued to the fee recipients.
    /// @param snipeTax Anti-snipe surcharge, donated to the curve reserve (never to the creator).
    event Trade(
        address indexed trader,
        address indexed recipient,
        address indexed referrer,
        bool isBuy,
        uint256 monAmount,
        uint256 tokenAmount,
        uint256 fee,
        uint256 snipeTax,
        uint256 realMonReserve,
        uint256 realTokenReserve
    );

    /// @notice The curve sold out: trading is frozen and graduation is enabled (atomically attempted in the same
    ///         transaction, retryable with `graduate()`). `realMonReserve >= R` by construction.
    event CurveCompleted(uint256 realMonReserve);

    /// @notice Liquidity was migrated to the DEX and locked. `tokensBurned` is the unused LP reserve.
    event Graduated(uint256 monToLiquidity, uint256 tokensToLiquidity, uint256 tokensBurned, uint256 graduationFee);

    /// @notice The atomic migration attempt reverted. The curve stays Completed and `graduate()` can retry.
    event MigrationFailed(bytes reason);

    event FeesClaimed(uint256 toCreator, uint256 toProtocol);
    event ReferrerFeesClaimed(address indexed referrer, uint256 amount);
    event CreatorFeeRecipientUpdated(address indexed recipient);

    // ------------------------------------------------------------------ errors

    error DeadlineExpired();
    error ZeroAmount();
    error InvalidRecipient();
    error InvalidReferrer();
    error NotTrading();
    error NotCompleted();
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error MaxBuyExceeded(uint256 amountOut, uint256 maxAmountOut);
    error OnlyFactory();
    error OnlyCreator();
    error OnlySelf();
    error DevBuyUnavailable();
    error InvalidDeployParams();

    // ------------------------------------------------------------------ trading

    /// @notice Buys tokens for `msg.sender` with exactly `msg.value` MON. If the buy exceeds the remaining supply
    ///         it is clipped, the excess MON is refunded and the curve completes (graduation is attempted in the
    ///         same transaction). `referrer` (or address(0)) earns the referrer share of the base fee.
    function buy(uint256 minTokensOut, address referrer) external payable returns (uint256 tokensOut);

    /// @notice `buy` with an explicit token recipient and a deadline (routers, bots, MEV-sensitive flows).
    ///         A clipped buy refunds the excess to `msg.sender`.
    function buyTo(address recipient, uint256 minTokensOut, address referrer, uint256 deadline)
        external
        payable
        returns (uint256 tokensOut);

    /// @notice Sells `tokenAmount` from `msg.sender` and pays the MON to `msg.sender`. No approve needed: the
    ///         token grants its curve an implicit allowance. The referrer share goes to the protocol.
    function sell(uint256 tokenAmount, uint256 minMonOut) external returns (uint256 monOut);

    /// @notice `sell` with an explicit MON recipient, a referrer and a deadline.
    function sellTo(address recipient, uint256 tokenAmount, uint256 minMonOut, address referrer, uint256 deadline)
        external
        returns (uint256 monOut);

    /// @notice Creator's initial buy, executed by the factory inside the creation transaction. Nobody can
    ///         front-run it, so it pays the base fee only. Capped at `maxDevBuyBps` of the total supply.
    function devBuy(uint256 minTokensOut, address recipient) external payable returns (uint256 tokensOut);

    // ------------------------------------------------------------------ quotes (same code path as the trades)

    /// @notice Result of `buy` with `monIn` at the current block. Does not apply the per-tx anti-snipe cap.
    /// @dev `refund` is the MON returned when the buy is clipped at the end of the curve (0 otherwise).
    function quoteBuy(uint256 monIn)
        external
        view
        returns (uint256 tokensOut, uint256 fee, uint256 snipeTax, uint256 refund);

    /// @notice Result of `sell` with `tokenAmount` at the current block.
    function quoteSell(uint256 tokenAmount) external view returns (uint256 monOut, uint256 fee, uint256 snipeTax);

    /// @notice Total fee at the current block: base fee plus the decaying anti-snipe component.
    function currentFeeBps() external view returns (uint256);

    /// @notice Largest buy (in tokens) allowed in one transaction at the current block.
    function maxBuyAmount() external view returns (uint256);

    function state() external view returns (CurveState memory);

    // ------------------------------------------------------------------ graduation

    /// @notice Permissionless retry of the migration when the curve is Completed but not Graduated.
    function graduate() external;

    // ------------------------------------------------------------------ fees (pull accounting, push payout)

    /// @notice MON owed to the creator and to the protocol. The protocol is the residual claimant.
    function claimableFees() external view returns (uint256 toCreator, uint256 toProtocol);

    /// @notice MON owed to `referrer` on this curve.
    function referrerFees(address referrer) external view returns (uint256);

    /// @notice Pays the creator and the protocol what they are owed. Callable by anyone; a reverting recipient
    ///         cannot block the other (forced transfer).
    function claimFees() external;

    /// @notice Pays `referrer` what it is owed on this curve. Callable by anyone (funds only go to `referrer`).
    function claimReferrerFees(address referrer) external returns (uint256 amount);

    /// @notice Creator-only: where creator fees go, for the curve phase and for post-graduation LP fees.
    function setCreatorFeeRecipient(address recipient) external;

    // ------------------------------------------------------------------ configuration (immutable per launch)

    function token() external view returns (address);

    function factory() external view returns (address);

    function migrator() external view returns (address);

    function creator() external view returns (address);

    function creatorFeeRecipient() external view returns (address);

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

    function snipeParams()
        external
        view
        returns (uint256 snipeFeeBps, uint256 snipeDecayBlocks, uint256 maxBuyBps, uint256 maxDevBuyBps);
}
