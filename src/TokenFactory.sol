// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {LibString} from "solady/utils/LibString.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";

import {BondingCurveManager} from "./BondingCurveManager.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {StockReserve} from "./StockReserve.sol";
import {IBondingCurveManager} from "./interfaces/IBondingCurveManager.sol";
import {ITokenFactory} from "./interfaces/ITokenFactory.sol";
import {CloneWithArgs} from "./libraries/CloneWithArgs.sol";
import {LaunchPresetLib} from "./libraries/LaunchPresetLib.sol";
import {
    CreateParams,
    CurveDeployParams,
    LaunchPreset,
    StockListing,
    StockReserveConfig
} from "./types/LaunchpadTypes.sol";

/// @title TokenFactory
/// @notice Launch entry point. Deploys a LaunchToken and its dedicated BondingCurveManager with CREATE2 from
///         constant init code, handing their parameters over through transient storage (ARCHITECTURE.md §2.4).
/// @dev Monad: creation reads the config slot and one preset entry, and writes a single fresh mapping entry
///      (`curveOf[token]`). No global counter or array exists, so creations only share the factory's account nonce
///      (CREATE2 increments it) and never touch the storage that trades use.
///      The factory never holds MON: `msg.value` is forwarded in full to the dev buy, and it has no `receive`.
///      Stock-reserve launches (§7.4) also deploy a StockReserve clone for the launch; nothing global is added to
///      their trade path either. Storage slots 5-6 (stock allowlist, keeper) are appended after the Phase 2 layout.
contract TokenFactory is ITokenFactory, Ownable2Step, EIP712 {
    using PoolIdLibrary for PoolKey;

    bytes32 public constant CREATE_TOKEN_TYPEHASH = keccak256(
        "CreateToken(string name,string symbol,string metadataURI,address creator,address deployer,uint32 presetId,bytes32 salt,bytes context,uint256 deadline)"
    );

    bytes32 public constant CREATE_STOCK_TOKEN_TYPEHASH = keccak256(
        "CreateStockToken(string name,string symbol,string metadataURI,address creator,address deployer,uint32 presetId,bytes32 salt,bytes context,address stockToken,uint256 deadline)"
    );

    /// @notice Share of each curve fee paid to the StockReserve of a stock-reserve launch, taken from the protocol
    ///         share: 30 % creator / 55 % protocol / 10 % referrer / 5 % stock with the approved preset (§7.4).
    uint16 public constant STOCK_FEE_BPS = 500;
    /// @notice Upper bound of a listing's per-purchase price-impact cap.
    uint16 public constant MAX_STOCK_SLIPPAGE_BPS = 1000;

    // Transient slots (EIP-1153): only non-zero inside `_create`, cleared before it returns.
    uint256 private constant _T_TOKEN = uint256(keccak256("launchpad.factory.deploy.token")) - 1;
    uint256 private constant _T_CURVE = uint256(keccak256("launchpad.factory.deploy.curve")) - 1;
    uint256 private constant _T_NAME = uint256(keccak256("launchpad.factory.deploy.name")) - 1;
    uint256 private constant _T_SYMBOL = uint256(keccak256("launchpad.factory.deploy.symbol")) - 1;
    uint256 private constant _T_SUPPLY = uint256(keccak256("launchpad.factory.deploy.supply")) - 1;
    uint256 private constant _T_CREATOR = uint256(keccak256("launchpad.factory.deploy.creator")) - 1;
    uint256 private constant _T_PRESET = uint256(keccak256("launchpad.factory.deploy.preset")) - 1;
    uint256 private constant _T_STOCK_RESERVE = uint256(keccak256("launchpad.factory.deploy.stockReserve")) - 1;

    /// @inheritdoc ITokenFactory
    bytes32 public immutable tokenInitCodeHash;
    /// @inheritdoc ITokenFactory
    bytes32 public immutable curveInitCodeHash;
    /// @inheritdoc ITokenFactory
    address public immutable stockReserveImplementation;

    /// @inheritdoc ITokenFactory
    address public protocolTreasury;
    /// @inheritdoc ITokenFactory
    bool public creationPaused;
    /// @inheritdoc ITokenFactory
    mapping(address token => address curve) public curveOf;
    mapping(uint32 presetId => LaunchPreset) private _presets;
    mapping(address stock => StockListing) private _stockListings; // slot 5
    /// @inheritdoc ITokenFactory
    address public stockKeeper; // slot 6

    constructor(address initialOwner, address treasury) Ownable(initialOwner) {
        if (treasury == address(0)) revert InvalidTreasury();
        tokenInitCodeHash = keccak256(type(LaunchToken).creationCode);
        curveInitCodeHash = keccak256(type(BondingCurveManager).creationCode);
        stockReserveImplementation = address(new StockReserve());
        protocolTreasury = treasury;
        emit ProtocolTreasuryUpdated(treasury);
    }

    // ------------------------------------------------------------------ launch

    /// @inheritdoc ITokenFactory
    function createToken(CreateParams calldata params) external payable returns (address token, address curve) {
        return _create(params, msg.sender, address(0));
    }

    /// @inheritdoc ITokenFactory
    function createTokenWithSig(CreateParams calldata params, uint256 deadline, bytes calldata signature)
        external
        payable
        returns (address token, address curve)
    {
        _checkCreatorSignature(params.creator, deadline, hashCreateToken(params, msg.sender, deadline), signature);
        return _create(params, msg.sender, address(0));
    }

    /// @inheritdoc ITokenFactory
    function createStockToken(CreateParams calldata params, address stockToken)
        external
        payable
        returns (address token, address curve)
    {
        return _create(params, msg.sender, stockToken);
    }

    /// @inheritdoc ITokenFactory
    function createStockTokenWithSig(
        CreateParams calldata params,
        address stockToken,
        uint256 deadline,
        bytes calldata signature
    ) external payable returns (address token, address curve) {
        _checkCreatorSignature(
            params.creator, deadline, hashCreateStockToken(params, stockToken, msg.sender, deadline), signature
        );
        return _create(params, msg.sender, stockToken);
    }

    /// @inheritdoc ITokenFactory
    function predictAddresses(address deployer, bytes32 salt) public view returns (address token, address curve) {
        return _predict(_deploySalt(deployer, salt));
    }

    /// @inheritdoc ITokenFactory
    function hashCreateToken(CreateParams calldata params, address deployer, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    CREATE_TOKEN_TYPEHASH,
                    keccak256(bytes(params.name)),
                    keccak256(bytes(params.symbol)),
                    keccak256(bytes(params.metadataURI)),
                    params.creator,
                    deployer,
                    params.presetId,
                    params.salt,
                    keccak256(params.context),
                    deadline
                )
            )
        );
    }

    /// @inheritdoc ITokenFactory
    function hashCreateStockToken(CreateParams calldata params, address stockToken, address deployer, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    CREATE_STOCK_TOKEN_TYPEHASH,
                    keccak256(bytes(params.name)),
                    keccak256(bytes(params.symbol)),
                    keccak256(bytes(params.metadataURI)),
                    params.creator,
                    deployer,
                    params.presetId,
                    params.salt,
                    keccak256(params.context),
                    stockToken,
                    deadline
                )
            )
        );
    }

    /// @inheritdoc ITokenFactory
    function predictStockReserve(address deployer, bytes32 salt, address stockToken) external view returns (address) {
        bytes32 deploySalt = _deploySalt(deployer, salt);
        (address token, address curve) = _predict(deploySalt);
        return CloneWithArgs.predictDeterministicAddress(
            stockReserveImplementation,
            _stockReserveArgs(_stockListings[stockToken], stockToken, token, curve),
            deploySalt,
            address(this)
        );
    }

    // ------------------------------------------------------------------ registry and config

    /// @inheritdoc ITokenFactory
    function preset(uint32 presetId) external view returns (LaunchPreset memory) {
        return _presets[presetId];
    }

    /// @inheritdoc ITokenFactory
    function stockListing(address stock) external view returns (StockListing memory) {
        return _stockListings[stock];
    }

    // ------------------------------------------------------------------ constructor callbacks

    /// @inheritdoc ITokenFactory
    function tokenDeployParams()
        external
        view
        returns (bytes32 packedName, bytes32 packedSymbol, address curve, uint256 totalSupply)
    {
        if (msg.sender != _tloadAddress(_T_TOKEN)) revert NotDeploying();
        return (_tloadBytes32(_T_NAME), _tloadBytes32(_T_SYMBOL), _tloadAddress(_T_CURVE), _tload(_T_SUPPLY));
    }

    /// @inheritdoc ITokenFactory
    function curveDeployParams() external view returns (CurveDeployParams memory p) {
        if (msg.sender != _tloadAddress(_T_CURVE)) revert NotDeploying();
        p.token = _tloadAddress(_T_TOKEN);
        p.creator = _tloadAddress(_T_CREATOR);
        p.preset = _presets[_tloadUint32(_T_PRESET)];
        p.stockReserve = _tloadAddress(_T_STOCK_RESERVE);
        if (p.stockReserve != address(0)) p.stockFeeBps = STOCK_FEE_BPS;
    }

    // ------------------------------------------------------------------ admin

    /// @inheritdoc ITokenFactory
    function setPreset(uint32 presetId, LaunchPreset calldata newPreset) external onlyOwner {
        LaunchPresetLib.validate(newPreset);
        if (newPreset.migrator.code.length == 0) revert LaunchPresetLib.InvalidMigrator();
        _presets[presetId] = newPreset;
        emit PresetUpdated(presetId, newPreset);
    }

    /// @inheritdoc ITokenFactory
    function setProtocolTreasury(address treasury) external onlyOwner {
        if (treasury == address(0)) revert InvalidTreasury();
        protocolTreasury = treasury;
        emit ProtocolTreasuryUpdated(treasury);
    }

    /// @inheritdoc ITokenFactory
    function setCreationPaused(bool paused) external onlyOwner {
        creationPaused = paused;
        emit CreationPausedUpdated(paused);
    }

    /// @inheritdoc ITokenFactory
    function listStock(
        address stock,
        bytes32 symbol,
        address poolManager,
        uint24 poolFee,
        int24 tickSpacing,
        uint16 maxSlippageBps
    ) external onlyOwner {
        if (
            stock == address(0) || stock.code.length == 0 || symbol == bytes32(0) || poolManager.code.length == 0
                || maxSlippageBps == 0 || maxSlippageBps > MAX_STOCK_SLIPPAGE_BPS
        ) revert InvalidStockListing();
        uint8 decimals = _decimals(stock);

        // Only a pool that exists and holds liquidity right now: no listing of an empty or future pool.
        PoolKey memory key = _stockPoolKey(stock, poolFee, tickSpacing);
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(IPoolManager(poolManager), poolId);
        uint128 liquidity = StateLibrary.getLiquidity(IPoolManager(poolManager), poolId);
        if (sqrtPriceX96 == 0 || liquidity == 0) revert StockPoolWithoutLiquidity(PoolId.unwrap(poolId));

        _stockListings[stock] = StockListing({
            symbol: symbol,
            poolManager: poolManager,
            poolFee: poolFee,
            tickSpacing: tickSpacing,
            maxSlippageBps: maxSlippageBps,
            decimals: decimals,
            listed: true
        });
        emit StockListed(
            stock,
            symbol,
            poolManager,
            PoolId.unwrap(poolId),
            poolFee,
            tickSpacing,
            maxSlippageBps,
            decimals,
            sqrtPriceX96,
            liquidity
        );
    }

    /// @inheritdoc ITokenFactory
    function delistStock(address stock) external onlyOwner {
        if (!_stockListings[stock].listed) revert StockNotListed(stock);
        _stockListings[stock].listed = false;
        emit StockDelisted(stock);
    }

    /// @inheritdoc ITokenFactory
    /// @dev address(0) is allowed on purpose: it pauses every stock purchase (MON keeps accruing in the reserves).
    // forge-lint: disable-next-line(missing-zero-check)
    function setStockKeeper(address keeper) external onlyOwner {
        stockKeeper = keeper;
        emit StockKeeperUpdated(keeper);
    }

    /// @notice Disabled: without an owner, presets and the treasury could never be fixed again. Hand the role to
    ///         a Safe (two-step transfer) instead.
    function renounceOwnership() public pure override {
        revert OwnershipRenounceDisabled();
    }

    // ------------------------------------------------------------------ internals

    function _create(CreateParams calldata params, address deployer, address stock)
        private
        returns (address token, address curve)
    {
        address reserve;
        (token, curve, reserve) = _deploy(params, deployer, stock);
        curveOf[token] = curve;
        _emitTokenCreated(params, token, curve, deployer);
        if (reserve != address(0)) {
            StockListing storage listing = _stockListings[stock];
            emit StockReserveCreated(
                token,
                stock,
                reserve,
                STOCK_FEE_BPS,
                PoolId.unwrap(_stockPoolKey(stock, listing.poolFee, listing.tickSpacing).toId())
            );
        }

        // Atomic with creation: nobody can trade before it, so it pays the base fee only (capped by the preset).
        // The destination is the curve deployed just above, not a user-supplied address.
        if (msg.value != 0) {
            // forge-lint: disable-next-line(arbitrary-send-eth, unused-return)
            IBondingCurveManager(curve).devBuy{value: msg.value}(params.minDevBuyOut, params.creator);
        }
    }

    /// @dev Validates, hands the parameters over in transient storage and deploys the contracts of the launch.
    function _deploy(CreateParams calldata params, address deployer, address stock)
        private
        returns (address token, address curve, address reserve)
    {
        if (creationPaused) revert CreationPaused();
        if (params.creator == address(0)) revert InvalidCreator();
        bytes32 packedName = LibString.packOne(params.name);
        if (packedName == bytes32(0)) revert InvalidName();
        bytes32 packedSymbol = LibString.packOne(params.symbol);
        if (packedSymbol == bytes32(0)) revert InvalidSymbol();
        LaunchPreset storage launchPreset = _presets[params.presetId];
        if (!launchPreset.enabled) revert PresetDisabled(params.presetId);

        bytes32 salt = _deploySalt(deployer, params.salt);
        (address predictedToken, address predictedCurve) = _predict(salt);
        if (curveOf[predictedToken] != address(0)) revert SaltAlreadyUsed();

        _tstore(_T_TOKEN, uint160(predictedToken));
        _tstore(_T_CURVE, uint160(predictedCurve));
        _tstore(_T_NAME, uint256(packedName));
        _tstore(_T_SYMBOL, uint256(packedSymbol));
        _tstore(_T_SUPPLY, uint256(launchPreset.curveSupply) + launchPreset.lpSupply);
        _tstore(_T_CREATOR, uint160(params.creator));
        _tstore(_T_PRESET, params.presetId);
        if (stock != address(0)) {
            if (launchPreset.curveFeeSplit.protocolBps < STOCK_FEE_BPS) {
                revert StockFeeExceedsProtocolShare(params.presetId);
            }
            reserve = _deployStockReserve(stock, salt, predictedToken, predictedCurve);
            _tstore(_T_STOCK_RESERVE, uint160(reserve));
        }

        // Each constructor authenticates itself by its predicted address when reading its parameters, so a wrong
        // prediction cannot deploy anything.
        token = address(new LaunchToken{salt: salt}());
        curve = address(new BondingCurveManager{salt: salt}());

        _tstore(_T_TOKEN, 0);
        _tstore(_T_CURVE, 0);
        _tstore(_T_NAME, 0);
        _tstore(_T_SYMBOL, 0);
        _tstore(_T_SUPPLY, 0);
        _tstore(_T_CREATOR, 0);
        _tstore(_T_PRESET, 0);
        if (reserve != address(0)) _tstore(_T_STOCK_RESERVE, 0);
    }

    /// @dev One clone per launch (CREATE2 with the launch salt): its own account, MON and stock balance. The listing
    ///      is copied into the clone's immutable arguments, so later listing changes never touch a live reserve.
    function _deployStockReserve(address stock, bytes32 salt, address token, address curve) private returns (address) {
        StockListing storage listing = _stockListings[stock];
        if (!listing.listed) revert StockNotListed(stock);
        return CloneWithArgs.deployDeterministic(
            stockReserveImplementation, _stockReserveArgs(listing, stock, token, curve), salt
        );
    }

    function _stockReserveArgs(StockListing storage listing, address stock, address token, address curve)
        private
        view
        returns (bytes memory)
    {
        return abi.encode(
            StockReserveConfig({
                factory: address(this),
                token: token,
                curve: curve,
                stock: stock,
                poolManager: listing.poolManager,
                poolFee: listing.poolFee,
                tickSpacing: listing.tickSpacing,
                maxSlippageBps: listing.maxSlippageBps
            })
        );
    }

    /// @dev The (native MON, stock) pool without hooks: MON is currency0 because address(0) sorts first.
    function _stockPoolKey(address stock, uint24 poolFee, int24 tickSpacing) private pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(stock),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
    }

    function _decimals(address stock) private view returns (uint8) {
        (bool ok, bytes memory data) = stock.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || data.length < 32) revert InvalidStockListing();
        uint256 value = abi.decode(data, (uint256));
        if (value > type(uint8).max) revert InvalidStockListing();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(value); // range checked above
    }

    /// @dev EIP-712 authorization by the creator. ECDSA first: covers plain EOAs and EIP-7702 delegated EOAs (which
    ///      have code). A contract without a key can never pass it, so falling back to ERC-1271 afterwards adds smart
    ///      wallets without false positives.
    function _checkCreatorSignature(address creator, uint256 deadline, bytes32 digest, bytes calldata signature)
        private
        view
    {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert SignatureExpired();
        if (creator == address(0)) revert InvalidCreator();
        if (
            ECDSA.tryRecoverCalldata(digest, signature) != creator
                && !SignatureCheckerLib.isValidERC1271SignatureNowCalldata(creator, digest, signature)
        ) revert InvalidSignature();
    }

    function _emitTokenCreated(CreateParams calldata params, address token, address curve, address deployer) private {
        emit TokenCreated(
            token,
            curve,
            params.creator,
            deployer,
            params.presetId,
            params.name,
            params.symbol,
            params.metadataURI,
            params.context
        );
    }

    function _deploySalt(address deployer, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(deployer, salt));
    }

    function _predict(bytes32 salt) private view returns (address token, address curve) {
        token = _create2Address(salt, tokenInitCodeHash);
        curve = _create2Address(salt, curveInitCodeHash);
    }

    function _create2Address(bytes32 salt, bytes32 initCodeHash) private view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Monad Launchpad TokenFactory", "1");
    }

    function _tstore(uint256 slot, uint256 value) private {
        /// @solidity memory-safe-assembly
        assembly {
            tstore(slot, value)
        }
    }

    function _tload(uint256 slot) private view returns (uint256 value) {
        /// @solidity memory-safe-assembly
        assembly {
            value := tload(slot)
        }
    }

    function _tloadAddress(uint256 slot) private view returns (address value) {
        /// @solidity memory-safe-assembly
        assembly {
            value := and(tload(slot), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    function _tloadBytes32(uint256 slot) private view returns (bytes32 value) {
        /// @solidity memory-safe-assembly
        assembly {
            value := tload(slot)
        }
    }

    function _tloadUint32(uint256 slot) private view returns (uint32 value) {
        /// @solidity memory-safe-assembly
        assembly {
            value := and(tload(slot), 0xffffffff)
        }
    }
}
