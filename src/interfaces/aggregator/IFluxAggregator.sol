// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IFluxAggregator
 * @notice Interface for the FluxAggregator contract
 * @dev Generated using the LLM - TODO review
 */
interface IFluxAggregator {
    // Events
    event AvailableFundsUpdated(uint256 indexed amount);
    event RoundDetailsUpdated(
        uint128 indexed paymentAmount,
        uint32 indexed minSubmissionCount,
        uint32 indexed maxSubmissionCount,
        uint32 restartDelay,
        uint32 timeout
    );
    event OraclePermissionsUpdated(address indexed oracle, bool indexed whitelisted);
    event OracleAdminUpdated(address indexed oracle, address indexed newAdmin);
    event OracleAdminUpdateRequested(address indexed oracle, address admin, address newAdmin);
    event SubmissionReceived(
        int256 indexed submission, uint32 indexed round, address indexed oracle
    );
    event RequesterPermissionsSet(address indexed requester, bool authorized, uint32 delay);
    event ValidatorUpdated(address indexed previous, address indexed current);

    // Functions
    function submit(uint256 _roundId, int256 _submission) external;
    function changeOracles(
        address[] calldata _removed,
        address[] calldata _added,
        address[] calldata _addedAdmins,
        uint32 _minSubmissions,
        uint32 _maxSubmissions,
        uint32 _restartDelay
    ) external;
    function updateFutureRounds(
        uint128 _paymentAmount,
        uint32 _minSubmissions,
        uint32 _maxSubmissions,
        uint32 _restartDelay,
        uint32 _timeout
    ) external;
    function allocatedFunds() external view returns (uint128);
    function availableFunds() external view returns (uint128);
    function updateAvailableFunds() external;
    function oracleCount() external view returns (uint8);
    function getOracles() external view returns (address[] memory);
    function latestAnswer() external view returns (int256);
    function latestTimestamp() external view returns (uint256);
    function latestRound() external view returns (uint256);
    function getAnswer(
        uint256 _roundId
    ) external view returns (int256);
    function getTimestamp(
        uint256 _roundId
    ) external view returns (uint256);
    function getRoundData(
        uint80 _roundId
    )
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
    function withdrawablePayment(
        address _oracle
    ) external view returns (uint256);
    function withdrawPayment(address _oracle, address _recipient, uint256 _amount) external;
    function withdrawFunds(address _recipient, uint256 _amount) external;
    function getAdmin(
        address _oracle
    ) external view returns (address);
    function transferAdmin(address _oracle, address _newAdmin) external;
    function acceptAdmin(
        address _oracle
    ) external;
    function requestNewRound() external returns (uint80);
    function setRequesterPermissions(
        address _requester,
        bool _authorized,
        uint32 _delay
    ) external;
    function onTokenTransfer(address _sender, uint256 _amount, bytes calldata _data) external;
    function oracleRoundState(
        address _oracle,
        uint32 _queriedRoundId
    )
        external
        view
        returns (
            bool _eligibleToSubmit,
            uint32 _roundId,
            int256 _latestSubmission,
            uint64 _startedAt,
            uint64 _timeout,
            uint128 _availableFunds,
            uint8 _oracleCount,
            uint128 _paymentAmount
        );
    function setValidator(
        address _newValidator
    ) external;
}
