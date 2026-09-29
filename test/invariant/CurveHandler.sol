// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {BondingCurveManager} from "../../src/BondingCurveManager.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {CurveState, CurveStatus} from "../../src/types/LaunchpadTypes.sol";
import {MockMigrator} from "../utils/Mocks.sol";

/// @notice Drives one launch through random trading, transfers, block progression, claims, migration failures
///         and graduation, while keeping ghost ledgers of every MON that enters or leaves the system.
contract CurveHandler is Test {
    BondingCurveManager public immutable curve;
    LaunchToken public immutable token;
    MockMigrator public immutable migrator;
    address public immutable creator;
    address public immutable treasury;

    address[] public actors;
    address[] public referrers; // index 0 is address(0): no referrer

    uint256 public ghostMonIn; // MON kept by the curve from buys (net of refunds)
    uint256 public ghostMonToSellers;
    uint256 public ghostFeesPaid; // creator + treasury + referrers
    uint256 public ghostRealMonAtCompletion;
    uint8 public ghostMaxStatus;
    bool public ghostStatusRegressed;

    // Coverage counters: actions that actually changed state.
    uint256 public buys;
    uint256 public sells;
    uint256 public completionsWithFailedMigration;
    uint256 public graduations;

    constructor(BondingCurveManager curve_, MockMigrator migrator_, address creator_, address treasury_) {
        curve = curve_;
        token = LaunchToken(curve_.token());
        migrator = migrator_;
        creator = creator_;
        treasury = treasury_;
        for (uint256 i; i < 4; ++i) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
        referrers.push(address(0));
        referrers.push(makeAddr("ref1"));
        referrers.push(makeAddr("ref2"));
    }

    // ------------------------------------------------------------------ actions

    function buy(uint256 actorSeed, uint256 amount, uint256 refSeed) external {
        if (_status() != CurveStatus.Trading) return;
        address actor = actors[actorSeed % actors.length];
        bool inWindow = curve.maxBuyAmount() != type(uint256).max;
        amount = bound(amount, 1e12, inWindow ? 10 ether : 400 ether);
        (uint256 q,,,) = curve.quoteBuy(amount);
        if (q == 0 || q > curve.maxBuyAmount()) return;
        _executeBuy(actor, amount, referrers[refSeed % referrers.length]);
    }

    /// @dev A whale sells the curve out (after the anti-snipe window, rolling to it if needed) so completion,
    ///      failed migration and graduation paths get coverage in every run.
    function buyOut(uint256 actorSeed, uint256 amount) external {
        // Let every run trade first: the interesting states are reached through many buys and sells.
        if (_status() != CurveStatus.Trading || buys + sells < 15) return;
        uint256 windowEnd = curve.launchBlock() + 200;
        if (vm.getBlockNumber() < windowEnd) vm.roll(windowEnd);
        _executeBuy(actors[actorSeed % actors.length], bound(amount, 2100 ether, 5000 ether), address(0));
    }

    function sell(uint256 actorSeed, uint256 amount, uint256 refSeed) external {
        if (_status() != CurveStatus.Trading) return;
        address actor = actors[actorSeed % actors.length];
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        if (token.lastBuyBlock(actor) == vm.getBlockNumber()) vm.roll(vm.getBlockNumber() + 1);
        amount = bound(amount, 1, balance);
        (uint256 q,,) = curve.quoteSell(amount);
        if (q == 0) return;
        vm.prank(actor);
        ghostMonToSellers += curve.sellTo(
            actor, amount, 0, referrers[refSeed % referrers.length], vm.getBlockTimestamp()
        );
        sells++;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function roll(uint256 blocks) external {
        vm.roll(vm.getBlockNumber() + bound(blocks, 1, 100));
    }

    function claimFees() external {
        uint256 before = creator.balance + treasury.balance;
        curve.claimFees();
        ghostFeesPaid += creator.balance + treasury.balance - before;
    }

    function claimReferrerFees(uint256 refSeed) external {
        ghostFeesPaid += curve.claimReferrerFees(referrers[refSeed % referrers.length]);
    }

    function setMigratorFailing(bool failing) external {
        migrator.setShouldRevert(failing);
    }

    function graduate() external {
        if (_status() != CurveStatus.Completed) return;
        migrator.setShouldRevert(false);
        curve.graduate();
        graduations++;
        _trackStatus();
    }

    // ------------------------------------------------------------------ views for invariants

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function referrerCount() external view returns (uint256) {
        return referrers.length;
    }

    // ------------------------------------------------------------------ internals

    function _executeBuy(address actor, uint256 amount, address referrer) private {
        uint256 realMonBefore = curve.state().realMonReserve;
        // Same block as the buy: the quote is exact (fee is charged on the MON actually used).
        (, uint256 fee,, uint256 refund) = curve.quoteBuy(amount);
        vm.deal(actor, actor.balance + amount);
        uint256 balanceBefore = actor.balance;
        vm.prank(actor);
        curve.buy{value: amount}(0, referrer);
        ghostMonIn += balanceBefore - actor.balance;
        buys++;

        if (_status() != CurveStatus.Trading && ghostRealMonAtCompletion == 0) {
            ghostRealMonAtCompletion = realMonBefore + (amount - refund) - fee;
            if (_status() == CurveStatus.Completed) completionsWithFailedMigration++;
            else graduations++;
        }
        _trackStatus();
    }

    function _trackStatus() private {
        uint8 s = uint8(_status());
        if (s < ghostMaxStatus) ghostStatusRegressed = true;
        if (s > ghostMaxStatus) ghostMaxStatus = s;
    }

    function _status() private view returns (CurveStatus) {
        return curve.state().status;
    }
}
