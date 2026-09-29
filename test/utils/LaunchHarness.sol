// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LibString} from "solady/utils/LibString.sol";

import {BondingCurveManager} from "../../src/BondingCurveManager.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {CurveDeployParams, LaunchPreset} from "../../src/types/LaunchpadTypes.sol";

/// @notice Test double of the TokenFactory with the same deployment mechanics (constant init code, parameters served
///         through constructor callbacks, CREATE2 addresses from (deployer, salt)) but none of its validation, and a
///         treasury that can be zero. Used only to test constructor-level and curve-level defenses in isolation.
contract LaunchHarness {
    address public protocolTreasury;

    bool private _deploying;
    bytes32 private _packedName;
    bytes32 private _packedSymbol;
    address private _curve;
    uint256 private _supply;
    CurveDeployParams private _curveParams;

    error NotDeploying();
    error AddressMismatch();

    constructor(address treasury) {
        protocolTreasury = treasury;
    }

    function setProtocolTreasury(address treasury) external {
        protocolTreasury = treasury;
    }

    /// @notice Stock-reserve fields served to the next curves (no validation: constructor-level tests).
    function setStockParams(address stockReserve, uint16 stockFeeBps) external {
        _curveParams.stockReserve = stockReserve;
        _curveParams.stockFeeBps = stockFeeBps;
    }

    function tokenDeployParams() external view returns (bytes32, bytes32, address, uint256) {
        if (!_deploying) revert NotDeploying();
        return (_packedName, _packedSymbol, _curve, _supply);
    }

    function curveDeployParams() external view returns (CurveDeployParams memory) {
        if (!_deploying) revert NotDeploying();
        return _curveParams;
    }

    function predictAddresses(address deployer, bytes32 salt) public view returns (address token, address curve) {
        bytes32 s = keccak256(abi.encode(deployer, salt));
        token = _create2Address(s, keccak256(type(LaunchToken).creationCode));
        curve = _create2Address(s, keccak256(type(BondingCurveManager).creationCode));
    }

    /// @notice Deploys token + curve; `msg.value > 0` runs the dev buy for `creator` in the same transaction.
    function launch(
        LaunchPreset memory preset,
        string memory name,
        string memory symbol,
        address creator,
        bytes32 salt,
        uint256 minDevBuyOut
    ) external payable returns (LaunchToken token, BondingCurveManager curve) {
        bytes32 s = keccak256(abi.encode(msg.sender, salt));
        (address predictedToken, address predictedCurve) = predictAddresses(msg.sender, salt);

        _deploying = true;
        _packedName = LibString.packOne(name);
        _packedSymbol = LibString.packOne(symbol);
        _curve = predictedCurve;
        _supply = uint256(preset.curveSupply) + preset.lpSupply;
        token = new LaunchToken{salt: s}();

        _curveParams.token = address(token);
        _curveParams.creator = creator;
        _curveParams.preset = preset;
        curve = new BondingCurveManager{salt: s}();
        _deploying = false;

        if (address(token) != predictedToken || address(curve) != predictedCurve) revert AddressMismatch();
        if (msg.value != 0) curve.devBuy{value: msg.value}(minDevBuyOut, creator);
    }

    function _create2Address(bytes32 salt, bytes32 initCodeHash) private view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    receive() external payable {}
}
