// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VRFTestBase} from "../utils/VRFTestBase.sol";
import {VRFVerifier} from "../../src/VRFVerifier.sol";
import {VRFCoordinator} from "../../src/VRFCoordinator.sol";
import {Subscription} from "../../src/Subscription.sol";
import {MockConsumer} from "../mocks/Consumers.sol";

/// @notice Attacks that try to spend one signature somewhere it does not belong.
///
/// @dev A BLS signature over a seed is unique and public: the moment a
///      fulfilment lands, the proof is in everyone's hands forever. Nothing
///      about the scheme stops it being copied, so everything rests on the seed
///      naming exactly one request, on one contract, on one chain. Each field
///      of that seed is a defence, and each one is attacked here by removing it.
contract ReplayAttackTest is VRFTestBase {
    VRFVerifier internal verifier;
    VRFCoordinator internal coordinator;
    Subscription internal subs;
    MockConsumer internal consumer;

    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer");
    uint256 internal subId;

    function setUp() public {
        _loadVectors();
        verifier = new VRFVerifier(groupPubKey, 1);
        coordinator = _coordinator();
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

    function _coordinator() internal returns (VRFCoordinator) {
        return new VRFCoordinator(
            address(verifier), 0, 0, 0, type(uint96).max, type(uint96).max, type(uint96).max
        );
    }

    /// The same group key serves every deployment that shares it. Without the
    /// coordinator's own address in the seed, a signature bought on a test
    /// deployment would close the identically-numbered request on the real one.
    function test_a_signature_does_not_carry_across_coordinators() public {
        VRFCoordinator other = _coordinator();
        Subscription otherSubs = Subscription(other.subscriptions());
        MockConsumer otherConsumer = new MockConsumer(address(other));

        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
        uint256 otherSubId = otherSubs.createSubscription();
        otherSubs.fundSubscription{value: 1 ether}(otherSubId);
        otherSubs.addConsumer(otherSubId, address(otherConsumer));
        vm.stopPrank();

        uint256 here = consumer.request(subId, 1);
        uint256 there = otherConsumer.request(otherSubId, 1);

        assertTrue(
            coordinator.seedOf(here) != other.seedOf(there),
            "two deployments produced the same seed"
        );

        bytes memory sig = _sign(verifier, coordinator.seedOf(here), groupSecretKey);
        vm.expectRevert(VRFCoordinator.InvalidProof.selector);
        other.fulfillRandomWords(there, sig);
    }

    /// An Orbit chain and its testnet run the same code at the same addresses.
    /// The chain id is what keeps a signature earned on one from closing a
    /// request on the other.
    function test_a_signature_does_not_carry_across_chains() public {
        uint256 requestId = consumer.request(subId, 1);
        bytes32 seedHere = coordinator.seedOf(requestId);

        vm.chainId(block.chainid + 1);
        assertTrue(coordinator.seedOf(requestId) != seedHere, "the seed ignored the chain id");
    }

    /// Two consumers on one subscription, each with its own request. The seed
    /// names the consumer, so neither can be closed with the other's proof.
    function test_a_signature_does_not_carry_between_consumers() public {
        MockConsumer second = new MockConsumer(address(coordinator));
        vm.prank(owner);
        subs.addConsumer(subId, address(second));

        uint256 mine = consumer.request(subId, 1);
        uint256 theirs = second.request(subId, 1);
        bytes memory sig = _sign(verifier, coordinator.seedOf(mine), groupSecretKey);

        vm.expectRevert(VRFCoordinator.InvalidProof.selector);
        coordinator.fulfillRandomWords(theirs, sig);
    }

    /// The negation of a valid G1 point is a valid G1 point, and for a pairing
    /// check written the wrong way round it verifies. A second signature over
    /// one seed would mean two legal outcomes for one request, which is the
    /// whole guarantee gone.
    function test_the_negated_signature_is_not_a_second_valid_proof() public {
        uint256 requestId = consumer.request(subId, 1);
        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);

        uint256 x;
        uint256 y;
        assembly {
            x := mload(add(sig, 32))
            y := mload(add(sig, 64))
        }
        uint256 p = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
        bytes memory negated = abi.encodePacked(x, p - y);

        vm.expectRevert(VRFCoordinator.InvalidProof.selector);
        coordinator.fulfillRandomWords(requestId, negated);
    }

    /// Trailing bytes must not be ignored: if they were, one signature would
    /// have unboundedly many encodings and "the proof was already used" would
    /// stop being a decidable statement off chain.
    function test_a_padded_signature_is_not_accepted() public {
        uint256 requestId = consumer.request(subId, 1);
        bytes memory sig = _sign(verifier, coordinator.seedOf(requestId), groupSecretKey);

        vm.expectRevert(VRFCoordinator.InvalidProof.selector);
        coordinator.fulfillRandomWords(requestId, abi.encodePacked(sig, bytes1(0)));
    }
}
