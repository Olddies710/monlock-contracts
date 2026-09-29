// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IBondingCurveManager} from "./interfaces/IBondingCurveManager.sol";
import {ILaunchToken} from "./interfaces/ILaunchToken.sol";
import {ILiquidityMigrator} from "./interfaces/ILiquidityMigrator.sol";
import {ITokenFactory} from "./interfaces/ITokenFactory.sol";
import {BondingCurveMath} from "./libraries/BondingCurveMath.sol";
import {LaunchPresetLib} from "./libraries/LaunchPresetLib.sol";
import {CurveDeployParams, CurveState, CurveStatus, FeeSplit, LaunchPreset} from "./types/LaunchpadTypes.sol";

/// @title BondingCurveManager
/// @notice Bonding curve of ONE token (one instance per launch). Buys and sells the token against native MON on a
///         virtual constant-product curve, charges the anti-snipe fee schedule, retains fees for pull-based claims
///         and, when the curve sells out, freezes trading and graduates the liquidity to the DEX.
/// @dev Monad layout (ARCHITECTURE.md §3): every mutable field lives in slots 0-3, i.e. in storage page 0
///      (128-slot pages), so a trade pays one cold page access for the whole curve state. Parameters are
///      immutables (bytecode, no SLOAD). The reentrancy lock uses transient storage on every chain.
///      The only storage outside page 0 is the per-referrer fee ledger, touched only by referred trades.
contract BondingCurveManager is IBondingCurveManager, ReentrancyGuardTransient {
    using SafeCastLib for uint256;
    using SafeTransferLib for address;

    uint256 private constant BPS = 10_000;

    // ------------------------------------------------------------------ immutables

    /// @inheritdoc IBondingCurveManager
    address public immutable token;
    /// @inheritdoc IBondingCurveManager
    address public immutable factory;
    /// @inheritdoc IBondingCurveManager
    address public immutable migrator;
    /// @inheritdoc IBondingCurveManager
    address public immutable creator;
    /// @inheritdoc IBondingCurveManager
    uint256 public immutable launchBlock;

    uint256 private immutable _vT0;
    uint256 private immutable _vM0;
    uint256 private immutable _curveSupply;
    uint256 private immutable _lpSupply;

    uint16 private immutable _tradeFeeBps;
    uint16 private immutable _graduationFeeBps;
    uint16 private immutable _creatorBps;
    uint16 private immutable _protocolBps;
    uint16 private immutable _referrerBps;
    uint16 private immutable _lpCreatorBps;
    uint16 private immutable _lpProtocolBps;
    uint16 private immutable _lpReferrerBps;

    uint16 private immutable _snipeFeeBps;
    uint32 private immutable _snipeDecayBlocks;
    uint16 private immutable _maxBuyBps;
    uint16 private immutable _maxDevBuyBps;
    uint256 private immutable _maxBuyTokens;
    uint256 private immutable _maxDevBuyTokens;

    // ------------------------------------------------------------------ storage (page 0: slots 0-3)

    uint128 private _realMonReserve; // slot 0
    uint128 private _realTokenReserve; // slot 0
    uint128 private _totalFeesAccrued; // slot 1
    uint96 private _referrerFeesAccrued; // slot 1
    CurveStatus private _status; // slot 1
    uint128 private _creatorFeesClaimed; // slot 2
    uint128 private _protocolFeesClaimed; // slot 2
    /// @inheritdoc IBondingCurveManager
    address public creatorFeeRecipient; // slot 3
    /// @inheritdoc IBondingCurveManager
    mapping(address referrer => uint256) public referrerFees; // slot 4 (entries hash outside page 0)

    // ------------------------------------------------------------------ construction

    /// @dev Parameters are read back from the deploying factory (transient storage), so the init code has no
    ///      arguments and every curve shares one init-code hash (ARCHITECTURE.md §2.4).
    constructor() {
        CurveDeployParams memory p = ITokenFactory(msg.sender).curveDeployParams();
        LaunchPreset memory preset = p.preset;
        LaunchPresetLib.validate(preset);
        if (p.token == address(0) || p.creator == address(0)) revert InvalidDeployParams();

        uint256 totalSupply = uint256(preset.curveSupply) + preset.lpSupply;
        // The token must have minted the whole supply to this (predicted) address before we exist.
        if (SafeTransferLib.balanceOf(p.token, address(this)) != totalSupply) revert InvalidDeployParams();

        token = p.token;
        factory = msg.sender;
        migrator = preset.migrator;
        creator = p.creator;
        launchBlock = block.number;

        _vT0 = preset.virtualTokenReserve0;
        _vM0 = preset.virtualMonReserve0;
        _curveSupply = preset.curveSupply;
        _lpSupply = preset.lpSupply;

        _tradeFeeBps = preset.tradeFeeBps;
        _graduationFeeBps = preset.graduationFeeBps;
        _creatorBps = preset.curveFeeSplit.creatorBps;
        _protocolBps = preset.curveFeeSplit.protocolBps;
        _referrerBps = preset.curveFeeSplit.referrerBps;
        _lpCreatorBps = preset.lpFeeSplit.creatorBps;
        _lpProtocolBps = preset.lpFeeSplit.protocolBps;
        _lpReferrerBps = preset.lpFeeSplit.referrerBps;

        _snipeFeeBps = preset.snipeFeeBps;
        _snipeDecayBlocks = preset.snipeDecayBlocks;
        _maxBuyBps = preset.maxBuyBps;
        _maxDevBuyBps = preset.maxDevBuyBps;
        _maxBuyTokens = totalSupply * preset.maxBuyBps / BPS;
        _maxDevBuyTokens = totalSupply * preset.maxDevBuyBps / BPS;

        _realTokenReserve = preset.curveSupply;
        creatorFeeRecipient = p.creator;
    }

    // ------------------------------------------------------------------ trading

    /// @inheritdoc IBondingCurveManager
    function buy(uint256 minTokensOut, address referrer) external payable nonReentrant returns (uint256) {
        return _buy(msg.sender, minTokensOut, referrer, currentFeeBps(), maxBuyAmount());
    }

    /// @inheritdoc IBondingCurveManager
    function buyTo(address recipient, uint256 minTokensOut, address referrer, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256)
    {
        _checkDeadline(deadline);
        return _buy(recipient, minTokensOut, referrer, currentFeeBps(), maxBuyAmount());
    }

    /// @inheritdoc IBondingCurveManager
    function sell(uint256 tokenAmount, uint256 minMonOut) external nonReentrant returns (uint256) {
        return _sell(msg.sender, tokenAmount, minMonOut, address(0));
    }

    /// @inheritdoc IBondingCurveManager
    function sellTo(address recipient, uint256 tokenAmount, uint256 minMonOut, address referrer, uint256 deadline)
        external
        nonReentrant
        returns (uint256)
    {
        _checkDeadline(deadline);
        return _sell(recipient, tokenAmount, minMonOut, referrer);
    }

    /// @inheritdoc IBondingCurveManager
    function devBuy(uint256 minTokensOut, address recipient) external payable nonReentrant returns (uint256) {
        if (msg.sender != factory) revert OnlyFactory();
        // Only as the very first trade of the launch block: the factory calls it inside the creation tx.
        if (block.number != launchBlock || _realTokenReserve != _curveSupply) revert DevBuyUnavailable();
        return _buy(recipient, minTokensOut, address(0), _tradeFeeBps, _maxDevBuyTokens);
    }

    // ------------------------------------------------------------------ quotes

    /// @inheritdoc IBondingCurveManager
    function quoteBuy(uint256 monIn)
        external
        view
        returns (uint256 tokensOut, uint256 fee, uint256 snipeTax, uint256 refund)
    {
        if (_status != CurveStatus.Trading) revert NotTrading();
        uint256 monUsed;
        (tokensOut, monUsed, fee, snipeTax) = _computeBuy(_realMonReserve, _realTokenReserve, monIn, currentFeeBps());
        refund = monIn - monUsed;
    }

    /// @inheritdoc IBondingCurveManager
    function quoteSell(uint256 tokenAmount) external view returns (uint256 monOut, uint256 fee, uint256 snipeTax) {
        if (_status != CurveStatus.Trading) revert NotTrading();
        uint256 gross;
        (gross, fee, snipeTax) = _computeSell(_realMonReserve, _realTokenReserve, tokenAmount, currentFeeBps());
        monOut = gross - fee - snipeTax;
    }

    /// @inheritdoc IBondingCurveManager
    function currentFeeBps() public view returns (uint256) {
        return BondingCurveMath.feeBpsAt(block.number - launchBlock, _tradeFeeBps, _snipeFeeBps, _snipeDecayBlocks);
    }

    /// @inheritdoc IBondingCurveManager
    function maxBuyAmount() public view returns (uint256) {
        return block.number - launchBlock < _snipeDecayBlocks ? _maxBuyTokens : type(uint256).max;
    }

    /// @inheritdoc IBondingCurveManager
    function state() external view returns (CurveState memory s) {
        s.status = _status;
        s.realMonReserve = _realMonReserve;
        s.realTokenReserve = _realTokenReserve;
        s.virtualMonReserve = _vM0 + s.realMonReserve;
        s.virtualTokenReserve = _vT0 - _curveSupply + s.realTokenReserve;
        s.totalFeesAccrued = _totalFeesAccrued;
        s.referrerFeesAccrued = _referrerFeesAccrued;
        s.currentFeeBps = currentFeeBps();
    }

    // ------------------------------------------------------------------ graduation

    /// @inheritdoc IBondingCurveManager
    function graduate() external nonReentrant {
        if (_status != CurveStatus.Completed) revert NotCompleted();
        this.executeGraduation();
    }

    /// @notice Migration step. External only so the atomic attempt can run inside try/catch: any failure reverts
    ///         the whole migration without reverting the buy that completed the curve. Callable only by itself.
    function executeGraduation() external {
        if (msg.sender != address(this)) revert OnlySelf();
        if (_status != CurveStatus.Completed) revert NotCompleted();

        uint256 realMon = _realMonReserve;
        (uint256 graduationFee, uint256 monForLiquidity, uint256 tokensForLiquidity) =
            BondingCurveMath.graduationAmounts(realMon, _vM0, _vT0 - _curveSupply, _lpSupply, _graduationFeeBps);

        _realMonReserve = 0;
        _status = CurveStatus.Graduated;
        _totalFeesAccrued = (_totalFeesAccrued + graduationFee).toUint128();

        token.safeTransfer(migrator, tokensForLiquidity);
        // The migrator emits the pool id and liquidity itself (`Migrated`); the curve only needs success.
        // forge-lint: disable-next-line(unused-return)
        ILiquidityMigrator(migrator).migrate{value: monForLiquidity}(token, tokensForLiquidity);

        // Burn the unused LP reserve plus any token dust sent to the curve: nothing stays behind.
        uint256 leftover = SafeTransferLib.balanceOf(token, address(this));
        if (leftover != 0) ILaunchToken(token).burn(leftover);

        emit Graduated(monForLiquidity, tokensForLiquidity, leftover, graduationFee);
    }

    // ------------------------------------------------------------------ fees

    /// @inheritdoc IBondingCurveManager
    function claimableFees() public view returns (uint256 toCreator, uint256 toProtocol) {
        uint256 total = _totalFeesAccrued;
        uint256 creatorEntitled = total * _creatorBps / BPS;
        toCreator = creatorEntitled - _creatorFeesClaimed;
        // Residual claimant: unreferred shares, the graduation fee's referrer share and all rounding dust.
        toProtocol = total - creatorEntitled - _referrerFeesAccrued - _protocolFeesClaimed;
    }

    /// @inheritdoc IBondingCurveManager
    function claimFees() external nonReentrant {
        (uint256 toCreator, uint256 toProtocol) = claimableFees();
        address treasury = ITokenFactory(factory).protocolTreasury();
        // Never burn protocol fees on a misconfigured treasury: they stay claimable.
        if (treasury == address(0)) toProtocol = 0;
        if (toCreator == 0 && toProtocol == 0) return;
        _creatorFeesClaimed += toCreator.toUint128();
        _protocolFeesClaimed += toProtocol.toUint128();
        emit FeesClaimed(toCreator, toProtocol);

        // Destinations are fixed (creator-set recipient, factory treasury); forced sends cannot be blocked.
        // forge-lint: disable-next-line(arbitrary-send-eth)
        if (toCreator != 0) creatorFeeRecipient.forceSafeTransferETH(toCreator);
        // forge-lint: disable-next-line(arbitrary-send-eth)
        if (toProtocol != 0) treasury.forceSafeTransferETH(toProtocol);
    }

    /// @inheritdoc IBondingCurveManager
    function claimReferrerFees(address referrer) external nonReentrant returns (uint256 amount) {
        amount = referrerFees[referrer];
        if (amount == 0) return 0;
        referrerFees[referrer] = 0;
        emit ReferrerFeesClaimed(referrer, amount);
        // Pays only the ledger owner, only what it is owed.
        // forge-lint: disable-next-line(arbitrary-send-eth)
        referrer.forceSafeTransferETH(amount);
    }

    /// @inheritdoc IBondingCurveManager
    function setCreatorFeeRecipient(address recipient) external {
        if (msg.sender != creator) revert OnlyCreator();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        creatorFeeRecipient = recipient;
        emit CreatorFeeRecipientUpdated(recipient);
    }

    // ------------------------------------------------------------------ configuration getters

    /// @inheritdoc IBondingCurveManager
    function curveParams()
        external
        view
        returns (uint256 virtualTokenReserve0, uint256 virtualMonReserve0, uint256 curveSupply, uint256 lpSupply)
    {
        return (_vT0, _vM0, _curveSupply, _lpSupply);
    }

    /// @inheritdoc IBondingCurveManager
    function feeParams()
        external
        view
        returns (
            uint256 tradeFeeBps,
            uint256 graduationFeeBps,
            FeeSplit memory curveFeeSplit,
            FeeSplit memory lpFeeSplit
        )
    {
        tradeFeeBps = _tradeFeeBps;
        graduationFeeBps = _graduationFeeBps;
        curveFeeSplit = FeeSplit(_creatorBps, _protocolBps, _referrerBps);
        lpFeeSplit = FeeSplit(_lpCreatorBps, _lpProtocolBps, _lpReferrerBps);
    }

    /// @inheritdoc IBondingCurveManager
    function snipeParams()
        external
        view
        returns (uint256 snipeFeeBps, uint256 snipeDecayBlocks, uint256 maxBuyBps, uint256 maxDevBuyBps)
    {
        return (_snipeFeeBps, _snipeDecayBlocks, _maxBuyBps, _maxDevBuyBps);
    }

    // ------------------------------------------------------------------ internals

    function _buy(address recipient, uint256 minTokensOut, address referrer, uint256 feeBps, uint256 maxTokensOut)
        private
        returns (uint256 tokensOut)
    {
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        if (referrer == address(this)) revert InvalidReferrer();
        if (msg.value == 0) revert ZeroAmount();
        if (_status != CurveStatus.Trading) revert NotTrading();

        uint256 realMon = _realMonReserve;
        uint256 realTokens = _realTokenReserve;
        uint256 monUsed;
        uint256 fee;
        uint256 tax;
        (tokensOut, monUsed, fee, tax) = _computeBuy(realMon, realTokens, msg.value, feeBps);
        if (tokensOut == 0 || tokensOut < minTokensOut) revert InsufficientOutput(tokensOut, minTokensOut);
        if (tokensOut > maxTokensOut) revert MaxBuyExceeded(tokensOut, maxTokensOut);

        // Effects. The anti-snipe tax stays in the reserve without minting tokens: a donation to all holders.
        realMon += monUsed - fee;
        realTokens -= tokensOut;
        _realMonReserve = realMon.toUint128();
        // forge-lint: disable-next-line(unsafe-typecast)
        _realTokenReserve = uint128(realTokens); // decreased from a uint128
        _accrueFees(fee, referrer);
        bool completed = realTokens == 0;
        if (completed) _status = CurveStatus.Completed;
        emit Trade(msg.sender, recipient, referrer, true, monUsed, tokensOut, fee, tax, realMon, realTokens);
        if (completed) emit CurveCompleted(realMon);

        // Interactions.
        token.safeTransfer(recipient, tokensOut);
        if (msg.value > monUsed) msg.sender.safeTransferETH(msg.value - monUsed);

        // Sold out: freeze and graduate atomically; on failure stay Completed so `graduate()` can retry.
        if (completed) {
            try this.executeGraduation() {}
            catch (bytes memory reason) {
                emit MigrationFailed(reason);
            }
        }
    }

    function _sell(address recipient, uint256 tokenAmount, uint256 minMonOut, address referrer)
        private
        returns (uint256 monOut)
    {
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        if (referrer == address(this)) revert InvalidReferrer();
        if (tokenAmount == 0) revert ZeroAmount();
        if (_status != CurveStatus.Trading) revert NotTrading();

        uint256 realMon = _realMonReserve;
        uint256 realTokens = _realTokenReserve;
        (uint256 gross, uint256 fee, uint256 tax) = _computeSell(realMon, realTokens, tokenAmount, currentFeeBps());
        monOut = gross - fee - tax;
        if (monOut == 0 || monOut < minMonOut) revert InsufficientOutput(monOut, minMonOut);

        // Effects. Checked subtraction: k never decreases, so the reserve always covers `gross` (invariant I1).
        realMon = realMon - gross + tax;
        realTokens += tokenAmount;
        // forge-lint: disable-next-line(unsafe-typecast)
        _realMonReserve = uint128(realMon); // decreased (tax <= gross) from a uint128
        _realTokenReserve = realTokens.toUint128();
        _accrueFees(fee, referrer);
        emit Trade(msg.sender, recipient, referrer, false, monOut, tokenAmount, fee, tax, realMon, realTokens);

        // Interactions. Direct call (not SafeTransferLib) so the token's `SameBlockRoundTrip` error reaches the
        // caller when `msg.sender` received curve tokens in this block. The token always returns true.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        ERC20(token).transferFrom(msg.sender, address(this), tokenAmount);
        // The seller chooses where its own proceeds go.
        // forge-lint: disable-next-line(arbitrary-send-eth)
        recipient.safeTransferETH(monOut);
    }

    /// @dev Buy math shared by `_buy` and `quoteBuy`. Clips at the end of the curve: the buyer gets exactly the
    ///      remaining tokens and pays the smallest gross amount that covers them (ARCHITECTURE.md §4.3).
    function _computeBuy(uint256 realMon, uint256 realTokens, uint256 monIn, uint256 feeBps)
        private
        view
        returns (uint256 tokensOut, uint256 monUsed, uint256 fee, uint256 tax)
    {
        uint256 vM = _vM0 + realMon;
        uint256 vT = _vT0 - _curveSupply + realTokens;
        monUsed = monIn;
        (fee, tax) = BondingCurveMath.splitFees(monIn, feeBps, _tradeFeeBps);
        tokensOut = BondingCurveMath.tokensOut(vM, vT, monIn - fee - tax);
        if (tokensOut >= realTokens) {
            tokensOut = realTokens;
            // grossUp(net) <= monIn whenever monIn already buys >= realTokens (ARCHITECTURE.md §4.3).
            monUsed = BondingCurveMath.grossUp(BondingCurveMath.monInForTokens(vM, vT, realTokens), feeBps);
            assert(monUsed <= monIn);
            (fee, tax) = BondingCurveMath.splitFees(monUsed, feeBps, _tradeFeeBps);
        }
    }

    function _computeSell(uint256 realMon, uint256 realTokens, uint256 tokenAmount, uint256 feeBps)
        private
        view
        returns (uint256 gross, uint256 fee, uint256 tax)
    {
        gross = BondingCurveMath.monOut(_vM0 + realMon, _vT0 - _curveSupply + realTokens, tokenAmount);
        (fee, tax) = BondingCurveMath.splitFees(gross, feeBps, _tradeFeeBps);
    }

    /// @dev One SSTORE on slot 1 for unreferred trades; referred trades also credit the referrer's ledger entry.
    ///      The referrer share rounds down; the protocol, as residual claimant, receives the dust.
    function _accrueFees(uint256 fee, address referrer) private {
        _totalFeesAccrued = (_totalFeesAccrued + fee).toUint128();
        if (referrer == address(0)) return;
        uint256 cut = fee * _referrerBps / BPS;
        if (cut == 0) return;
        referrerFees[referrer] += cut;
        _referrerFeesAccrued = (_referrerFeesAccrued + cut).toUint96();
    }

    function _checkDeadline(uint256 deadline) private view {
        // Deadlines are the intended use of the timestamp (1 s resolution on Monad is enough).
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert DeadlineExpired();
    }

    /// @dev Solady defaults to a persistent-storage lock on every chain but Ethereum mainnet. On Monad that would
    ///      write a slot outside page 0 on every trade (extra cold page, and state growth on first use).
    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }
}
