// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VRFTestBase} from "./utils/VRFTestBase.sol";
import {VRFVerifier} from "../src/VRFVerifier.sol";
import {VRFCoordinator} from "../src/VRFCoordinator.sol";
import {Subscription} from "../src/Subscription.sol";
import {MockConsumer} from "./mocks/Consumers.sol";

/// @notice Pricing has to survive going from free to paid without every
///         integration having to move. That means the fee can change — and the
///         whole design here is about bounding what "can change" means.
contract FeesTest is VRFTestBase {
    /// The callback budget every mock consumer asks for.
    uint32 internal constant DEFAULT_CALLBACK_GAS = 500_000;

    uint96 internal constant MAX_BASE = 0.01 ether;
    uint96 internal constant MAX_PER_WORD = 0.001 ether;

    VRFVerifier internal verifier;
    VRFCoordinator internal coordinator;
    Subscription internal subs;
    MockConsumer internal consumer;

    address internal admin = address(this);
    address internal stranger = makeAddr("stranger");
    address internal successor = makeAddr("successor");
    address internal subOwner = makeAddr("subOwner");
    uint256 internal subId;

    function setUp() public {
        _loadVectors();
        verifier = new VRFVerifier(groupPubKey, 1);
        // launch configuration: free, with a ceiling agreed up front
        coordinator = new VRFCoordinator(address(verifier), 0, 0, 0, MAX_BASE, MAX_PER_WORD, 1 gwei);
        subs = Subscription(coordinator.subscriptions());
        consumer = new MockConsumer(address(coordinator));

        vm.deal(subOwner, 10 ether);
        vm.startPrank(subOwner);
        subId = subs.createSubscription();
        subs.fundSubscription{value: 1 ether}(subId);
        subs.addConsumer(subId, address(consumer));
        vm.stopPrank();

        vm.roll(1_000_000);
    }

    /* ------------------------------ launch -------------------------------- */

    function test_launches_free_and_needs_no_funding_at_all() public {
        assertEq(coordinator.price(1, DEFAULT_CALLBACK_GAS), 0);
        assertEq(coordinator.price(500, DEFAULT_CALLBACK_GAS), 0);

        vm.prank(subOwner);
        uint256 empty = subs.createSubscription();
        vm.prank(subOwner);
        subs.addConsumer(empty, address(consumer));

        uint256 requestId = consumer.request(empty, 1);
        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);
        coordinator.fulfillRandomWords(requestId, sig);

        assertEq(consumer.callbackCount(), 1, "a request on an unfunded account must go through");
    }

    function test_caps_are_immutable_and_the_constructor_respects_them() public {
        assertEq(coordinator.maxBaseFee(), MAX_BASE);
        assertEq(coordinator.maxPerWordFee(), MAX_PER_WORD);

        vm.expectRevert(VRFCoordinator.FeeAboveCap.selector);
        new VRFCoordinator(address(verifier), MAX_BASE + 1, 0, 0, MAX_BASE, MAX_PER_WORD, 1 gwei);
    }

    /* ---------------------------- the ceiling ----------------------------- */

    /// The cap is the whole promise: an integrator has to be able to read, once,
    /// the worst price this coordinator can ever charge.
    function test_a_fee_above_the_cap_can_never_be_proposed() public {
        vm.expectRevert(VRFCoordinator.FeeAboveCap.selector);
        coordinator.proposeFees(MAX_BASE + 1, 0, 0);

        vm.expectRevert(VRFCoordinator.FeeAboveCap.selector);
        coordinator.proposeFees(0, MAX_PER_WORD + 1, 0);

        coordinator.proposeFees(MAX_BASE, MAX_PER_WORD, 1 gwei); // exactly at the cap is fine
    }

    function test_only_the_owner_proposes_or_cancels() public {
        vm.prank(stranger);
        vm.expectRevert(VRFCoordinator.NotOwner.selector);
        coordinator.proposeFees(1, 1, 0);

        coordinator.proposeFees(1, 1, 0);

        vm.prank(stranger);
        vm.expectRevert(VRFCoordinator.NotOwner.selector);
        coordinator.cancelFeeChange();
    }

    /* ----------------------------- the delay ------------------------------ */

    function test_a_proposed_fee_does_nothing_until_the_delay_has_passed() public {
        coordinator.proposeFees(0.001 ether, 0.0001 ether, 0);

        assertEq(coordinator.baseFee(), 0, "the price moved on proposal");
        assertEq(coordinator.price(1, DEFAULT_CALLBACK_GAS), 0);
        assertEq(coordinator.pendingBaseFee(), 0.001 ether);

        vm.roll(block.number + coordinator.FEE_TIMELOCK_BLOCKS() - 1);
        vm.expectRevert(VRFCoordinator.TooEarly.selector);
        coordinator.applyFees();
        assertEq(coordinator.price(1, DEFAULT_CALLBACK_GAS), 0);
    }

    function test_anyone_may_apply_the_change_once_it_is_due() public {
        coordinator.proposeFees(0.001 ether, 0.0001 ether, 0);
        vm.roll(block.number + coordinator.FEE_TIMELOCK_BLOCKS());

        vm.prank(stranger);
        coordinator.applyFees();

        assertEq(coordinator.baseFee(), 0.001 ether);
        assertEq(coordinator.perWordFee(), 0.0001 ether);
        assertEq(coordinator.price(3, DEFAULT_CALLBACK_GAS), 0.001 ether + 3 * 0.0001 ether);
        assertEq(coordinator.pendingFeesEffectiveAtBlock(), 0, "the proposal was not cleared");
    }

    function test_applying_without_a_proposal_reverts() public {
        vm.expectRevert(VRFCoordinator.NoFeeChangePending.selector);
        coordinator.applyFees();
    }

    function test_a_pending_change_can_be_cancelled() public {
        coordinator.proposeFees(0.001 ether, 0, 0);
        coordinator.cancelFeeChange();

        vm.roll(block.number + coordinator.FEE_TIMELOCK_BLOCKS() + 1);
        vm.expectRevert(VRFCoordinator.NoFeeChangePending.selector);
        coordinator.applyFees();
        assertEq(coordinator.price(1, DEFAULT_CALLBACK_GAS), 0);
    }

    /// Re-proposing must restart the clock, or the owner could park a proposal,
    /// wait out the notice period, and then swap in a different number.
    function test_reproposing_restarts_the_clock() public {
        coordinator.proposeFees(0.001 ether, 0, 0);
        vm.roll(block.number + coordinator.FEE_TIMELOCK_BLOCKS() - 10);

        coordinator.proposeFees(0.002 ether, 0, 0);
        vm.roll(block.number + 10);

        vm.expectRevert(VRFCoordinator.TooEarly.selector);
        coordinator.applyFees();

        vm.roll(block.number + coordinator.FEE_TIMELOCK_BLOCKS());
        coordinator.applyFees();
        assertEq(coordinator.baseFee(), 0.002 ether);
    }

    /* ------------------------- requests in flight ------------------------- */

    /// The reason the price is recorded on the request: a fee change must never
    /// reach a request that was already made. Otherwise "we raised the price"
    /// silently means "we raised the price on work you already ordered".
    function test_a_request_already_made_is_settled_at_the_price_it_was_quoted() public {
        coordinator.proposeFees(0.001 ether, 0.0001 ether, 0);
        vm.roll(block.number + coordinator.FEE_TIMELOCK_BLOCKS());
        coordinator.applyFees();

        uint256 requestId = consumer.request(subId, 2);
        uint96 quoted = coordinator.price(2, DEFAULT_CALLBACK_GAS);
        (uint96 balanceBefore, uint96 reserved) = subs.accountOf(subId);
        assertEq(reserved, quoted);

        // the price is raised while the request is in flight
        coordinator.proposeFees(MAX_BASE, MAX_PER_WORD, 1 gwei);
        vm.roll(block.number + coordinator.FEE_TIMELOCK_BLOCKS());
        coordinator.applyFees();
        assertGt(coordinator.price(2, DEFAULT_CALLBACK_GAS), quoted);

        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);
        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        coordinator.fulfillRandomWords(requestId, sig);

        (uint96 balanceAfter, uint96 reservedAfter) = subs.accountOf(subId);
        assertEq(balanceBefore - balanceAfter, quoted, "settled at the new price");
        assertEq(reservedAfter, 0, "the old reservation was not released cleanly");
        assertEq(subs.withdrawableOf(relayer), quoted);
    }

    function test_a_refund_releases_exactly_what_was_reserved() public {
        coordinator.proposeFees(0.001 ether, 0.0001 ether, 0);
        vm.roll(block.number + coordinator.FEE_TIMELOCK_BLOCKS());
        coordinator.applyFees();

        uint256 requestId = consumer.request(subId, 2);
        uint96 quoted = coordinator.price(2, DEFAULT_CALLBACK_GAS);

        coordinator.proposeFees(MAX_BASE, MAX_PER_WORD, 1 gwei);
        vm.roll(block.number + coordinator.FEE_TIMELOCK_BLOCKS());
        coordinator.applyFees();

        vm.roll(block.number + coordinator.TIMEOUT_BLOCKS() + 1);
        coordinator.refund(requestId);

        (uint96 balance, uint96 reserved) = subs.accountOf(subId);
        assertEq(reserved, 0);
        assertEq(balance, 1 ether, "a refund at the new price left dust behind");
        assertEq(coordinator.priceOf(requestId), quoted);
    }

    /* ----------------------------- ownership ------------------------------ */

    function test_ownership_transfer_takes_two_steps() public {
        coordinator.transferOwnership(successor);
        assertEq(coordinator.owner(), admin);

        vm.prank(successor);
        coordinator.acceptOwnership();
        assertEq(coordinator.owner(), successor);

        vm.expectRevert(VRFCoordinator.NotOwner.selector);
        coordinator.proposeFees(1, 1, 0);

        vm.prank(successor);
        coordinator.proposeFees(1, 1, 0);
    }

    function test_only_the_named_successor_accepts() public {
        coordinator.transferOwnership(successor);
        vm.prank(stranger);
        vm.expectRevert(VRFCoordinator.NotPendingOwner.selector);
        coordinator.acceptOwnership();
    }

    /// The end state worth having: once pricing settles, the owner walks away
    /// and the fee becomes as immutable as everything else.
    function test_renouncing_ownership_freezes_the_fee_forever() public {
        coordinator.proposeFees(0.001 ether, 0, 0);
        vm.roll(block.number + coordinator.FEE_TIMELOCK_BLOCKS());
        coordinator.applyFees();

        coordinator.renounceOwnership();
        assertEq(coordinator.owner(), address(0));

        vm.expectRevert(VRFCoordinator.NotOwner.selector);
        coordinator.proposeFees(0, 0, 0);

        // and a change that was in flight cannot sneak through afterwards
        assertEq(coordinator.pendingFeesEffectiveAtBlock(), 0);
        assertEq(
            coordinator.price(1, DEFAULT_CALLBACK_GAS),
            0.001 ether,
            "the frozen price is not what was applied"
        );
    }

    function test_renouncing_drops_any_pending_change() public {
        coordinator.proposeFees(MAX_BASE, MAX_PER_WORD, 1 gwei);
        coordinator.renounceOwnership();

        vm.roll(block.number + coordinator.FEE_TIMELOCK_BLOCKS() + 1);
        vm.expectRevert(VRFCoordinator.NoFeeChangePending.selector);
        coordinator.applyFees();
        assertEq(coordinator.price(1, DEFAULT_CALLBACK_GAS), 0);
    }

    /* ------------------------------- fuzz --------------------------------- */

    function testFuzz_the_price_never_exceeds_the_cap(uint96 base, uint96 perWord, uint32 numWords)
        public
    {
        base = uint96(bound(base, 0, MAX_BASE));
        perWord = uint96(bound(perWord, 0, MAX_PER_WORD));
        numWords = uint32(bound(numWords, 1, coordinator.MAX_WORDS()));

        coordinator.proposeFees(base, perWord, 0);
        vm.roll(block.number + coordinator.FEE_TIMELOCK_BLOCKS());
        coordinator.applyFees();

        assertLe(
            coordinator.price(numWords, DEFAULT_CALLBACK_GAS),
            MAX_BASE + uint96(numWords) * MAX_PER_WORD
        );
    }
}
