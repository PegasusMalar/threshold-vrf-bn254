// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VRFConsumerBase} from "../src/VRFConsumerBase.sol";
import {IVRFCoordinator} from "../src/interfaces/IVRFCoordinator.sol";

/// @notice Fires many requests from one transaction, so that the load test
///         measures the protocol rather than the tester's own nonce.
///
/// @dev A caller sending requests one transaction at a time is limited to one
///      per nonce per block, which says nothing about what the operators can
///      take. Here a single transaction opens a whole burst, all of them landing
///      in the same block with the same timestamp — which also makes the latency
///      of a burst unambiguous to measure.
///
///      The callback does the least it possibly can: one counter. Anything more
///      would be measuring the consumer.
contract LoadGenerator is VRFConsumerBase {
    error NothingToFire();

    event Burst(uint256 indexed firstRequestId, uint32 count, uint64 atBlock);

    uint256 public immutable subId;

    uint256 public fired;
    uint256 public delivered;
    /// @notice Requests this contract fired, in order, so the driver can watch
    ///         exactly the right ids without trusting log ordering.
    uint256[] public requestIds;

    constructor(address _vrfCoordinator, uint256 _subId) VRFConsumerBase(_vrfCoordinator) {
        subId = _subId;
    }

    function fire(uint32 count, uint32 numWords, uint32 callbackGasLimit)
        external
        returns (uint256 first)
    {
        if (count == 0) revert NothingToFire();

        IVRFCoordinator.RandomWordsRequest memory req = IVRFCoordinator.RandomWordsRequest({
            keyHash: bytes32(0),
            subId: subId,
            requestConfirmations: 0,
            callbackGasLimit: callbackGasLimit,
            numWords: numWords,
            extraArgs: ""
        });

        for (uint32 i = 0; i < count; i++) {
            uint256 id = s_vrfCoordinator.requestRandomWords(req);
            if (i == 0) first = id;
            requestIds.push(id);
        }
        fired += count;
        emit Burst(first, count, uint64(block.number));
    }

    function fulfillRandomWords(uint256, uint256[] calldata) internal override {
        delivered++;
    }

    function requestCount() external view returns (uint256) {
        return requestIds.length;
    }

    /// @notice A window of the fired ids, for a driver that does not want them all.
    function requestsFrom(uint256 start, uint256 count)
        external
        view
        returns (uint256[] memory out)
    {
        if (start >= requestIds.length) return out;
        uint256 end = start + count;
        if (end > requestIds.length) end = requestIds.length;
        out = new uint256[](end - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = requestIds[start + i];
        }
    }
}
