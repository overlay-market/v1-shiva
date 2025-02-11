// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IFluxAggregator} from "../../src/interfaces/aggregator/IFluxAggregator.sol";

contract MockAggregator is IFluxAggregator {
    struct Round {
        int256 answer;
        uint64 startedAt;
        uint64 updatedAt;
        uint32 answeredInRound;
    }

    // Storage variables
    mapping(uint256 => Round) private rounds;
    uint256 private currentRound;
    address[] private oracleList;
    mapping(address => bool) private isOracle;

    // Constants
    uint8 public constant decimals = 8;
    string public constant description = "Mock Price Feed";

    // Initial setup values
    int256 private constant INITIAL_PRICE = 979701714; // ~$9.79 with 8 decimals
    uint256 private constant MIN_ANSWER = 1e8; // $1
    uint256 private constant MAX_ANSWER = 1000000e8; // $1M

    constructor() {
        // Initialize first round
        currentRound = 1;
        rounds[currentRound] = Round({
            answer: INITIAL_PRICE,
            startedAt: uint64(block.timestamp),
            updatedAt: uint64(block.timestamp),
            answeredInRound: uint32(currentRound)
        });

        // Add deployer as initial oracle
        oracleList.push(msg.sender);
        isOracle[msg.sender] = true;
    }

    function submit(uint256 _roundId, int256 _submission) external override {
        require(isOracle[msg.sender], "Not authorized oracle");
        require(_submission >= int256(MIN_ANSWER), "Answer below minimum");
        require(_submission <= int256(MAX_ANSWER), "Answer above maximum");
        require(_roundId > currentRound, "Round too old");

        currentRound = _roundId;

        rounds[_roundId] = Round({
            answer: _submission,
            startedAt: uint64(block.timestamp),
            updatedAt: uint64(block.timestamp),
            answeredInRound: uint32(_roundId)
        });

        emit SubmissionReceived(_submission, uint32(_roundId), msg.sender);
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        Round memory round = rounds[currentRound];
        return (
            uint80(currentRound),
            round.answer,
            round.startedAt,
            round.updatedAt,
            uint80(round.answeredInRound)
        );
    }

    function getRoundData(
        uint80 _roundId
    )
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        Round memory round = rounds[_roundId];
        require(round.updatedAt > 0, "No data present");

        return (
            uint80(_roundId),
            round.answer,
            round.startedAt,
            round.updatedAt,
            uint80(round.answeredInRound)
        );
    }

    function getOracles() external view override returns (address[] memory) {
        return oracleList;
    }

    function latestAnswer() external view override returns (int256) {
        return rounds[currentRound].answer;
    }

    function latestRound() external view override returns (uint256) {
        return currentRound;
    }

    function latestTimestamp() external view override returns (uint256) {
        return rounds[currentRound].updatedAt;
    }

    function getAnswer(
        uint256 _roundId
    ) external view override returns (int256) {
        return rounds[_roundId].answer;
    }

    function getTimestamp(
        uint256 _roundId
    ) external view override returns (uint256) {
        return rounds[_roundId].updatedAt;
    }

    // Helper functions
    function addOracle(
        address oracle
    ) external {
        require(!isOracle[oracle], "Oracle already exists");
        oracleList.push(oracle);
        isOracle[oracle] = true;
    }

    function removeOracle(
        address oracle
    ) external {
        require(isOracle[oracle], "Oracle doesn't exist");
        isOracle[oracle] = false;
        for (uint256 i = 0; i < oracleList.length; i++) {
            if (oracleList[i] == oracle) {
                oracleList[i] = oracleList[oracleList.length - 1];
                oracleList.pop();
                break;
            }
        }
    }

    // Required interface functions that we don't need to implement for testing
    function changeOracles(
        address[] calldata,
        address[] calldata,
        address[] calldata,
        uint32,
        uint32,
        uint32
    ) external pure override {
        revert("Not implemented");
    }

    function updateFutureRounds(uint128, uint32, uint32, uint32, uint32) external pure override {
        revert("Not implemented");
    }

    function allocatedFunds() external pure override returns (uint128) {
        return 0;
    }

    function availableFunds() external pure override returns (uint128) {
        return 0;
    }

    function updateAvailableFunds() external pure override {}

    function oracleCount() external view override returns (uint8) {
        return uint8(oracleList.length);
    }

    function withdrawablePayment(
        address
    ) external pure override returns (uint256) {
        return 0;
    }

    function withdrawPayment(address, address, uint256) external pure override {}
    function withdrawFunds(address, uint256) external pure override {}

    function getAdmin(
        address
    ) external pure override returns (address) {
        return address(0);
    }

    function transferAdmin(address, address) external pure override {}
    function acceptAdmin(
        address
    ) external pure override {}

    function requestNewRound() external pure override returns (uint80) {
        return 0;
    }

    function setRequesterPermissions(address, bool, uint32) external pure override {}
    function onTokenTransfer(address, uint256, bytes calldata) external pure override {}

    function oracleRoundState(
        address,
        uint32
    )
        external
        pure
        override
        returns (bool, uint32, int256, uint64, uint64, uint128, uint8, uint128)
    {
        return (false, 0, 0, 0, 0, 0, 0, 0);
    }

    function setValidator(
        address
    ) external pure override {}
}
