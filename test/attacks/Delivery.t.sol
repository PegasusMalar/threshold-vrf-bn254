// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VRFTestBase} from "../utils/VRFTestBase.sol";
import {VRFVerifier} from "../../src/VRFVerifier.sol";
import {VRFCoordinator} from "../../src/VRFCoordinator.sol";
import {Subscription} from "../../src/Subscription.sol";
import {DoubleDeliveryAttacker} from "../mocks/Attackers.sol";

/// @notice Attacks on how many times a request may be delivered.
///
/// @dev One request, one set of words, delivered at most once. Everything else
///      about this system tolerates being called twice — fulfilment is
///      permissionless, retry is permissionless, the signature is public — and
///      it is the delivery count that has to hold the line, because a consumer
///      that counts a payout per delivery is the normal shape of a VRF
///      integration, not an exotic one.
contract DeliveryAttackTest is VRFTestBase {
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

        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
        subId = subs.createSubscription();
        subs.fundSubscription{value: 1 ether}(subId);
        vm.stopPrank();

        vm.roll(1_000_000);
    }

    /// Requests, fails the first delivery, and arms the attacker for the retry.
    function _stranded()
        internal
        returns (DoubleDeliveryAttacker attacker, uint256 requestId, bytes memory sig)
    {
        attacker = new DoubleDeliveryAttacker(address(coordinator));
        vm.prank(owner);
        subs.addConsumer(subId, address(attacker));
        requestId = attacker.request(subId, 1);
        sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);

        vm.prank(relayer);
        coordinator.fulfillRandomWords(requestId, sig);

        (,,,,,, bool delivered) = coordinator.requests(requestId);
        assertFalse(delivered, "the first callback was supposed to fail");
        assertEq(attacker.deliveries(), 0);
    }

    /// The invariant: one request, one delivery, whatever the consumer does
    /// with the control it is handed.
    ///
    /// It holds for a reason the contract never states, and the reason is not
    /// the `callbackSucceeded` flag the comment credits — inside the window
    /// that flag is still false. It is the gas check. A delivery runs with at
    /// most `callbackGasLimit`, and `retryCallback` demands the whole budget
    /// again plus `POST_CALLBACK_GAS` before it will do anything. The callee
    /// can therefore never satisfy the entry condition of the function that
    /// would deliver to it a second time, and the 64/63 rule widens rather
    /// than narrows the gap. Asserted here so that lowering
    /// `POST_CALLBACK_GAS`, or relaxing the check to "enough for the callback"
    /// instead of "the full budget", fails loudly rather than opening a door.
    function test_a_retry_re_entered_from_the_first_delivery_is_refused() public {
        (DoubleDeliveryAttacker attacker, uint256 requestId, bytes memory sig) = _stranded();

        attacker.arm(sig);
        coordinator.retryCallback(requestId, sig);

        assertTrue(attacker.reentryAttempted(), "the attack never ran");
        assertTrue(attacker.reentryReverted(), "the re-entered retry was allowed through");
        assertEq(
            bytes4(attacker.reentryError()),
            VRFCoordinator.InsufficientGas.selector,
            "refused, but not by the gas check this invariant rests on"
        );
        assertEq(attacker.deliveries(), 1, "the consumer was delivered more than once");
    }

    /// Same attack from the other entry point. `fulfillRandomWords` hands out
    /// control under exactly the same gas budget, so the same wall stands.
    function test_a_retry_re_entered_from_a_fulfilment_is_refused() public {
        DoubleDeliveryAttacker attacker = new DoubleDeliveryAttacker(address(coordinator));
        vm.prank(owner);
        subs.addConsumer(subId, address(attacker));
        uint256 requestId = attacker.request(subId, 1);
        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);
        attacker.arm(sig);

        vm.prank(relayer);
        coordinator.fulfillRandomWords(requestId, sig);

        assertTrue(attacker.reentryAttempted(), "the attack never ran");
        assertTrue(attacker.reentryReverted(), "the re-entered retry was allowed through");
        assertEq(attacker.deliveries(), 1, "the consumer was delivered more than once");
    }

    /// Whatever the consumer does with its control, the money moves once: the
    /// publisher is paid for one fulfilment, the subscription charged for one
    /// request.
    function test_a_re_entered_delivery_never_charges_or_pays_twice() public {
        DoubleDeliveryAttacker attacker = new DoubleDeliveryAttacker(address(coordinator));
        vm.prank(owner);
        subs.addConsumer(subId, address(attacker));
        uint256 requestId = attacker.request(subId, 1);
        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);
        attacker.arm(sig);

        (uint96 balanceBefore,) = subs.accountOf(subId);
        vm.prank(relayer);
        coordinator.fulfillRandomWords(requestId, sig);

        (uint96 balanceAfter,) = subs.accountOf(subId);
        uint96 quoted = coordinator.price(1, attacker.DEFAULT_CALLBACK_GAS());
        assertEq(balanceBefore - balanceAfter, quoted, "the subscription paid for more than one");
        assertEq(subs.withdrawableOf(relayer), quoted, "the publisher was paid more than once");
    }
}
