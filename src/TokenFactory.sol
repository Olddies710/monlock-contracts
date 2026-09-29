// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {LibString} from "solady/utils/LibString.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";

import {BondingCurveManager} from "./BondingCurveManager.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {IBondingCurveManager} from "./interfaces/IBondingCurveManager.sol";
import {ITokenFactory} from "./interfaces/ITokenFactory.sol";
import {LaunchPresetLib} from "./libraries/LaunchPresetLib.sol";
import {CreateParams, CurveDeployParams, LaunchPreset} from "./types/LaunchpadTypes.sol";

/// @title TokenFactory
/// @notice Launch entry point. Deploys a LaunchToken and its dedicated BondingCurveManager with CREATE2 from
///         constant init code, handing their parameters over through transient storage (ARCHITECTURE.md §2.4).
/// @dev Monad: creation reads the config slot and one preset entry, and writes a single fresh mapping entry
///      (`curveOf[token]`). No global counter or array exists, so creations only share the factory's account nonce
///      (CREATE2 increments it) and never touch the storage that trades use.
///      The factory never holds MON: `msg.value` is forwarded in full to the dev buy, and it has no `receive`.
contract TokenFactory is ITokenFactory, Ownable2Step, EIP712 {
    bytes32 public constant CREATE_TOKEN_TYPEHASH = keccak256(
        "CreateToken(string name,string symbol,string metadataURI,address creator,address deployer,uint32 presetId,bytes32 salt,bytes context,uint256 deadline)"
    );

    // Transient slots (EIP-1153): only non-zero inside `_create`, cleared before it returns.
    uint256 private constant _T_TOKEN = uint256(keccak256("launchpad.factory.deploy.token")) - 1;
    uint256 private constant _T_CURVE = uint256(keccak256("launchpad.factory.deploy.curve")) - 1;
    uint256 private constant _T_NAME = uint256(keccak256("launchpad.factory.deploy.name")) - 1;
    uint256 private constant _T_SYMBOL = uint256(keccak256("launchpad.factory.deploy.symbol")) - 1;
    uint256 private constant _T_SUPPLY = uint256(keccak256("launchpad.factory.deploy.supply")) - 1;
    uint256 private constant _T_CREATOR = uint256(keccak256("launchpad.factory.deploy.creator")) - 1;
    uint256 private constant _T_PRESET = uint256(keccak256("launchpad.factory.deploy.preset")) - 1;

    /// @inheritdoc ITokenFactory
    bytes32 public immutable tokenInitCodeHash;
    /// @inheritdoc ITokenFactory
    bytes32 public immutable curveInitCodeHash;

    /// @inheritdoc ITokenFactory
    address public protocolTreasury;
    /// @inheritdoc ITokenFactory
    bool public creationPaused;
    /// @inheritdoc ITokenFactory
    mapping(address token => address curve) public curveOf;
    mapping(uint32 presetId => LaunchPreset) private _presets;

    constructor(address initialOwner, address treasury) Ownable(initialOwner) {
        if (treasury == address(0)) revert InvalidTreasury();
        tokenInitCodeHash = keccak256(type(LaunchToken).creationCode);
        curveInitCodeHash = keccak256(type(BondingCurveManager).creationCode);
        protocolTreasury = treasury;
        emit ProtocolTreasuryUpdated(treasury);
    }

    // ------------------------------------------------------------------ launch

    /// @inheritdoc ITokenFactory
    function createToken(CreateParams calldata params) external payable returns (address token, address curve) {
        return _create(params, msg.sender);
    }

    /// @inheritdoc ITokenFactory
    function createTokenWithSig(CreateParams calldata params, uint256 deadline, bytes calldata signature)
        external
        payable
        returns (address token, address curve)
    {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert SignatureExpired();
        address creator = params.creator;
        if (creator == address(0)) revert InvalidCreator();
        bytes32 digest = hashCreateToken(params, msg.sender, deadline);
        // ECDSA first: covers plain EOAs and EIP-7702 delegated EOAs (which have code). A contract without a key
        // can never pass it, so falling back to ERC-1271 afterwards adds smart wallets without false positives.
        if (
            ECDSA.tryRecoverCalldata(digest, signature) != creator
                && !SignatureCheckerLib.isValidERC1271SignatureNowCalldata(creator, digest, signature)
        ) revert InvalidSignature();
        return _create(params, msg.sender);
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

    // ------------------------------------------------------------------ registry and config

    /// @inheritdoc ITokenFactory
    function preset(uint32 presetId) external view returns (LaunchPreset memory) {
        return _presets[presetId];
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

    /// @notice Disabled: without an owner, presets and the treasury could never be fixed again. Hand the role to
    ///         a Safe (two-step transfer) instead.
    function renounceOwnership() public pure override {
        revert OwnershipRenounceDisabled();
    }

    // ------------------------------------------------------------------ internals

    function _create(CreateParams calldata params, address deployer) private returns (address token, address curve) {
        (token, curve) = _deploy(params, deployer);
        curveOf[token] = curve;
        _emitTokenCreated(params, token, curve, deployer);

        // Atomic with creation: nobody can trade before it, so it pays the base fee only (capped by the preset).
        // The destination is the curve deployed just above, not a user-supplied address.
        if (msg.value != 0) {
            // forge-lint: disable-next-line(arbitrary-send-eth, unused-return)
            IBondingCurveManager(curve).devBuy{value: msg.value}(params.minDevBuyOut, params.creator);
        }
    }

    /// @dev Validates, hands the parameters over in transient storage and deploys both contracts.
    function _deploy(CreateParams calldata params, address deployer) private returns (address token, address curve) {
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
