// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Test.sol";
import {VRFTestBase} from "./utils/VRFTestBase.sol";
import {VRFVerifier} from "../src/VRFVerifier.sol";
import {VRFCoordinator} from "../src/VRFCoordinator.sol";
import {Subscription} from "../src/Subscription.sol";
import {CountingConsumer} from "./mocks/Attackers.sol";

/// @notice Where a single fulfilment's gas actually goes.
///
/// @dev Written to decide what is worth optimising rather than to guess. Every
///      number is measured on the same contracts the service runs, and the
///      probes below are deliberately dumb: one operation each, measured with
///      gasleft() on either side.
contract GasBreakdownTest is VRFTestBase {
    VRFVerifier internal verifier;
    VRFCoordinator internal coordinator;
    Subscription internal subs;
    CountingConsumer internal consumer;

    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer");
    uint256 internal subId;

    uint256 private constant P =
        21888242871839275222246405745257275088696311157297823662689037894645226208583;

    function setUp() public {
        _loadVectors();
        verifier = new VRFVerifier(groupPubKey, 1);
        coordinator = new VRFCoordinator(
            address(verifier),
            0.0001 ether,
            0,
            0,
            type(uint96).max,
            type(uint96).max,
            type(uint96).max
        );
        subs = Subscription(coordinator.subscriptions());
        consumer = new CountingConsumer(address(coordinator));

        vm.deal(owner, 100 ether);
        vm.startPrank(owner);
        subId = subs.createSubscription();
        subs.fundSubscription{value: 10 ether}(subId);
        subs.addConsumer(subId, address(consumer));
        vm.stopPrank();
        vm.roll(1_000_000);
    }

    /// The two precompiles the scheme cannot do without, priced on their own.
    function test_gas_precompiles_alone() public view {
        uint256[6] memory pairInput = [
            uint256(1), uint256(2), groupPubKey[1], groupPubKey[0], groupPubKey[3], groupPubKey[2]
        ];
        uint256[1] memory out;
        bool ok;

        uint256 before = gasleft();
        assembly {
            ok := staticcall(gas(), 8, pairInput, 192, out, 0x20)
        }
        console.log("  ecPairing k=1        ", before - gasleft());

        uint256[12] memory two;
        for (uint256 i = 0; i < 6; i++) {
            two[i] = pairInput[i];
            two[i + 6] = pairInput[i];
        }
        before = gasleft();
        assembly {
            ok := staticcall(gas(), 8, two, 384, out, 0x20)
        }
        console.log("  ecPairing k=2        ", before - gasleft());

        // A modexp of the shape a square root needs — the expensive step inside
        // the map from a field element to a curve point.
        uint256[6] memory expInput = [uint256(32), 32, 32, 3, (P + 1) / 4, P];
        uint256[1] memory root;
        before = gasleft();
        assembly {
            ok := staticcall(gas(), 5, expInput, 192, root, 32)
        }
        console.log("  one modexp sqrt      ", before - gasleft());
        assertTrue(ok);
    }

    /// Hash-to-curve, and the two halves it is made of. RFC 9380's random
    /// oracle construction maps twice and adds; the cheaper non-uniform
    /// construction maps once, which is the only place a real saving could come
    /// from without leaving the standard.
    function test_gas_hash_to_curve() public view {
        bytes32 seed = keccak256("a seed");
        uint256 before = gasleft();
        verifier.hashSeedToPoint(seed);
        console.log("  hashSeedToPoint      ", before - gasleft());

        before = gasleft();
        verifier.verify(seed, new bytes(64));
        console.log("  verify, bad sig      ", before - gasleft());
    }

    /// The whole path, and then the same path with the parts that are not
    /// cryptography removed, so the difference is what is left to optimise.
    function test_gas_fulfilment_parts() public {
        uint256 id = consumer.request(subId, 1);
        bytes memory sig = _sign(verifier, coordinator.seedOf(id), groupSecretKey);

        uint256 before = gasleft();
        vm.prank(relayer);
        coordinator.fulfillRandomWords(id, sig);
        uint256 whole = before - gasleft();
        console.log("  fulfillRandomWords   ", whole);

        // The same verification, called directly, is the irreducible part.
        uint256 id2 = consumer.request(subId, 1);
        bytes memory sig2 = _sign(verifier, coordinator.seedOf(id2), groupSecretKey);
        before = gasleft();
        verifier.verify(coordinator.seedOf(id2), sig2);
        uint256 crypto = before - gasleft();
        console.log("  of which verify()    ", crypto);
        console.log("  everything else      ", whole - crypto);

        // Settling on its own: the external call into the accounting contract
        // and the writes it makes.
        before = gasleft();
        subs.availableOf(subId);
        console.log("  one view into subs   ", before - gasleft());
    }

    /// The number the economics must be built on.
    ///
    /// Access lists reset at every transaction boundary, so in production each
    /// fulfilment starts cold: cold account access into the accounting
    /// contract, cold slots for the subscription's balance and the publisher's
    /// credit. Two fulfilments measured inside one test share those warm slots
    /// and produce a figure that never occurs on chain. vm.cool puts the
    /// contracts back the way a new transaction would find them.
    function test_gas_fulfilment_as_a_real_transaction() public {
        uint256[] memory ids = new uint256[](3);
        bytes[] memory sigs = new bytes[](3);
        for (uint256 i = 0; i < 3; i++) {
            ids[i] = consumer.request(subId, 1);
            sigs[i] = _sign(verifier, coordinator.seedOf(ids[i]), groupSecretKey);
        }

        for (uint256 i = 0; i < 3; i++) {
            vm.cool(address(coordinator));
            vm.cool(address(subs));
            vm.cool(address(verifier));
            vm.cool(address(consumer));
            uint256 before = gasleft();
            vm.prank(relayer);
            coordinator.fulfillRandomWords(ids[i], sigs[i]);
            console.log("  cold fulfilment      ", before - gasleft());
        }
    }

    /// What the accounting costs when it is reached cold, as it always is in a
    /// transaction of its own.
    function test_gas_settlement_cold() public {
        uint256 id = consumer.request(subId, 1);
        bytes memory sig = _sign(verifier, coordinator.seedOf(id), groupSecretKey);

        vm.cool(address(coordinator));
        vm.cool(address(subs));
        vm.cool(address(verifier));
        vm.cool(address(consumer));

        uint256 before = gasleft();
        vm.prank(relayer);
        coordinator.fulfillRandomWords(id, sig);
        uint256 whole = before - gasleft();

        // The verification alone, also cold.
        uint256 id2 = consumer.request(subId, 1);
        bytes memory sig2 = _sign(verifier, coordinator.seedOf(id2), groupSecretKey);
        bytes32 seed2 = coordinator.seedOf(id2);
        vm.cool(address(verifier));
        before = gasleft();
        verifier.verify(seed2, sig2);
        uint256 crypto = before - gasleft();

        console.log("  cold fulfilment      ", whole);
        console.log("  cold verify()        ", crypto);
        console.log("  all the rest         ", whole - crypto);
        console.log("  the rest, percent    ", (whole - crypto) * 100 / whole);
    }

    /// A second fulfilment for the same publisher and subscription, to separate
    /// one-off cold-slot costs from what every request pays.
    function test_gas_cold_versus_warm() public {
        uint256 first = consumer.request(subId, 1);
        uint256 second = consumer.request(subId, 1);

        bytes memory a = _sign(verifier, coordinator.seedOf(first), groupSecretKey);
        bytes memory b = _sign(verifier, coordinator.seedOf(second), groupSecretKey);

        uint256 before = gasleft();
        vm.prank(relayer);
        coordinator.fulfillRandomWords(first, a);
        console.log("  first fulfilment     ", before - gasleft());

        before = gasleft();
        vm.prank(relayer);
        coordinator.fulfillRandomWords(second, b);
        console.log("  second, same payee   ", before - gasleft());
    }
}
