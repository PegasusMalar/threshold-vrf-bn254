// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title Threshold BLS signature verifier for the VRF
/// @notice The only thing standing between a forged signature and a paid-out
///         random number. It holds no funds and has no privileged functions.
interface IVRFVerifier {
    /// @notice Check that `signature` is the group's BLS signature over `seed`.
    /// @dev MUST NOT revert on malformed input: the coordinator treats `false`
    ///      as "not fulfilled yet", while a revert would let a griefer choose
    ///      between the two failure modes.
    /// @param seed The value being signed, as emitted by the coordinator
    /// @param signature 64 bytes: the G1 point (x, y), big-endian
    function verify(bytes32 seed, bytes calldata signature) external view returns (bool);

    /// @notice The immutable group public key in G2, as [x.c0, x.c1, y.c0, y.c1]
    /// @notice Verifies one aggregate signature over many seeds at once.
    ///
    /// @dev The seeds are summed as curve points, so the order they arrive in
    ///      does not matter and a seed appearing twice counts twice. A caller
    ///      that settles per seed must therefore reject duplicates itself: two
    ///      copies of a seed sum to 2·H(s), and 2·σ is something anyone holding
    ///      one published signature can compute.
    ///
    /// @return true when the aggregate is the group's signature over exactly
    ///         these seeds. False, never a revert, on anything malformed.
    function verifyBatch(bytes32[] calldata seeds, bytes calldata signature)
        external
        view
        returns (bool);

    function groupPublicKey() external view returns (uint256[4] memory);

    /// @notice Identifier of the group key, for consumers that want to pin the
    ///         epoch their request is served by.
    function keyHash() external view returns (bytes32);

    /// @notice Key epoch this verifier was deployed for
    function epoch() external view returns (uint64);

    /// @notice Domain separation tag used when hashing a seed to G1
    function domainSeparationTag() external pure returns (bytes memory);

    /// @notice Hash a seed to a point on G1, exactly as operators must do off-chain
    function hashSeedToPoint(bytes32 seed) external view returns (uint256[2] memory);
}
