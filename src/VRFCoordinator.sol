// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVRFVerifier} from "./interfaces/IVRFVerifier.sol";
import {IVRFCoordinator} from "./interfaces/IVRFCoordinator.sol";
import {IVRFConsumer} from "./interfaces/IVRFConsumer.sol";
import {Subscription} from "./Subscription.sol";

/// @title VRFCoordinator
/// @notice Takes requests, emits seeds for the operators to sign, and closes
///         requests against a valid group signature.
///
/// @dev Holds no funds of its own — the money lives in `Subscription`, which
///      only this address may move. Fulfillment is open to anyone, because the
///      signature over a seed is unique and nobody can bring a different result.
///
///      There is exactly one privilege in the system and it lives here: an
///      owner who may propose a new price, never above a ceiling fixed at
///      deployment, never sooner than a week after announcing it, and never
///      reaching a request that was already made. That owner can also give the
///      power up for good — see `renounceOwnership`.
///
///      A note on `block.number`: on an Arbitrum Orbit chain this is the *L1*
///      block number, not the L2 one (25.8M vs 47.6M on Robinhood Chain as of
///      2026-08-27), and it advances roughly every 12 seconds. `TIMEOUT_BLOCKS`
///      is denominated in those. That is the safer of the two clocks here: the
///      sequencer can lag it, which only delays refunds, but cannot run it
///      forward to trigger refunds early.
contract VRFCoordinator is IVRFCoordinator {
    error BadWordCount();
    error ConsumerNotAuthorized();
    error NoSuchRequest();
    error RequestClosed();
    error InvalidProof();
    error TooEarly();
    error InsufficientGas();
    error NotFulfilled();
    error CallbackAlreadyDelivered();
    error NotOwner();
    error NotPendingOwner();
    error FeeAboveCap();
    error NoFeeChangePending();
    error UnknownKeyHash();
    error BadRequestConfirmations();
    error BadCallbackGasLimit();
    error PriceOverflow();
    error InvalidExtraArgsTag();
    error NativePaymentOnly();
    error EmptyBatch();
    error BatchNotSorted();

    /// @dev Argument types and order match the established convention exactly,
    ///      so `topic0` is the one existing indexers already listen for and no
    ///      subgraph needs rewriting. `seed` sits where that convention puts a
    ///      pre-seed; here it is the final value the operators sign, not an
    ///      input to further hashing.
    event RandomWordsRequested(
        bytes32 indexed keyHash,
        uint256 requestId,
        uint256 seed,
        uint256 indexed subId,
        uint16 requestConfirmations,
        uint32 callbackGasLimit,
        uint32 numWords,
        bytes extraArgs,
        address indexed sender
    );

    /// @dev Same shape, same reason. `nativePayment` is always true and
    ///      `onlyPremium` always false — there is one currency and one tier —
    ///      but the fields are carried so decoders line up.
    event RandomWordsFulfilled(
        uint256 indexed requestId,
        uint256 outputSeed,
        uint256 indexed subId,
        uint96 payment,
        bool nativePayment,
        bool success,
        bool onlyPremium
    );
    event CallbackRetried(uint256 indexed requestId, bool callbackSucceeded);
    event RequestRefunded(uint256 indexed requestId, uint96 released);
    event FeeChangeProposed(
        uint96 baseFee, uint96 perWordFee, uint96 perCallbackGasFee, uint64 effectiveAtBlock
    );
    event FeeChangeCancelled();
    event FeesChanged(uint96 baseFee, uint96 perWordFee, uint96 perCallbackGasFee);
    event OwnerTransferRequested(address indexed from, address indexed to);
    event OwnerTransferred(address indexed from, address indexed to);

    struct Request {
        address consumer;
        uint64 subId;
        uint32 numWords;
        uint32 callbackGasLimit;
        uint64 createdAtBlock;
        // What this request was quoted, recorded so that a later fee change can
        // never reach back and reprice work that was already ordered. Shares a
        // slot with the fields around it.
        uint96 paid;
        bool fulfilled;
        bool refunded;
        // Whether the consumer actually accepted the words. Shares a slot with
        // the two flags above, so recording it costs a warm write and nothing
        // more — and without it a consumer that reverted once could never be
        // told apart from one that was never called.
        bool callbackSucceeded;
    }

    /// @notice Largest batch a single request may ask for
    uint32 public constant MAX_WORDS = 500;

    /// @notice Ceiling on `callbackGasLimit`.
    uint32 public constant maxCallbackGasLimit = 2_500_000;

    /// @notice Always zero, and that is the point.
    ///
    /// @dev A VRF whose seed includes the request block's hash has to wait out
    ///      confirmations, because a sequencer or miner can otherwise influence
    ///      that hash. Nothing in this seed comes from a block — it is the
    ///      request id, the consumer, this address and the chain id — so there
    ///      is nothing to wait out. The field is accepted on requests anyway, so
    ///      that existing consumer code compiles unchanged, and echoed into the
    ///      event rather than quietly dropped.
    uint16 public constant minimumRequestConfirmations = 0;

    /// @notice Largest `requestConfirmations` value accepted. Wide enough that
    ///         a request copied from an existing integration does not revert.
    uint16 public constant maxRequestConfirmations = 200;

    /// @dev The version tag the usual client library prefixes payment options
    ///      with, so that a request built by it is accepted verbatim.
    bytes4 private constant EXTRA_ARGS_V1_TAG = bytes4(keccak256("VRF ExtraArgsV1"));

    /// @notice Gas the coordinator needs after the callback returns
    uint256 private constant POST_CALLBACK_GAS = 30_000;

    /// @notice Roughly a day, in L1 blocks. See the note above about which
    ///         clock `block.number` follows here.
    uint64 public constant TIMEOUT_BLOCKS = 7200;

    /// @notice Notice period before a fee change takes effect: ~7 days, in the
    ///         same L1 blocks as everything else here. One clock in the whole
    ///         system, and one the sequencer cannot run forward.
    uint64 public constant FEE_TIMELOCK_BLOCKS = 50_400;

    IVRFVerifier public immutable verifier;
    Subscription public immutable subscriptions;

    /// @notice The most this coordinator can ever charge, whatever anyone
    ///         decides later. Immutable: it is the only fee promise an
    ///         integrator has to take on trust, so it is made once, at
    ///         deployment, and cannot be walked back.
    uint96 public immutable maxBaseFee;
    /// @notice Ceiling on the marginal price per word
    uint96 public immutable maxPerWordFee;
    /// @notice Ceiling on the price per unit of callback gas
    uint96 public immutable maxPerCallbackGasFee;

    /// @notice Flat part of the price, in wei. Zero for the free tier.
    uint96 public baseFee;
    /// @notice Marginal price per random word, in wei
    uint96 public perWordFee;
    /// @notice Price per unit of requested callback gas, in wei
    uint96 public perCallbackGasFee;

    /// @notice Whoever may propose a fee change. Can do nothing else: not touch
    ///         requests, not touch funds, not touch the verifier. Renouncing
    ///         makes the current fee permanent.
    address public owner;
    address public pendingOwner;

    uint96 public pendingBaseFee;
    uint96 public pendingPerWordFee;
    uint96 public pendingPerCallbackGasFee;
    /// @notice Block from which a proposed change may be applied; 0 = none
    uint64 public pendingFeesEffectiveAtBlock;

    mapping(uint256 => Request) private _requests;
    mapping(address => uint256) public nonces;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        address verifier_,
        uint96 baseFee_,
        uint96 perWordFee_,
        uint96 perCallbackGasFee_,
        uint96 maxBaseFee_,
        uint96 maxPerWordFee_,
        uint96 maxPerCallbackGasFee_
    ) {
        if (
            baseFee_ > maxBaseFee_ || perWordFee_ > maxPerWordFee_
                || perCallbackGasFee_ > maxPerCallbackGasFee_
        ) {
            revert FeeAboveCap();
        }

        verifier = IVRFVerifier(verifier_);
        baseFee = baseFee_;
        perWordFee = perWordFee_;
        perCallbackGasFee = perCallbackGasFee_;
        maxBaseFee = maxBaseFee_;
        maxPerWordFee = maxPerWordFee_;
        maxPerCallbackGasFee = maxPerCallbackGasFee_;
        owner = msg.sender;
        subscriptions = new Subscription(address(this));
    }

    /* ------------------------------ pricing ------------------------------- */

    /// @notice Announce a new price. It takes effect no sooner than
    ///         `FEE_TIMELOCK_BLOCKS` later, and never above the cap.
    ///
    /// @dev The point of the delay is that an integrator gets a week to leave.
    ///      Re-proposing restarts it, so a proposal cannot be parked until the
    ///      notice period lapses and then swapped for a different number.
    function proposeFees(uint96 newBaseFee, uint96 newPerWordFee, uint96 newPerCallbackGasFee)
        external
        onlyOwner
    {
        if (
            newBaseFee > maxBaseFee || newPerWordFee > maxPerWordFee
                || newPerCallbackGasFee > maxPerCallbackGasFee
        ) revert FeeAboveCap();

        pendingBaseFee = newBaseFee;
        pendingPerWordFee = newPerWordFee;
        pendingPerCallbackGasFee = newPerCallbackGasFee;
        pendingFeesEffectiveAtBlock = uint64(block.number) + FEE_TIMELOCK_BLOCKS;
        emit FeeChangeProposed(
            newBaseFee, newPerWordFee, newPerCallbackGasFee, pendingFeesEffectiveAtBlock
        );
    }

    /// @notice Put an announced price into effect. Anyone may call: the delay
    ///         has already run, and making it the owner's move would only let
    ///         them sit on a change indefinitely.
    function applyFees() external {
        uint64 effectiveAt = pendingFeesEffectiveAtBlock;
        if (effectiveAt == 0) revert NoFeeChangePending();
        if (block.number < effectiveAt) revert TooEarly();

        baseFee = pendingBaseFee;
        perWordFee = pendingPerWordFee;
        perCallbackGasFee = pendingPerCallbackGasFee;
        _clearPendingFees();
        emit FeesChanged(baseFee, perWordFee, perCallbackGasFee);
    }

    /// @notice Withdraw an announced price change.
    function cancelFeeChange() external onlyOwner {
        _clearPendingFees();
        emit FeeChangeCancelled();
    }

    /* ----------------------------- ownership ------------------------------ */

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnerTransferRequested(msg.sender, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner || msg.sender == address(0)) revert NotPendingOwner();
        emit OwnerTransferred(owner, msg.sender);
        owner = msg.sender;
        delete pendingOwner;
    }

    /// @notice Give up the ability to change the fee, permanently.
    ///
    /// @dev The end state this design is aiming at: once pricing has settled,
    ///      the last privileged function in the system goes away and the price
    ///      becomes as fixed as the verifier. Any announced change is dropped
    ///      with it, so nothing can land after the owner is gone.
    function renounceOwnership() external onlyOwner {
        emit OwnerTransferred(owner, address(0));
        owner = address(0);
        delete pendingOwner;
        _clearPendingFees();
    }

    function _clearPendingFees() private {
        delete pendingBaseFee;
        delete pendingPerWordFee;
        delete pendingPerCallbackGasFee;
        delete pendingFeesEffectiveAtBlock;
    }

    /// @inheritdoc IVRFCoordinator
    function requestRandomWords(RandomWordsRequest calldata req)
        external
        returns (uint256 requestId)
    {
        // keyHash zero means "whatever key is current"; anything else has to be
        // the key actually deployed, so a request cannot be served by an epoch
        // the consumer did not expect.
        if (req.keyHash != bytes32(0) && req.keyHash != verifier.keyHash()) {
            revert UnknownKeyHash();
        }
        if (req.numWords == 0 || req.numWords > MAX_WORDS) revert BadWordCount();
        if (req.callbackGasLimit == 0 || req.callbackGasLimit > maxCallbackGasLimit) {
            revert BadCallbackGasLimit();
        }
        // Accepted and immediately satisfied — see minimumRequestConfirmations.
        if (req.requestConfirmations > maxRequestConfirmations) revert BadRequestConfirmations();
        _checkExtraArgs(req.extraArgs);
        if (!subscriptions.isConsumer(req.subId, msg.sender)) revert ConsumerNotAuthorized();

        requestId = uint256(
            keccak256(
                abi.encodePacked(msg.sender, nonces[msg.sender]++, address(this), block.chainid)
            )
        );
        uint96 quoted = price(req.numWords, req.callbackGasLimit);

        _requests[requestId] = Request({
            consumer: msg.sender,
            subId: uint64(req.subId),
            numWords: req.numWords,
            callbackGasLimit: req.callbackGasLimit,
            createdAtBlock: uint64(block.number),
            paid: quoted,
            fulfilled: false,
            refunded: false,
            callbackSucceeded: false
        });

        // Reverts if the subscription cannot cover it, and locks the money so
        // the owner cannot withdraw while the operators are signing.
        subscriptions.reserve(req.subId, quoted);

        emit RandomWordsRequested(
            verifier.keyHash(),
            requestId,
            uint256(_seedOf(requestId, msg.sender)),
            req.subId,
            req.requestConfirmations,
            req.callbackGasLimit,
            req.numWords,
            req.extraArgs,
            msg.sender
        );
    }

    /// @dev An empty value means the chain's own coin, because that is the only
    ///      thing there is. A request that explicitly asks to be billed in a
    ///      token is refused rather than quietly charged in something else.
    function _checkExtraArgs(bytes calldata extraArgs) private pure {
        if (extraArgs.length == 0) return;
        // casting to 'bytes4' is safe because the length is checked first
        // forge-lint: disable-next-line(unsafe-typecast)
        if (extraArgs.length < 4 || bytes4(extraArgs) != EXTRA_ARGS_V1_TAG) {
            revert InvalidExtraArgsTag();
        }
        if (!abi.decode(extraArgs[4:], (bool))) revert NativePaymentOnly();
    }

    /// @inheritdoc IVRFCoordinator
    function fulfillRandomWords(uint256 requestId, bytes calldata signature) external {
        Request storage request = _requests[requestId];
        address consumer = request.consumer;
        if (consumer == address(0)) revert NoSuchRequest();
        if (request.fulfilled || request.refunded) revert RequestClosed();

        // A relayer that supplies just enough gas for the pairing but not for
        // the callback would close the request and hand the consumer nothing.
        // The 64/63 rule means the callee only ever receives 63/64 of what is
        // left, so require the whole budget up front.
        if (gasleft() < (uint256(request.callbackGasLimit) * 64) / 63 + POST_CALLBACK_GAS) {
            revert InsufficientGas();
        }

        if (!verifier.verify(_seedOf(requestId, consumer), signature)) revert InvalidProof();

        request.fulfilled = true;

        uint32 numWords = request.numWords;
        bytes32 randomness = keccak256(signature);
        uint256[] memory words = new uint256[](numWords);
        for (uint32 i = 0; i < numWords; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(randomness, requestId, i)));
        }

        // Exactly what was quoted, not what the price happens to be now.
        uint96 paid = request.paid;
        subscriptions.settle(request.subId, paid, msg.sender);

        bool ok = _callback(consumer, requestId, words, request.callbackGasLimit);
        if (ok) request.callbackSucceeded = true;
        emit RandomWordsFulfilled(
            requestId, uint256(randomness), request.subId, paid, true, ok, false
        );
    }

    /// @notice Settles many requests against one aggregate signature.
    ///
    /// @dev Where the saving is. More than half of a fulfilment is the pairing,
    ///      and the pairing does not shrink with anything — but signatures under
    ///      one group key add, and so does the verification equation. A batch of
    ///      any size costs one pairing plus a hash-to-curve per member.
    ///
    ///      Ascending order, strictly, and that is not a convenience. Two copies
    ///      of a request sum to 2·H(seed), and 2·σ is something anyone holding
    ///      one published signature can compute — so the aggregate would verify
    ///      and the request would settle twice. Requiring each id to exceed the
    ///      last makes duplicates unrepresentable rather than merely detected,
    ///      in one comparison per member instead of a quadratic scan.
    ///
    ///      Each request is carried all the way through before the next begins.
    ///      Marking the batch fulfilled up front would be cheaper and would put
    ///      every later member into the state `retryCallback` serves —
    ///      fulfilled, not yet delivered — reachable from inside an earlier
    ///      member's callback. Settled one at a time, a later member is simply
    ///      not fulfilled yet, and the retry refuses it.
    ///
    ///      All or nothing: one closed request reverts the batch. A signature
    ///      is over exactly the set it was made for, so a member that cannot be
    ///      settled makes the aggregate meaningless for the rest.
    function fulfillBatch(uint256[] calldata requestIds, bytes calldata signature) external {
        uint256 count = requestIds.length;
        if (count == 0) revert EmptyBatch();

        bytes32[] memory seeds = new bytes32[](count);
        uint256 gasNeeded;
        uint256 previous;

        for (uint256 i = 0; i < count; i++) {
            uint256 requestId = requestIds[i];
            if (i != 0 && requestId <= previous) revert BatchNotSorted();
            previous = requestId;

            Request storage request = _requests[requestId];
            address consumer = request.consumer;
            if (consumer == address(0)) revert NoSuchRequest();
            if (request.fulfilled || request.refunded) revert RequestClosed();

            seeds[i] = _seedOf(requestId, consumer);
            gasNeeded += (uint256(request.callbackGasLimit) * 64) / 63 + POST_CALLBACK_GAS;
        }

        // Checked once, for the whole batch: a relayer that funds the pairing
        // but not the callbacks would close every request in it and hand the
        // consumers nothing.
        if (gasleft() < gasNeeded) revert InsufficientGas();
        if (!verifier.verifyBatch(seeds, signature)) revert InvalidProof();

        bytes32 randomness = keccak256(signature);
        for (uint256 i = 0; i < count; i++) {
            _settle(requestIds[i], randomness);
        }
    }

    /// @dev Marks one request fulfilled, pays the publisher and delivers.
    ///      Shared so the single and batch paths cannot drift apart in what a
    ///      request is worth or what words it gets.
    function _settle(uint256 requestId, bytes32 randomness) private {
        Request storage request = _requests[requestId];
        request.fulfilled = true;

        uint32 numWords = request.numWords;
        uint256[] memory words = new uint256[](numWords);
        for (uint32 i = 0; i < numWords; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(randomness, requestId, i)));
        }

        uint96 paid = request.paid;
        subscriptions.settle(request.subId, paid, msg.sender);

        bool ok = _callback(request.consumer, requestId, words, request.callbackGasLimit);
        if (ok) request.callbackSucceeded = true;
        emit RandomWordsFulfilled(
            requestId, uint256(randomness), request.subId, paid, true, ok, false
        );
    }

    /// @inheritdoc IVRFCoordinator
    ///
    /// @dev The escape hatch for a consumer whose callback failed. Without it
    ///      such a request is stranded forever: it is paid for, so `refund`
    ///      refuses it, and the words exist only in an event that no contract
    ///      can read.
    ///
    ///      Safe to leave open to anyone, and safe to call repeatedly, because
    ///      it re-verifies the same signature and can therefore only ever
    ///      deliver the one set of words that request was always going to get.
    ///      The only thing it must not do is deliver twice.
    ///
    ///      Sequentially that is the `callbackSucceeded` check. Re-entrantly it
    ///      is not: both delivery paths record that flag only after the
    ///      consumer returns, so a consumer still holding control sees its own
    ///      request as fulfilled-but-undelivered — precisely what this function
    ///      serves. What closes the window is the gas check below. A delivery
    ///      runs with at most `callbackGasLimit`, while this function demands
    ///      that whole budget again plus `POST_CALLBACK_GAS` before it does
    ///      anything, and the 64/63 rule widens the gap rather than narrowing
    ///      it. The callee therefore cannot satisfy the entry condition of the
    ///      call that would deliver to it twice.
    ///
    ///      So the check is load-bearing twice over, and weakening it to
    ///      "enough for the callback" would open a door that looks unrelated.
    ///      `test/attacks/Delivery.t.sol` fails if it is.
    function retryCallback(uint256 requestId, bytes calldata signature) external {
        Request storage request = _requests[requestId];
        address consumer = request.consumer;
        if (consumer == address(0)) revert NoSuchRequest();
        if (!request.fulfilled) revert NotFulfilled();
        if (request.callbackSucceeded) revert CallbackAlreadyDelivered();
        if (gasleft() < (uint256(request.callbackGasLimit) * 64) / 63 + POST_CALLBACK_GAS) {
            revert InsufficientGas();
        }
        if (!verifier.verify(_seedOf(requestId, consumer), signature)) revert InvalidProof();

        uint32 numWords = request.numWords;
        bytes32 randomness = keccak256(signature);
        uint256[] memory words = new uint256[](numWords);
        for (uint32 i = 0; i < numWords; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(randomness, requestId, i)));
        }

        bool ok = _callback(consumer, requestId, words, request.callbackGasLimit);
        if (ok) request.callbackSucceeded = true;
        emit CallbackRetried(requestId, ok);
    }

    /// @inheritdoc IVRFCoordinator
    function refund(uint256 requestId) external {
        Request storage request = _requests[requestId];
        if (request.consumer == address(0)) revert NoSuchRequest();
        if (request.fulfilled || request.refunded) revert RequestClosed();
        if (block.number <= uint256(request.createdAtBlock) + TIMEOUT_BLOCKS) revert TooEarly();

        request.refunded = true;
        subscriptions.release(request.subId, request.paid);
        emit RequestRefunded(requestId, request.paid);
    }

    /// @inheritdoc IVRFCoordinator
    function seedOf(uint256 requestId) public view returns (bytes32) {
        return _seedOf(requestId, _requests[requestId].consumer);
    }

    /// @inheritdoc IVRFCoordinator
    function price(uint32 numWords, uint32 callbackGasLimit) public view returns (uint96) {
        uint256 total = uint256(baseFee) + uint256(perWordFee) * numWords
            + uint256(perCallbackGasFee) * callbackGasLimit;
        if (total > type(uint96).max) revert PriceOverflow();
        // casting to 'uint96' is safe because the line above rejects anything
        // that would not fit
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint96(total);
    }

    /// @inheritdoc IVRFCoordinator
    function getRequestConfig()
        external
        view
        returns (uint16, uint16, uint32, uint32, bytes32[] memory)
    {
        bytes32[] memory keyHashes = new bytes32[](1);
        keyHashes[0] = verifier.keyHash();
        return (
            minimumRequestConfirmations,
            maxRequestConfirmations,
            maxCallbackGasLimit,
            MAX_WORDS,
            keyHashes
        );
    }

    /// @notice What a particular request was quoted when it was made.
    function priceOf(uint256 requestId) external view returns (uint96) {
        return _requests[requestId].paid;
    }

    function requests(uint256 requestId)
        external
        view
        returns (
            address consumer,
            uint256 subId,
            uint32 numWords,
            uint32 callbackGasLimit,
            bool fulfilled,
            bool refunded,
            bool callbackSucceeded
        )
    {
        Request storage request = _requests[requestId];
        return (
            request.consumer,
            request.subId,
            request.numWords,
            request.callbackGasLimit,
            request.fulfilled,
            request.refunded,
            request.callbackSucceeded
        );
    }

    function createdAtBlockOf(uint256 requestId) external view returns (uint64) {
        return _requests[requestId].createdAtBlock;
    }

    /// @dev Nothing the consumer picks goes in here — not the timestamp, not a
    ///      block hash, not calldata of its own, not the amount paid. All of
    ///      those are grindable by someone who wants a particular outcome. The
    ///      seed is public and that is fine: unpredictability comes from the
    ///      signature being unobtainable below the threshold, not from secrecy.
    function _seedOf(uint256 requestId, address consumer) private view returns (bytes32) {
        return keccak256(abi.encodePacked(requestId, consumer, address(this), block.chainid));
    }

    /// @dev Raw call so that return data is never copied into our memory: a
    ///      consumer returning a large blob would otherwise make the relayer
    ///      pay for the memory expansion.
    function _callback(address consumer, uint256 requestId, uint256[] memory words, uint256 limit)
        private
        returns (bool ok)
    {
        bytes memory payload =
            abi.encodeWithSelector(IVRFConsumer.rawFulfillRandomWords.selector, requestId, words);
        assembly ("memory-safe") {
            ok := call(limit, consumer, 0, add(payload, 0x20), mload(payload), 0, 0)
        }
    }
}
