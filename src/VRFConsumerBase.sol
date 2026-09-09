// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IVRFCoordinator} from "./interfaces/IVRFCoordinator.sol";

/// @title VRFConsumerBase
/// @notice Inherit this to receive random words.
///
/// @dev Member names, callback names and errors follow the convention most
///      integrators already have in their codebase, so an existing consumer
///      usually needs only its imports changed.
///
/// @dev Three rules, and every one of them has bitten someone before:
///
///      1. The result arrives in a *different transaction*. That is deliberate:
///         it is what stops a consumer from reverting its own transaction when
///         it dislikes the outcome, which would turn any VRF into a free reroll.
///      2. Close the bet, take the payment, lock the action at request time —
///         not at callback time.
///      3. Never use `requestId` as entropy. It is public and predictable
///         before the randomness exists.
///
///      `fulfillRandomWords` must not revert and must not run out of gas: the
///      coordinator caps the callback at the `callbackGasLimit` you asked for
///      and does not roll fulfillment back if it fails. A failed callback is
///      recoverable — anyone can call `retryCallback` and the same words are
///      delivered again — so make your callback idempotent.
abstract contract VRFConsumerBase {
    error OnlyCoordinatorCanFulfill(address have, address want);
    error ZeroAddress();

    /// @notice The coordinator this consumer is bound to.
    IVRFCoordinator public immutable s_vrfCoordinator;

    constructor(address _vrfCoordinator) {
        if (_vrfCoordinator == address(0)) revert ZeroAddress();
        s_vrfCoordinator = IVRFCoordinator(_vrfCoordinator);
    }

    /// @notice Address of the coordinator this consumer is wired to.
    /// @dev A subscription manager can call this on any address before adding
    ///      it as a consumer, to catch the most common integration mistake:
    ///      adding a contract that is not wired to this coordinator at all.
    function coordinator() public view returns (address) {
        return address(s_vrfCoordinator);
    }

    /// @notice Entry point for the coordinator. Do not override.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(s_vrfCoordinator)) {
            revert OnlyCoordinatorCanFulfill(msg.sender, address(s_vrfCoordinator));
        }
        fulfillRandomWords(requestId, randomWords);
    }

    /// @notice Your logic goes here.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal virtual;
}
