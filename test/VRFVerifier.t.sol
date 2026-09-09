// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {VRFVerifier} from "../src/VRFVerifier.sol";
import {IVRFVerifier} from "../src/interfaces/IVRFVerifier.sol";

/// @notice Attack-oriented test-suite for the threshold BLS verifier (TZ section 4.2).
///
/// Fixtures in test/vectors/bls.json are produced by offchain/scripts/genVectors.ts,
/// i.e. by an *independent* implementation (mcl-wasm / noble-curves). A bug that
/// exists in both the Solidity and the TypeScript side simultaneously is the only
/// one these tests can miss.
contract VRFVerifierTest is Test {
    /// @dev Declared gas budget for a single verification. The whole economic
    ///      model of the project hangs off this number (TZ sections 10.4, 11).
    /// Measured 165,529 on Robinhood Chain mainnet and testnet (script/bench.sh),
    /// 161,729 on a vanilla EVM. The budget leaves ~6% headroom so that a real
    /// regression trips the test instead of quietly repricing the product.
    uint256 internal constant MAX_VERIFY_GAS = 175_000;

    uint256 internal constant P =
        21888242871839275222246405745257275088696311157297823662689037894645226208583;
    uint256 internal constant R =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    VRFVerifier internal verifier;

    uint256 internal groupSecretKey;
    uint256[4] internal groupPubKey;
    uint256[4] internal wrongPubKey;
    uint256[4] internal pubKeyOffSubgroup;
    bytes32 internal vectorMessage;
    uint256[2] internal vectorMessagePoint;
    uint256[2] internal vectorSignature;
    uint256[2] internal vectorThresholdSigA;
    uint256[2] internal vectorThresholdSigB;
    uint256[2] internal vectorWrongKeySignature;
    string internal vectorDst;

    function setUp() public {
        string memory json = vm.readFile("test/vectors/bls.json");
        vectorDst = vm.parseJsonString(json, ".dst");
        groupSecretKey = vm.parseJsonUint(json, ".groupSecretKey");
        groupPubKey = _g2(json, ".groupPubKey");
        wrongPubKey = _g2(json, ".wrongPubKey");
        pubKeyOffSubgroup = _g2(json, ".pubKeyOffSubgroup");
        vectorMessage = bytes32(vm.parseJsonUint(json, ".message"));
        vectorMessagePoint = _g1(json, ".messagePoint");
        vectorSignature = _g1(json, ".signature");
        vectorThresholdSigA = _g1(json, ".thresholdSignatureQuorumA");
        vectorThresholdSigB = _g1(json, ".thresholdSignatureQuorumB");
        vectorWrongKeySignature = _g1(json, ".wrongKeySignature");

        verifier = new VRFVerifier(groupPubKey, 1);
    }

    /* ------------------------------------------------------------------ */
    /*                          happy path                                 */
    /* ------------------------------------------------------------------ */

    function test_accepts_valid_signature() public view {
        assertTrue(verifier.verify(vectorMessage, _encode(vectorSignature)));
    }

    /// The whole point of the scheme: any quorum of t operators produces the
    /// byte-identical signature, so the on-chain result cannot be steered by
    /// choosing who signs.
    function test_accepts_threshold_aggregated_signature_from_any_quorum() public view {
        assertEq(vectorThresholdSigA[0], vectorSignature[0]);
        assertEq(vectorThresholdSigB[0], vectorSignature[0]);
        assertTrue(verifier.verify(vectorMessage, _encode(vectorThresholdSigA)));
        assertTrue(verifier.verify(vectorMessage, _encode(vectorThresholdSigB)));
    }

    /// The off-chain signer and the on-chain verifier must hash identically or
    /// nothing else in this suite means anything.
    function test_hash_to_point_matches_offchain_implementation() public view {
        uint256[2] memory p = verifier.hashSeedToPoint(vectorMessage);
        assertEq(p[0], vectorMessagePoint[0]);
        assertEq(p[1], vectorMessagePoint[1]);
    }

    function test_domain_separation_tag_matches_offchain() public view {
        assertEq(string(verifier.domainSeparationTag()), vectorDst);
    }

    function test_exposes_immutable_group_key_and_epoch() public view {
        uint256[4] memory pk = verifier.groupPublicKey();
        for (uint256 i = 0; i < 4; i++) {
            assertEq(pk[i], groupPubKey[i]);
        }
        assertEq(verifier.epoch(), 1);
    }

    /* ------------------------------------------------------------------ */
    /*                             attacks                                 */
    /* ------------------------------------------------------------------ */

    function test_rejects_signature_from_wrong_key() public view {
        assertFalse(verifier.verify(vectorMessage, _encode(vectorWrongKeySignature)));
    }

    function test_rejects_signature_for_different_seed() public view {
        bytes32 otherSeed = keccak256("some other seed");
        assertFalse(verifier.verify(otherSeed, _encode(vectorSignature)));
    }

    function test_rejects_zero_point() public view {
        assertFalse(verifier.verify(vectorMessage, _encode([uint256(0), uint256(0)])));
    }

    function test_rejects_point_not_on_curve() public view {
        assertFalse(verifier.verify(vectorMessage, _encode([uint256(1), uint256(1)])));
    }

    function test_rejects_field_element_at_or_above_modulus() public view {
        assertFalse(verifier.verify(vectorMessage, _encode([P, vectorSignature[1]])));
        assertFalse(verifier.verify(vectorMessage, _encode([vectorSignature[0], P])));
        assertFalse(
            verifier.verify(vectorMessage, _encode([vectorSignature[0] + P, vectorSignature[1]]))
        );
    }

    function test_rejects_malformed_signature_length() public view {
        assertFalse(verifier.verify(vectorMessage, ""));
        assertFalse(verifier.verify(vectorMessage, hex"00"));
        assertFalse(verifier.verify(vectorMessage, abi.encodePacked(vectorSignature[0])));
        assertFalse(
            verifier.verify(vectorMessage, abi.encodePacked(_encode(vectorSignature), hex"00"))
        );
        assertFalse(
            verifier.verify(vectorMessage, abi.encodePacked(_encode(vectorSignature), uint256(0)))
        );
    }

    /// Negating a valid signature yields another on-curve point. It must not verify:
    /// otherwise two distinct signatures exist per seed and randomness is no longer
    /// a function of the seed alone.
    function test_rejects_negated_signature() public view {
        uint256[2] memory neg = [vectorSignature[0], P - vectorSignature[1]];
        assertFalse(verifier.verify(vectorMessage, _encode(neg)));
    }

    /// BN254 G1 has cofactor 1, so every on-curve point except infinity already
    /// lies in the order-r subgroup: there is no small subgroup for an attacker
    /// to push a signature into. This test pins that assumption down instead of
    /// trusting it — if the curve parameters ever change, it breaks.
    function test_rejects_subgroup_attack_on_signature() public view {
        // infinity, the only low-order point, is rejected outright
        assertFalse(verifier.verify(vectorMessage, _encode([uint256(0), uint256(0)])));
        // r * P == infinity for an arbitrary on-curve point => order divides r,
        // and r is prime => order is exactly r (or 1).
        uint256[2] memory pt = verifier.hashSeedToPoint(keccak256("arbitrary"));
        uint256[2] memory scaled = _ecMul(pt, R);
        assertEq(scaled[0], 0);
        assertEq(scaled[1], 0);
    }

    /// The group key is where a subgroup attack is actually possible (G2 has a
    /// large cofactor), so it is validated at deploy time and can never change.
    function test_constructor_rejects_group_key_outside_subgroup() public {
        vm.expectRevert(VRFVerifier.InvalidGroupPublicKey.selector);
        new VRFVerifier(pubKeyOffSubgroup, 1);
    }

    function test_constructor_rejects_group_key_not_on_curve() public {
        vm.expectRevert(VRFVerifier.InvalidGroupPublicKey.selector);
        new VRFVerifier([uint256(1), uint256(2), uint256(3), uint256(4)], 1);
    }

    function test_constructor_rejects_zero_group_key() public {
        vm.expectRevert(VRFVerifier.InvalidGroupPublicKey.selector);
        new VRFVerifier([uint256(0), uint256(0), uint256(0), uint256(0)], 1);
    }

    function test_constructor_rejects_group_key_above_field_modulus() public {
        uint256[4] memory pk = groupPubKey;
        pk[0] += P;
        vm.expectRevert(VRFVerifier.InvalidGroupPublicKey.selector);
        new VRFVerifier(pk, 1);
    }

    /// A signature made under epoch N's key must not verify against epoch N+1's
    /// verifier. Distinct group keys give this for free (TZ section 4.3).
    function test_rejects_signature_from_other_epoch() public {
        VRFVerifier nextEpoch = new VRFVerifier(wrongPubKey, 2);
        assertTrue(verifier.verify(vectorMessage, _encode(vectorSignature)));
        assertFalse(nextEpoch.verify(vectorMessage, _encode(vectorSignature)));
        assertTrue(nextEpoch.verify(vectorMessage, _encode(vectorWrongKeySignature)));
    }

    /* ------------------------------------------------------------------ */
    /*                    no admin path (TZ section 10.2)                  */
    /* ------------------------------------------------------------------ */

    /// invariant_verifier_has_no_admin_path: the deployed runtime code must not
    /// be able to write storage, call out, delegate, or self-destruct. Anything
    /// that could switch verification off has to be absent at the bytecode level,
    /// not merely absent from the source we happen to be reading.
    function test_verifier_bytecode_has_no_state_changing_opcodes() public view {
        bytes memory code = address(verifier).code;
        assertGt(code.length, 0);
        assertEq(_forbiddenOpcode(code), "");
    }

    /// The scanner above is only worth anything if it can actually fail.
    function test_bytecode_scanner_detects_a_contract_that_can_mutate_state() public {
        MutableContract bad = new MutableContract();
        assertEq(_forbiddenOpcode(address(bad).code), "SSTORE");
    }

    /// @dev Returns the name of the first state-changing opcode found, or "".
    ///      PUSH immediates are skipped so constant data is never mistaken for code.
    function _forbiddenOpcode(bytes memory code) internal pure returns (string memory) {
        for (uint256 i = 0; i < code.length;) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += 1 + (op - 0x5f); // PUSH1..PUSH32 immediates
                continue;
            }
            if (op == 0x55) return "SSTORE";
            if (op == 0xf0 || op == 0xf5) return "CREATE";
            if (op == 0xf1) return "CALL";
            if (op == 0xf2) return "CALLCODE";
            if (op == 0xf4) return "DELEGATECALL";
            if (op == 0xff) return "SELFDESTRUCT";
            if (op >= 0xa0 && op <= 0xa4) return "LOG";
            unchecked {
                ++i;
            }
        }
        return "";
    }

    /* ------------------------------------------------------------------ */
    /*                               fuzz                                  */
    /* ------------------------------------------------------------------ */

    /// Any seed can be signed and verified. This is the property the coordinator
    /// relies on: no seed is "unsignable".
    function testFuzz_accepts_valid_signature_for_any_seed(bytes32 seed) public view {
        assertTrue(verifier.verify(seed, _encode(_sign(seed))));
    }

    function testFuzz_rejects_arbitrary_points(bytes32 seed, uint256 x, uint256 y) public view {
        assertFalse(verifier.verify(seed, _encode([x, y])));
    }

    function testFuzz_rejects_signature_bound_to_a_different_seed(bytes32 a, bytes32 b)
        public
        view
    {
        vm.assume(a != b);
        assertFalse(verifier.verify(b, _encode(_sign(a))));
    }

    function testFuzz_rejects_malformed_length(bytes calldata sig) public view {
        vm.assume(sig.length != 64);
        assertFalse(verifier.verify(vectorMessage, sig));
    }

    /* ------------------------------------------------------------------ */
    /*                           gas budget                                */
    /* ------------------------------------------------------------------ */

    function test_gas_within_budget() public view {
        bytes memory sig = _encode(vectorSignature);
        uint256 before = gasleft();
        bool ok = verifier.verify(vectorMessage, sig);
        uint256 used = before - gasleft();
        assertTrue(ok);
        console.log("verify() gas (incl. call overhead):", used);
        assertLt(used, MAX_VERIFY_GAS);
    }

    function test_gas_report_breakdown() public view {
        bytes memory sig = _encode(vectorSignature);

        uint256 g0 = gasleft();
        verifier.hashSeedToPoint(vectorMessage);
        uint256 hashGas = g0 - gasleft();

        g0 = gasleft();
        verifier.verify(vectorMessage, sig);
        uint256 verifyGas = g0 - gasleft();

        console.log("hashSeedToPoint():", hashGas);
        console.log("verify():         ", verifyGas);
        console.log("pairing share:    ", verifyGas - hashGas);
    }

    /* ------------------------------------------------------------------ */
    /*                             helpers                                 */
    /* ------------------------------------------------------------------ */

    /// Sign on-chain with the test group secret: sigma = sk * H(seed).
    function _sign(bytes32 seed) internal view returns (uint256[2] memory) {
        return _ecMul(verifier.hashSeedToPoint(seed), groupSecretKey);
    }

    function _ecMul(uint256[2] memory point, uint256 scalar)
        internal
        view
        returns (uint256[2] memory out)
    {
        uint256[3] memory input = [point[0], point[1], scalar];
        bool ok;
        assembly {
            ok := staticcall(gas(), 7, input, 96, out, 64)
        }
        require(ok, "ecMul failed");
    }

    function _encode(uint256[2] memory sig) internal pure returns (bytes memory) {
        return abi.encodePacked(sig[0], sig[1]);
    }

    function _g1(string memory json, string memory key) internal pure returns (uint256[2] memory) {
        uint256[] memory v = vm.parseJsonUintArray(json, key);
        return [v[0], v[1]];
    }

    function _g2(string memory json, string memory key) internal pure returns (uint256[4] memory) {
        uint256[] memory v = vm.parseJsonUintArray(json, key);
        return [v[0], v[1], v[2], v[3]];
    }
}

/// @dev Fixture proving the opcode scanner is not vacuous.
contract MutableContract {
    uint256 public value;

    function set(uint256 v) external {
        value = v;
    }
}
