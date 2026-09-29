// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CreateParams, CurveDeployParams, LaunchPreset, StockListing} from "../types/LaunchpadTypes.sol";

/// @title ITokenFactory
/// @notice Entry point for launches, built for humans and bots alike (Clanker-style programmatic and social
///         deploys). One call deploys a fixed-supply LaunchToken plus its own BondingCurveManager instance and,
///         optionally, executes the creator's dev buy in the same transaction.
///
///         Concurrency: the factory is read-mostly. Creation writes one mapping entry (curveOf) and nothing
///         global: no arrays, no counters. Launch history is served by events to the indexer.
///
///         Trust model: the owner can edit presets, the treasury and pause *creation*. It cannot pause trading,
///         change parameters of a live curve, mint tokens or move user funds.
interface ITokenFactory {
    // ------------------------------------------------------------------ events

    event TokenCreated(
        address indexed token,
        address indexed curve,
        address indexed creator,
        address deployer,
        uint32 presetId,
        string name,
        string symbol,
        string metadataURI,
        bytes context
    );

    event PresetUpdated(uint32 indexed presetId, LaunchPreset preset);
    event ProtocolTreasuryUpdated(address indexed treasury);
    event CreationPausedUpdated(bool paused);

    /// @notice A stock was (re)listed for stock-reserve launches. Carries the pool state it was validated against.
    event StockListed(
        address indexed stock,
        bytes32 symbol,
        address poolManager,
        bytes32 poolId,
        uint24 poolFee,
        int24 tickSpacing,
        uint16 maxSlippageBps,
        uint8 decimals,
        uint160 sqrtPriceX96,
        uint128 liquidity
    );
    event StockDelisted(address indexed stock);
    event StockKeeperUpdated(address indexed keeper);
    /// @notice Emitted right after TokenCreated for a stock-reserve launch.
    event StockReserveCreated(
        address indexed token, address indexed stock, address stockReserve, uint16 stockFeeBps, bytes32 poolId
    );

    // ------------------------------------------------------------------ errors

    error CreationPaused();
    error PresetDisabled(uint32 presetId);
    error InvalidName();
    error InvalidSymbol();
    error InvalidCreator();
    error InvalidTreasury();
    error SaltAlreadyUsed();
    error SignatureExpired();
    error InvalidSignature();
    error NotDeploying();
    error OwnershipRenounceDisabled();
    error StockNotListed(address stock);
    error InvalidStockListing();
    error StockPoolWithoutLiquidity(bytes32 poolId);
    error StockFeeExceedsProtocolShare(uint32 presetId);

    // ------------------------------------------------------------------ launch

    /// @notice Deploys token + curve with CREATE2 and runs the optional dev buy (`msg.value > 0`, tokens to
    ///         `params.creator`). `msg.sender` is recorded as deployer; the salt is bound to it, so nobody can
    ///         squat the predicted addresses.
    function createToken(CreateParams calldata params) external payable returns (address token, address curve);

    /// @notice Same as `createToken`, authorized by an EIP-712 signature of `params.creator`: ECDSA for EOAs
    ///         (including EIP-7702 delegated ones) or ERC-1271 for smart wallets. Lets a bot or relayer deploy and
    ///         pay gas on behalf of a creator who explicitly consented. The signed `deployer` is `msg.sender`, so
    ///         another relayer cannot reuse the signature, and replay is impossible: the same deployer and salt map
    ///         to the same CREATE2 addresses, which can only be deployed once. Digest: `hashCreateToken`.
    function createTokenWithSig(CreateParams calldata params, uint256 deadline, bytes calldata signature)
        external
        payable
        returns (address token, address curve);

    /// @notice `createToken` with an optional stock reserve (ARCHITECTURE.md §7.4): also deploys this launch's
    ///         StockReserve, and the curve pays it `STOCK_FEE_BPS` of every fee, taken from the protocol share.
    ///         `stockToken` must be listed; address(0) is exactly `createToken`. Token and curve addresses are the
    ///         same as with `createToken` for the same (deployer, salt).
    function createStockToken(CreateParams calldata params, address stockToken)
        external
        payable
        returns (address token, address curve);

    /// @notice Signed variant of `createStockToken`: the creator also signs the stock choice
    ///         (`hashCreateStockToken`). Same signer rules as `createTokenWithSig`.
    function createStockTokenWithSig(
        CreateParams calldata params,
        address stockToken,
        uint256 deadline,
        bytes calldata signature
    ) external payable returns (address token, address curve);

    /// @notice EIP-712 digest for `createStockTokenWithSig`: CreateStockToken(string name,string symbol,
    ///         string metadataURI,address creator,address deployer,uint32 presetId,bytes32 salt,bytes context,
    ///         address stockToken,uint256 deadline).
    function hashCreateStockToken(CreateParams calldata params, address stockToken, address deployer, uint256 deadline)
        external
        view
        returns (bytes32);

    /// @notice StockReserve address of a (deployer, salt, stock) launch under the stock's current listing.
    function predictStockReserve(address deployer, bytes32 salt, address stockToken) external view returns (address);

    /// @notice Addresses a (deployer, salt) pair will produce. Lets bots announce a launch before it lands.
    function predictAddresses(address deployer, bytes32 salt) external view returns (address token, address curve);

    /// @notice EIP-712 digest the creator signs for `createTokenWithSig`:
    ///         CreateToken(string name,string symbol,string metadataURI,address creator,address deployer,
    ///         uint32 presetId,bytes32 salt,bytes context,uint256 deadline).
    ///         `minDevBuyOut` is not signed: the dev buy is funded (and bounded) by the deployer.
    function hashCreateToken(CreateParams calldata params, address deployer, uint256 deadline)
        external
        view
        returns (bytes32);

    // ------------------------------------------------------------------ registry and config (reads)

    /// @notice Curve of `token`, or address(0) if the token was not launched by this factory.
    function curveOf(address token) external view returns (address curve);

    function preset(uint32 presetId) external view returns (LaunchPreset memory);

    function protocolTreasury() external view returns (address);

    function creationPaused() external view returns (bool);

    function tokenInitCodeHash() external view returns (bytes32);

    function curveInitCodeHash() external view returns (bytes32);

    function stockListing(address stock) external view returns (StockListing memory);

    /// @notice The only account allowed to run `StockReserve.claimAndBuyStock` (address(0): purchases disabled).
    function stockKeeper() external view returns (address);

    /// @notice Implementation behind every StockReserve clone (deployed by this factory's constructor).
    function stockReserveImplementation() external view returns (address);

    // ------------------------------------------------------------------ constructor callbacks

    /// @notice Read by the LaunchToken constructor. Values live in transient storage during `createToken`,
    ///         which keeps the init code constant (predictable CREATE2 addresses, no circular dependency).
    ///         Only the token being deployed can read them; anyone else gets NotDeploying.
    function tokenDeployParams()
        external
        view
        returns (bytes32 packedName, bytes32 packedSymbol, address curve, uint256 totalSupply);

    /// @notice Read by the BondingCurveManager constructor. Same mechanism; only the curve being deployed.
    function curveDeployParams() external view returns (CurveDeployParams memory);

    // ------------------------------------------------------------------ admin (Ownable2Step, future launches only)

    /// @notice Registers or replaces a preset. Validated with `LaunchPresetLib`; the migrator must be a contract.
    function setPreset(uint32 presetId, LaunchPreset calldata preset) external;

    function setProtocolTreasury(address treasury) external;

    function setCreationPaused(bool paused) external;

    /// @notice Lists `stock` for future stock-reserve launches. The (native MON, stock) pool of `poolManager` with
    ///         this fee and spacing, and no hooks, must be initialized and hold liquidity. Re-listing overwrites.
    function listStock(
        address stock,
        bytes32 symbol,
        address poolManager,
        uint24 poolFee,
        int24 tickSpacing,
        uint16 maxSlippageBps
    ) external;

    /// @notice Future launches can no longer pick `stock`. Existing reserves keep their configuration.
    function delistStock(address stock) external;

    function setStockKeeper(address keeper) external;
}
