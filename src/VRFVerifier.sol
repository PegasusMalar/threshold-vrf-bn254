// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BLS} from "@kevincharm/bls-bn254/contracts/BLS.sol";
import {IVRFVerifier} from "./interfaces/IVRFVerifier.sol";

/// @title VRFVerifier
/// @notice Verifies threshold BLS signatures on BN254 against a fixed group key.
///
/// @dev Design constraints, from the spec:
///      - the group public key is immutable and set at deployment;
///      - there is no owner, no proxy, no delegatecall, no way to disable
///        verification. The contract cannot write storage at all — see
///        `test_verifier_bytecode_has_no_state_changing_opcodes`;
///      - the pairing itself comes from a reviewed BN254 implementation
///        (kevincharm/bls-bn254 v2.0.0, SvdW hash-to-curve per RFC9380);
///      - `verify` returns false rather than reverting on any malformed input.
///
///      Key rotation is deployment, not mutation: one verifier per epoch. If a
///      resharing preserves the group key the same instance keeps working and
///      no integration notices; if it does not, a new verifier is deployed for
///      the new epoch and the old one keeps verifying old signatures forever.
///
///      Signature subgroup: BN254 G1 has cofactor 1, so any point satisfying
///      the curve equation other than infinity is already in the order-r
///      subgroup. Rejecting infinity is therefore the whole of the small
///      subgroup defence on the attacker-controlled input. The group key lives
///      in G2, which has a large cofactor, and *is* subgroup-checked — once, in
///      the constructor.
contract VRFVerifier is IVRFVerifier {
    /// @notice Group public key was not a valid, non-trivial point of G2
    error InvalidGroupPublicKey();

    /// @dev Base field modulus of BN254
    uint256 private constant P_MOD =
        21888242871839275222246405745257275088696311157297823662689037894645226208583;

    /// @dev Length of a serialised G1 point: two 32-byte big-endian coordinates
    uint256 private constant SIGNATURE_LENGTH = 64;

    /// @dev Fixed for the lifetime of the protocol. Operators hash with exactly
    ///      these bytes; changing them invalidates every signature ever made.
    bytes private constant DST = "RH-VRF-BN254G1_XMD:KECCAK-256_SVDW_RO_V1_";

    uint256 private immutable _pkX0;
    uint256 private immutable _pkX1;
    uint256 private immutable _pkY0;
    uint256 private immutable _pkY1;
    uint64 private immutable _epoch;

    /// @param groupPublicKey_ Group key in G2 as [x.c0, x.c1, y.c0, y.c1]
    /// @param epoch_ Identifier of the DKG epoch this key belongs to
    constructor(uint256[4] memory groupPublicKey_, uint64 epoch_) {
        if (!_isUsableGroupKey(groupPublicKey_)) revert InvalidGroupPublicKey();

        _pkX0 = groupPublicKey_[0];
        _pkX1 = groupPublicKey_[1];
        _pkY0 = groupPublicKey_[2];
        _pkY1 = groupPublicKey_[3];
        _epoch = epoch_;
    }

    /// @inheritdoc IVRFVerifier
    function verify(bytes32 seed, bytes calldata signature) external view returns (bool) {
        if (signature.length != SIGNATURE_LENGTH) return false;

        uint256 x;
        uint256 y;
        assembly ("memory-safe") {
            x := calldataload(signature.offset)
            y := calldataload(add(signature.offset, 32))
        }

        // Point at infinity is encoded as (0, 0) and is the only low-order point
        // in G1; it must never be treated as a signature.
        if (x == 0 && y == 0) return false;
        // Field range and curve membership. Skipping either lets the pairing
        // precompile be fed garbage, and a failing precompile call is not the
        // same thing as a failing verification.
        if (!BLS.isValidSignature([x, y])) return false;

        (bool pairingOk, bool callOk) = BLS.verifySingle(
            [x, y], _groupPublicKey(), BLS.hashToPoint(DST, abi.encodePacked(seed))
        );
        return callOk && pairingOk;
    }

    /// @inheritdoc IVRFVerifier
    function verifyBatch(bytes32[] calldata seeds, bytes calldata signature)
        external
        view
        returns (bool)
    {
        if (seeds.length == 0) return false;
        if (signature.length != SIGNATURE_LENGTH) return false;

        uint256 x;
        uint256 y;
        assembly ("memory-safe") {
            x := calldataload(signature.offset)
            y := calldataload(add(signature.offset, 32))
        }
        if (x == 0 && y == 0) return false;
        if (!BLS.isValidSignature([x, y])) return false;

        // Signatures under one key add, and the verification equation adds with
        // them: e(Σσ, g2) == e(ΣH(m), pk). So a batch of any size costs one
        // pairing — the part that does not shrink with anything else — plus a
        // hash-to-curve and a point addition for each member.
        //
        // The hash stays on chain deliberately. A caller that could hand in the
        // curve point instead of the seed would be choosing what the group is
        // deemed to have signed, and no signature check downstream would notice.
        uint256[2] memory sum = BLS.hashToPoint(DST, abi.encodePacked(seeds[0]));
        for (uint256 i = 1; i < seeds.length; i++) {
            uint256[2] memory next = BLS.hashToPoint(DST, abi.encodePacked(seeds[i]));
            uint256[4] memory input = [sum[0], sum[1], next[0], next[1]];
            bool added;
            assembly ("memory-safe") {
                added := staticcall(gas(), 6, input, 128, sum, 64)
            }
            if (!added) return false;
        }

        (bool pairingOk, bool callOk) = BLS.verifySingle([x, y], _groupPublicKey(), sum);
        return callOk && pairingOk;
    }

    /// @inheritdoc IVRFVerifier
    function groupPublicKey() external view returns (uint256[4] memory) {
        return _groupPublicKey();
    }

    /// @inheritdoc IVRFVerifier
    function keyHash() external view returns (bytes32) {
        return keccak256(abi.encode(_groupPublicKey()));
    }

    /// @inheritdoc IVRFVerifier
    function epoch() external view returns (uint64) {
        return _epoch;
    }

    /// @inheritdoc IVRFVerifier
    function domainSeparationTag() external pure returns (bytes memory) {
        return DST;
    }

    /// @inheritdoc IVRFVerifier
    function hashSeedToPoint(bytes32 seed) external view returns (uint256[2] memory) {
        return BLS.hashToPoint(DST, abi.encodePacked(seed));
    }

    function _groupPublicKey() private view returns (uint256[4] memory) {
        return [_pkX0, _pkX1, _pkY0, _pkY1];
    }

    /// @dev Curve membership plus subgroup membership. The subgroup part is
    ///      delegated to the pairing precompile, which per EIP-197 fails the
    ///      whole call when an input point is not in the correct subgroup —
    ///      there is no way to compute a G2 scalar multiplication on the EVM to
    ///      check it directly.
    function _isUsableGroupKey(uint256[4] memory pk) private view returns (bool) {
        if (pk[0] == 0 && pk[1] == 0 && pk[2] == 0 && pk[3] == 0) return false;
        if (!BLS.isValidPublicKey(pk)) return false;

        // e(G1, pk): the result is irrelevant, only whether the precompile
        // accepted the point at all.
        uint256[6] memory input = [uint256(1), uint256(2), pk[1], pk[0], pk[3], pk[2]];
        uint256[1] memory out;
        bool callOk;
        assembly ("memory-safe") {
            callOk := staticcall(gas(), 8, input, 192, out, 0x20)
        }
        return callOk;
    }
}
