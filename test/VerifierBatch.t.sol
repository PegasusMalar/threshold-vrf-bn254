// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Test.sol";
import {VRFTestBase} from "./utils/VRFTestBase.sol";
import {VRFVerifier} from "../src/VRFVerifier.sol";

/// @notice One pairing for a whole batch.
///
/// @dev More than half of what a fulfilment costs is the pairing, and it is the
///      one part that does not shrink with anything: 107,805 gas whether the
///      request asked for one word or five hundred. Signatures under a single
///      group key add, though, and the verification equation adds with them —
///
///          e(Σσᵢ, g₂) == e(ΣH(mᵢ), pk)
///
///      so a batch of any size costs one pairing plus one hash-to-curve and one
///      point addition per member. The hash cannot be moved off chain: a seed
///      the publisher supplies is a seed the publisher chooses.
contract VerifierBatchTest is VRFTestBase {
    VRFVerifier internal verifier;

    function setUp() public {
        _loadVectors();
        verifier = new VRFVerifier(groupPubKey, 1);
    }

    function _seeds(uint256 n) internal pure returns (bytes32[] memory seeds) {
        seeds = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            seeds[i] = keccak256(abi.encodePacked("seed", i));
        }
    }

    /// Signs each seed and adds the signatures into one.
    function _aggregate(bytes32[] memory seeds) internal view returns (bytes memory) {
        uint256[2] memory sum;
        for (uint256 i = 0; i < seeds.length; i++) {
            bytes memory one = _sign(verifier, seeds[i], groupSecretKey);
            uint256 x;
            uint256 y;
            assembly {
                x := mload(add(one, 32))
                y := mload(add(one, 64))
            }
            sum = i == 0 ? [x, y] : _add(sum, [x, y]);
        }
        return abi.encodePacked(sum[0], sum[1]);
    }

    function _add(uint256[2] memory a, uint256[2] memory b)
        internal
        view
        returns (uint256[2] memory out)
    {
        uint256[4] memory input = [a[0], a[1], b[0], b[1]];
        bool ok;
        assembly {
            ok := staticcall(gas(), 6, input, 128, out, 64)
        }
        require(ok, "ecAdd failed");
    }

    function test_a_batch_of_signatures_verifies_with_one_pairing() public view {
        for (uint256 n = 1; n <= 8; n++) {
            bytes32[] memory seeds = _seeds(n);
            assertTrue(
                verifier.verifyBatch(seeds, _aggregate(seeds)), "an honest batch was refused"
            );
        }
    }

    /// A batch of one has to agree with the single-signature path, or the two
    /// are different verifiers and integrators would have to know which is which.
    function test_a_batch_of_one_agrees_with_the_single_path() public view {
        bytes32[] memory seeds = _seeds(1);
        bytes memory sig = _aggregate(seeds);
        assertTrue(verifier.verify(seeds[0], sig));
        assertTrue(verifier.verifyBatch(seeds, sig));
    }

    /// Swapping one seed after the fact changes the sum, and the aggregate no
    /// longer matches it.
    function test_a_batch_with_one_seed_changed_is_refused() public view {
        bytes32[] memory seeds = _seeds(4);
        bytes memory sig = _aggregate(seeds);
        seeds[2] = keccak256("something else");
        assertFalse(verifier.verifyBatch(seeds, sig));
    }

    function test_a_batch_missing_a_member_is_refused() public view {
        bytes32[] memory four = _seeds(4);
        bytes memory sig = _aggregate(four);

        bytes32[] memory three = new bytes32[](3);
        for (uint256 i = 0; i < 3; i++) {
            three[i] = four[i];
        }
        assertFalse(verifier.verifyBatch(three, sig));
    }

    /// The sum does not care about order, and neither may anything built on it.
    /// Stated as a test because a verifier that quietly depended on order would
    /// make batches fail for reasons nobody could reproduce.
    function test_the_order_of_a_batch_does_not_matter() public view {
        bytes32[] memory seeds = _seeds(5);
        bytes memory sig = _aggregate(seeds);

        bytes32[] memory reversed = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            reversed[i] = seeds[4 - i];
        }
        assertTrue(verifier.verifyBatch(reversed, sig));
    }

    /// The attack the caller has to defend against, stated here so the property
    /// is visible where the arithmetic lives: a seed repeated twice sums to
    /// 2·H(s), and 2·σ is something anyone holding one published signature can
    /// compute. The verifier will accept it, correctly — the equation holds.
    /// What must never happen is a caller settling that request twice, and that
    /// is the caller's duty, not this contract's.
    function test_a_repeated_seed_verifies_and_so_the_caller_must_reject_duplicates() public view {
        bytes32 seed = keccak256("one seed");
        bytes memory one = _sign(verifier, seed, groupSecretKey);
        uint256 x;
        uint256 y;
        assembly {
            x := mload(add(one, 32))
            y := mload(add(one, 64))
        }
        uint256[2] memory doubled = _add([x, y], [x, y]);

        bytes32[] memory twice = new bytes32[](2);
        twice[0] = seed;
        twice[1] = seed;

        assertTrue(
            verifier.verifyBatch(twice, abi.encodePacked(doubled[0], doubled[1])),
            "the equation should hold for a doubled signature"
        );
    }

    function test_an_empty_batch_is_refused() public view {
        assertFalse(verifier.verifyBatch(new bytes32[](0), _aggregate(_seeds(1))));
    }

    function test_a_batch_with_a_malformed_signature_is_refused() public view {
        bytes32[] memory seeds = _seeds(3);
        assertFalse(verifier.verifyBatch(seeds, hex"1234"));
        assertFalse(verifier.verifyBatch(seeds, new bytes(64)));
    }

    function test_a_batch_signed_by_another_key_is_refused() public view {
        bytes32[] memory seeds = _seeds(3);
        uint256[2] memory sum;
        for (uint256 i = 0; i < seeds.length; i++) {
            bytes memory one = _sign(verifier, seeds[i], otherEpochSecretKey);
            uint256 x;
            uint256 y;
            assembly {
                x := mload(add(one, 32))
                y := mload(add(one, 64))
            }
            sum = i == 0 ? [x, y] : _add(sum, [x, y]);
        }
        assertFalse(verifier.verifyBatch(seeds, abi.encodePacked(sum[0], sum[1])));
    }

    /// The number this is all for.
    function test_gas_batch_verification() public view {
        for (uint256 n = 1; n <= 25; n += 6) {
            bytes32[] memory seeds = _seeds(n);
            bytes memory sig = _aggregate(seeds);
            uint256 before = gasleft();
            verifier.verifyBatch(seeds, sig);
            uint256 spent = before - gasleft();
            console.log("  batch of", n);
            console.log("    total   ", spent);
            console.log("    per seed", spent / n);
        }
    }
}
