// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVRFVerifier} from "../src/interfaces/IVRFVerifier.sol";
import {IVRFCoordinator} from "../src/interfaces/IVRFCoordinator.sol";
import {VRFVerifier} from "../src/VRFVerifier.sol";
import {VRFCoordinator} from "../src/VRFCoordinator.sol";
import {Subscription} from "../src/Subscription.sol";

/// @notice Measurement harness for the phase-1 gas benchmark.
///
/// @dev Deployed nowhere: it is injected with an `eth_call` state override so
///      the numbers come from the target chain's own EVM, at its own ArbOS
///      version, without spending anything. See script/bench.sh.
contract GasProbe {
    function probe(address verifier, bytes32 seed, bytes calldata signature)
        external
        view
        returns (uint256 verifyGas, uint256 hashGas, uint256 pairingGas, bool verified)
    {
        uint256 g = gasleft();
        verified = IVRFVerifier(verifier).verify(seed, signature);
        verifyGas = g - gasleft();

        g = gasleft();
        IVRFVerifier(verifier).hashSeedToPoint(seed);
        hashGas = g - gasleft();

        pairingGas = _rawPairingGas();
    }

    /// @dev Cost of the bare ecPairing precompile with k=2, isolated from
    ///      everything else. This is the number the economics hang on.
    function _rawPairingGas() private view returns (uint256) {
        // e(G1, G2) * e(-G1, G2) == 1: two pairs, valid points, result 1.
        uint256 p = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
        uint256[12] memory input = [
            uint256(1),
            uint256(2),
            11559732032986387107991004021392285783925812861821192530917403151452391805634,
            10857046999023057135944570762232829481370756359578518086990519993285655852781,
            4082367875863433681332203403145435568316851327593401208105741076214120093531,
            8495653923123431417604973247489272438418190587263600148770280649306958101930,
            uint256(1),
            p - 2,
            11559732032986387107991004021392285783925812861821192530917403151452391805634,
            10857046999023057135944570762232829481370756359578518086990519993285655852781,
            4082367875863433681332203403145435568316851327593401208105741076214120093531,
            8495653923123431417604973247489272438418190587263600148770280649306958101930
        ];
        uint256[1] memory out;
        bool ok;
        uint256 g = gasleft();
        assembly ("memory-safe") {
            ok := staticcall(gas(), 8, input, 384, out, 0x20)
        }
        uint256 used = g - gasleft();
        require(ok && out[0] == 1, "pairing probe failed");
        return used;
    }

    /// @notice Builds the whole stack inside this `eth_call` and measures a real
    ///         `fulfillRandomWords` on the target chain.
    ///
    /// @dev Nothing is deployed and nothing is spent: the call is discarded when
    ///      it returns. The group secret is passed in because only a *test* key
    ///      is ever used here — it lets the probe produce `sigma = sk * H(seed)`
    ///      with the ecMul precompile instead of needing an off-chain signer.
    function probeFulfill(uint256[4] calldata groupPublicKey, uint256 secretKey, uint32 numWords)
        external
        returns (uint256 requestGas, uint256 coldFulfillGas, uint256 warmFulfillGas)
    {
        VRFCoordinator coordinator = new VRFCoordinator(
            address(new VRFVerifier(groupPublicKey, 1)),
            0.0001 ether,
            0.00001 ether,
            0,
            type(uint96).max,
            type(uint96).max,
            type(uint96).max
        );
        {
            Subscription subs = Subscription(address(coordinator.subscriptions()));
            uint256 subId = subs.createSubscription();
            subs.fundSubscription{value: 1 ether}(subId);
            subs.addConsumer(subId, address(this));
            IVRFCoordinator.RandomWordsRequest memory req = IVRFCoordinator.RandomWordsRequest({
                keyHash: bytes32(0),
                subId: subId,
                requestConfirmations: 0,
                callbackGasLimit: 500_000,
                numWords: numWords,
                extraArgs: ""
            });
            coordinator.requestRandomWords(req);

            // second request measured separately: by then the nonce, the account
            // and the subscription slots are warm, which is the steady state a
            // running service actually pays
            uint256 g = gasleft();
            coordinator.requestRandomWords(req);
            requestGas = g - gasleft();
        }
        coldFulfillGas = _fulfill(coordinator, 0, secretKey);
        warmFulfillGas = _fulfill(coordinator, 1, secretKey);
    }

    function _fulfill(VRFCoordinator coordinator, uint256 nonce, uint256 secretKey)
        private
        returns (uint256 used)
    {
        uint256 requestId = uint256(
            keccak256(abi.encodePacked(address(this), nonce, address(coordinator), block.chainid))
        );
        bytes memory sig = _sign(
            VRFVerifier(address(coordinator.verifier())), coordinator.seedOf(requestId), secretKey
        );
        uint256 g = gasleft();
        coordinator.fulfillRandomWords(requestId, sig);
        used = g - gasleft();
        (,,,, bool ok,,) = coordinator.requests(requestId);
        require(ok, "fulfillment failed");
    }

    /// @dev Stands in for a consumer whose callback costs nothing, so the number
    ///      reported is the protocol's own cost.
    function rawFulfillRandomWords(uint256, uint256[] calldata) external {}

    function _sign(VRFVerifier verifier, bytes32 seed, uint256 secretKey)
        private
        view
        returns (bytes memory)
    {
        uint256[2] memory point = verifier.hashSeedToPoint(seed);
        uint256[3] memory input = [point[0], point[1], secretKey];
        uint256[2] memory out;
        bool ok;
        assembly ("memory-safe") {
            ok := staticcall(gas(), 7, input, 96, out, 64)
        }
        require(ok, "ecMul failed");
        return abi.encodePacked(out[0], out[1]);
    }
}
