// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VRFTestBase} from "../utils/VRFTestBase.sol";
import {VRFVerifier} from "../../src/VRFVerifier.sol";
import {VRFCoordinator} from "../../src/VRFCoordinator.sol";
import {Subscription} from "../../src/Subscription.sol";
import {MockConsumer} from "../mocks/Consumers.sol";

/// @notice What an outage leaves behind, and who can clear it.
///
/// @dev A request nobody fulfils is not a lost transaction — it holds a
///      reservation, and the reservation holds the account. The live testnet
///      fleet ran out of gas money once and left 341 of them; the subscription
///      then refused new requests with `InsufficientBalance` while its balance
///      sat untouched, because available means balance minus reserved. Nothing
///      was broken, and the account was unusable all the same.
///
///      The way out has to be open to everyone, because the party who most
///      wants it cleared — the account owner — is exactly the party a
///      permissioned version would let hold requests hostage.
contract StarvationTest is VRFTestBase {
    VRFVerifier internal verifier;
    VRFCoordinator internal coordinator;
    Subscription internal subs;
    MockConsumer internal consumer;

    uint96 internal constant BASE_FEE = 0.001 ether;

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");
    uint256 internal subId;

    function setUp() public {
        _loadVectors();
        verifier = new VRFVerifier(groupPubKey, 1);
        coordinator = new VRFCoordinator(
            address(verifier), BASE_FEE, 0, 0, type(uint96).max, type(uint96).max, type(uint96).max
        );
        subs = Subscription(coordinator.subscriptions());
        consumer = new MockConsumer(address(coordinator));

        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
        subId = subs.createSubscription();
        subs.fundSubscription{value: 0.003 ether}(subId);
        subs.addConsumer(subId, address(consumer));
        vm.stopPrank();

        vm.roll(1_000_000);
    }

    /// The shape the outage took: the balance is fine, and the account still
    /// refuses work, because every unfulfilled request is still holding its
    /// share of it.
    function test_unfulfilled_requests_starve_an_account_that_still_has_money() public {
        consumer.request(subId, 1);
        consumer.request(subId, 1);
        consumer.request(subId, 1);

        (uint96 balance, uint96 reserved) = subs.accountOf(subId);
        assertEq(balance, 0.003 ether, "the money went somewhere");
        assertEq(reserved, 0.003 ether, "the requests reserved nothing");
        assertEq(subs.availableOf(subId), 0, "available did not account for the reservations");

        vm.expectRevert(Subscription.InsufficientBalance.selector);
        consumer.request(subId, 1);
    }

    /// And it cannot be escaped by closing the account: an owner who could
    /// cancel out from under open requests would be walking away mid-work.
    function test_a_starved_account_cannot_be_closed_to_escape_it() public {
        consumer.request(subId, 1);

        vm.expectRevert(Subscription.FundsReserved.selector);
        vm.prank(owner);
        subs.cancelSubscription(subId, owner);
    }

    /// The way out, and it belongs to nobody in particular. A stranger clears
    /// the request once the timeout has run, the reservation goes back, and the
    /// account works again.
    function test_anyone_can_clear_a_stranded_request_once_the_timeout_has_run() public {
        uint256 requestId = consumer.request(subId, 1);
        assertEq(subs.availableOf(subId), 0.002 ether);

        vm.expectRevert(VRFCoordinator.TooEarly.selector);
        vm.prank(stranger);
        coordinator.refund(requestId);

        vm.roll(block.number + coordinator.TIMEOUT_BLOCKS() + 1);
        vm.prank(stranger);
        coordinator.refund(requestId);

        assertEq(subs.availableOf(subId), 0.003 ether, "the reservation was not released");

        vm.prank(owner);
        subs.cancelSubscription(subId, owner);
        assertEq(owner.balance, 10 ether, "the owner did not get the money back");
    }

    /// Refunding is not a second way to spend: a request cleared this way pays
    /// nobody, and cannot afterwards be fulfilled by a late signature.
    function test_a_refunded_request_pays_nobody_and_cannot_be_fulfilled_late() public {
        uint256 requestId = consumer.request(subId, 1);
        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);

        vm.roll(block.number + coordinator.TIMEOUT_BLOCKS() + 1);
        vm.prank(stranger);
        coordinator.refund(requestId);

        assertEq(subs.withdrawableOf(stranger), 0, "clearing a request paid the caller");

        vm.expectRevert(VRFCoordinator.RequestClosed.selector);
        coordinator.fulfillRandomWords(requestId, sig);
    }

    /// Removing a consumer stops it making new requests and does not touch the
    /// ones already in flight — otherwise an owner could strand work that has
    /// already been paid for and is already being signed.
    function test_removing_a_consumer_does_not_strand_its_open_request() public {
        uint256 requestId = consumer.request(subId, 1);

        vm.prank(owner);
        subs.removeConsumer(subId, address(consumer));

        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);
        coordinator.fulfillRandomWords(requestId, sig);

        (,,,, bool fulfilled,, bool delivered) = coordinator.requests(requestId);
        assertTrue(fulfilled, "an in-flight request died with the consumer's authorisation");
        assertTrue(delivered);
    }
}
