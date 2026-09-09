// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VRFTestBase} from "../utils/VRFTestBase.sol";
import {VRFVerifier} from "../../src/VRFVerifier.sol";
import {VRFCoordinator} from "../../src/VRFCoordinator.sol";
import {Subscription} from "../../src/Subscription.sol";
import {BudgetBurner, GreedyConsumer} from "../mocks/Attackers.sol";

/// @notice Attacks that cost the operators money rather than breaking a rule.
///
/// @dev Nothing here violates the protocol. That is the point: the contracts
///      can be perfectly correct and the operator set still starve, because who
///      chooses the work and who pays for it are different people. A threshold
///      VRF whose operators run at a loss stops producing randomness, and it
///      does so while every signature it ever made stays valid — which is
///      exactly the failure mode a load test found on the live testnet fleet,
///      with every health counter reading green.
contract EconomicAttackTest is VRFTestBase {
    VRFVerifier internal verifier;
    Subscription internal subs;
    VRFCoordinator internal free;

    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal bystander = makeAddr("bystander");
    uint256 internal subId;

    function setUp() public {
        _loadVectors();
        verifier = new VRFVerifier(groupPubKey, 1);
        // The free tier as launched: every fee zero.
        free = new VRFCoordinator(
            address(verifier), 0, 0, 0, type(uint96).max, type(uint96).max, type(uint96).max
        );
        subs = Subscription(free.subscriptions());

        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
        subId = subs.createSubscription();
        subs.fundSubscription{value: 1 ether}(subId);
        vm.stopPrank();

        vm.roll(1_000_000);
    }

    function _consumer() internal returns (GreedyConsumer c) {
        c = new GreedyConsumer(address(free));
        vm.prank(owner);
        subs.addConsumer(subId, address(c));
    }

    /// The hole, stated as an equation. With `perCallbackGasFee` at zero the
    /// price does not move with `callbackGasLimit` at all — and the consumer is
    /// the one who picks that limit, up to `maxCallbackGasLimit`.
    ///
    /// The limit alone is only a ceiling: an operator pays for gas used, not
    /// gas allowed, so a generous budget left unspent costs nothing. A consumer
    /// that spends it turns the ceiling into a bill. Here the same zero price
    /// buys a twenty-five-fold difference in what the operator burns, and the
    /// operator has no way to refuse: it cannot know how much of the budget the
    /// callback will use until it has already paid for it.
    function test_a_consumer_that_burns_its_budget_bills_the_operator_for_it() public {
        BudgetBurner cheap = new BudgetBurner(address(free));
        BudgetBurner greedy = new BudgetBurner(address(free));
        vm.startPrank(owner);
        subs.addConsumer(subId, address(cheap));
        subs.addConsumer(subId, address(greedy));
        vm.stopPrank();

        uint256 small = cheap.request(subId, 1, 100_000);
        uint256 large = greedy.request(subId, 1, 2_500_000);

        assertEq(free.priceOf(small), free.priceOf(large), "the price moved with the gas limit");
        assertEq(free.priceOf(large), 0, "the free tier is not free");

        bytes memory sigSmall = _sign(verifier, free.seedOf(small), groupSecretKey);
        bytes memory sigLarge = _sign(verifier, free.seedOf(large), groupSecretKey);

        vm.startPrank(operator);
        uint256 before = gasleft();
        free.fulfillRandomWords(small, sigSmall);
        uint256 gasSmall = before - gasleft();

        before = gasleft();
        free.fulfillRandomWords(large, sigLarge);
        uint256 gasLarge = before - gasleft();
        vm.stopPrank();

        assertGt(gasLarge, gasSmall + 2_000_000, "the burnt budget did not reach the operator");
        assertEq(subs.withdrawableOf(operator), 0, "the operator earned something after all");
    }

    /// Five hundred words is the ceiling, and every one of them is a keccak and
    /// a memory word the operator pays for. Priced per word that is fine; at
    /// zero it is a lever with no counterweight.
    function test_the_largest_request_is_free_to_make_and_not_free_to_serve() public {
        GreedyConsumer c = _consumer();
        uint256 requestId = c.requestWithGas(subId, free.MAX_WORDS(), 2_500_000);
        assertEq(free.priceOf(requestId), 0, "the largest request was not free to make");

        bytes memory sig = _sign(verifier, free.seedOf(requestId), groupSecretKey);
        vm.prank(operator);
        uint256 before = gasleft();
        free.fulfillRandomWords(requestId, sig);
        uint256 spent = before - gasleft();

        assertEq(c.wordsSeen(), free.MAX_WORDS());
        assertGt(spent, 300_000, "the maximum request was cheap to serve after all");
        assertEq(subs.withdrawableOf(operator), 0, "the operator was paid for it");
    }

    /// Fulfilment is permissionless by design, and the proof travels in
    /// calldata. Anyone who sees an operator's transaction before it lands can
    /// resubmit the same bytes and take the fee, having done none of the work.
    ///
    /// The defence is not in the contract and cannot be: the signature has to
    /// be public for the fulfilment to be checkable. It is the sequencer's
    /// first-come-first-served ordering, which leaves no room to outbid a
    /// transaction already in flight. This test states the exposure so that a
    /// move to any chain with a priority gas auction is understood to reopen it.
    function test_a_bystander_can_take_the_fee_by_copying_the_proof() public {
        VRFCoordinator paid = new VRFCoordinator(
            address(verifier),
            0.001 ether,
            0,
            0,
            type(uint96).max,
            type(uint96).max,
            type(uint96).max
        );
        Subscription paidSubs = Subscription(paid.subscriptions());
        GreedyConsumer c = new GreedyConsumer(address(paid));

        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
        uint256 id = paidSubs.createSubscription();
        paidSubs.fundSubscription{value: 1 ether}(id);
        paidSubs.addConsumer(id, address(c));
        vm.stopPrank();

        uint256 requestId = c.request(id, 1);
        bytes memory sig = _sign(verifier, paid.seedOf(requestId), groupSecretKey);

        // The operator's transaction, observed and copied before it lands.
        vm.prank(bystander);
        paid.fulfillRandomWords(requestId, sig);

        assertEq(paidSubs.withdrawableOf(bystander), 0.001 ether, "the copy was not paid");
        assertEq(paidSubs.withdrawableOf(operator), 0, "the operator was paid anyway");

        vm.expectRevert(VRFCoordinator.RequestClosed.selector);
        vm.prank(operator);
        paid.fulfillRandomWords(requestId, sig);
    }
}
