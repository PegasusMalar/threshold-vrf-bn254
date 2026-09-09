// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RequestingConsumer} from "./Consumers.sol";
import {IVRFCoordinator} from "../../src/interfaces/IVRFCoordinator.sol";

/// @notice Re-enters `retryCallback` from inside a delivery, to be delivered
///         the same words twice.
///
/// @dev The window it aims at is real: both delivery paths record
///      `callbackSucceeded` only after the consumer returns, so while the
///      consumer holds control the request reads as "fulfilled, never
///      delivered" — exactly the state `retryCallback` exists to serve. The
///      contract's own comment claims the flag is what prevents a second
///      delivery, and inside that window the flag is still false.
///
///      Re-entering is not something a consumer does to itself for fun. The
///      realistic shape is a consumer that pays someone from inside its
///      callback — a lottery paying a winner, a game paying a player — and the
///      payee re-enters. The callback would then run twice on one request, and
///      a consumer that counts a payout per delivery pays twice.
contract DoubleDeliveryAttacker is RequestingConsumer {
    bytes public signature;
    uint256 public target;
    uint256 public deliveries;
    bool public failFirst = true;
    bool public reentryAttempted;
    bool public reentryReverted;
    bytes public reentryError;

    constructor(address coordinator_) RequestingConsumer(coordinator_) {}

    function arm(bytes calldata signature_) external {
        signature = signature_;
        failFirst = false;
    }

    /// Aims the re-entry at a different request than the one being delivered.
    /// That is the shape a batch adds: several of this consumer's requests are
    /// in flight inside one transaction, and an earlier callback runs while the
    /// later ones are somewhere in the middle of being settled.
    function armFor(uint256 requestId_, bytes calldata signature_) external {
        target = requestId_;
        signature = signature_;
        failFirst = false;
    }

    function fulfillRandomWords(uint256 requestId, uint256[] calldata) internal override {
        // Until armed the consumer is simply broken, which is how a request
        // reaches the "fulfilled but never delivered" state that retry serves.
        if (failFirst) revert("consumer is broken");

        deliveries++;
        if (reentryAttempted) return; // one attempt: it either lands or it does not
        reentryAttempted = true;

        // Swallowed rather than bubbled: an attacker gains nothing by taking
        // the whole transaction down, and swallowing is what a payee
        // re-entering through an unrelated protocol would do anyway.
        try s_vrfCoordinator.retryCallback(target == 0 ? requestId : target, signature) {}
        catch (bytes memory err) {
            reentryReverted = true;
            reentryError = err;
        }
    }
}

/// @notice Orders the largest, most expensive request the coordinator allows,
///         to price what a request costs the person making it against what it
///         costs the operator who has to fulfil it.
contract GreedyConsumer is RequestingConsumer {
    uint256 public deliveries;
    uint256 public wordsSeen;

    constructor(address coordinator_) RequestingConsumer(coordinator_) {}

    function fulfillRandomWords(uint256, uint256[] calldata words) internal override {
        deliveries++;
        wordsSeen = words.length;
    }
}

/// @notice Spends every unit of callback gas it is given, on nothing.
///
/// @dev The callback budget is a ceiling, not a charge: an operator pays only
///      for gas the consumer actually uses, so a large limit alone costs it
///      nothing. This is the consumer that turns the ceiling into a bill.
contract BudgetBurner {
    address public immutable coordinator;

    constructor(address coordinator_) {
        coordinator = coordinator_;
    }

    function request(uint256 subId, uint32 numWords, uint32 callbackGasLimit)
        external
        returns (uint256)
    {
        return IVRFCoordinator(coordinator)
            .requestRandomWords(
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

    fallback() external {
        uint256 i;
        while (true) {
            i = i + 1;
        }
    }
}

/// @notice The cheapest callback that still proves delivery happened.
///
/// @dev Used where the number being measured is the protocol's own cost. A
///      consumer that writes an array to storage adds tens of thousands of gas
///      of its own, which is real for that consumer and noise for a comparison
///      between two ways of settling the same request.
contract CountingConsumer is RequestingConsumer {
    uint256 public deliveries;

    constructor(address coordinator_) RequestingConsumer(coordinator_) {}

    function fulfillRandomWords(uint256, uint256[] calldata) internal override {
        deliveries++;
    }
}
