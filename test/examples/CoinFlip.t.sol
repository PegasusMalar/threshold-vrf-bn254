// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VRFTestBase} from "../utils/VRFTestBase.sol";
import {VRFVerifier} from "../../src/VRFVerifier.sol";
import {VRFCoordinator} from "../../src/VRFCoordinator.sol";
import {Subscription} from "../../src/Subscription.sol";
import {VRFConsumerBase} from "../../src/VRFConsumerBase.sol";
import {CoinFlip} from "./CoinFlip.sol";

/// @notice Exercises the documented integration example end to end, so the
///         code in docs/integration.md cannot quietly rot.
contract CoinFlipTest is VRFTestBase {
    VRFVerifier internal verifier;
    VRFCoordinator internal coordinator;
    Subscription internal subs;
    CoinFlip internal game;

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
        subs.fundSubscription{value: 1 ether}(subId);
        game = new CoinFlip(address(coordinator), subId);
        subs.addConsumer(subId, address(game));
        vm.stopPrank();

        vm.deal(address(game), 10 ether); // the house bankroll
        vm.deal(player, 10 ether);
        vm.roll(1_000_000);
    }

    function _fulfill(uint256 requestId) internal returns (uint256 word) {
        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);
        coordinator.fulfillRandomWords(requestId, sig);
        return uint256(keccak256(abi.encodePacked(keccak256(sig), requestId, uint32(0))));
    }

    function test_a_bet_settles_according_to_the_random_word() public {
        vm.prank(player);
        uint256 requestId = game.flip{value: 1 ether}(true);

        assertEq(player.balance, 9 ether, "stake must be taken at request time");
        assertEq(game.stakeOf(requestId), 1 ether);

        uint256 word = _fulfill(requestId);
        bool heads = word % 2 == 1;

        assertTrue(game.settled(requestId));
        assertEq(game.winningsOf(player), heads ? 2 ether : 0);
    }

    function test_player_cannot_take_the_stake_back_while_the_bet_is_open() public {
        vm.prank(player);
        uint256 requestId = game.flip{value: 1 ether}(true);

        vm.expectRevert(CoinFlip.NothingToWithdraw.selector);
        vm.prank(player);
        game.withdraw();

        _fulfill(requestId);
        assertTrue(game.settled(requestId));
    }

    function test_only_the_coordinator_can_settle_a_bet() public {
        vm.prank(player);
        uint256 requestId = game.flip{value: 1 ether}(true);

        uint256[] memory forged = new uint256[](1);
        forged[0] = 1; // heads
        vm.expectRevert(
            abi.encodeWithSelector(
                VRFConsumerBase.OnlyCoordinatorCanFulfill.selector, player, address(coordinator)
            )
        );
        vm.prank(player);
        game.rawFulfillRandomWords(requestId, forged);
    }

    function test_stake_bounds_are_enforced() public {
        vm.expectRevert(CoinFlip.BadStake.selector);
        vm.prank(player);
        game.flip{value: 0}(true);

        vm.expectRevert(CoinFlip.BadStake.selector);
        vm.prank(player);
        game.flip{value: 6 ether}(true);
    }
}
