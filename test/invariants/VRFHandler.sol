// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {VRFVerifier} from "../../src/VRFVerifier.sol";
import {VRFCoordinator} from "../../src/VRFCoordinator.sol";
import {Subscription} from "../../src/Subscription.sol";
import {VRFConsumerBase} from "../../src/VRFConsumerBase.sol";
import {IVRFCoordinator} from "../../src/interfaces/IVRFCoordinator.sol";

/// @notice Drives the coordinator through random sequences of the actions a
///         real integrator and a real relayer can take, recording enough ghost
///         state for the invariants to be checkable.
///
/// @dev The handler is itself the consumer, so callbacks land here and the
///         delivered words can be compared against what a second delivery
///         would have produced.
contract VRFHandler is CommonBase, StdCheats, StdUtils, VRFConsumerBase {
    VRFVerifier public immutable verifier;
    VRFCoordinator public immutable vrf;
    Subscription public immutable subs;
    uint256 private immutable groupSecretKey;

    /// The callback budget this handler asks for on every request.
    uint32 public constant CALLBACK_GAS = 500_000;

    uint256[] public subIds;
    uint256[] public requestIds;

    mapping(uint256 => uint256) public deliveries;
    mapping(uint256 => bytes32) public deliveredDigest;
    mapping(uint256 => bool) public seen;

    address public immutable successor;

    /// When set, the handler's own callback reverts. That is what makes the
    /// retry path reachable at all: without a consumer that refuses delivery
    /// there is nothing to retry.
    bool public refuseDeliveries;
    uint256 public totalRetried;

    uint256 public totalFulfilled;
    uint256 public totalRefunded;
    bool public sawDuplicateDelivery;
    bool public sawInconsistentWords;

    constructor(VRFVerifier verifier_, VRFCoordinator coordinator_, uint256 groupSecretKey_)
        VRFConsumerBase(address(coordinator_))
    {
        verifier = verifier_;
        vrf = coordinator_;
        subs = Subscription(coordinator_.subscriptions());
        groupSecretKey = groupSecretKey_;
        successor = address(uint160(uint256(keccak256("successor"))));
    }

    receive() external payable {}

    function createSubscription(uint96 funding) external {
        funding = uint96(bound(funding, 0, 10 ether));
        uint256 subId = subs.createSubscription();
        deal(address(this), address(this).balance + funding);
        subs.fundSubscription{value: funding}(subId);
        subs.addConsumer(subId, address(this));
        subIds.push(subId);
    }

    function fund(uint256 subSeed, uint96 amount) external {
        if (subIds.length == 0) return;
        uint256 subId = subIds[subSeed % subIds.length];
        if (subs.ownerOf(subId) == address(0)) return;
        amount = uint96(bound(amount, 0, 5 ether));
        deal(address(this), address(this).balance + amount);
        subs.fundSubscription{value: amount}(subId);
    }

    function request(uint256 subSeed, uint32 numWords) external {
        if (subIds.length == 0) return;
        uint256 subId = subIds[subSeed % subIds.length];
        numWords = uint32(bound(numWords, 1, 20));
        try vrf.requestRandomWords(
            IVRFCoordinator.RandomWordsRequest({
                keyHash: bytes32(0),
                subId: subId,
                requestConfirmations: 0,
                callbackGasLimit: CALLBACK_GAS,
                numWords: numWords,
                extraArgs: ""
            })
        ) returns (
            uint256 requestId
        ) {
            requestIds.push(requestId);
        } catch {}
    }

    function fulfill(uint256 requestSeed) external {
        if (requestIds.length == 0) return;
        uint256 requestId = requestIds[requestSeed % requestIds.length];
        bytes memory sig = _sign(vrf.seedOf(requestId));
        try vrf.fulfillRandomWords(requestId, sig) {
            totalFulfilled++;
        } catch {}
    }

    /// A relayer replaying someone else's signature onto another request.
    function fulfillWithForeignSignature(uint256 requestSeed, uint256 otherSeed) external {
        if (requestIds.length < 2) return;
        uint256 target = requestIds[requestSeed % requestIds.length];
        uint256 other = requestIds[otherSeed % requestIds.length];
        bytes memory sig = _sign(vrf.seedOf(other));
        try vrf.fulfillRandomWords(target, sig) {
            totalFulfilled++;
        } catch {}
    }

    /// Fee changes are driven from here on purpose: a mismatch between what a
    /// request reserved and what it later settles would only ever show up when
    /// the price moves underneath requests that are already in flight.
    function proposeFees(uint96 base, uint96 perWord) external {
        base = uint96(bound(base, 0, vrf.maxBaseFee()));
        perWord = uint96(bound(perWord, 0, vrf.maxPerWordFee()));
        try vrf.proposeFees(base, perWord, 0) {} catch {}
    }

    function applyFees() external {
        try vrf.applyFees() {} catch {}
    }

    function setRefuseDeliveries(bool refuse) external {
        refuseDeliveries = refuse;
    }

    function retryFailedCallback(uint256 requestSeed) external {
        if (requestIds.length == 0) return;
        uint256 requestId = requestIds[requestSeed % requestIds.length];
        bytes memory sig = _sign(vrf.seedOf(requestId));
        try vrf.retryCallback(requestId, sig) {
            totalRetried++;
        } catch {}
    }

    /// Taking part of the deposit back is something the owner can do at any
    /// moment, so the invariants have to hold across it.
    function withdrawFromSubscription(uint256 subSeed, uint96 amount) external {
        if (subIds.length == 0) return;
        uint256 subId = subIds[subSeed % subIds.length];
        try subs.withdrawFromSubscription(
            subId, uint96(bound(amount, 0, 5 ether)), address(this)
        ) {}
            catch {}
    }

    function offerSubscription(uint256 subSeed) external {
        if (subIds.length == 0) return;
        try subs.requestSubscriptionOwnerTransfer(subIds[subSeed % subIds.length], successor) {}
            catch {}
    }

    function acceptAsSuccessor(uint256 subSeed) external {
        if (subIds.length == 0) return;
        uint256 subId = subIds[subSeed % subIds.length];
        vm.prank(successor);
        try subs.acceptSubscriptionOwnerTransfer(subId) {} catch {}
    }

    /// The successor hands it back, so the handler can keep driving the rest.
    function reclaimSubscription(uint256 subSeed) external {
        if (subIds.length == 0) return;
        uint256 subId = subIds[subSeed % subIds.length];
        vm.prank(successor);
        try subs.requestSubscriptionOwnerTransfer(subId, address(this)) {}
        catch {
            return;
        }
        try subs.acceptSubscriptionOwnerTransfer(subId) {} catch {}
    }

    function refundRequest(uint256 requestSeed) external {
        if (requestIds.length == 0) return;
        uint256 requestId = requestIds[requestSeed % requestIds.length];
        try vrf.refund(requestId) {
            totalRefunded++;
        } catch {}
    }

    function cancel(uint256 subSeed) external {
        if (subIds.length == 0) return;
        uint256 subId = subIds[subSeed % subIds.length];
        try subs.cancelSubscription(subId, address(this)) {} catch {}
    }

    function advanceBlocks(uint256 blocks) external {
        vm.roll(block.number + bound(blocks, 1, 10_000));
    }

    function withdrawFees() external {
        try subs.withdraw(address(this)) {} catch {}
    }

    /* ------------------------------- ghosts -------------------------------- */

    function fulfillRandomWords(uint256 requestId, uint256[] calldata words) internal override {
        require(!refuseDeliveries, "handler is refusing deliveries");
        deliveries[requestId] += 1;
        if (deliveries[requestId] > 1) sawDuplicateDelivery = true;

        bytes32 digest = keccak256(abi.encode(words));
        if (seen[requestId] && deliveredDigest[requestId] != digest) sawInconsistentWords = true;
        seen[requestId] = true;
        deliveredDigest[requestId] = digest;
    }

    function subCount() external view returns (uint256) {
        return subIds.length;
    }

    function requestCount() external view returns (uint256) {
        return requestIds.length;
    }

    function _sign(bytes32 seed) private view returns (bytes memory) {
        uint256[2] memory point = verifier.hashSeedToPoint(seed);
        uint256[3] memory input = [point[0], point[1], groupSecretKey];
        uint256[2] memory out;
        bool ok;
        assembly {
            ok := staticcall(gas(), 7, input, 96, out, 64)
        }
        require(ok, "ecMul failed");
        return abi.encodePacked(out[0], out[1]);
    }
}
