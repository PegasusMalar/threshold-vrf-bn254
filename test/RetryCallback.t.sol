// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Test.sol";
import {VRFTestBase} from "./utils/VRFTestBase.sol";
import {VRFVerifier} from "../src/VRFVerifier.sol";
import {VRFCoordinator} from "../src/VRFCoordinator.sol";
import {Subscription} from "../src/Subscription.sol";
import {MockConsumer, FlakyConsumer, RetryReentrantConsumer} from "./mocks/Consumers.sol";

/// @notice A failed callback used to strand a request forever: the money was
///         spent, the randomness was delivered to nobody, and `refund` is
///         refused because the request is fulfilled. `retryCallback` is the way
///         out, and it must not become a way to deliver twice.
contract RetryCallbackTest is VRFTestBase {
    /// The callback budget every mock consumer asks for.
    uint32 internal constant DEFAULT_CALLBACK_GAS = 500_000;

    uint96 internal constant BASE_FEE = 0.0001 ether;
    uint96 internal constant PER_WORD_FEE = 0.00001 ether;

    VRFVerifier internal verifier;
    VRFCoordinator internal coordinator;
    Subscription internal subs;
    FlakyConsumer internal consumer;

    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer");
    address internal helper = makeAddr("helper");
    uint256 internal subId;

    function setUp() public {
        _loadVectors();
        verifier = new VRFVerifier(groupPubKey, 1);
        coordinator = new VRFCoordinator(
            address(verifier),
            BASE_FEE,
            PER_WORD_FEE,
            0,
            type(uint96).max,
            type(uint96).max,
            type(uint96).max
        );
        subs = Subscription(coordinator.subscriptions());
        consumer = new FlakyConsumer(address(coordinator));

        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
        subId = subs.createSubscription();
        subs.fundSubscription{value: 1 ether}(subId);
        subs.addConsumer(subId, address(consumer));
        vm.stopPrank();

        vm.roll(1_000_000);
    }

    function _requestAndFailCallback(uint32 numWords)
        internal
        returns (uint256 requestId, bytes memory signature)
    {
        requestId = consumer.request(subId, numWords);
        signature = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);
        vm.prank(relayer);
        coordinator.fulfillRandomWords(requestId, signature);

        (,,,,, bool refunded, bool callbackSucceeded) = coordinator.requests(requestId);
        assertFalse(callbackSucceeded, "the callback was supposed to fail");
        assertFalse(refunded);
        assertEq(consumer.deliveries(), 0);
    }

    /* ------------------------------ the fix ------------------------------- */

    function test_retry_delivers_the_words_after_the_consumer_is_fixed() public {
        (uint256 requestId, bytes memory signature) = _requestAndFailCallback(3);

        consumer.fix();
        vm.prank(helper);
        coordinator.retryCallback(requestId, signature);

        assertEq(consumer.deliveries(), 1);
        assertEq(consumer.lastRequestId(), requestId);
        assertEq(consumer.wordsLength(), 3);

        (,,,,,, bool callbackSucceeded) = coordinator.requests(requestId);
        assertTrue(callbackSucceeded);
    }

    /// The retry must produce exactly the words the first attempt would have.
    function test_retry_delivers_the_same_words_the_first_attempt_carried() public {
        (uint256 requestId, bytes memory signature) = _requestAndFailCallback(4);
        consumer.fix();
        coordinator.retryCallback(requestId, signature);

        bytes32 randomness = keccak256(signature);
        for (uint32 i = 0; i < 4; i++) {
            assertEq(
                consumer.lastWords(i),
                uint256(keccak256(abi.encodePacked(randomness, requestId, i)))
            );
        }
    }

    function test_retry_is_permissionless() public {
        (uint256 requestId, bytes memory signature) = _requestAndFailCallback(1);
        consumer.fix();

        vm.prank(makeAddr("a stranger"));
        coordinator.retryCallback(requestId, signature);
        assertEq(consumer.deliveries(), 1);
    }

    function test_retry_does_not_charge_the_subscription_again() public {
        (uint256 requestId, bytes memory signature) = _requestAndFailCallback(1);
        (uint96 balanceBefore, uint96 reservedBefore) = subs.accountOf(subId);
        uint96 relayerBefore = subs.withdrawableOf(relayer);

        consumer.fix();
        vm.prank(helper);
        coordinator.retryCallback(requestId, signature);

        (uint96 balanceAfter, uint96 reservedAfter) = subs.accountOf(subId);
        assertEq(balanceAfter, balanceBefore, "the subscription paid twice");
        assertEq(reservedAfter, reservedBefore);
        assertEq(subs.withdrawableOf(relayer), relayerBefore);
        assertEq(subs.withdrawableOf(helper), 0, "the retrier must not be paid");
    }

    /* ------------------------------ the limits ---------------------------- */

    /// The one thing a retry must never become: a second delivery.
    function test_retry_rejected_once_the_callback_has_succeeded() public {
        MockConsumer working = new MockConsumer(address(coordinator));
        vm.prank(owner);
        subs.addConsumer(subId, address(working));

        uint256 requestId = working.request(subId, 1);
        bytes memory signature = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);
        coordinator.fulfillRandomWords(requestId, signature);
        assertEq(working.callbackCount(), 1);

        vm.expectRevert(VRFCoordinator.CallbackAlreadyDelivered.selector);
        coordinator.retryCallback(requestId, signature);
        assertEq(working.callbackCount(), 1);
    }

    function test_retry_rejected_for_a_request_that_was_never_fulfilled() public {
        uint256 requestId = consumer.request(subId, 1);
        bytes memory signature = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);

        vm.expectRevert(VRFCoordinator.NotFulfilled.selector);
        coordinator.retryCallback(requestId, signature);
    }

    function test_retry_rejected_for_a_refunded_request() public {
        uint256 requestId = consumer.request(subId, 1);
        bytes memory signature = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);
        vm.roll(block.number + coordinator.TIMEOUT_BLOCKS() + 1);
        coordinator.refund(requestId);

        vm.expectRevert(VRFCoordinator.NotFulfilled.selector);
        coordinator.retryCallback(requestId, signature);
    }

    function test_retry_rejected_for_an_unknown_request() public {
        vm.expectRevert(VRFCoordinator.NoSuchRequest.selector);
        coordinator.retryCallback(4242, abi.encodePacked(uint256(1), uint256(2)));
    }

    /// Without re-verifying, anyone could hand the consumer whatever words they
    /// liked under the guise of a retry.
    function test_retry_rejects_a_signature_that_does_not_verify() public {
        (uint256 requestId,) = _requestAndFailCallback(1);
        consumer.fix();

        vm.expectRevert(VRFCoordinator.InvalidProof.selector);
        coordinator.retryCallback(requestId, abi.encodePacked(uint256(1), uint256(2)));

        bytes memory otherKey = _sign(verifier, coordinator.seedOf(requestId), otherEpochSecretKey);
        vm.expectRevert(VRFCoordinator.InvalidProof.selector);
        coordinator.retryCallback(requestId, otherKey);

        assertEq(consumer.deliveries(), 0);
    }

    /// A signature for a different request must not be usable here either.
    function test_retry_rejects_a_signature_for_another_request() public {
        (uint256 requestId,) = _requestAndFailCallback(1);
        uint256 other = consumer.request(subId, 1);
        bytes memory otherSignature = _sign(verifier, coordinator.seedOf(other), groupSecretKey);
        consumer.fix();

        vm.expectRevert(VRFCoordinator.InvalidProof.selector);
        coordinator.retryCallback(requestId, otherSignature);
    }

    function test_retry_without_enough_gas_for_the_callback_reverts() public {
        (uint256 requestId, bytes memory signature) = _requestAndFailCallback(1);
        consumer.fix();

        vm.expectRevert(VRFCoordinator.InsufficientGas.selector);
        coordinator.retryCallback{gas: 400_000}(requestId, signature);

        (,,,,,, bool callbackSucceeded) = coordinator.requests(requestId);
        assertFalse(callbackSucceeded, "a starved retry must leave the request retryable");
    }

    /// A retry that fails again changes nothing, so it can be tried once more.
    function test_a_failed_retry_leaves_the_request_retryable() public {
        (uint256 requestId, bytes memory signature) = _requestAndFailCallback(1);

        coordinator.retryCallback(requestId, signature); // still broken
        (,,,,,, bool callbackSucceeded) = coordinator.requests(requestId);
        assertFalse(callbackSucceeded);
        assertEq(consumer.deliveries(), 0);

        consumer.fix();
        coordinator.retryCallback(requestId, signature);
        assertEq(consumer.deliveries(), 1);
    }

    /// What the "retry delivery" button costs whoever presses it.
    function test_gas_retry() public {
        (uint256 requestId, bytes memory signature) = _requestAndFailCallback(1);
        consumer.fix();

        uint256 before = gasleft();
        coordinator.retryCallback(requestId, signature);
        console.log("retryCallback (1 word, storing consumer):", before - gasleft());
    }

    function test_reentrancy_on_retry() public {
        RetryReentrantConsumer attacker = new RetryReentrantConsumer(address(coordinator));
        vm.prank(owner);
        subs.addConsumer(subId, address(attacker));

        uint256 requestId = attacker.request(subId, 1);
        bytes memory signature = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);
        vm.prank(relayer);
        coordinator.fulfillRandomWords(requestId, signature);

        (uint96 balanceBefore,) = subs.accountOf(subId);
        attacker.arm(signature);
        coordinator.retryCallback(requestId, signature);

        (,,,,,, bool callbackSucceeded) = coordinator.requests(requestId);
        assertTrue(callbackSucceeded);

        (uint96 balanceAfter,) = subs.accountOf(subId);
        assertEq(balanceAfter, balanceBefore, "re-entering the retry moved money");
        assertEq(
            subs.withdrawableOf(relayer),
            coordinator.price(1, DEFAULT_CALLBACK_GAS),
            "the relayer was paid twice"
        );
    }
}
