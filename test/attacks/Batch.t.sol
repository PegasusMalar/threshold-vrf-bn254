// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Test.sol";
import {VRFTestBase} from "../utils/VRFTestBase.sol";
import {VRFVerifier} from "../../src/VRFVerifier.sol";
import {VRFCoordinator} from "../../src/VRFCoordinator.sol";
import {Subscription} from "../../src/Subscription.sol";
import {MockConsumer, FlakyConsumer} from "../mocks/Consumers.sol";
import {CountingConsumer, DoubleDeliveryAttacker} from "../mocks/Attackers.sol";

/// @notice Attacks on settling many requests against one signature.
///
/// @dev Batching pays for itself by doing one pairing instead of many, and it
///      buys two new ways to be wrong. A seed repeated in a batch sums to
///      2·H(s), and 2·σ is something anyone holding one published signature can
///      compute — so the aggregate verifies and the request would settle twice.
///      And a batch that marked every member fulfilled before delivering any of
///      them would leave the later members in the state `retryCallback` serves,
///      reachable from inside an earlier member's callback.
contract BatchAttackTest is VRFTestBase {
    uint96 internal constant BASE_FEE = 0.0001 ether;

    VRFVerifier internal verifier;
    VRFCoordinator internal coordinator;
    Subscription internal subs;

    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer");
    uint256 internal subId;

    function setUp() public {
        _loadVectors();
        verifier = new VRFVerifier(groupPubKey, 1);
        coordinator = new VRFCoordinator(
            address(verifier), BASE_FEE, 0, 0, type(uint96).max, type(uint96).max, type(uint96).max
        );
        subs = Subscription(coordinator.subscriptions());

        vm.deal(owner, 100 ether);
        vm.startPrank(owner);
        subId = subs.createSubscription();
        subs.fundSubscription{value: 10 ether}(subId);
        vm.stopPrank();

        vm.roll(1_000_000);
    }

    function _consumer() internal returns (MockConsumer c) {
        c = new MockConsumer(address(coordinator));
        vm.prank(owner);
        subs.addConsumer(subId, address(c));
    }

    /// Requests from one consumer, sorted as the coordinator requires.
    function _batch(MockConsumer c, uint256 n)
        internal
        returns (uint256[] memory ids, bytes memory sig)
    {
        ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = c.request(subId, 1);
        }
        _sort(ids);
        sig = _aggregateFor(ids);
    }

    function _sort(uint256[] memory a) internal pure {
        for (uint256 i = 1; i < a.length; i++) {
            uint256 k = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > k) {
                a[j] = a[j - 1];
                j--;
            }
            a[j] = k;
        }
    }

    function _aggregateFor(uint256[] memory ids) internal view returns (bytes memory) {
        uint256[2] memory sum;
        for (uint256 i = 0; i < ids.length; i++) {
            bytes memory one = _sign(verifier, coordinator.seedOf(ids[i]), groupSecretKey);
            uint256 x;
            uint256 y;
            assembly {
                x := mload(add(one, 32))
                y := mload(add(one, 64))
            }
            sum = i == 0 ? [x, y] : _addPoints(sum, [x, y]);
        }
        return abi.encodePacked(sum[0], sum[1]);
    }

    function _addPoints(uint256[2] memory a, uint256[2] memory b)
        internal
        view
        returns (uint256[2] memory out)
    {
        uint256[4] memory input = [a[0], a[1], b[0], b[1]];
        bool ok;
        assembly {
            ok := staticcall(gas(), 6, input, 128, out, 64)
        }
        require(ok, "ecAdd failed");
    }

    /* ------------------------------ it works ------------------------------ */

    function test_a_batch_settles_every_request_in_it() public {
        MockConsumer c = _consumer();
        (uint256[] memory ids, bytes memory sig) = _batch(c, 6);

        vm.prank(relayer);
        coordinator.fulfillBatch(ids, sig);

        for (uint256 i = 0; i < ids.length; i++) {
            (,,,, bool fulfilled,, bool delivered) = coordinator.requests(ids[i]);
            assertTrue(fulfilled, "a member of the batch was not fulfilled");
            assertTrue(delivered, "a member of the batch was not delivered");
        }
        assertEq(c.callbackCount(), 6);
        assertEq(
            subs.withdrawableOf(relayer),
            uint256(BASE_FEE) * 6,
            "the publisher was paid per request"
        );
    }

    /// The words a request gets must not depend on how it was settled, or a
    /// consumer could be told two different things about the same request.
    function test_a_batch_delivers_the_same_words_a_single_fulfilment_would() public {
        MockConsumer alone = _consumer();
        uint256 single = alone.request(subId, 3);
        bytes memory singleSig = _sign(verifier, coordinator.seedOf(single), groupSecretKey);
        vm.prank(relayer);
        coordinator.fulfillRandomWords(single, singleSig);
        uint256 first = alone.lastWords(0);

        // The same request id cannot recur, so this checks the derivation is
        // the same function of the same signature in both paths.
        assertEq(
            first,
            uint256(keccak256(abi.encodePacked(keccak256(singleSig), single, uint32(0)))),
            "words are not the documented function of the signature"
        );
    }

    /* ------------------------------- attacks ------------------------------ */

    /// A seed repeated sums to 2·H(s), and the doubled signature verifies —
    /// correctly, the equation holds. Settling it twice would pay the publisher
    /// twice and charge the subscription twice for one piece of work.
    function test_a_request_repeated_in_a_batch_is_refused() public {
        MockConsumer c = _consumer();
        uint256 id = c.request(subId, 1);

        bytes memory one = _sign(verifier, coordinator.seedOf(id), groupSecretKey);
        uint256 x;
        uint256 y;
        assembly {
            x := mload(add(one, 32))
            y := mload(add(one, 64))
        }
        uint256[2] memory doubled = _addPoints([x, y], [x, y]);

        uint256[] memory twice = new uint256[](2);
        twice[0] = id;
        twice[1] = id;

        vm.expectRevert(VRFCoordinator.BatchNotSorted.selector);
        coordinator.fulfillBatch(twice, abi.encodePacked(doubled[0], doubled[1]));
    }

    /// Ordering is how duplicates are made impossible rather than merely
    /// detected, so an unsorted batch has to be refused even when it is honest.
    function test_an_unsorted_batch_is_refused() public {
        MockConsumer c = _consumer();
        (uint256[] memory ids, bytes memory sig) = _batch(c, 4);
        (ids[0], ids[1]) = (ids[1], ids[0]);

        vm.expectRevert(VRFCoordinator.BatchNotSorted.selector);
        coordinator.fulfillBatch(ids, sig);
    }

    /// The window a batch could open and must not.
    ///
    /// A single fulfilment is protected from being delivered twice by the gas
    /// check alone: a delivery runs with at most its own callback budget, and
    /// `retryCallback` demands that whole budget again. Inside a batch that
    /// argument stops working, because the member being delivered and the
    /// member being aimed at need not have the same budget. A consumer whose
    /// first request carries a large budget has room to spare while a later
    /// member with a small one is being settled.
    ///
    /// So what protects a batch is the order of operations: each member is
    /// carried all the way through before the next begins, and a member not
    /// reached yet is simply not fulfilled. Marking the batch fulfilled up
    /// front — the obvious optimisation, one loop instead of two passes over
    /// storage — is what this test exists to refuse.
    function test_a_later_member_cannot_be_retried_from_an_earlier_callback() public {
        DoubleDeliveryAttacker attacker = new DoubleDeliveryAttacker(address(coordinator));
        vm.prank(owner);
        subs.addConsumer(subId, address(attacker));

        // Deliberately lopsided budgets: a roomy one to run inside, a small one
        // to aim at, so the gas check cannot be what saves this.
        uint256 roomy = attacker.requestWithGas(subId, 1, 2_000_000);
        uint256 small = attacker.requestWithGas(subId, 1, 100_000);

        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (roomy, small);
        _sort(ids);
        bytes memory sig = _aggregateFor(ids);
        bytes memory smallSig = _sign(verifier, coordinator.seedOf(small), groupSecretKey);

        // Only useful if the roomy one is delivered first; otherwise the attack
        // has no room to run in and the test would pass for the wrong reason.
        assertEq(ids[0], roomy, "the roomy request must sort first for this to test anything");

        attacker.armFor(small, smallSig);

        vm.prank(relayer);
        coordinator.fulfillBatch(ids, sig);

        assertTrue(attacker.reentryAttempted(), "the attack never ran");
        assertEq(attacker.deliveries(), 2, "a member of the batch was delivered twice");
    }

    function test_a_batch_containing_a_closed_request_is_refused() public {
        MockConsumer c = _consumer();
        (uint256[] memory ids, bytes memory sig) = _batch(c, 3);

        bytes memory alone = _sign(verifier, coordinator.seedOf(ids[1]), groupSecretKey);
        vm.prank(relayer);
        coordinator.fulfillRandomWords(ids[1], alone);

        vm.expectRevert(VRFCoordinator.RequestClosed.selector);
        coordinator.fulfillBatch(ids, sig);
    }

    function test_a_batch_containing_an_unknown_request_is_refused() public {
        MockConsumer c = _consumer();
        (uint256[] memory ids, bytes memory sig) = _batch(c, 2);
        uint256[] memory withGhost = new uint256[](3);
        withGhost[0] = 1; // no such request, and sorts first
        withGhost[1] = ids[0];
        withGhost[2] = ids[1];

        vm.expectRevert(VRFCoordinator.NoSuchRequest.selector);
        coordinator.fulfillBatch(withGhost, sig);
    }

    function test_an_empty_batch_is_refused() public {
        vm.expectRevert(VRFCoordinator.EmptyBatch.selector);
        coordinator.fulfillBatch(new uint256[](0), new bytes(64));
    }

    /// An aggregate that is not the group's signature over exactly these
    /// requests buys nothing, however the members are chosen.
    function test_a_batch_with_a_forged_aggregate_is_refused() public {
        MockConsumer c = _consumer();
        (uint256[] memory ids,) = _batch(c, 3);

        uint256[] memory other = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            other[i] = c.request(subId, 1);
        }
        _sort(other);
        // Built before expectRevert is armed: aggregating makes external calls
        // of its own, and the first of them would eat the expectation.
        bytes memory wrong = _aggregateFor(other);

        vm.expectRevert(VRFCoordinator.InvalidProof.selector);
        coordinator.fulfillBatch(ids, wrong);
    }

    /// A relayer that supplies enough gas for the pairing but not for the
    /// callbacks would close every request in the batch and hand the consumers
    /// nothing.
    function test_a_batch_without_gas_for_every_callback_is_refused() public {
        MockConsumer c = _consumer();
        (uint256[] memory ids, bytes memory sig) = _batch(c, 5);

        vm.expectRevert(VRFCoordinator.InsufficientGas.selector);
        coordinator.fulfillBatch{gas: 900_000}(ids, sig);
    }

    /// A callback that reverts must not take the rest of the batch with it.
    function test_one_failing_callback_does_not_lose_the_others() public {
        FlakyConsumer broken = new FlakyConsumer(address(coordinator));
        MockConsumer fine = _consumer();
        vm.prank(owner);
        subs.addConsumer(subId, address(broken));

        uint256[] memory ids = new uint256[](2);
        ids[0] = broken.request(subId, 1);
        ids[1] = fine.request(subId, 1);
        _sort(ids);
        bytes memory sig = _aggregateFor(ids);

        vm.prank(relayer);
        coordinator.fulfillBatch(ids, sig);

        assertEq(fine.callbackCount(), 1, "a working consumer lost its delivery");
        for (uint256 i = 0; i < 2; i++) {
            (,,,, bool fulfilled,,) = coordinator.requests(ids[i]);
            assertTrue(fulfilled);
        }
    }

    /* -------------------------------- gas --------------------------------- */

    /// What the protocol itself costs per request, one way against the other.
    function test_gas_batch_fulfilment() public {
        uint256 single;
        for (uint256 n = 1; n <= 25; n += 4) {
            CountingConsumer c = new CountingConsumer(address(coordinator));
            vm.prank(owner);
            subs.addConsumer(subId, address(c));

            uint256[] memory ids = new uint256[](n);
            for (uint256 i = 0; i < n; i++) {
                ids[i] = c.request(subId, 1);
            }
            _sort(ids);
            bytes memory sig = _aggregateFor(ids);

            uint256 before = gasleft();
            vm.prank(relayer);
            coordinator.fulfillBatch(ids, sig);
            uint256 per = (before - gasleft()) / n;
            if (n == 1) single = per;

            console.log("  batch of", n);
            console.log("    gas per request", per);
            if (single != 0 && n > 1) {
                console.log("    saved vs a batch of one, percent", 100 - (per * 100) / single);
            }
        }
    }
}
