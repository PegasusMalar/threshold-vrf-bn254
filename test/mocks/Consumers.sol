// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VRFConsumerBase} from "../../src/VRFConsumerBase.sol";
import {IVRFCoordinator} from "../../src/interfaces/IVRFCoordinator.sol";

/// @dev Every mock builds its request the way an integrator would, so the tests
///      exercise the Chainlink-shaped struct rather than a shortcut.
abstract contract RequestingConsumer is VRFConsumerBase {
    uint32 public constant DEFAULT_CALLBACK_GAS = 500_000;

    constructor(address coordinator_) VRFConsumerBase(coordinator_) {}

    function request(uint256 subId, uint32 numWords) external returns (uint256) {
        return s_vrfCoordinator.requestRandomWords(
            IVRFCoordinator.RandomWordsRequest({
                keyHash: bytes32(0),
                subId: subId,
                requestConfirmations: 0,
                callbackGasLimit: DEFAULT_CALLBACK_GAS,
                numWords: numWords,
                extraArgs: ""
            })
        );
    }

    function requestWithGas(uint256 subId, uint32 numWords, uint32 callbackGasLimit)
        external
        returns (uint256)
    {
        return s_vrfCoordinator.requestRandomWords(
            IVRFCoordinator.RandomWordsRequest({
                keyHash: bytes32(0),
                subId: subId,
                requestConfirmations: 0,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: ""
            })
        );
    }

    function requestRandomWords(IVRFCoordinator.RandomWordsRequest calldata req)
        external
        returns (uint256)
    {
        return s_vrfCoordinator.requestRandomWords(req);
    }
}

/// @notice A consumer that behaves.
contract MockConsumer is RequestingConsumer {
    uint256 public lastRequestId;
    uint256[] public lastWords;
    uint256 public callbackCount;

    constructor(address coordinator_) RequestingConsumer(coordinator_) {}

    function fulfillRandomWords(uint256 requestId, uint256[] calldata words) internal override {
        lastRequestId = requestId;
        lastWords = words;
        callbackCount++;
    }

    function wordsLength() external view returns (uint256) {
        return lastWords.length;
    }
}

/// @notice A consumer with a bug in it. Must not be able to block its own request.
contract RevertingConsumer is RequestingConsumer {
    constructor(address coordinator_) RequestingConsumer(coordinator_) {}

    function fulfillRandomWords(uint256, uint256[] calldata) internal pure override {
        revert("consumer is broken");
    }
}

/// @notice Reverts until it is fixed, then works. Stands in for the integrator
///         who ships a bug, notices, and needs the result delivered again.
contract FlakyConsumer is RequestingConsumer {
    bool public fixed_;
    uint256 public lastRequestId;
    uint256[] public lastWords;
    uint256 public deliveries;

    constructor(address coordinator_) RequestingConsumer(coordinator_) {}

    function fix() external {
        fixed_ = true;
    }

    function fulfillRandomWords(uint256 requestId, uint256[] calldata words) internal override {
        require(fixed_, "not fixed yet");
        lastRequestId = requestId;
        lastWords = words;
        deliveries++;
    }

    function wordsLength() external view returns (uint256) {
        return lastWords.length;
    }
}

/// @notice Re-enters retryCallback from inside its own retried callback.
contract RetryReentrantConsumer is RequestingConsumer {
    bytes public signature;
    bool public armed;
    uint256 public deliveries;
    uint256 public depth;

    constructor(address coordinator_) RequestingConsumer(coordinator_) {}

    function arm(bytes calldata signature_) external {
        signature = signature_;
        armed = true;
    }

    function fulfillRandomWords(uint256 requestId, uint256[] calldata) internal override {
        deliveries++;
        if (!armed) revert("first delivery fails");
        if (depth < 3) {
            depth++;
            try s_vrfCoordinator.retryCallback(requestId, signature) {} catch {}
        }
    }
}

/// @notice Tries to re-enter the coordinator from inside its own callback.
contract ReentrantConsumer is RequestingConsumer {
    bytes public signature;
    bool public reenterFulfill;
    bool public reenterRefund;
    bool public reenterRequest;
    uint256 public subId;

    bool public fulfillReentryReverted;
    bool public refundReentryReverted;
    uint256 public reentrantRequestId;

    constructor(address coordinator_) RequestingConsumer(coordinator_) {}

    function arm(
        bytes calldata signature_,
        bool fulfill_,
        bool refund_,
        bool request_,
        uint256 sub_
    ) external {
        signature = signature_;
        reenterFulfill = fulfill_;
        reenterRefund = refund_;
        reenterRequest = request_;
        subId = sub_;
    }

    function fulfillRandomWords(uint256 requestId, uint256[] calldata) internal override {
        if (reenterFulfill) {
            try s_vrfCoordinator.fulfillRandomWords(requestId, signature) {}
            catch {
                fulfillReentryReverted = true;
            }
        }
        if (reenterRefund) {
            try s_vrfCoordinator.refund(requestId) {}
            catch {
                refundReentryReverted = true;
            }
        }
        if (reenterRequest) {
            try s_vrfCoordinator.requestRandomWords(
                IVRFCoordinator.RandomWordsRequest({
                    keyHash: bytes32(0),
                    subId: subId,
                    requestConfirmations: 0,
                    callbackGasLimit: 500_000,
                    numWords: 1,
                    extraArgs: ""
                })
            ) returns (
                uint256 id
            ) {
                reentrantRequestId = id;
            } catch {}
        }
    }
}

/// @notice Burns every drop of gas it is given, then would return a huge blob.
contract GasBombConsumer {
    address public immutable coordinator;

    constructor(address coordinator_) {
        coordinator = coordinator_;
    }

    function request(uint256 subId, uint32 numWords) external returns (uint256) {
        return IVRFCoordinator(coordinator)
            .requestRandomWords(
                IVRFCoordinator.RandomWordsRequest({
                keyHash: bytes32(0),
                subId: subId,
                requestConfirmations: 0,
                callbackGasLimit: 500_000,
                numWords: numWords,
                extraArgs: ""
            })
            );
    }

    fallback() external {
        uint256 i;
        while (true) {
            i = i + 1;
        }
    }
}

/// @notice Returns 64 KiB of return data, to see whether the coordinator is
///         careless enough to copy it into its own memory.
contract ReturnBombConsumer {
    address public immutable coordinator;

    constructor(address coordinator_) {
        coordinator = coordinator_;
    }

    function request(uint256 subId, uint32 numWords) external returns (uint256) {
        return IVRFCoordinator(coordinator)
            .requestRandomWords(
                IVRFCoordinator.RandomWordsRequest({
                keyHash: bytes32(0),
                subId: subId,
                requestConfirmations: 0,
                callbackGasLimit: 500_000,
                numWords: numWords,
                extraArgs: ""
            })
            );
    }

    fallback() external {
        assembly {
            return(0, 0x10000)
        }
    }
}
