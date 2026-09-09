// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Test.sol";
import {VRFTestBase} from "./utils/VRFTestBase.sol";
import {VRFVerifier} from "../src/VRFVerifier.sol";
import {VRFCoordinator} from "../src/VRFCoordinator.sol";
import {Subscription} from "../src/Subscription.sol";
import {VRFConsumerBase} from "../src/VRFConsumerBase.sol";
import {IVRFCoordinator} from "../src/interfaces/IVRFCoordinator.sol";
import {
    MockConsumer,
    RevertingConsumer,
    GasBombConsumer,
    ReturnBombConsumer,
    ReentrantConsumer
} from "./mocks/Consumers.sol";

/// @notice Attack tests for the coordinator (TZ section 10.1).
contract VRFCoordinatorTest is VRFTestBase {
    /// The callback budget every mock consumer asks for.
    uint32 internal constant DEFAULT_CALLBACK_GAS = 500_000;

    uint96 internal constant BASE_FEE = 0.0001 ether;
    uint96 internal constant PER_WORD_FEE = 0.00001 ether;

    VRFVerifier internal verifier;
    VRFCoordinator internal coordinator;
    Subscription internal subs;
    MockConsumer internal consumer;

    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer");
    address internal stranger = makeAddr("stranger");

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
        consumer = new MockConsumer(address(coordinator));

        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
        subId = subs.createSubscription();
        subs.fundSubscription{value: 1 ether}(subId);
        subs.addConsumer(subId, address(consumer));
        vm.stopPrank();

        vm.roll(1_000_000);
    }

    function _request(uint32 numWords) internal returns (uint256 requestId) {
        return consumer.request(subId, numWords);
    }

    function _fulfill(uint256 requestId) internal {
        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);
        vm.prank(relayer);
        coordinator.fulfillRandomWords(requestId, sig);
    }

    /* ------------------------------ happy path ---------------------------- */

    function test_request_reserves_funds_and_emits_the_seed() public {
        uint256 requestId = _request(3);

        (uint96 balance, uint96 reserved) = subs.accountOf(subId);
        assertEq(balance, 1 ether);
        assertEq(reserved, coordinator.price(3, DEFAULT_CALLBACK_GAS));
        assertEq(
            coordinator.seedOf(requestId),
            keccak256(
                abi.encodePacked(requestId, address(consumer), address(coordinator), block.chainid)
            )
        );
    }

    function test_fulfillment_delivers_words_and_pays_whoever_published() public {
        uint256 requestId = _request(3);
        uint96 expected = coordinator.price(3, DEFAULT_CALLBACK_GAS);
        _fulfill(requestId);

        assertEq(consumer.callbackCount(), 1);
        assertEq(consumer.lastRequestId(), requestId);
        assertEq(consumer.wordsLength(), 3);

        (uint96 balance, uint96 reserved) = subs.accountOf(subId);
        assertEq(balance, 1 ether - expected);
        assertEq(reserved, 0);
        assertEq(subs.withdrawableOf(relayer), expected);
    }

    /// Fulfillment must be open to anyone: the signature for a seed is unique,
    /// so nobody can bring a different result, and our own relayer going down
    /// must not take the service with it.
    function test_fulfillment_is_permissionless() public {
        uint256 requestId = _request(1);
        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);

        vm.prank(stranger);
        coordinator.fulfillRandomWords(requestId, sig);
        assertEq(consumer.callbackCount(), 1);
    }

    function test_words_are_a_deterministic_function_of_the_signature() public {
        uint256 requestId = _request(4);
        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);
        _fulfill(requestId);

        bytes32 randomness = keccak256(sig);
        for (uint32 i = 0; i < 4; i++) {
            assertEq(
                consumer.lastWords(i),
                uint256(keccak256(abi.encodePacked(randomness, requestId, i)))
            );
        }
    }

    /* -------------------------------- attacks ----------------------------- */

    function test_fake_signature_rejected() public {
        uint256 requestId = _request(1);
        vm.expectRevert(VRFCoordinator.InvalidProof.selector);
        coordinator.fulfillRandomWords(requestId, abi.encodePacked(uint256(1), uint256(2)));
    }

    function test_signature_replay_across_requests_reverts() public {
        uint256 first = _request(1);
        uint256 second = _request(1);
        bytes memory sig = _sign(verifier, coordinator.seedOf(first), groupSecretKey);

        coordinator.fulfillRandomWords(first, sig);

        vm.expectRevert(VRFCoordinator.InvalidProof.selector);
        coordinator.fulfillRandomWords(second, sig);
    }

    function test_signature_from_old_epoch_rejected() public {
        uint256 requestId = _request(1);
        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), otherEpochSecretKey);

        vm.expectRevert(VRFCoordinator.InvalidProof.selector);
        coordinator.fulfillRandomWords(requestId, sig);
    }

    function test_double_fulfillment_reverts() public {
        uint256 requestId = _request(1);
        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);

        coordinator.fulfillRandomWords(requestId, sig);
        vm.expectRevert(VRFCoordinator.RequestClosed.selector);
        coordinator.fulfillRandomWords(requestId, sig);
    }

    /// After a refund the operators' signature must be worthless: otherwise an
    /// operator sits on it, watches the refund happen, and then publishes only
    /// if the outcome suits them.
    function test_fulfill_after_refund_reverts() public {
        uint256 requestId = _request(1);
        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);

        vm.roll(block.number + coordinator.TIMEOUT_BLOCKS() + 1);
        coordinator.refund(requestId);

        vm.expectRevert(VRFCoordinator.RequestClosed.selector);
        coordinator.fulfillRandomWords(requestId, sig);
    }

    function test_refund_after_fulfill_reverts() public {
        uint256 requestId = _request(1);
        _fulfill(requestId);

        vm.roll(block.number + coordinator.TIMEOUT_BLOCKS() + 1);
        vm.expectRevert(VRFCoordinator.RequestClosed.selector);
        coordinator.refund(requestId);
    }

    function test_refund_before_timeout_reverts() public {
        uint256 requestId = _request(1);

        vm.roll(block.number + coordinator.TIMEOUT_BLOCKS());
        vm.expectRevert(VRFCoordinator.TooEarly.selector);
        coordinator.refund(requestId);

        vm.roll(block.number + 1);
        coordinator.refund(requestId);
        (, uint96 reserved) = subs.accountOf(subId);
        assertEq(reserved, 0);
    }

    /// The consumer chooses nothing that goes into the seed: not the time, not
    /// the block, not the word count, not a payload of its own.
    function test_consumer_cannot_influence_seed() public {
        MockConsumer other = new MockConsumer(address(coordinator));
        vm.prank(owner);
        subs.addConsumer(subId, address(other));

        vm.warp(111);
        vm.roll(2_000_000);
        uint256 idA = other.request(subId, 1);

        bytes32 expected =
            keccak256(abi.encodePacked(idA, address(other), address(coordinator), block.chainid));
        assertEq(coordinator.seedOf(idA), expected);

        // the very same request id would have come out at any other time, from
        // any other block, for any other word count
        assertEq(
            idA,
            uint256(
                keccak256(
                    abi.encodePacked(
                        address(other), uint256(0), address(coordinator), block.chainid
                    )
                )
            )
        );
    }

    function test_unauthorized_consumer_reverts() public {
        MockConsumer rogue = new MockConsumer(address(coordinator));
        vm.expectRevert(VRFCoordinator.ConsumerNotAuthorized.selector);
        rogue.request(subId, 1);
    }

    /// The reservation is the whole point: the owner must not be able to walk
    /// away with the money after the operators have started signing.
    function test_subscription_drain_between_request_and_fulfill_reverts() public {
        _request(1);

        vm.expectRevert(Subscription.FundsReserved.selector);
        vm.prank(owner);
        subs.cancelSubscription(subId, owner);
    }

    function test_request_without_enough_balance_reverts() public {
        vm.prank(owner);
        uint256 poor = subs.createSubscription();
        vm.prank(owner);
        subs.addConsumer(poor, address(consumer));

        vm.expectRevert(Subscription.InsufficientBalance.selector);
        consumer.request(poor, 1);
    }

    /* ---------------------------- broken consumers ------------------------ */

    function test_callback_revert_does_not_block_fulfillment() public {
        RevertingConsumer broken = new RevertingConsumer(address(coordinator));
        vm.prank(owner);
        subs.addConsumer(subId, address(broken));
        uint256 requestId = broken.request(subId, 1);

        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);
        vm.prank(relayer);
        coordinator.fulfillRandomWords(requestId, sig);

        (,,,, bool fulfilled,,) = coordinator.requests(requestId);
        assertTrue(fulfilled, "a broken consumer must not be able to jam its own request");
        assertEq(
            subs.withdrawableOf(relayer),
            coordinator.price(1, DEFAULT_CALLBACK_GAS),
            "relayer still gets paid"
        );
    }

    function test_callback_gas_bomb_does_not_break_coordinator() public {
        GasBombConsumer bomb = new GasBombConsumer(address(coordinator));
        vm.prank(owner);
        subs.addConsumer(subId, address(bomb));
        uint256 requestId = bomb.request(subId, 1);

        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);
        vm.prank(relayer);
        coordinator.fulfillRandomWords(requestId, sig);

        (,,,, bool fulfilled,,) = coordinator.requests(requestId);
        assertTrue(fulfilled);
    }

    function test_callback_return_bomb_is_not_copied_into_memory() public {
        ReturnBombConsumer bomb = new ReturnBombConsumer(address(coordinator));
        vm.prank(owner);
        subs.addConsumer(subId, address(bomb));
        uint256 requestId = bomb.request(subId, 1);

        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);
        vm.prank(relayer);
        uint256 before = gasleft();
        coordinator.fulfillRandomWords(requestId, sig);
        uint256 used = before - gasleft();

        (,,,, bool fulfilled,,) = coordinator.requests(requestId);
        assertTrue(fulfilled);
        assertLt(used, 400_000, "64 KiB of return data leaked into the coordinator's memory");
    }

    /// A relayer that supplies just enough gas for the pairing but not for the
    /// callback would close the request and leave the consumer with nothing.
    function test_fulfill_without_enough_gas_for_the_callback_reverts() public {
        uint256 requestId = _request(1);
        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);

        vm.expectRevert(VRFCoordinator.InsufficientGas.selector);
        coordinator.fulfillRandomWords{gas: 400_000}(requestId, sig);

        (,,,, bool fulfilled,,) = coordinator.requests(requestId);
        assertFalse(fulfilled, "the request must survive a starved relayer");
    }

    function test_reentrancy_on_fulfill() public {
        ReentrantConsumer attacker = new ReentrantConsumer(address(coordinator));
        vm.prank(owner);
        subs.addConsumer(subId, address(attacker));
        uint256 requestId = attacker.request(subId, 1);

        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);
        attacker.arm(sig, true, true, true, subId);

        vm.roll(block.number + coordinator.TIMEOUT_BLOCKS() + 1);
        vm.prank(relayer);
        coordinator.fulfillRandomWords(requestId, sig);

        assertTrue(attacker.fulfillReentryReverted(), "re-entered fulfillment was not rejected");
        assertTrue(attacker.refundReentryReverted(), "re-entered refund was not rejected");
        assertEq(
            subs.withdrawableOf(relayer), coordinator.price(1, DEFAULT_CALLBACK_GAS), "paid twice"
        );

        (,,,, bool fulfilled, bool refunded,) = coordinator.requests(requestId);
        assertTrue(fulfilled);
        assertFalse(refunded);
    }

    /* ------------------------------- bounds ------------------------------- */

    function test_word_count_bounds() public {
        // read first: an argument expression after expectRevert would eat it
        uint32 maxWords = coordinator.MAX_WORDS();

        vm.expectRevert(VRFCoordinator.BadWordCount.selector);
        consumer.request(subId, 0);

        vm.expectRevert(VRFCoordinator.BadWordCount.selector);
        consumer.request(subId, maxWords + 1);

        consumer.request(subId, maxWords);
    }

    function test_unknown_request_cannot_be_fulfilled_or_refunded() public {
        vm.expectRevert(VRFCoordinator.NoSuchRequest.selector);
        coordinator.fulfillRandomWords(12345, abi.encodePacked(uint256(1), uint256(2)));

        vm.expectRevert(VRFCoordinator.NoSuchRequest.selector);
        coordinator.refund(12345);
    }

    /* -------------------------------- fuzz -------------------------------- */

    function testFuzz_seed_unique_per_request(uint8 requests) public {
        requests = uint8(bound(requests, 2, 12));
        bytes32[] memory seeds = new bytes32[](requests);

        for (uint256 i = 0; i < requests; i++) {
            seeds[i] = coordinator.seedOf(_request(1));
            for (uint256 j = 0; j < i; j++) {
                assertTrue(seeds[i] != seeds[j], "seed collision");
            }
        }
    }

    function testFuzz_words_derivation_no_collision(bytes32 randomness, uint256 requestId)
        public
        pure
    {
        uint256 a = uint256(keccak256(abi.encodePacked(randomness, requestId, uint32(0))));
        uint256 b = uint256(keccak256(abi.encodePacked(randomness, requestId, uint32(1))));
        assertTrue(a != b);
    }

    function testFuzz_price_is_monotonic(uint32 n) public view {
        n = uint32(bound(n, 1, coordinator.MAX_WORDS() - 1));
        assertGt(
            coordinator.price(n + 1, DEFAULT_CALLBACK_GAS),
            coordinator.price(n, DEFAULT_CALLBACK_GAS)
        );
    }

    /* -------------------------------- gas --------------------------------- */

    /// TZ section 10.4. Reported twice on purpose: with a consumer that stores
    /// every word (what an integrator will actually see) and with one that
    /// throws them away (what the protocol itself costs).
    function test_gas_fulfill() public {
        NoopConsumer noop = new NoopConsumer(address(coordinator));
        vm.prank(owner);
        subs.addConsumer(subId, address(noop));

        uint32[3] memory counts = [uint32(1), 10, 100];
        for (uint256 i = 0; i < counts.length; i++) {
            uint256 storing = _measure(_request(counts[i]));
            uint256 bare = _measure(noop.request(subId, counts[i]));
            console.log("words:", counts[i]);
            console.log("  storing consumer:", storing);
            console.log("  protocol only:   ", bare);
        }
    }

    function _measure(uint256 requestId) internal returns (uint256) {
        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);
        vm.prank(relayer);
        uint256 before = gasleft();
        coordinator.fulfillRandomWords(requestId, sig);
        return before - gasleft();
    }
}

/// @dev Discards the words, to isolate the protocol's own cost.
contract NoopConsumer is VRFConsumerBase {
    uint32 internal constant DEFAULT_CALLBACK_GAS = 500_000;

    constructor(address coordinator_) VRFConsumerBase(coordinator_) {}

    function request(uint256 subId, uint32 numWords) external returns (uint256) {
        return s_vrfCoordinator.requestRandomWords(
            IVRFCoordinator.RandomWordsRequest({
                keyHash: bytes32(0),
                subId: subId,
                requestConfirmations: 0,
                callbackGasLimit: DEFAULT_CALLBACK_GAS,
                numWords: numWords,
                extraArgs: ""
            })
        );
    }

    function fulfillRandomWords(uint256, uint256[] calldata) internal override {}
}
