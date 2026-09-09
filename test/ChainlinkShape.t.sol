// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VRFTestBase} from "./utils/VRFTestBase.sol";
import {VRFVerifier} from "../src/VRFVerifier.sol";
import {VRFCoordinator} from "../src/VRFCoordinator.sol";
import {Subscription} from "../src/Subscription.sol";
import {IVRFCoordinator} from "../src/interfaces/IVRFCoordinator.sol";
import {MockConsumer} from "./mocks/Consumers.sol";

/// @notice The interface is deliberately shaped like Chainlink VRF v2.5 so an
///         integrator can bring their existing consumer across with almost no
///         edits. These tests pin the shape, not just the behaviour: a rename
///         here is a migration for everyone who already integrated.
contract ChainlinkShapeTest is VRFTestBase {
    VRFVerifier internal verifier;
    VRFCoordinator internal coordinator;
    Subscription internal subs;
    MockConsumer internal consumer;

    address internal owner = makeAddr("owner");
    address internal successor = makeAddr("successor");
    uint256 internal subId;

    function setUp() public {
        _loadVectors();
        verifier = new VRFVerifier(groupPubKey, 1);
        coordinator = new VRFCoordinator(address(verifier), 0, 0, 0, 1 ether, 1 ether, 1 gwei);
        subs = Subscription(coordinator.subscriptions());
        consumer = new MockConsumer(address(coordinator));

        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
        subId = subs.createSubscription();
        subs.fundSubscriptionWithNative{value: 1 ether}(subId);
        subs.addConsumer(subId, address(consumer));
        vm.stopPrank();

        vm.roll(1_000_000);
    }

    function _req(uint32 numWords, uint32 callbackGasLimit)
        internal
        view
        returns (IVRFCoordinator.RandomWordsRequest memory)
    {
        return IVRFCoordinator.RandomWordsRequest({
            keyHash: verifier.keyHash(),
            subId: subId,
            requestConfirmations: 3,
            callbackGasLimit: callbackGasLimit,
            numWords: numWords,
            extraArgs: ""
        });
    }

    /* --------------------------- the request ------------------------------ */

    function test_a_chainlink_shaped_request_goes_through() public {
        uint256 requestId = consumer.requestRandomWords(_req(3, 200_000));

        (address who, uint256 sub, uint32 words, uint32 gasLimit,,,) =
            coordinator.requests(requestId);
        assertEq(who, address(consumer));
        assertEq(sub, subId);
        assertEq(words, 3);
        assertEq(gasLimit, 200_000);
    }

    /// keyHash means something here: it pins which group key the consumer
    /// expects, so a request written for one epoch cannot be silently served by
    /// another. Zero means "whatever key is current".
    function test_key_hash_binds_the_request_to_a_group_key() public {
        IVRFCoordinator.RandomWordsRequest memory r = _req(1, 100_000);
        r.keyHash = keccak256("some other group");

        vm.expectRevert(VRFCoordinator.UnknownKeyHash.selector);
        consumer.requestRandomWords(r);

        r.keyHash = bytes32(0);
        consumer.requestRandomWords(r);
    }

    /// Accepted so that Chainlink code compiles unchanged, and honoured as the
    /// zero it is: nothing in our seed comes from a block, so there is nothing
    /// to wait for. The value is echoed in the event rather than swallowed.
    function test_request_confirmations_are_accepted_and_are_always_zero() public {
        assertEq(coordinator.minimumRequestConfirmations(), 0);
        assertEq(coordinator.maxRequestConfirmations(), 200);

        IVRFCoordinator.RandomWordsRequest memory r = _req(1, 100_000);
        r.requestConfirmations = 200;
        consumer.requestRandomWords(r);

        r.requestConfirmations = 201;
        vm.expectRevert(VRFCoordinator.BadRequestConfirmations.selector);
        consumer.requestRandomWords(r);
    }

    function test_callback_gas_limit_is_bounded_and_priced() public {
        // built first: _req reads keyHash from the verifier, and an external
        // call between expectRevert and the call under test eats the expectation
        IVRFCoordinator.RandomWordsRequest memory tooMuch =
            _req(1, coordinator.maxCallbackGasLimit() + 1);
        IVRFCoordinator.RandomWordsRequest memory none = _req(1, 0);

        vm.expectRevert(VRFCoordinator.BadCallbackGasLimit.selector);
        consumer.requestRandomWords(tooMuch);

        vm.expectRevert(VRFCoordinator.BadCallbackGasLimit.selector);
        consumer.requestRandomWords(none);

        // and a bigger callback costs more, once there is a price at all
        vm.prank(coordinator.owner());
        coordinator.proposeFees(0, 0, 1 gwei);
        vm.roll(block.number + coordinator.FEE_TIMELOCK_BLOCKS());
        coordinator.applyFees();

        assertGt(coordinator.price(1, 500_000), coordinator.price(1, 100_000));
    }

    /// The callback really is capped at what was asked and paid for, not at
    /// some global constant.
    function test_the_callback_gets_exactly_the_gas_it_paid_for() public {
        uint256 requestId = consumer.requestRandomWords(_req(1, 120_000));
        (,,, uint32 gasLimit,,,) = coordinator.requests(requestId);
        assertEq(gasLimit, 120_000);

        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);
        coordinator.fulfillRandomWords(requestId, sig);
        assertEq(consumer.callbackCount(), 1);
    }

    function test_request_config_is_readable_in_one_call() public view {
        (
            uint16 minConfirmations,
            uint16 maxConfirmations,
            uint32 maxGasLimit,
            uint32 maxWords,
            bytes32[] memory keyHashes
        ) = coordinator.getRequestConfig();

        assertEq(minConfirmations, 0);
        assertEq(maxConfirmations, 200);
        assertEq(maxGasLimit, coordinator.maxCallbackGasLimit());
        assertEq(maxWords, coordinator.MAX_WORDS());
        assertEq(keyHashes.length, 1);
        assertEq(keyHashes[0], verifier.keyHash());
    }

    /* ------------------------- the subscription --------------------------- */

    /// One call instead of scanning logs — this is what a subscription manager
    /// screen is built on.
    /// Field for field as Chainlink's, LINK slot included — it is always zero
    /// here, and putting anything else there would silently show a ported
    /// dashboard the wrong number.
    function test_get_subscription_returns_everything_in_one_call() public {
        consumer.requestRandomWords(_req(1, 100_000));

        (
            uint96 linkBalance,
            uint96 nativeBalance,
            uint64 reqCount,
            address subOwner,
            address[] memory list
        ) = subs.getSubscription(subId);

        assertEq(linkBalance, 0, "there is no LINK on this chain");
        assertEq(nativeBalance, 1 ether);
        assertEq(reqCount, 1);
        assertEq(subOwner, owner);
        assertEq(list.length, 1);
        assertEq(list[0], address(consumer));

        // the reserved part has no slot in Chainlink's shape and lives here
        (, uint96 reserved) = subs.accountOf(subId);
        assertEq(reserved, coordinator.price(1, 100_000));
    }

    /* ------------------------------ extraArgs ----------------------------- */

    /// A request built by Chainlink's own library has to be accepted verbatim.
    function test_accepts_chainlink_extra_args_for_native_payment() public {
        IVRFCoordinator.RandomWordsRequest memory r = _req(1, 100_000);
        r.extraArgs = abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), true);
        consumer.requestRandomWords(r);
        assertEq(subs.pendingRequestCount(subId), 1);
    }

    /// Asking to pay in LINK must fail loudly, not be charged in something else.
    function test_rejects_a_request_that_asks_to_pay_in_link() public {
        IVRFCoordinator.RandomWordsRequest memory r = _req(1, 100_000);
        r.extraArgs = abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), false);

        vm.expectRevert(VRFCoordinator.NativePaymentOnly.selector);
        consumer.requestRandomWords(r);
    }

    function test_rejects_extra_args_with_an_unknown_tag() public {
        IVRFCoordinator.RandomWordsRequest memory r = _req(1, 100_000);
        r.extraArgs = abi.encodeWithSelector(bytes4(keccak256("something else")), true);

        vm.expectRevert(VRFCoordinator.InvalidExtraArgsTag.selector);
        consumer.requestRandomWords(r);
    }

    /* ------------------------- paging the accounts ------------------------ */

    function test_active_subscription_ids_can_be_paged() public {
        vm.startPrank(owner);
        uint256 second = subs.createSubscription();
        uint256 third = subs.createSubscription();
        vm.stopPrank();

        assertEq(subs.activeSubscriptionCount(), 3);

        uint256[] memory all = subs.getActiveSubscriptionIds(0, 0);
        assertEq(all.length, 3);
        assertEq(all[0], subId);
        assertEq(all[1], second);
        assertEq(all[2], third);

        uint256[] memory page = subs.getActiveSubscriptionIds(1, 1);
        assertEq(page.length, 1);
        assertEq(page[0], second);

        // past the end is an error, not an empty page
        vm.expectRevert(Subscription.IndexOutOfRange.selector);
        subs.getActiveSubscriptionIds(3, 1);
    }

    function test_a_cancelled_account_leaves_the_active_list() public {
        vm.startPrank(owner);
        uint256 second = subs.createSubscription();
        subs.cancelSubscription(subId, owner);
        vm.stopPrank();

        assertEq(subs.activeSubscriptionCount(), 1);
        uint256[] memory all = subs.getActiveSubscriptionIds(0, 0);
        assertEq(all[0], second);
    }

    function test_the_consumer_list_tracks_additions_and_removals() public {
        MockConsumer second = new MockConsumer(address(coordinator));

        vm.prank(owner);
        subs.addConsumer(subId, address(second));
        (,,,, address[] memory list) = subs.getSubscription(subId);
        assertEq(list.length, 2);

        vm.prank(owner);
        subs.removeConsumer(subId, address(consumer));
        (,,,, list) = subs.getSubscription(subId);
        assertEq(list.length, 1);
        assertEq(list[0], address(second));

        // adding twice must not duplicate the entry
        vm.prank(owner);
        subs.addConsumer(subId, address(second));
        (,,,, list) = subs.getSubscription(subId);
        assertEq(list.length, 1);
    }

    function test_pending_request_exists_matches_what_is_reserved() public {
        assertFalse(subs.pendingRequestExists(subId));

        uint256 requestId = consumer.requestRandomWords(_req(1, 100_000));
        assertTrue(subs.pendingRequestExists(subId));

        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);
        coordinator.fulfillRandomWords(requestId, sig);
        assertFalse(subs.pendingRequestExists(subId));
    }

    function test_owner_transfer_uses_the_chainlink_names() public {
        vm.prank(owner);
        subs.requestSubscriptionOwnerTransfer(subId, successor);
        assertEq(subs.pendingOwnerOf(subId), successor);

        vm.prank(successor);
        subs.acceptSubscriptionOwnerTransfer(subId);
        assertEq(subs.ownerOf(subId), successor);
    }

    /* ---------------------------- the verifier ---------------------------- */

    function test_key_hash_is_the_hash_of_the_group_key() public view {
        assertEq(verifier.keyHash(), keccak256(abi.encode(verifier.groupPublicKey())));
    }
}
