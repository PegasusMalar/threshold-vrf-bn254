// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VRFConsumerBase} from "../../src/VRFConsumerBase.sol";
import {IVRFCoordinator} from "../../src/interfaces/IVRFCoordinator.sol";

/// @title Plinko
/// @notice Reference integration: a ball falls through sixteen rows of pegs,
///         going left or right at each, and lands in one of seventeen buckets.
///
/// @dev Copy the shape of this, not the multipliers. What matters here is the
///      integration pattern, and every part of it is load-bearing:
///
///      - **the stake is taken in `drop()`**, at request time. There is no path
///        where the player sees the outcome and then decides whether to pay;
///      - **`fulfillRandomWords` only writes storage.** It cannot revert, cannot
///        run out of gas, and never calls out to anyone;
///      - **winnings are pulled, not pushed.** A transfer inside the callback
///        would hand an arbitrary external call to whoever publishes the
///        signature;
///      - **the callback is idempotent.** `retryCallback` can deliver the same
///        words a second time, and a round that is already settled must not pay
///        again;
///      - **the house is checked before the round opens.** A drop that the
///        bankroll could not cover in the best case is refused, rather than
///        discovered when the player tries to withdraw.
///
///      Randomness is packed rather than requested per ball: one 256-bit word
///      carries sixteen balls at sixteen rows each. Asking for a word per ball
///      would be paying sixteen times over for the same entropy.
contract Plinko is VRFConsumerBase {
    error BadStake();
    error BadBallCount();
    error HouseCannotCover();
    error NothingToWithdraw();
    error PayoutFailed();

    event Dropped(
        uint256 indexed requestId, address indexed player, uint32 balls, uint96 stakePerBall
    );
    event Landed(
        uint256 indexed requestId, address indexed player, uint8[] buckets, uint256 payout
    );

    /// @notice Rows of pegs. Sixteen rows means seventeen buckets, and sixteen
    ///         bits per ball — which divides 256 exactly, so a ball's bits never
    ///         straddle two words.
    uint8 public constant ROWS = 16;

    /// @notice Balls per drop. Bounded so that one drop cannot ask for more
    ///         randomness, or more bankroll, than the game is sized for.
    uint32 public constant MAX_BALLS = 32;

    uint32 public constant BALLS_PER_WORD = 256 / ROWS;

    uint96 public constant MIN_STAKE_PER_BALL = 0.001 ether;
    uint96 public constant MAX_STAKE_PER_BALL = 1 ether;

    /// @notice Gas the callback needs. Sized for the worst case — thirty-two
    ///         balls written to storage — and paid for whether used or not.
    uint32 public constant CALLBACK_GAS_LIMIT = 600_000;

    uint256 public immutable subId;

    /// @dev Payout per bucket in basis points; 10 000 is the stake back. The
    ///      table is symmetric and the edges are where the money is, which is
    ///      what makes the game worth playing. Its expected return is asserted
    ///      in the tests against the binomial distribution, not trusted.
    uint32[17] private _multipliersBps = [
        1_100_000,
        410_000,
        100_000,
        50_000,
        30_000,
        15_000,
        10_000,
        5_000,
        3_000,
        5_000,
        10_000,
        15_000,
        30_000,
        50_000,
        100_000,
        410_000,
        1_100_000
    ];

    struct Round {
        address player;
        uint96 stakePerBall;
        uint32 balls;
        bool settled;
    }

    mapping(uint256 => Round) private _rounds;
    mapping(uint256 => uint8[]) private _buckets;
    mapping(address => uint256) private _winnings;

    /// @notice Winnings owed but not yet paid out, so the bankroll check does
    ///         not count money that is already spoken for.
    uint256 public owed;

    constructor(address _vrfCoordinator, uint256 _subId) VRFConsumerBase(_vrfCoordinator) {
        subId = _subId;
    }

    receive() external payable {}

    /// @notice Drop `balls` balls. The stake is `msg.value` split evenly, and it
    ///         is locked here and now.
    function drop(uint32 balls) external payable returns (uint256 requestId) {
        if (balls == 0 || balls > MAX_BALLS) revert BadBallCount();

        uint96 stakePerBall = uint96(msg.value / balls);
        if (stakePerBall < MIN_STAKE_PER_BALL || stakePerBall > MAX_STAKE_PER_BALL) {
            revert BadStake();
        }

        // The bankroll must cover the best case for every ball, or a lucky
        // player would find the money gone when they came to withdraw.
        uint256 worstCase = (uint256(stakePerBall) * _multipliersBps[0] * balls) / 10_000;
        if (address(this).balance < owed + worstCase) revert HouseCannotCover();

        uint32 numWords = (balls + BALLS_PER_WORD - 1) / BALLS_PER_WORD;
        requestId = s_vrfCoordinator.requestRandomWords(
            IVRFCoordinator.RandomWordsRequest({
                keyHash: bytes32(0),
                subId: subId,
                requestConfirmations: 0,
                callbackGasLimit: CALLBACK_GAS_LIMIT,
                numWords: numWords,
                extraArgs: ""
            })
        );

        _rounds[requestId] =
            Round({player: msg.sender, stakePerBall: stakePerBall, balls: balls, settled: false});
        emit Dropped(requestId, msg.sender, balls, stakePerBall);
    }

    function withdraw() external {
        uint256 amount = _winnings[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        _winnings[msg.sender] = 0;
        owed -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert PayoutFailed();
    }

    /// @dev Storage writes only, and idempotent: the coordinator can deliver
    ///      these same words twice if the first attempt ran out of gas.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords)
        internal
        override
    {
        Round storage round = _rounds[requestId];
        if (round.settled || round.player == address(0)) return;
        round.settled = true;

        uint8[] memory landed = new uint8[](round.balls);
        uint256 payout = 0;
        for (uint32 i = 0; i < round.balls; i++) {
            uint8 bucket = bucketOfBall(randomWords, i);
            landed[i] = bucket;
            payout += (uint256(round.stakePerBall) * _multipliersBps[bucket]) / 10_000;
        }

        _buckets[requestId] = landed;
        if (payout > 0) {
            _winnings[round.player] += payout;
            owed += payout;
        }
        emit Landed(requestId, round.player, landed, payout);
    }

    /// @notice Which bucket ball `index` falls into, given the words.
    ///
    /// @dev The bucket is simply how many times the ball went right, so the
    ///      distribution is binomial and the middle is the likeliest place to
    ///      land. Sixteen bits per ball, sixteen balls per word, no straddling.
    function bucketOfBall(uint256[] memory randomWords, uint32 index) public pure returns (uint8) {
        uint256 word = randomWords[index / BALLS_PER_WORD];
        uint256 path = (word >> ((index % BALLS_PER_WORD) * ROWS)) & ((1 << ROWS) - 1);

        uint8 rights = 0;
        for (uint8 row = 0; row < ROWS; row++) {
            if ((path >> row) & 1 == 1) rights++;
        }
        return rights;
    }

    /* -------------------------------- views ------------------------------- */

    function multiplierBps(uint8 bucket) external view returns (uint32) {
        return _multipliersBps[bucket];
    }

    /// @notice What the table pays back on average, in basis points of the
    ///         stake. Under 10 000 by construction — that difference is the
    ///         house edge.
    function expectedReturnBps() external view returns (uint256) {
        uint256 total = 1 << ROWS;
        uint256 sum = 0;
        uint256 paths = 1;
        for (uint8 k = 0; k <= ROWS; k++) {
            sum += paths * _multipliersBps[k];
            if (k < ROWS) paths = (paths * (ROWS - k)) / (k + 1);
        }
        return sum / total;
    }

    function roundOf(uint256 requestId)
        external
        view
        returns (address player, uint96 stakePerBall, uint32 balls, bool isSettled)
    {
        Round storage round = _rounds[requestId];
        return (round.player, round.stakePerBall, round.balls, round.settled);
    }

    function settled(uint256 requestId) external view returns (bool) {
        return _rounds[requestId].settled;
    }

    function bucketOf(uint256 requestId, uint32 index) external view returns (uint8) {
        return _buckets[requestId][index];
    }

    function bucketsOf(uint256 requestId) external view returns (uint8[] memory) {
        return _buckets[requestId];
    }

    function winningsOf(address player) external view returns (uint256) {
        return _winnings[player];
    }
}
