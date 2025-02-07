pragma solidity ^0.8.10;

/**
 * @title IBerachainRewardsVault
 * @notice Interface for the BerachainRewardsVault contract
 */
interface IBerachainRewardsVault {
    function delegateStake(address account, uint256 amount) external;

    function delegateWithdraw(address account, uint256 amount) external;

    function getTotalDelegateStaked(address account) external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function withdraw(uint256 amount) external;

    function exit(address recipient) external;
}

/**
 * @title IBerachainRewardsVaultFactory
 * @notice Interface for the BerachainRewardsVaultFactory contract
 */
interface IBerachainRewardsVaultFactory {
    function createRewardVault(address stakingToken) external returns (address);
}
