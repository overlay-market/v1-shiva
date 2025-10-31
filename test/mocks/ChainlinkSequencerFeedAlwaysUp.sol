// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

interface AggregatorV3Interface {
  function decimals() external view returns (uint8);

  function description() external view returns (string memory);

  function version() external view returns (uint256);

  function getRoundData(
    uint80 _roundId
  ) external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

  function latestRoundData()
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract ChainlinkSequencerFeedAlwaysUp is AggregatorV3Interface {
    int256 immutable answer;
    uint256 immutable timestamp;
    uint80 immutable roundId;

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

    // Required interface functions
    function decimals() external pure override returns (uint8) {
        return 0;
    }

    function description() external pure override returns (string memory) {
        return "Chainlink Sequencer Feed - Always Up";
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
