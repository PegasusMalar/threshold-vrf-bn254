// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VRFConsumerBase} from "../../src/VRFConsumerBase.sol";
import {IVRFCoordinator} from "../../src/interfaces/IVRFCoordinator.sol";

/// @notice Reference integration. Deliberately boring, and deliberately shaped
///         around the three rules in docs/integration.md.
///
/// @dev What to copy from this:
///
///      - the stake is taken in `flip()`, at request time. There is no path
///        where the player learns the outcome and then decides whether to pay;
///      - `fulfillRandomWords` only writes storage. It cannot revert, cannot
///        run out of gas, and never calls out to anyone;
///      - winnings are pulled, not pushed. A push here would hand the caller of
///        `fulfillRandomWords` an arbitrary external call.
contract CoinFlip is VRFConsumerBase {
    error BadStake();
    error NothingToWithdraw();
    error PayoutFailed();

    event FlipPlaced(
        uint256 indexed requestId, address indexed player, bool guessHeads, uint96 stake
    );
    event FlipSettled(uint256 indexed requestId, address indexed player, bool won, uint96 payout);

    struct Bet {
        address player;
        uint96 stake;
        bool guessHeads;
        bool settled;
    }

    /// Enough for the storage writes this callback does, and no more: unused
    /// callback gas is paid for either way.
    uint32 public constant CALLBACK_GAS_LIMIT = 150_000;

    uint96 public constant MIN_STAKE = 0.001 ether;
    uint96 public constant MAX_STAKE = 5 ether;

    uint256 public immutable subId;

    mapping(uint256 => Bet) private _bets;
    mapping(address => uint256) private _winnings;

    constructor(address coordinator_, uint256 subId_) VRFConsumerBase(coordinator_) {
        subId = subId_;
    }

    receive() external payable {}

    /// @notice Place a bet. The stake is locked here and now.
    function flip(bool guessHeads) external payable returns (uint256 requestId) {
        if (msg.value < MIN_STAKE || msg.value > MAX_STAKE) revert BadStake();

        // The Chainlink-shaped request. keyHash 0 means "the group key that is
        // current"; requestConfirmations is accepted for source compatibility
        // and is always satisfied immediately here.
        requestId = s_vrfCoordinator.requestRandomWords(
            IVRFCoordinator.RandomWordsRequest({
                keyHash: bytes32(0),
                subId: subId,
                requestConfirmations: 0,
                callbackGasLimit: CALLBACK_GAS_LIMIT,
                numWords: 1,
                extraArgs: ""
            })
        );
        _bets[requestId] = Bet({
            player: msg.sender, stake: uint96(msg.value), guessHeads: guessHeads, settled: false
        });

        emit FlipPlaced(requestId, msg.sender, guessHeads, uint96(msg.value));
    }

    function withdraw() external {
        uint256 amount = _winnings[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        _winnings[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert PayoutFailed();
    }

    /// @dev Storage writes only. The result arrives in someone else's
    ///      transaction, so anything expensive or failure-prone here is paid
    ///      for by a stranger and breaks the player's bet when it runs out.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata words) internal override {
        Bet storage bet = _bets[requestId];
        if (bet.settled || bet.player == address(0)) return;
        bet.settled = true;

        bool heads = words[0] % 2 == 1;
        bool won = heads == bet.guessHeads;
        uint96 payout = won ? bet.stake * 2 : 0;
        if (won) _winnings[bet.player] += payout;

        emit FlipSettled(requestId, bet.player, won, payout);
    }

    function stakeOf(uint256 requestId) external view returns (uint96) {
        return _bets[requestId].stake;
    }

    function settled(uint256 requestId) external view returns (bool) {
        return _bets[requestId].settled;
    }

    function winningsOf(address player) external view returns (uint256) {
        return _winnings[player];
    }
}
