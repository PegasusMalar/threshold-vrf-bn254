// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VRFTestBase} from "../utils/VRFTestBase.sol";
import {VRFVerifier} from "../../src/VRFVerifier.sol";
import {VRFCoordinator} from "../../src/VRFCoordinator.sol";
import {Subscription} from "../../src/Subscription.sol";
import {VRFConsumerBase} from "../../src/VRFConsumerBase.sol";
import {Plinko} from "./Plinko.sol";

/// @notice Exercises the reference Plinko integration end to end. The point of
///         these tests is not that Plinko works — it is that the *integration*
///         pattern is correct: the stake is taken at request time, the callback
///         only writes storage, payouts are pulled, and a failed delivery is
///         recoverable.
contract PlinkoTest is VRFTestBase {
    VRFVerifier internal verifier;
    VRFCoordinator internal coordinator;
    Subscription internal subs;
    Plinko internal game;

    address internal house = makeAddr("house");
    address internal player = makeAddr("player");
    uint256 internal subId;

    function setUp() public {
        _loadVectors();
        verifier = new VRFVerifier(groupPubKey, 1);
        coordinator = new VRFCoordinator(
            address(verifier), 0, 0, 0, type(uint96).max, type(uint96).max, type(uint96).max
        );
        subs = Subscription(coordinator.subscriptions());

        vm.deal(house, 100 ether);
        vm.startPrank(house);
        subId = subs.createSubscription();
        subs.fundSubscriptionWithNative{value: 1 ether}(subId);
        game = new Plinko(address(coordinator), subId);
        subs.addConsumer(subId, address(game));
        vm.stopPrank();

        vm.deal(address(game), 50 ether); // the house bankroll
        vm.deal(player, 10 ether);
        vm.roll(1_000_000);
    }

    function _settle(uint256 requestId) internal returns (uint256[] memory words) {
        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);
        (,, uint32 numWords,,,,) = coordinator.requests(requestId);

        bytes32 randomness = keccak256(sig);
        words = new uint256[](numWords);
        for (uint32 i = 0; i < numWords; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(randomness, requestId, i)));
        }
        coordinator.fulfillRandomWords(requestId, sig);
    }

    /* ------------------------------ the game ------------------------------ */

    function test_a_drop_settles_into_buckets_derived_from_the_words() public {
        vm.prank(player);
        uint256 requestId = game.drop{value: 0.03 ether}(3); // 0.01 per ball

        assertEq(player.balance, 9.97 ether, "the stake must be taken at request time");
        assertFalse(game.settled(requestId));

        uint256[] memory words = _settle(requestId);
        assertTrue(game.settled(requestId));

        // every bucket the contract recorded is the one the word dictates
        uint256 expectedPayout = 0;
        for (uint32 i = 0; i < 3; i++) {
            uint8 bucket = game.bucketOfBall(words, i);
            assertEq(game.bucketOf(requestId, i), bucket);
            // uint256 explicitly: without it the literal takes uint32 from the
            // multiplier and 1e16 does not fit
            expectedPayout += (uint256(0.01 ether) * game.multiplierBps(bucket)) / 10_000;
        }
        assertEq(game.winningsOf(player), expectedPayout);
    }

    function test_the_bucket_is_the_number_of_right_turns() public view {
        uint256[] memory words = new uint256[](1);

        words[0] = 0; // every peg sends the ball left
        assertEq(game.bucketOfBall(words, 0), 0);

        words[0] = type(uint256).max; // every peg sends it right
        assertEq(game.bucketOfBall(words, 0), game.ROWS());

        words[0] = 0xFF; // eight rights out of sixteen rows
        assertEq(game.bucketOfBall(words, 0), 8);
    }

    /// One word carries sixteen balls, so a drop of sixteen costs one word and a
    /// drop of seventeen costs two. Asking for one word per ball would be paying
    /// sixteen times over.
    function test_words_are_packed_not_one_per_ball() public {
        vm.prank(player);
        uint256 sixteen = game.drop{value: 0.16 ether}(16);
        (,, uint32 words,,,,) = coordinator.requests(sixteen);
        assertEq(words, 1);

        vm.prank(player);
        uint256 seventeen = game.drop{value: 0.17 ether}(17);
        (,, words,,,,) = coordinator.requests(seventeen);
        assertEq(words, 2);
    }

    function test_winnings_are_pulled_not_pushed() public {
        vm.prank(player);
        uint256 requestId = game.drop{value: 0.01 ether}(1);
        _settle(requestId);

        uint256 owed = game.winningsOf(player);
        assertGt(owed, 0, "every bucket pays something");

        vm.prank(player);
        game.withdraw();
        assertEq(player.balance, 9.99 ether + owed);
        assertEq(game.winningsOf(player), 0);
    }

    /* --------------------------- the integration -------------------------- */

    /// The callback must be idempotent, because `retryCallback` can deliver the
    /// same words again.
    function test_a_retried_delivery_does_not_pay_twice() public {
        vm.prank(player);
        uint256 requestId = game.drop{value: 0.01 ether}(1);
        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);
        coordinator.fulfillRandomWords(requestId, sig);

        uint256 owed = game.winningsOf(player);

        vm.expectRevert(VRFCoordinator.CallbackAlreadyDelivered.selector);
        coordinator.retryCallback(requestId, sig);
        assertEq(game.winningsOf(player), owed, "the retry paid a second time");
    }

    function test_only_the_coordinator_can_settle_a_drop() public {
        vm.prank(player);
        uint256 requestId = game.drop{value: 0.01 ether}(1);

        uint256[] memory forged = new uint256[](1);
        forged[0] = type(uint256).max; // the top bucket
        vm.expectRevert(
            abi.encodeWithSelector(
                VRFConsumerBase.OnlyCoordinatorCanFulfill.selector, player, address(coordinator)
            )
        );
        vm.prank(player);
        game.rawFulfillRandomWords(requestId, forged);
    }

    function test_stake_and_ball_count_are_bounded() public {
        vm.expectRevert(Plinko.BadBallCount.selector);
        vm.prank(player);
        game.drop{value: 1 ether}(0);

        uint32 tooMany = game.MAX_BALLS() + 1;
        vm.expectRevert(Plinko.BadBallCount.selector);
        vm.prank(player);
        game.drop{value: 1 ether}(tooMany);

        vm.expectRevert(Plinko.BadStake.selector);
        vm.prank(player);
        game.drop{value: 0}(1);
    }

    /// The house must not be able to run out mid-round: a drop is refused unless
    /// the bankroll could cover the best possible outcome for every ball.
    function test_a_drop_the_house_cannot_cover_is_refused() public {
        Plinko poor = new Plinko(address(coordinator), subId);
        vm.prank(house);
        subs.addConsumer(subId, address(poor));
        vm.deal(address(poor), 1 ether);

        vm.expectRevert(Plinko.HouseCannotCover.selector);
        vm.prank(player);
        poor.drop{value: 1 ether}(1);
    }

    /* ---------------------------- the economics --------------------------- */

    /// The multiplier table has to lose to the house in expectation, or the game
    /// bankrupts itself. Computed exactly from the binomial distribution rather
    /// than trusted: one mistyped multiplier is the whole bankroll.
    function test_the_payout_table_leaves_the_house_ahead() public view {
        uint8 rows = game.ROWS();
        uint256 total = 1 << rows; // 65536 equally likely paths

        uint256 expectedBps = 0;
        uint256 pathsToBucket = 1; // C(16, 0)
        for (uint8 k = 0; k <= rows; k++) {
            expectedBps += pathsToBucket * game.multiplierBps(k);
            // C(n, k+1) = C(n, k) * (n - k) / (k + 1)
            if (k < rows) pathsToBucket = (pathsToBucket * (rows - k)) / (k + 1);
        }
        uint256 rtpBps = expectedBps / total;

        assertLt(rtpBps, 10_000, "the table pays out more than it takes");
        assertGt(rtpBps, 9_000, "a house edge above 10% is not a game, it is a tax");
        assertEq(rtpBps, game.expectedReturnBps(), "the contract misreports its own RTP");
    }

    /// Every path has to land somewhere, or some outcome pays nothing by accident.
    function test_every_bucket_is_reachable_and_paid() public view {
        for (uint8 k = 0; k <= game.ROWS(); k++) {
            assertGt(game.multiplierBps(k), 0, "a bucket pays nothing at all");
        }
    }

    function testFuzz_any_word_lands_in_a_real_bucket(uint256 word) public view {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        for (uint32 i = 0; i < 16; i++) {
            assertLe(game.bucketOfBall(words, i), game.ROWS());
        }
    }
}
