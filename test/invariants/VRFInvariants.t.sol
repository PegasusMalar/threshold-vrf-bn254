// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {VRFTestBase} from "../utils/VRFTestBase.sol";
import {VRFVerifier} from "../../src/VRFVerifier.sol";
import {VRFCoordinator} from "../../src/VRFCoordinator.sol";
import {Subscription} from "../../src/Subscription.sol";
import {VRFHandler} from "./VRFHandler.sol";

/// @notice TZ section 10.2 — the properties that must hold no matter what
///         sequence of requests, fulfilments, refunds and cancellations runs.
contract VRFInvariantsTest is StdInvariant, VRFTestBase {
    /// The callback budget every mock consumer asks for.
    uint32 internal constant DEFAULT_CALLBACK_GAS = 500_000;

    VRFVerifier internal verifier;
    VRFCoordinator internal coordinator;
    Subscription internal subs;
    VRFHandler internal handler;

    function setUp() public {
        _loadVectors();
        verifier = new VRFVerifier(groupPubKey, 1);
        coordinator = new VRFCoordinator(
            address(verifier), 0.0001 ether, 0.00001 ether, 0, 0.01 ether, 0.001 ether, 1 gwei
        );
        subs = Subscription(coordinator.subscriptions());
        handler = new VRFHandler(verifier, coordinator, groupSecretKey);
        // so the fuzzer can move the price under requests that are in flight
        coordinator.transferOwnership(address(handler));
        vm.prank(address(handler));
        coordinator.acceptOwnership();

        // rawFulfillRandomWords is the coordinator's entry point, not an action
        // the fuzzer should drive directly — calling it would only ever revert.
        bytes4[] memory selectors = new bytes4[](17);
        selectors[0] = VRFHandler.createSubscription.selector;
        selectors[1] = VRFHandler.fund.selector;
        selectors[2] = VRFHandler.request.selector;
        selectors[3] = VRFHandler.fulfill.selector;
        selectors[4] = VRFHandler.fulfillWithForeignSignature.selector;
        selectors[5] = VRFHandler.refundRequest.selector;
        selectors[6] = VRFHandler.cancel.selector;
        selectors[7] = VRFHandler.advanceBlocks.selector;
        selectors[8] = VRFHandler.withdrawFees.selector;
        selectors[9] = VRFHandler.retryFailedCallback.selector;
        selectors[10] = VRFHandler.setRefuseDeliveries.selector;
        selectors[11] = VRFHandler.offerSubscription.selector;
        selectors[12] = VRFHandler.acceptAsSuccessor.selector;
        selectors[13] = VRFHandler.reclaimSubscription.selector;
        selectors[14] = VRFHandler.proposeFees.selector;
        selectors[15] = VRFHandler.applyFees.selector;
        selectors[16] = VRFHandler.withdrawFromSubscription.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// Guards against the whole invariant suite being vacuously true: if the
    /// handler could never actually fulfil anything, every property below would
    /// hold for the boring reason.
    function test_handler_can_actually_reach_fulfillment() public {
        handler.createSubscription(1 ether);
        handler.request(0, 3);
        handler.fulfill(0);

        assertEq(handler.totalFulfilled(), 1);
        assertEq(handler.deliveries(handler.requestIds(0)), 1);

        // and the retry path is reachable: refuse a delivery, then take it
        handler.setRefuseDeliveries(true);
        handler.request(0, 1);
        handler.fulfill(1);
        assertEq(handler.deliveries(handler.requestIds(1)), 0, "the refusal did not take");
        handler.setRefuseDeliveries(false);
        handler.retryFailedCallback(1);
        assertEq(handler.totalRetried(), 1, "the retry did not go through");
        assertEq(handler.deliveries(handler.requestIds(1)), 1);

        // and a fee change really does reach requests that are already in flight
        handler.request(0, 1);
        uint256 inFlight = handler.requestIds(2);
        uint96 quoted = coordinator.priceOf(inFlight);
        handler.proposeFees(type(uint96).max, type(uint96).max); // bounded to the cap inside
        vm.roll(block.number + coordinator.FEE_TIMELOCK_BLOCKS());
        handler.applyFees();
        assertGt(coordinator.price(1, DEFAULT_CALLBACK_GAS), quoted, "the fee change did not take");
        assertEq(coordinator.priceOf(inFlight), quoted, "an in-flight request was repriced");
        handler.fulfill(2);
        assertEq(handler.deliveries(inFlight), 1, "the repriced request was not delivered");

        // and ownership can move and come back
        handler.offerSubscription(0);
        handler.acceptAsSuccessor(0);
        assertEq(subs.ownerOf(handler.subIds(0)), handler.successor());
        handler.reclaimSubscription(0);
        assertEq(subs.ownerOf(handler.subIds(0)), address(handler));

        handler.request(0, 2);
        handler.advanceBlocks(10_000);
        handler.refundRequest(3);
        assertEq(handler.totalRefunded(), 1, "the refund path is unreachable");
    }

    function invariant_request_fulfilled_at_most_once() public view {
        assertFalse(handler.sawDuplicateDelivery(), "a request was delivered twice");
    }

    function invariant_randomness_deterministic_for_seed() public view {
        assertFalse(handler.sawInconsistentWords(), "same request produced different words");
    }

    function invariant_refunded_xor_fulfilled() public view {
        uint256 count = handler.requestCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 requestId = handler.requestIds(i);
            (,,,, bool fulfilled, bool refunded,) = coordinator.requests(requestId);
            assertFalse(fulfilled && refunded, "request both fulfilled and refunded");
        }
    }

    function invariant_reserved_never_exceeds_balance() public view {
        uint256 count = handler.subCount();
        for (uint256 i = 0; i < count; i++) {
            (uint96 balance, uint96 reserved) = subs.accountOf(handler.subIds(i));
            assertLe(reserved, balance, "reserved exceeds balance");
        }
    }

    /// Every wei the contract holds is accounted for by exactly one claim on it.
    function invariant_contract_balance_covers_all_claims() public view {
        uint256 owed = subs.withdrawableOf(address(handler));
        uint256 count = handler.subCount();
        for (uint256 i = 0; i < count; i++) {
            (uint96 balance,) = subs.accountOf(handler.subIds(i));
            owed += balance;
        }
        assertEq(address(subs).balance, owed, "subscription balance does not match its books");
    }

    /// Reservations are never stranded: an open request holds exactly its price,
    /// a closed one holds nothing.
    function invariant_reserved_matches_open_requests() public view {
        uint256 count = handler.requestCount();
        uint256 subCount = handler.subCount();

        for (uint256 s = 0; s < subCount; s++) {
            uint256 subId = handler.subIds(s);
            if (subs.ownerOf(subId) == address(0)) continue;

            uint256 expected = 0;
            for (uint256 i = 0; i < count; i++) {
                uint256 requestId = handler.requestIds(i);
                (, uint256 reqSub,,, bool fulfilled, bool refunded,) =
                    coordinator.requests(requestId);
                // priceOf, not price(): what this request was quoted, which is
                // exactly the thing recording it was meant to protect
                if (reqSub == subId && !fulfilled && !refunded) {
                    expected += coordinator.priceOf(requestId);
                }
            }
            (, uint96 reserved) = subs.accountOf(subId);
            assertEq(reserved, expected, "reservations drifted from open requests");
        }
    }

    /// A retried callback must never become a second delivery, and a request
    /// cannot report a successful callback it never had.
    function invariant_callback_success_implies_fulfilment() public view {
        uint256 count = handler.requestCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 requestId = handler.requestIds(i);
            (,,,, bool fulfilled,, bool callbackSucceeded) = coordinator.requests(requestId);
            if (callbackSucceeded) {
                assertTrue(fulfilled, "callback succeeded on an unfulfilled request");
            }
            assertLe(handler.deliveries(requestId), 1, "words were delivered twice");
        }
    }

    /// Ownership only ever sits with the handler or its successor, and a live
    /// subscription is never ownerless.
    function invariant_subscription_ownership_is_never_lost() public view {
        uint256 count = handler.subCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 subId = handler.subIds(i);
            address owner = subs.ownerOf(subId);
            if (owner == address(0)) {
                // cancelled: nothing may be left dangling behind it
                assertEq(
                    subs.pendingOwnerOf(subId),
                    address(0),
                    "a cancelled subscription is still on offer"
                );
                continue;
            }
            assertTrue(
                owner == address(handler) || owner == handler.successor(),
                "ownership escaped to a third party"
            );
        }
    }

    /// The one fee promise an integrator takes on trust, checked against every
    /// sequence the fuzzer can produce.
    function invariant_price_never_exceeds_the_cap() public view {
        assertLe(coordinator.baseFee(), coordinator.maxBaseFee());
        assertLe(coordinator.perWordFee(), coordinator.maxPerWordFee());
        assertLe(coordinator.pendingBaseFee(), coordinator.maxBaseFee());
        assertLe(coordinator.pendingPerWordFee(), coordinator.maxPerWordFee());
    }

    function invariant_coordinator_holds_no_funds() public view {
        assertEq(address(coordinator).balance, 0);
    }
}
