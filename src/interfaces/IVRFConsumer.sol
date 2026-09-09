// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

interface IVRFConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata words) external;
}
