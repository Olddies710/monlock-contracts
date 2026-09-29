// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Lifecycle of a bonding curve. Transitions are one-way: Trading -> Completed -> Graduated.
enum CurveStatus {
    /// @dev Open for buys and sells.
    Trading,
    /// @dev Sold out (realTokenReserve == 0). Trading halted; migration pending and retryable by anyone.
    Completed,
    /// @dev Liquidity migrated to the DEX and locked forever. The curve is inert except for fee claims.
    Graduated
}

/// @notice Split of one fee stream between its recipients, in basis points. Must sum to 10_000.
struct FeeSplit {
    uint16 creatorBps;
    uint16 protocolBps;
    uint16 interfaceBps;
}

/// @notice Launch preset whitelisted by the protocol (curve shape + fees + anti-snipe policy).
/// @dev Every field is copied into the immutables of a curve at creation. Editing a preset only affects
///      future launches: live curves can never be re-parameterized (credible neutrality).
///      Parameter derivation (vT0, vM0 from C, L, target raise): ARCHITECTURE.md §4.5.
struct LaunchPreset {
    // --- Curve shape. Token amounts in wei (18 decimals). Total supply S = curveSupply + lpSupply.
    uint128 virtualTokenReserve0; // vT0
    uint128 virtualMonReserve0; // vM0
    uint128 curveSupply; // C: tokens sold through the curve
    uint128 lpSupply; // L: tokens reserved for DEX liquidity at graduation
    // --- Fees.
    uint16 tradeFeeBps; // base fee on MON notional, charged on buys and sells
    uint16 graduationFeeBps; // share of the raised MON kept as fee at graduation
    FeeSplit curveFeeSplit; // split of curve trade fees and of the graduation fee
    FeeSplit lpFeeSplit; // split of DEX LP fees after graduation
    // --- Anti-snipe (ARCHITECTURE.md §5).
    uint16 snipeFeeBps; // total fee at the launch block; decays quadratically to tradeFeeBps
    uint32 snipeDecayBlocks; // length of the decay window, in blocks (300 ms each on Monad)
    uint16 maxBuyBps; // per-tx buy cap during the decay window, in bps of curveSupply
    uint16 maxDevBuyBps; // cap of the creator's atomic initial buy, in bps of curveSupply
    // --- Migration.
    address migrator; // ILiquidityMigrator used at graduation
    bool enabled;
}

/// @notice Arguments of `TokenFactory.createToken`.
struct CreateParams {
    string name; // <= 31 bytes: packed into an immutable, no storage
    string symbol; // <= 31 bytes: packed into an immutable, no storage
    string metadataURI; // image, description, socials (e.g. ipfs://...). Emitted, never stored
    address creator; // fee admin of the launch; receives the dev-buy tokens
    address interfaceRecipient; // bot/frontend that earns the interface fee share; address(0) routes it to the protocol
    uint32 presetId;
    bytes32 salt; // effective CREATE2 salt = keccak256(abi.encode(deployer, salt)): no address squatting
    uint256 minDevBuyOut; // slippage bound of the optional dev buy funded with msg.value
    bytes context; // social provenance (cast hash, tweet id, ...). Emitted, never stored
}

/// @notice Values a curve reads from the factory inside its constructor (constant init code, see §2.4).
struct CurveDeployParams {
    address token;
    address creator;
    address interfaceRecipient;
    LaunchPreset preset;
}

/// @notice Snapshot of a curve for quoting and off-chain consumers.
struct CurveState {
    CurveStatus status;
    uint256 virtualMonReserve; // vM = vM0 + realMonReserve
    uint256 virtualTokenReserve; // vT = vT0 - C + realTokenReserve
    uint256 realMonReserve; // MON backing the curve (excludes unclaimed fees)
    uint256 realTokenReserve; // tokens still for sale on the curve
    uint256 totalFeesAccrued; // monotonic accumulator of fees, in MON
    uint256 currentFeeBps; // base + anti-snipe component at the current block
}
