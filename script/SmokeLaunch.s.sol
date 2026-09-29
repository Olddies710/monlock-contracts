// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {BondingCurveManager} from "../src/BondingCurveManager.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LiquidityMigrator} from "../src/LiquidityMigrator.sol";
import {TokenFactory} from "../src/TokenFactory.sol";
import {BondingCurveMath} from "../src/libraries/BondingCurveMath.sol";
import {CreateParams, CurveState, CurveStatus} from "../src/types/LaunchpadTypes.sol";
import {MonadMainnet} from "./config/MonadAddresses.sol";
import {Presets} from "./config/Presets.sol";
import {DeploymentLib} from "./utils/DeploymentLib.sol";

/// @notice Lifecycle smoke test against a deployed testnet launchpad, on the smoke preset (graduates at 1 MON).
///         One invocation per step, because the anti-snipe window and the same-block round-trip guard need real
///         blocks in between (DEPLOYMENT.md §5). Every broadcast lands in `broadcast/SmokeLaunch.s.sol/<chainId>/`
///         with its receipts: that is where the measured testnet gas comes from.
///
///           --sig "launch()"            create a token with a dev buy                  (DEV_BUY, PRESET_ID)
///           --sig "trade(address)"      sell half of the sender's tokens, then buy     (BUY_AMOUNT, REFERRER)
///           --sig "graduate(address)"   buy the rest of the curve after the window     (~1.02 MON on preset 2)
///           --sig "claim(address)"      pay out curve fees, and LP fees once graduated
/// @dev Refuses to run on mainnet. The factory comes from `deployments/<chainId>.json` unless FACTORY is set.
contract SmokeLaunch is Script {
    error MainnetNotAllowed();
    error InvalidPresetId(uint256 presetId);
    error SnipeWindowOpen(uint256 blocksLeft);
    error NotGraduated(CurveStatus status);

    function launch() external returns (address token, address curve) {
        TokenFactory factory = _factory();
        address sender = DeploymentLib.broadcaster();
        CreateParams memory p;
        p.name = "Launchpad Smoke";
        p.symbol = "SMOKE";
        p.metadataURI = "ipfs://launchpad-smoke";
        p.creator = sender;
        uint256 presetId = DeploymentLib.envUint("PRESET_ID", uint256(Presets.SMOKE_PRESET_ID));
        if (presetId > type(uint32).max) revert InvalidPresetId(presetId);
        // forge-lint: disable-next-line(unsafe-typecast)
        p.presetId = uint32(presetId); // range checked above
        p.salt = keccak256(abi.encode("launchpad.smoke", vm.getBlockNumber()));

        vm.broadcast(sender);
        (token, curve) = factory.createToken{value: DeploymentLib.envUint("DEV_BUY", uint256(0.01 ether))}(p);
        console.log("token %s", token);
        console.log("curve %s", curve);
        console.log("dev buy: %s tokens", LaunchToken(token).balanceOf(sender));
    }

    function trade(address token) external {
        BondingCurveManager curve = _curve(token);
        address sender = DeploymentLib.broadcaster();
        uint256 balance = LaunchToken(token).balanceOf(sender);

        vm.startBroadcast(sender);
        // Sell first: buying first would mark this block and the sell would hit the round-trip guard.
        if (balance > 1) {
            (uint256 monOut,,) = curve.quoteSell(balance / 2);
            curve.sell(balance / 2, monOut * 99 / 100);
        }
        uint256 value = DeploymentLib.envUint("BUY_AMOUNT", uint256(0.001 ether));
        (uint256 tokensOut,,,) = curve.quoteBuy(value);
        curve.buy{value: value}(tokensOut * 99 / 100, DeploymentLib.envAddress("REFERRER", address(0)));
        vm.stopBroadcast();
        console.log("fee now %s bps, holdings %s", curve.currentFeeBps(), LaunchToken(token).balanceOf(sender));
    }

    function graduate(address token) external {
        BondingCurveManager curve = _curve(token);
        (,, uint256 decayBlocks,) = curve.snipeParams();
        uint256 windowEnd = curve.launchBlock() + decayBlocks;
        if (vm.getBlockNumber() < windowEnd) revert SnipeWindowOpen(windowEnd - vm.getBlockNumber());

        // MON that buys the remaining supply at the base fee, plus 2% headroom (the curve refunds any excess).
        CurveState memory s = curve.state();
        uint256 value = BondingCurveMath.monInForTokens(s.virtualMonReserve, s.virtualTokenReserve, s.realTokenReserve)
            * 102 / 100 + 1;
        console.log("buying out the curve with %s wei", value);

        vm.broadcast(DeploymentLib.broadcaster());
        curve.buy{value: value}(s.realTokenReserve, address(0));

        s = curve.state();
        if (s.status != CurveStatus.Graduated) revert NotGraduated(s.status);
        LiquidityMigrator migrator = LiquidityMigrator(payable(curve.migrator()));
        console.log("graduated: pool %s", vm.toString(migrator.positionOf(token).poolId));
    }

    function claim(address token) external {
        BondingCurveManager curve = _curve(token);
        (uint256 toCreator, uint256 toProtocol) = curve.claimableFees();
        console.log("curve fees: creator %s, protocol %s", toCreator, toProtocol);

        vm.startBroadcast(DeploymentLib.broadcaster());
        if (toCreator + toProtocol != 0) curve.claimFees();
        if (curve.state().status == CurveStatus.Graduated) {
            LiquidityMigrator(payable(curve.migrator())).collectFees(token);
        }
        vm.stopBroadcast();
    }

    // ------------------------------------------------------------------ helpers

    function _factory() private view returns (TokenFactory) {
        if (block.chainid == MonadMainnet.CHAIN_ID) revert MainnetNotAllowed();
        address factory = DeploymentLib.envAddress("FACTORY", address(0));
        if (factory == address(0)) factory = DeploymentLib.read(DeploymentLib.path(block.chainid)).factory;
        return TokenFactory(factory);
    }

    function _curve(address token) private view returns (BondingCurveManager) {
        return BondingCurveManager(payable(_factory().curveOf(token)));
    }
}
