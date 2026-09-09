// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Subscription} from "../src/Subscription.sol";

/// @notice The test contract itself plays the coordinator, since that is the
///         only address allowed to move reserved funds around.
contract SubscriptionTest is Test {
    Subscription internal subs;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal consumer = makeAddr("consumer");
    address internal relayer = makeAddr("relayer");

    function setUp() public {
        subs = new Subscription(address(this));
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _funded(uint96 amount) internal returns (uint256 subId) {
        vm.prank(alice);
        subId = subs.createSubscription();
        vm.prank(alice);
        subs.fundSubscription{value: amount}(subId);
    }

    /* ----------------------------- lifecycle ----------------------------- */

    function test_create_assigns_sequential_ids_and_records_owner() public {
        vm.prank(alice);
        uint256 a = subs.createSubscription();
        vm.prank(bob);
        uint256 b = subs.createSubscription();

        assertEq(a, 1);
        assertEq(b, 2);
        assertEq(subs.ownerOf(a), alice);
        assertEq(subs.ownerOf(b), bob);
    }

    function test_anyone_can_fund_someone_elses_subscription() public {
        uint256 subId = _funded(1 ether);
        vm.prank(bob);
        subs.fundSubscription{value: 2 ether}(subId);

        (uint96 balance,) = subs.accountOf(subId);
        assertEq(balance, 3 ether);
        assertEq(address(subs).balance, 3 ether);
    }

    function test_funding_an_unknown_subscription_reverts() public {
        vm.expectRevert(Subscription.NoSuchSubscription.selector);
        vm.prank(alice);
        subs.fundSubscription{value: 1 ether}(999);
    }

    function test_only_owner_manages_consumers() public {
        uint256 subId = _funded(1 ether);

        vm.expectRevert(Subscription.NotSubscriptionOwner.selector);
        vm.prank(bob);
        subs.addConsumer(subId, consumer);

        vm.prank(alice);
        subs.addConsumer(subId, consumer);
        assertTrue(subs.isConsumer(subId, consumer));

        vm.expectRevert(Subscription.NotSubscriptionOwner.selector);
        vm.prank(bob);
        subs.removeConsumer(subId, consumer);

        vm.prank(alice);
        subs.removeConsumer(subId, consumer);
        assertFalse(subs.isConsumer(subId, consumer));
    }

    function test_cancel_returns_the_remainder_and_forgets_the_subscription() public {
        uint256 subId = _funded(5 ether);
        vm.prank(alice);
        subs.cancelSubscription(subId, bob);

        assertEq(bob.balance, 105 ether);
        assertEq(address(subs).balance, 0);
        assertEq(subs.ownerOf(subId), address(0));
    }

    function test_only_owner_cancels() public {
        uint256 subId = _funded(5 ether);
        vm.expectRevert(Subscription.NotSubscriptionOwner.selector);
        vm.prank(bob);
        subs.cancelSubscription(subId, bob);
    }

    /* --------------------------- reservations ---------------------------- */

    function test_reserve_locks_funds_against_withdrawal() public {
        uint256 subId = _funded(1 ether);
        subs.reserve(subId, 0.4 ether);

        (uint96 balance, uint96 reserved) = subs.accountOf(subId);
        assertEq(balance, 1 ether);
        assertEq(reserved, 0.4 ether);
    }

    /// Without this, the owner drains the balance between request and fulfillment
    /// and the operators work for free.
    function test_cannot_cancel_a_subscription_with_funds_reserved() public {
        uint256 subId = _funded(1 ether);
        subs.reserve(subId, 0.4 ether);

        vm.expectRevert(Subscription.FundsReserved.selector);
        vm.prank(alice);
        subs.cancelSubscription(subId, alice);
    }

    function test_reserve_beyond_the_free_balance_reverts() public {
        uint256 subId = _funded(1 ether);
        subs.reserve(subId, 0.6 ether);

        vm.expectRevert(Subscription.InsufficientBalance.selector);
        subs.reserve(subId, 0.5 ether);
    }

    function test_release_unlocks_without_spending() public {
        uint256 subId = _funded(1 ether);
        subs.reserve(subId, 0.4 ether);
        subs.release(subId, 0.4 ether);

        (uint96 balance, uint96 reserved) = subs.accountOf(subId);
        assertEq(balance, 1 ether);
        assertEq(reserved, 0);
    }

    function test_settle_spends_the_reservation_and_credits_the_payee() public {
        uint256 subId = _funded(1 ether);
        subs.reserve(subId, 0.4 ether);
        subs.settle(subId, 0.4 ether, relayer);

        (uint96 balance, uint96 reserved) = subs.accountOf(subId);
        assertEq(balance, 0.6 ether);
        assertEq(reserved, 0);
        assertEq(subs.withdrawableOf(relayer), 0.4 ether);
        assertEq(address(subs).balance, 1 ether, "funds stay put until withdrawn");
    }

    function test_withdraw_pays_out_once() public {
        uint256 subId = _funded(1 ether);
        subs.reserve(subId, 0.4 ether);
        subs.settle(subId, 0.4 ether, relayer);

        vm.prank(relayer);
        subs.withdraw(relayer);
        assertEq(relayer.balance, 0.4 ether);
        assertEq(subs.withdrawableOf(relayer), 0);

        vm.expectRevert(Subscription.NothingToWithdraw.selector);
        vm.prank(relayer);
        subs.withdraw(relayer);
    }

    function test_only_the_coordinator_moves_money() public {
        uint256 subId = _funded(1 ether);

        vm.startPrank(alice);
        vm.expectRevert(Subscription.NotCoordinator.selector);
        subs.reserve(subId, 1);
        vm.expectRevert(Subscription.NotCoordinator.selector);
        subs.release(subId, 1);
        vm.expectRevert(Subscription.NotCoordinator.selector);
        subs.settle(subId, 1, alice);
        vm.stopPrank();
    }

    /* --------------------------- partial withdrawal ---------------------- */

    /// The thing Chainlink has no answer for: there, the only way to get money
    /// back is `cancelSubscription`, which closes the account and invalidates
    /// the id every integration was deployed against. Top up generously, use
    /// what you use, take the rest back — and keep the id.
    function test_part_of_the_deposit_can_be_taken_back_without_closing() public {
        uint256 subId = _funded(5 ether);

        vm.prank(alice);
        subs.withdrawFromSubscription(subId, 2 ether, bob);

        (uint96 balance,) = subs.accountOf(subId);
        assertEq(balance, 3 ether);
        assertEq(bob.balance, 102 ether);
        assertEq(subs.ownerOf(subId), alice, "the account must survive a withdrawal");
    }

    /// What is locked behind open requests is not yours to take yet.
    function test_a_withdrawal_cannot_touch_what_is_reserved() public {
        uint256 subId = _funded(1 ether);
        subs.reserve(subId, 0.4 ether);

        vm.expectRevert(Subscription.InsufficientBalance.selector);
        vm.prank(alice);
        subs.withdrawFromSubscription(subId, 0.7 ether, alice);

        // exactly the free part is fine
        vm.prank(alice);
        subs.withdrawFromSubscription(subId, 0.6 ether, alice);

        (uint96 balance, uint96 reserved) = subs.accountOf(subId);
        assertEq(balance, 0.4 ether);
        assertEq(reserved, 0.4 ether);
        assertEq(subs.availableOf(subId), 0);
    }

    function test_only_the_owner_withdraws() public {
        uint256 subId = _funded(1 ether);
        vm.expectRevert(Subscription.NotSubscriptionOwner.selector);
        vm.prank(bob);
        subs.withdrawFromSubscription(subId, 1, bob);
    }

    function test_a_withdrawal_leaves_the_account_usable() public {
        uint256 subId = _funded(1 ether);
        vm.prank(alice);
        subs.addConsumer(subId, consumer);
        vm.prank(alice);
        subs.withdrawFromSubscription(subId, 0.9 ether, alice);

        // still funded enough for a request, still the same id and consumers
        subs.reserve(subId, 0.05 ether);
        assertTrue(subs.isConsumer(subId, consumer));
        (,,,, address[] memory list) = subs.getSubscription(subId);
        assertEq(list.length, 1);
    }

    /* --------------------------- ownership ------------------------------- */

    /// Two steps on purpose. A one-step transfer to a mistyped address destroys
    /// the subscription, its balance and every integration pointed at it, with
    /// no way back.
    function test_ownership_transfer_takes_two_steps() public {
        uint256 subId = _funded(1 ether);

        vm.prank(alice);
        subs.requestSubscriptionOwnerTransfer(subId, bob);
        assertEq(subs.ownerOf(subId), alice, "ownership moved before it was accepted");
        assertEq(subs.pendingOwnerOf(subId), bob);

        vm.prank(bob);
        subs.acceptSubscriptionOwnerTransfer(subId);
        assertEq(subs.ownerOf(subId), bob);
        assertEq(subs.pendingOwnerOf(subId), address(0));
    }

    function test_only_the_owner_can_offer_the_subscription() public {
        uint256 subId = _funded(1 ether);
        vm.expectRevert(Subscription.NotSubscriptionOwner.selector);
        vm.prank(bob);
        subs.requestSubscriptionOwnerTransfer(subId, bob);
    }

    function test_only_the_named_successor_can_accept() public {
        uint256 subId = _funded(1 ether);
        vm.prank(alice);
        subs.requestSubscriptionOwnerTransfer(subId, bob);

        vm.expectRevert(Subscription.NotPendingOwner.selector);
        vm.prank(consumer);
        subs.acceptSubscriptionOwnerTransfer(subId);

        vm.expectRevert(Subscription.NotPendingOwner.selector);
        vm.prank(alice);
        subs.acceptSubscriptionOwnerTransfer(subId);

        assertEq(subs.ownerOf(subId), alice);
    }

    function test_accepting_without_an_offer_reverts() public {
        uint256 subId = _funded(1 ether);
        vm.expectRevert(Subscription.NotPendingOwner.selector);
        vm.prank(bob);
        subs.acceptSubscriptionOwnerTransfer(subId);
    }

    function test_an_offer_can_be_withdrawn_or_redirected() public {
        uint256 subId = _funded(1 ether);

        vm.prank(alice);
        subs.requestSubscriptionOwnerTransfer(subId, bob);
        vm.prank(alice);
        subs.requestSubscriptionOwnerTransfer(subId, consumer);
        assertEq(subs.pendingOwnerOf(subId), consumer);

        vm.expectRevert(Subscription.NotPendingOwner.selector);
        vm.prank(bob);
        subs.acceptSubscriptionOwnerTransfer(subId);

        vm.prank(alice);
        subs.requestSubscriptionOwnerTransfer(subId, address(0));
        assertEq(subs.pendingOwnerOf(subId), address(0));

        vm.expectRevert(Subscription.NotPendingOwner.selector);
        vm.prank(consumer);
        subs.acceptSubscriptionOwnerTransfer(subId);
    }

    function test_the_new_owner_takes_over_and_the_old_one_loses_control() public {
        uint256 subId = _funded(1 ether);
        vm.prank(alice);
        subs.addConsumer(subId, consumer);
        vm.prank(alice);
        subs.requestSubscriptionOwnerTransfer(subId, bob);
        vm.prank(bob);
        subs.acceptSubscriptionOwnerTransfer(subId);

        vm.expectRevert(Subscription.NotSubscriptionOwner.selector);
        vm.prank(alice);
        subs.removeConsumer(subId, consumer);

        vm.prank(bob);
        subs.removeConsumer(subId, consumer);
        assertFalse(subs.isConsumer(subId, consumer));

        // and the balance travels with it
        vm.prank(bob);
        subs.cancelSubscription(subId, bob);
        assertEq(bob.balance, 101 ether);
    }

    /// A pending offer on a cancelled subscription must not be acceptable
    /// afterwards: that would resurrect a dead subscription under a new owner.
    function test_cancelling_clears_a_pending_offer() public {
        uint256 subId = _funded(1 ether);
        vm.prank(alice);
        subs.requestSubscriptionOwnerTransfer(subId, bob);
        vm.prank(alice);
        subs.cancelSubscription(subId, alice);

        assertEq(subs.pendingOwnerOf(subId), address(0));
        vm.expectRevert(Subscription.NotPendingOwner.selector);
        vm.prank(bob);
        subs.acceptSubscriptionOwnerTransfer(subId);
        assertEq(subs.ownerOf(subId), address(0));
    }

    function test_offering_an_unknown_subscription_reverts() public {
        vm.expectRevert(Subscription.NotSubscriptionOwner.selector);
        vm.prank(alice);
        subs.requestSubscriptionOwnerTransfer(999, bob);
    }

    /// Transferring while requests are open is fine — the reservation belongs to
    /// the subscription, not to whoever happens to own it.
    function test_ownership_can_change_while_funds_are_reserved() public {
        uint256 subId = _funded(1 ether);
        subs.reserve(subId, 0.4 ether);

        vm.prank(alice);
        subs.requestSubscriptionOwnerTransfer(subId, bob);
        vm.prank(bob);
        subs.acceptSubscriptionOwnerTransfer(subId);

        (uint96 balance, uint96 reserved) = subs.accountOf(subId);
        assertEq(balance, 1 ether);
        assertEq(reserved, 0.4 ether);

        vm.expectRevert(Subscription.FundsReserved.selector);
        vm.prank(bob);
        subs.cancelSubscription(subId, bob);
    }

    /* ------------------------------- fuzz -------------------------------- */

    function testFuzz_no_overflow_in_billing(uint96 funding, uint96 price, uint8 rounds) public {
        vm.assume(funding > 0);
        rounds = uint8(bound(rounds, 1, 20));
        vm.deal(alice, funding);

        uint256 subId = _funded(funding);
        uint96 spent = 0;
        for (uint256 i = 0; i < rounds; i++) {
            (uint96 balance, uint96 reserved) = subs.accountOf(subId);
            if (price > balance - reserved) break;
            subs.reserve(subId, price);
            subs.settle(subId, price, relayer);
            spent += price;
        }

        (uint96 finalBalance, uint96 finalReserved) = subs.accountOf(subId);
        assertEq(finalBalance, funding - spent);
        assertEq(finalReserved, 0);
        assertEq(subs.withdrawableOf(relayer), spent);
        assertLe(finalReserved, finalBalance);
    }

    function testFuzz_reserved_never_exceeds_balance(uint96 funding, uint96 toReserve) public {
        vm.assume(funding > 0);
        vm.deal(alice, funding);
        uint256 subId = _funded(funding);

        if (toReserve > funding) {
            vm.expectRevert(Subscription.InsufficientBalance.selector);
            subs.reserve(subId, toReserve);
        } else {
            subs.reserve(subId, toReserve);
        }

        (uint96 balance, uint96 reserved) = subs.accountOf(subId);
        assertLe(reserved, balance);
    }
}
