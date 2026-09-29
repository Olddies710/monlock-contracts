// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";

import {ILaunchToken} from "../src/interfaces/ILaunchToken.sol";
import {LaunchpadTest} from "./utils/LaunchpadTest.sol";
import {Presets} from "./utils/Presets.sol";

contract LaunchTokenTest is LaunchpadTest {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 internal constant ACCOUNTS_SLOT = 1; // `_accounts` (see `forge inspect LaunchToken storageLayout`)

    function setUp() public override {
        super.setUp();
        _rollPastSnipeWindow();
    }

    // ------------------------------------------------------------------ fair launch

    function test_metadataAndFixedSupplyMintedToCurve() public view {
        assertEq(token.name(), "Monad Cat");
        assertEq(token.symbol(), "MCAT");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), Presets.TOTAL_SUPPLY);
        assertEq(token.balanceOf(address(curve)), Presets.TOTAL_SUPPLY, "whole supply on the curve");
        assertEq(token.curve(), address(curve));
        assertEq(token.factory(), address(harness));
    }

    function test_constructor_rejectsNamesLongerThan31Bytes() public {
        vm.expectRevert(ILaunchToken.InvalidDeployParams.selector);
        harness.launch(
            Presets.defaultPreset(address(migrator)),
            "abcdefghijklmnopqrstuvwxyz012345", // 32 bytes
            "MCAT",
            creator,
            bytes32("long-name"),
            0
        );
    }

    // ------------------------------------------------------------------ allowances

    function test_curveHasImplicitNonRevocableAllowance() public {
        assertEq(token.allowance(alice, address(curve)), type(uint256).max);
        vm.prank(alice);
        token.approve(address(curve), 0);
        assertEq(token.allowance(alice, address(curve)), type(uint256).max, "cannot be revoked");
    }

    function test_permit2KeepsSoladyInfiniteAllowance() public view {
        assertEq(token.allowance(alice, PERMIT2), type(uint256).max);
    }

    function test_transferFrom_othersNeedAllowance() public {
        _buy(alice, 1 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(bob);
        vm.expectRevert(ERC20.InsufficientAllowance.selector);
        token.transferFrom(alice, bob, 1);

        vm.prank(alice);
        token.approve(bob, 100);
        vm.prank(bob);
        token.transferFrom(alice, bob, 60);
        assertEq(token.allowance(alice, bob), 40);
        assertEq(token.balanceOf(bob), 60);
    }

    function test_permit_setsAllowanceWithMonadDomain() public {
        (address owner, uint256 ownerKey) = makeAddrAndKey("permit-owner");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                bob,
                123,
                token.nonces(owner),
                deadline
            )
        );
        bytes32 expectedDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Monad Cat"),
                keccak256("1"),
                MONAD_CHAIN_ID,
                address(token)
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expectedDomain, "precomputed name hash matches");

        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ownerKey, keccak256(abi.encodePacked("\x19\x01", expectedDomain, structHash)));
        token.permit(owner, bob, 123, deadline, v, r, s);
        assertEq(token.allowance(owner, bob), 123);
        assertEq(token.nonces(owner), 1);
    }

    // ------------------------------------------------------------------ anti-sandwich round-trip guard (§5.4)

    function test_buyMarksRecipientWithCurrentBlock() public {
        assertEq(token.lastBuyBlock(alice), 0);
        _buy(alice, 1 ether);
        assertEq(token.lastBuyBlock(alice), vm.getBlockNumber());
    }

    function test_sameBlockSellToCurveReverts() public {
        uint256 bought = _buy(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(ILaunchToken.SameBlockRoundTrip.selector);
        curve.sell(bought, 0);
    }

    function test_sellInNextBlockSucceeds() public {
        uint256 bought = _buy(alice, 1 ether);
        vm.roll(vm.getBlockNumber() + 1);
        assertGt(_sell(alice, bought), 0);
    }

    function test_markPropagatesThroughSameBlockTransfers() public {
        uint256 bought = _buy(alice, 1 ether);
        vm.prank(alice);
        token.transfer(bob, bought);
        assertEq(token.lastBuyBlock(bob), vm.getBlockNumber(), "bob inherits the mark");

        vm.prank(bob);
        vm.expectRevert(ILaunchToken.SameBlockRoundTrip.selector);
        curve.sell(bought, 0);

        vm.roll(vm.getBlockNumber() + 1);
        assertGt(_sell(bob, bought), 0);
    }

    function test_transferInLaterBlockDoesNotMark() public {
        uint256 bought = _buy(alice, 1 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(alice);
        token.transfer(bob, bought);
        assertEq(token.lastBuyBlock(bob), 0);
        assertGt(_sell(bob, bought), 0, "bob can sell right away");
    }

    function test_plainTransfersBetweenMarkedAccountsStillWork() public {
        uint256 bought = _buy(alice, 1 ether);
        vm.prank(alice);
        token.transfer(bob, bought / 2);
        vm.prank(bob);
        token.transfer(carol, bought / 4);
        assertEq(token.balanceOf(carol), bought / 4);
    }

    // ------------------------------------------------------------------ zero-cost packing

    function test_markerLivesInTheBalanceSlot() public {
        uint256 bought = _buy(alice, 1 ether);
        bytes32 raw = vm.load(address(token), _accountSlot(alice));
        assertEq(uint256(raw) & ((1 << 216) - 1), bought, "low 216 bits: balance");
        assertEq(uint256(raw) >> 216, vm.getBlockNumber(), "high 40 bits: lastBuyBlock");
    }

    function test_transferWritesExactlyTwoSlots() public {
        uint256 bought = _buy(alice, 1 ether);
        vm.record();
        vm.prank(alice);
        token.transfer(bob, bought);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(token));
        _assertOnly(reads, _accountSlot(alice), _accountSlot(bob));
        _assertOnly(writes, _accountSlot(alice), _accountSlot(bob));
    }

    /// @dev A sell pulls with transferFrom but touches no allowance slot (implicit allowance, ADR-4).
    function test_sellTouchesNoAllowanceSlot() public {
        uint256 bought = _buy(alice, 1 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.record();
        _sell(alice, bought);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(token));
        _assertOnly(reads, _accountSlot(alice), _accountSlot(address(curve)));
        _assertOnly(writes, _accountSlot(alice), _accountSlot(address(curve)));
    }

    // ------------------------------------------------------------------ ERC-20 edge cases

    function test_burnReducesSupply() public {
        uint256 bought = _buy(alice, 1 ether);
        vm.prank(alice);
        token.burn(bought / 2);
        assertEq(token.totalSupply(), Presets.TOTAL_SUPPLY - bought / 2);
        assertEq(token.balanceOf(alice), bought - bought / 2);

        vm.prank(alice);
        vm.expectRevert(ERC20.InsufficientBalance.selector);
        token.burn(bought);
    }

    function test_transferMoreThanBalanceReverts() public {
        uint256 bought = _buy(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(ERC20.InsufficientBalance.selector);
        token.transfer(bob, bought + 1);
    }

    function test_selfTransferKeepsBalanceAndMark() public {
        uint256 bought = _buy(alice, 1 ether);
        vm.prank(alice);
        token.transfer(alice, bought);
        assertEq(token.balanceOf(alice), bought);
        assertEq(token.lastBuyBlock(alice), vm.getBlockNumber());
    }

    function testFuzz_transfersConserveSupply(uint256 amount, uint256 splitA, uint256 splitB, bool sameBlock) public {
        amount = bound(amount, 0.01 ether, 5 ether);
        uint256 bought = _buy(alice, amount);
        if (!sameBlock) vm.roll(vm.getBlockNumber() + 1);
        splitA = bound(splitA, 0, bought);
        vm.prank(alice);
        token.transfer(bob, splitA);
        splitB = bound(splitB, 0, splitA);
        vm.prank(bob);
        token.transfer(carol, splitB);

        assertEq(
            token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol) + token.balanceOf(address(curve)),
            token.totalSupply()
        );
        uint256 expectedMark = sameBlock ? vm.getBlockNumber() : 0;
        assertEq(token.lastBuyBlock(bob), splitA != 0 ? expectedMark : 0);
        assertEq(token.lastBuyBlock(carol), splitB != 0 ? expectedMark : 0, "zero-amount transfers never mark");
    }

    // ------------------------------------------------------------------ helpers

    function _accountSlot(address account) internal pure returns (bytes32) {
        return keccak256(abi.encode(account, ACCOUNTS_SLOT));
    }

    function _assertOnly(bytes32[] memory slots, bytes32 a, bytes32 b) internal pure {
        assertGt(slots.length, 0);
        for (uint256 i; i < slots.length; ++i) {
            assertTrue(slots[i] == a || slots[i] == b, "unexpected storage slot touched");
        }
    }
}
