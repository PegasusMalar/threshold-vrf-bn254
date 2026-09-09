// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {VRFVerifier} from "../../src/VRFVerifier.sol";

/// @notice Shared fixture: loads the BLS test vectors and can sign any seed.
///
/// @dev Signing happens on-chain via the ecMul precompile: sigma = sk * H(seed).
///      That is only possible because the fixture knows the whole group secret,
///      which in production never exists anywhere. It lets the tests sign
///      arbitrary seeds instead of being limited to precomputed vectors.
abstract contract VRFTestBase is Test {
    uint256 internal groupSecretKey;
    uint256[4] internal groupPubKey;
    uint256[4] internal otherEpochPubKey;
    uint256 internal otherEpochSecretKey;

    function _loadVectors() internal {
        string memory json = vm.readFile("test/vectors/bls.json");
        groupSecretKey = vm.parseJsonUint(json, ".groupSecretKey");
        uint256[] memory pk = vm.parseJsonUintArray(json, ".groupPubKey");
        groupPubKey = [pk[0], pk[1], pk[2], pk[3]];
        uint256[] memory wrong = vm.parseJsonUintArray(json, ".wrongPubKey");
        otherEpochPubKey = [wrong[0], wrong[1], wrong[2], wrong[3]];
        otherEpochSecretKey = vm.parseJsonUint(json, ".wrongSecretKey");
    }

    function _sign(VRFVerifier verifier, bytes32 seed, uint256 secretKey)
        internal
        view
        returns (bytes memory)
    {
        uint256[2] memory point = verifier.hashSeedToPoint(seed);
        uint256[3] memory input = [point[0], point[1], secretKey];
        uint256[2] memory out;
        bool ok;
        assembly {
            ok := staticcall(gas(), 7, input, 96, out, 64)
        }
        require(ok, "ecMul failed");
        return abi.encodePacked(out[0], out[1]);
    }
}
