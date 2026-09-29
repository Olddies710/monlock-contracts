// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice External dependencies on Monad mainnet (chain id 143), verified on-chain (ARCHITECTURE.md §1).
///         Contracts receive them as constructor parameters; nothing is hardcoded in `src/`.
library MonadMainnet {
    uint256 internal constant CHAIN_ID = 143;

    /// @dev Uniswap v4 (developers.uniswap.org/docs/protocols/v4/deployments).
    address internal constant POOL_MANAGER = 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e;
    address internal constant POSITION_MANAGER = 0x5b7eC4a94fF9beDb700fb82aB09d5846972F4016;

    /// @dev Canonical contracts (docs.monad.xyz/developer-essentials/network-information).
    address internal constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @dev Arachnid deterministic deployer (Forge's default CREATE2 factory), present on Monad.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev Pinned block for deterministic, cacheable fork tests (public RPCs serve historical state).
    uint256 internal constant FORK_BLOCK = 109_000_000;
}

/// @notice Default parameters of the graduated Uniswap v4 pools **[open decision, ARCHITECTURE.md §11]**.
library MigratorDefaults {
    /// @dev Static LP fee in hundredths of a bip: 10_000 = 1%.
    uint24 internal constant LP_FEE = 10_000;
    /// @dev Conventional spacing for 1% pools; full-range positions only need it to be a valid spacing.
    int24 internal constant TICK_SPACING = 200;
}
