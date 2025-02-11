// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract MockSequencerOracle is AggregatorV3Interface {
    int256 private answer;
    uint256 private timestamp;
    uint80 private roundId;

    constructor() {
        // Initialize with sequencer up (0 = up, 1 = down)
        answer = 0;
        timestamp = block.timestamp - 3601; // Set timestamp to more than gracePeriod ago
        roundId = 1;
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId_,
            int256 answer_,
            uint256 startedAt_,
            uint256 updatedAt_,
            uint80 answeredInRound_
        )
    {
        return (roundId, answer, timestamp, timestamp, uint80(roundId));
    }

    // Helper function to set the sequencer status
    function setSequencerStatus(bool isUp, uint256 timestamp_) external {
        answer = isUp ? int256(0) : int256(1);
        timestamp = timestamp_;
        roundId++;
    }

    // Required interface functions
    function decimals() external pure override returns (uint8) {
        return 0;
    }

    function description() external pure override returns (string memory) {
        return "Mock Sequencer Oracle";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(
        uint80
    )
        external
        view
        override
        returns (
            uint80 roundId_,
            int256 answer_,
            uint256 startedAt_,
            uint256 updatedAt_,
            uint80 answeredInRound_
        )
    {
        return (roundId, answer, timestamp, timestamp, uint80(roundId));
    }
}
