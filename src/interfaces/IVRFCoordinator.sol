// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title IVRFCoordinator
/// @notice The request surface of the VRF.
///
/// @dev The shape follows the interface most integrators already have in their
///      codebase, so that bringing an existing consumer across is a matter of
///      changing imports rather than rewriting logic. Where it departs from
///      that convention it is because this scheme genuinely differs, and every
///      such place is called out below.
interface IVRFCoordinator {
    /// @param keyHash Which group key the request is meant for. Pass `0` for
    ///        "whatever key is current". There is one operator group here, so
    ///        this selects nothing — but it does pin the epoch, so a request
    ///        cannot be silently served by a key the consumer did not expect.
    /// @param subId The subscription that pays
    /// @param requestConfirmations Accepted so that existing consumer code
    ///        compiles unchanged, and always satisfied immediately. Nothing in
    ///        this seed comes from a block, so there is nothing for
    ///        confirmations to protect against — see
    ///        `minimumRequestConfirmations()`.
    /// @param callbackGasLimit Gas handed to your `fulfillRandomWords`. You pay
    ///        for it whether or not you use it.
    /// @param numWords How many random words you want, 1 to `MAX_WORDS`
    /// @param extraArgs Payment options, abi-encoded behind a version tag. The
    ///        only currency here is the chain's own, so an empty value means
    ///        exactly that; a request that explicitly asks to be billed in a
    ///        token is rejected rather than silently charged in something else.
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }

    /// @notice Ask for randomness. The caller must be an approved consumer of
    ///         the subscription, and the subscription must cover the price,
    ///         which is reserved immediately.
    function requestRandomWords(RandomWordsRequest calldata req)
        external
        returns (uint256 requestId);

    /// @notice Publish the group signature over a request's seed. Anyone may call.
    function fulfillRandomWords(uint256 requestId, bytes calldata signature) external;

    /// @notice Deliver the words again to a consumer whose callback failed.
    /// @dev Anyone may call, and nobody is charged for it: the signature is
    ///      public, the words it produces are fixed, and the only thing that
    ///      can happen is that the consumer finally receives what it already
    ///      paid for. Rejected once the callback has succeeded, so it cannot be
    ///      used to deliver twice. Without it a failed callback would lose the
    ///      result permanently: the request is paid for, so `refund` refuses it,
    ///      and the words exist only in an event no contract can read.
    function retryCallback(uint256 requestId, bytes calldata signature) external;

    /// @notice Release a timed-out request's reservation. Anyone may call.
    function refund(uint256 requestId) external;

    /// @notice The value the operators sign for a request.
    function seedOf(uint256 requestId) external view returns (bytes32);

    /// @notice Price of a request, in wei. Quoted on-chain rather than
    ///         estimated off-chain, so a caller can check before committing.
    function price(uint32 numWords, uint32 callbackGasLimit) external view returns (uint96);

    /// @notice Limits and the key hashes this coordinator will serve.
    function getRequestConfig()
        external
        view
        returns (
            uint16 minimumRequestConfirmations,
            uint16 maxRequestConfirmations,
            uint32 maxCallbackGasLimit,
            uint32 maxNumWords,
            bytes32[] memory keyHashes
        );
}
