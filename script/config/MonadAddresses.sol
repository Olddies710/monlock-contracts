// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice One Monad network as seen by scripts and fork tests.
struct MonadNetwork {
    string name;
    uint256 chainId;
    address poolManager; // Uniswap v4 PoolManager
    uint256 forkBlock; // pinned block for deterministic, cacheable fork tests
    string rpcEnv; // environment variable holding the RPC URL
}

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
    /// @dev Arachnid deterministic deployer (Forge's default CREATE2 factory), present on mainnet and testnet.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev Pinned block for deterministic, cacheable fork tests (public RPCs serve historical state).
    uint256 internal constant FORK_BLOCK = 109_000_000;
}

/// @notice Monad testnet (chain id 10143). Uniswap v4 here is Monad-maintained infrastructure (not in Uniswap's
///         official list): monad-crypto/protocols `testnet/uniswap_v4.jsonc` (PR #479, merged 2026-09-14),
///         verified on-chain (PositionManager.poolManager() points at this PoolManager). Its bytecode differs from
///         mainnet's, which is why the whole v4 fork suite also runs against this network.
library MonadTestnet {
    uint256 internal constant CHAIN_ID = 10_143;
    address internal constant POOL_MANAGER = 0x451D64ab3b650040d2aE1886602b97ed6eDc643d;
    address internal constant POSITION_MANAGER = 0x3Bb14E3D0Cd50aBe3EdACa06d06c29C78676C31A;
    address internal constant STATE_VIEW = 0xB639209539c61BaF67AC04876315786F8D0b153c;
    address internal constant UNIVERSAL_ROUTER = 0x1b7bFCd2870329B987191910D85c22C7287f3c22;
    uint256 internal constant FORK_BLOCK = 66_700_000;
}

library MonadNetworks {
    function mainnet() internal pure returns (MonadNetwork memory) {
        return MonadNetwork({
            name: "monad-mainnet",
            chainId: MonadMainnet.CHAIN_ID,
            poolManager: MonadMainnet.POOL_MANAGER,
            forkBlock: MonadMainnet.FORK_BLOCK,
            rpcEnv: "MONAD_RPC_URL"
        });
    }

    function testnet() internal pure returns (MonadNetwork memory) {
        return MonadNetwork({
            name: "monad-testnet",
            chainId: MonadTestnet.CHAIN_ID,
            poolManager: MonadTestnet.POOL_MANAGER,
            forkBlock: MonadTestnet.FORK_BLOCK,
            rpcEnv: "MONAD_TESTNET_RPC_URL"
        });
    }

    /// @return network The known network for `chainId`.
    /// @return known False for any other chain (local Anvil, forks with custom ids...).
    function byChainId(uint256 chainId) internal pure returns (MonadNetwork memory network, bool known) {
        if (chainId == MonadMainnet.CHAIN_ID) return (mainnet(), true);
        if (chainId == MonadTestnet.CHAIN_ID) return (testnet(), true);
    }
}

/// @notice Default parameters of the graduated Uniswap v4 pools **[open decision, ARCHITECTURE.md §11]**.
library MigratorDefaults {
    /// @dev Static LP fee in hundredths of a bip: 10_000 = 1%.
    uint24 internal constant LP_FEE = 10_000;
    /// @dev Conventional spacing for 1% pools; full-range positions only need it to be a valid spacing.
    int24 internal constant TICK_SPACING = 200;
}
