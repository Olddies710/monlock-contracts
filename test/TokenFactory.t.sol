// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Presets} from "../script/config/Presets.sol";
import {BondingCurveManager} from "../src/BondingCurveManager.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {TokenFactory} from "../src/TokenFactory.sol";
import {IBondingCurveManager} from "../src/interfaces/IBondingCurveManager.sol";
import {ITokenFactory} from "../src/interfaces/ITokenFactory.sol";
import {BondingCurveMath} from "../src/libraries/BondingCurveMath.sol";
import {LaunchPresetLib} from "../src/libraries/LaunchPresetLib.sol";
import {CreateParams, CurveDeployParams, CurveStatus, LaunchPreset} from "../src/types/LaunchpadTypes.sol";
import {LaunchpadTest} from "./utils/LaunchpadTest.sol";
import {EmptyDelegate, MockSmartWallet} from "./utils/Mocks.sol";

contract TokenFactoryTest is LaunchpadTest {
    uint256 internal constant CURVE_OF_SLOT = 3; // `forge inspect TokenFactory storageLayout`
    uint256 internal constant PRESETS_SLOT = 4;

    address internal bot = makeAddr("bot");
    address internal signerCreator;
    uint256 internal signerKey;

    function setUp() public override {
        super.setUp();
        (signerCreator, signerKey) = makeAddrAndKey("signer-creator");
        vm.deal(bot, 1000 ether);
    }

    // ------------------------------------------------------------------ deployment and admin

    function test_constructor_setsConfigAndInitCodeHashes() public view {
        assertEq(factory.owner(), owner);
        assertEq(factory.protocolTreasury(), treasury);
        assertFalse(factory.creationPaused());
        assertEq(factory.tokenInitCodeHash(), keccak256(type(LaunchToken).creationCode));
        assertEq(factory.curveInitCodeHash(), keccak256(type(BondingCurveManager).creationCode));
    }

    function test_constructor_rejectsZeroOwnerOrTreasury() public {
        vm.expectRevert(ITokenFactory.InvalidTreasury.selector);
        new TokenFactory(owner, address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new TokenFactory(address(0), treasury);
    }

    function test_setPreset_isOwnedValidatedAndEmitted() public {
        LaunchPreset memory p = Presets.defaultPreset(address(migrator));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setPreset(2, p);

        vm.startPrank(owner);
        p.curveFeeSplit.protocolBps = 1;
        vm.expectRevert(LaunchPresetLib.InvalidFeeSplit.selector);
        factory.setPreset(2, p);

        p = Presets.defaultPreset(alice); // an EOA is not a migrator
        vm.expectRevert(LaunchPresetLib.InvalidMigrator.selector);
        factory.setPreset(2, p);

        p = Presets.defaultPreset(address(migrator));
        p.tradeFeeBps = 50;
        vm.expectEmit(address(factory));
        emit ITokenFactory.PresetUpdated(2, p);
        factory.setPreset(2, p);
        vm.stopPrank();

        LaunchPreset memory stored = factory.preset(2);
        assertEq(stored.tradeFeeBps, 50);
        assertEq(stored.virtualTokenReserve0, Presets.EXPECTED_VT0);
        assertEq(stored.migrator, address(migrator));
        assertTrue(stored.enabled);
    }

    function test_presetEdits_neverAffectLiveCurves() public {
        LaunchPreset memory p = Presets.defaultPreset(address(migrator));
        p.tradeFeeBps = 200;
        vm.prank(owner);
        factory.setPreset(PRESET_ID, p);

        (uint256 liveFee,,,) = curve.feeParams();
        assertEq(liveFee, Presets.TRADE_FEE_BPS, "existing curve keeps its immutables");
        (, address newCurve) = factory.createToken(_params(bytes32("after-edit")));
        (uint256 newFee,,,) = BondingCurveManager(newCurve).feeParams();
        assertEq(newFee, 200, "only future launches");
    }

    function test_setProtocolTreasury_redirectsFutureClaims() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setProtocolTreasury(alice);

        vm.startPrank(owner);
        vm.expectRevert(ITokenFactory.InvalidTreasury.selector);
        factory.setProtocolTreasury(address(0));
        address newTreasury = makeAddr("new-treasury");
        vm.expectEmit(address(factory));
        emit ITokenFactory.ProtocolTreasuryUpdated(newTreasury);
        factory.setProtocolTreasury(newTreasury);
        vm.stopPrank();

        _rollPastSnipeWindow();
        _buy(alice, 10 ether);
        (, uint256 toProtocol) = curve.claimableFees();
        curve.claimFees();
        assertEq(newTreasury.balance, toProtocol, "curves read the treasury at claim time");
    }

    function test_pauseBlocksCreationButNeverTrading() public {
        vm.prank(owner);
        vm.expectEmit(address(factory));
        emit ITokenFactory.CreationPausedUpdated(true);
        factory.setCreationPaused(true);

        vm.expectRevert(ITokenFactory.CreationPaused.selector);
        factory.createToken(_params(bytes32("paused")));

        _rollPastSnipeWindow();
        assertGt(_buy(alice, 1 ether), 0, "live curves keep trading");

        vm.prank(owner);
        factory.setCreationPaused(false);
        factory.createToken(_params(bytes32("unpaused")));
    }

    function test_ownershipIsTwoStepAndCannotBeRenounced() public {
        vm.prank(owner);
        factory.transferOwnership(alice);
        assertEq(factory.owner(), owner, "pending until accepted");
        assertEq(factory.pendingOwner(), alice);
        vm.prank(alice);
        factory.acceptOwnership();
        assertEq(factory.owner(), alice);

        vm.prank(alice);
        vm.expectRevert(ITokenFactory.OwnershipRenounceDisabled.selector);
        factory.renounceOwnership();
    }

    // ------------------------------------------------------------------ createToken

    function test_createToken_deploysAtPredictedAddressesAndRegisters() public {
        CreateParams memory p = _params(bytes32("predict"));
        (address predictedToken, address predictedCurve) = factory.predictAddresses(address(this), p.salt);

        vm.expectEmit(address(factory));
        emit ITokenFactory.TokenCreated(
            predictedToken,
            predictedCurve,
            creator,
            address(this),
            PRESET_ID,
            p.name,
            p.symbol,
            p.metadataURI,
            p.context
        );
        (address t, address c) = factory.createToken(p);

        assertEq(t, predictedToken);
        assertEq(c, predictedCurve);
        assertEq(factory.curveOf(t), c);
        LaunchToken launched = LaunchToken(t);
        BondingCurveManager launchedCurve = BondingCurveManager(c);
        assertEq(launched.name(), "Monad Cat");
        assertEq(launched.symbol(), "MCAT");
        assertEq(launched.curve(), c);
        assertEq(launched.balanceOf(c), Presets.TOTAL_SUPPLY);
        assertEq(launchedCurve.token(), t);
        assertEq(launchedCurve.creator(), creator);
        assertEq(launchedCurve.factory(), address(factory));
        assertEq(launchedCurve.migrator(), address(migrator));
        assertEq(launchedCurve.launchBlock(), block.number);
    }

    function test_createToken_validatesInputs() public {
        CreateParams memory p = _params(bytes32("v"));
        p.name = "";
        vm.expectRevert(ITokenFactory.InvalidName.selector);
        factory.createToken(p);

        p.name = "abcdefghijklmnopqrstuvwxyz012345"; // 32 bytes
        vm.expectRevert(ITokenFactory.InvalidName.selector);
        factory.createToken(p);

        p = _params(bytes32("v"));
        p.symbol = "";
        vm.expectRevert(ITokenFactory.InvalidSymbol.selector);
        factory.createToken(p);

        p = _params(bytes32("v"));
        p.creator = address(0);
        vm.expectRevert(ITokenFactory.InvalidCreator.selector);
        factory.createToken(p);

        p = _params(bytes32("v"));
        p.presetId = 99;
        vm.expectRevert(abi.encodeWithSelector(ITokenFactory.PresetDisabled.selector, uint32(99)));
        factory.createToken(p);
    }

    function test_createToken_disabledPresetRejected() public {
        LaunchPreset memory p = Presets.defaultPreset(address(migrator));
        p.enabled = false;
        vm.prank(owner);
        factory.setPreset(PRESET_ID, p);
        vm.expectRevert(abi.encodeWithSelector(ITokenFactory.PresetDisabled.selector, PRESET_ID));
        factory.createToken(_params(bytes32("disabled")));
    }

    function test_createToken_saltIsBoundToDeployer() public {
        CreateParams memory p = _params(bytes32("launch-day"));
        (address mine,) = factory.predictAddresses(address(this), p.salt);

        vm.prank(alice); // front-runner copying the salt
        (address theirs,) = factory.createToken(p);
        assertTrue(theirs != mine, "a copied salt lands elsewhere");

        (address t,) = factory.createToken(p);
        assertEq(t, mine, "the announced address is still ours");
    }

    function test_createToken_rejectsSaltReuse() public {
        vm.expectRevert(ITokenFactory.SaltAlreadyUsed.selector);
        factory.createToken(_params(bytes32("default"))); // used in setUp
    }

    function test_createToken_devBuySlippageReverts() public {
        CreateParams memory p = _params(bytes32("dev-slippage"));
        p.minDevBuyOut = Presets.CURVE_SUPPLY;
        uint256 out = BondingCurveMath.tokensOut(Presets.EXPECTED_VM0, Presets.EXPECTED_VT0, 0.99 ether);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IBondingCurveManager.InsufficientOutput.selector, out, p.minDevBuyOut));
        factory.createToken{value: 1 ether}(p);
    }

    function test_factoryNeverHoldsMon() public {
        vm.deal(address(this), 10 ether);
        factory.createToken{value: 10 ether}(_params(bytes32("dev")));
        assertEq(address(factory).balance, 0, "msg.value fully forwarded to the dev buy");

        (bool ok,) = address(factory).call{value: 1 ether}("");
        assertFalse(ok, "no receive");
    }

    function test_deployCallbacks_onlyServeTheContractBeingDeployed() public {
        vm.expectRevert(ITokenFactory.NotDeploying.selector);
        factory.tokenDeployParams();
        vm.expectRevert(ITokenFactory.NotDeploying.selector);
        factory.curveDeployParams();

        // Not even the addresses of an existing launch.
        vm.prank(address(token));
        vm.expectRevert(ITokenFactory.NotDeploying.selector);
        factory.tokenDeployParams();
        vm.prank(address(curve));
        vm.expectRevert(ITokenFactory.NotDeploying.selector);
        factory.curveDeployParams();
    }

    /// @notice Monad: a creation writes exactly one fresh slot in the factory (its registry entry). No global
    ///         counters or arrays, so concurrent creations only share the account nonce.
    function test_createToken_writesOnlyItsRegistryEntry() public {
        CreateParams memory p = _params(bytes32("footprint"));
        (address predictedToken,) = factory.predictAddresses(address(this), p.salt);
        bytes32 registrySlot = keccak256(abi.encode(predictedToken, CURVE_OF_SLOT));
        uint256 presetBase = uint256(keccak256(abi.encode(uint256(PRESET_ID), PRESETS_SLOT)));

        vm.record();
        factory.createToken(p);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(factory));

        assertEq(writes.length, 1);
        assertEq(writes[0], registrySlot);
        for (uint256 i; i < reads.length; ++i) {
            uint256 slot = uint256(reads[i]);
            bool isConfig = slot == 2; // treasury + creationPaused
            bool isRegistry = reads[i] == registrySlot;
            bool isPreset = slot >= presetBase && slot < presetBase + 8;
            assertTrue(isConfig || isRegistry || isPreset, "unexpected factory slot read");
        }
    }

    // ------------------------------------------------------------------ createTokenWithSig

    function test_createTokenWithSig_botDeploysForConsentingCreator() public {
        CreateParams memory p = _signerParams(bytes32("sig"));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _sign(signerKey, p, bot, deadline);

        (address predictedToken, address predictedCurve) = factory.predictAddresses(bot, p.salt);
        vm.expectEmit(address(factory));
        emit ITokenFactory.TokenCreated(
            predictedToken, predictedCurve, signerCreator, bot, PRESET_ID, p.name, p.symbol, p.metadataURI, p.context
        );
        vm.prank(bot);
        (address t, address c) = factory.createTokenWithSig{value: 5 ether}(p, deadline, sig);

        assertEq(BondingCurveManager(c).creator(), signerCreator);
        assertGt(LaunchToken(t).balanceOf(signerCreator), 0, "bot-funded dev buy goes to the creator");
        assertEq(t, predictedToken, "addresses derive from the relaying deployer");
    }

    function test_createTokenWithSig_rejectsExpiredOrForged() public {
        CreateParams memory p = _signerParams(bytes32("sig"));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _sign(signerKey, p, bot, deadline);

        vm.warp(deadline + 1);
        vm.prank(bot);
        vm.expectRevert(ITokenFactory.SignatureExpired.selector);
        factory.createTokenWithSig(p, deadline, sig);
        vm.warp(deadline - 1);

        (, uint256 wrongKey) = makeAddrAndKey("impostor");
        bytes memory forged = _sign(wrongKey, p, bot, deadline);
        vm.prank(bot);
        vm.expectRevert(ITokenFactory.InvalidSignature.selector);
        factory.createTokenWithSig(p, deadline, forged);

        CreateParams memory tampered = _signerParams(bytes32("sig"));
        tampered.name = "Rug Cat";
        vm.prank(bot);
        vm.expectRevert(ITokenFactory.InvalidSignature.selector);
        factory.createTokenWithSig(tampered, deadline, sig);
    }

    function test_createTokenWithSig_isBoundToDeployerAndNotReplayable() public {
        CreateParams memory p = _signerParams(bytes32("sig"));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _sign(signerKey, p, bot, deadline);

        vm.prank(alice); // another relayer grabbing the signature
        vm.expectRevert(ITokenFactory.InvalidSignature.selector);
        factory.createTokenWithSig(p, deadline, sig);

        vm.prank(bot);
        factory.createTokenWithSig(p, deadline, sig);
        vm.prank(bot);
        vm.expectRevert(ITokenFactory.SaltAlreadyUsed.selector);
        factory.createTokenWithSig(p, deadline, sig);
    }

    function test_createTokenWithSig_smartWalletCreator() public {
        MockSmartWallet wallet = new MockSmartWallet(signerCreator);
        CreateParams memory p = _signerParams(bytes32("wallet"));
        p.creator = address(wallet);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _sign(signerKey, p, bot, deadline);

        vm.prank(bot);
        (, address c) = factory.createTokenWithSig(p, deadline, sig);
        assertEq(BondingCurveManager(c).creator(), address(wallet), "ERC-1271");
    }

    function test_createTokenWithSig_eip7702DelegatedCreator() public {
        // Delegated EOA: has code (designator) but no ERC-1271. Its key still signs.
        vm.etch(signerCreator, abi.encodePacked(hex"ef0100", address(new EmptyDelegate())));
        assertGt(signerCreator.code.length, 0);
        CreateParams memory p = _signerParams(bytes32("7702"));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _sign(signerKey, p, bot, deadline);

        vm.prank(bot);
        (, address c) = factory.createTokenWithSig(p, deadline, sig);
        assertEq(BondingCurveManager(c).creator(), signerCreator);
    }

    function test_hashCreateToken_isStandardEip712() public view {
        CreateParams memory p = _signerParams(bytes32("sig"));
        uint256 deadline = 1234;
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Monad Launchpad TokenFactory"),
                keccak256("1"),
                MONAD_CHAIN_ID,
                address(factory)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "CreateToken(string name,string symbol,string metadataURI,address creator,address deployer,uint32 presetId,bytes32 salt,bytes context,uint256 deadline)"
                ),
                keccak256(bytes(p.name)),
                keccak256(bytes(p.symbol)),
                keccak256(bytes(p.metadataURI)),
                p.creator,
                bot,
                p.presetId,
                p.salt,
                keccak256(p.context),
                deadline
            )
        );
        assertEq(factory.hashCreateToken(p, bot, deadline), keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    }

    // ------------------------------------------------------------------ end to end

    /// @notice Social launch -> anti-snipe trading -> referrals -> sell-out -> graduation -> every claim.
    function test_endToEnd_socialLaunchToGraduation() public {
        CreateParams memory p = _signerParams(bytes32("e2e"));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _sign(signerKey, p, bot, deadline);
        vm.prank(bot);
        (address t, address c) = factory.createTokenWithSig{value: 5 ether}(p, deadline, sig);
        LaunchToken launched = LaunchToken(t);
        BondingCurveManager launchedCurve = BondingCurveManager(c);
        uint256 monIn = 5 ether;
        uint256 monOut;

        // Sniper in the launch block pays ~50%, capped at 1% of supply.
        vm.prank(carol);
        launchedCurve.buy{value: 10 ether}(0, address(0));
        monIn += 10 ether;

        // Normal trading after the window, routed by the bot as referrer.
        vm.roll(launchedCurve.launchBlock() + Presets.SNIPE_DECAY_BLOCKS);
        vm.prank(alice);
        launchedCurve.buyTo{value: 300 ether}(alice, 0, bot, vm.getBlockTimestamp());
        monIn += 300 ether;
        vm.roll(vm.getBlockNumber() + 1);
        uint256 half = launched.balanceOf(alice) / 2;
        vm.prank(alice);
        monOut += launchedCurve.sellTo(alice, half, 0, bot, vm.getBlockTimestamp());

        // Sell-out and atomic graduation.
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        launchedCurve.buy{value: 5000 ether}(0, bot);
        monIn += bobBefore - bob.balance;
        assertEq(uint8(launchedCurve.state().status), uint8(CurveStatus.Graduated));
        assertEq(migrator.lastCurve(), c);

        // Every fee recipient is paid; nothing stays behind.
        launchedCurve.claimFees();
        launchedCurve.claimReferrerFees(bot);
        uint256 botFees = bot.balance - (1000 ether - 5 ether);
        assertEq(address(launchedCurve).balance, 0, "curve drained to the last wei");
        assertEq(launched.balanceOf(c), 0);
        assertEq(address(factory).balance, 0);
        assertEq(monIn - monOut, migrator.monReceived() + signerCreator.balance + treasury.balance + botFees);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_predictAddresses_matchesDeployment(address deployer, bytes32 salt) public {
        vm.assume(deployer != address(0) && deployer != address(this));
        CreateParams memory p = _params(salt);
        (address predictedToken, address predictedCurve) = factory.predictAddresses(deployer, salt);
        vm.prank(deployer);
        (address t, address c) = factory.createToken(p);
        assertEq(t, predictedToken);
        assertEq(c, predictedCurve);
    }

    function testFuzz_nameAndSymbolLength(uint8 nameLength, uint8 symbolLength) public {
        CreateParams memory p = _params(bytes32(uint256(nameLength) << 8 | symbolLength));
        p.name = _string(nameLength);
        p.symbol = _string(symbolLength);
        bool validName = nameLength >= 1 && nameLength <= 31;
        bool validSymbol = symbolLength >= 1 && symbolLength <= 31;
        if (!validName) vm.expectRevert(ITokenFactory.InvalidName.selector);
        else if (!validSymbol) vm.expectRevert(ITokenFactory.InvalidSymbol.selector);
        (address t,) = factory.createToken(p);
        if (validName && validSymbol) {
            assertEq(LaunchToken(t).name(), p.name);
            assertEq(LaunchToken(t).symbol(), p.symbol);
        }
    }

    // ------------------------------------------------------------------ helpers

    function _signerParams(bytes32 salt) internal view returns (CreateParams memory p) {
        p = _params(salt);
        p.creator = signerCreator;
    }

    function _sign(uint256 key, CreateParams memory p, address deployer, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, factory.hashCreateToken(p, deployer, deadline));
        return abi.encodePacked(r, s, v);
    }

    function _string(uint256 length) internal pure returns (string memory) {
        bytes memory b = new bytes(length);
        for (uint256 i; i < length; ++i) {
            b[i] = bytes1(uint8(0x61 + i % 26));
        }
        return string(b);
    }
}
