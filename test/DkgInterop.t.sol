// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {VRFVerifier} from "../src/VRFVerifier.sol";

/// @notice The end-to-end claim: a group key and a signature produced by the Go
///         node's real Pedersen DKG — code that never touched the TypeScript
///         reference — are accepted by the contract that will be deployed.
///
/// @dev Fixtures come from `go run ./cmd/gen-dkg-vector` in node/. The ceremony
///      is randomised, so CI regenerates it and re-runs this suite against a
///      fresh group every time: the property is re-established, not remembered.
contract DkgInteropTest is Test {
    VRFVerifier internal verifier;

    bytes32 internal seed;
    bytes internal signatureQuorumA;
    bytes internal signatureQuorumB;
    bytes internal signatureBelowThreshold;
    bytes internal signatureAfterRotation;
    uint256 internal threshold;
    uint256 internal operators;

    function setUp() public {
        string memory json = vm.readFile("test/vectors/dkg.json");
        uint256[] memory pk = vm.parseJsonUintArray(json, ".groupPubKey");
        uint64 epoch = uint64(vm.parseJsonUint(json, ".epoch"));

        verifier = new VRFVerifier([pk[0], pk[1], pk[2], pk[3]], epoch);

        seed = vm.parseJsonBytes32(json, ".seed");
        signatureQuorumA = vm.parseJsonBytes(json, ".signatureQuorumA");
        signatureQuorumB = vm.parseJsonBytes(json, ".signatureQuorumB");
        signatureBelowThreshold = vm.parseJsonBytes(json, ".signatureBelowThreshold");
        signatureAfterRotation = vm.parseJsonBytes(json, ".signatureAfterRotation");
        threshold = vm.parseJsonUint(json, ".threshold");
        operators = vm.parseJsonUint(json, ".operators");
    }

    /// Reaching setUp at all is half the assertion: the constructor rejects a
    /// key that is malformed, zero, or outside the order-r subgroup.
    function test_group_key_from_the_dkg_is_a_usable_verifier_key() public view {
        assertEq(threshold, 5);
        assertEq(operators, 9);

        uint256[] memory expected =
            vm.parseJsonUintArray(vm.readFile("test/vectors/dkg.json"), ".groupPubKey");
        uint256[4] memory onChain = verifier.groupPublicKey();
        for (uint256 i = 0; i < 4; i++) {
            assertEq(onChain[i], expected[i]);
            assertTrue(onChain[i] != 0);
        }
    }

    function test_accepts_a_signature_produced_by_the_go_dkg() public view {
        assertTrue(verifier.verify(seed, signatureQuorumA));
    }

    /// Different five operators, same signature, same on-chain result.
    function test_two_disjoint_quorums_are_indistinguishable_on_chain() public view {
        assertEq(keccak256(signatureQuorumA), keccak256(signatureQuorumB));
        assertTrue(verifier.verify(seed, signatureQuorumB));
    }

    function test_rejects_an_aggregate_one_share_short_of_the_threshold() public view {
        assertFalse(verifier.verify(seed, signatureBelowThreshold));
    }

    /// After a resharing that swapped one operator out, the deployed key is
    /// unchanged and the new group signs for it.
    function test_accepts_a_signature_from_the_group_after_rotation() public view {
        assertEq(keccak256(signatureAfterRotation), keccak256(signatureQuorumA));
        assertTrue(verifier.verify(seed, signatureAfterRotation));
    }

    function test_rejects_the_dkg_signature_for_a_different_seed() public view {
        assertFalse(verifier.verify(keccak256("some other seed"), signatureQuorumA));
    }
}
