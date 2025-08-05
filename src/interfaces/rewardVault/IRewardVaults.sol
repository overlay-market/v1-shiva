pragma solidity ^0.8.10;

/**
 * @title IRewardsVault
 * @notice Interface for the RewardsVault contract
 */
interface IRewardsVault {
    function delegateStake(address account, uint256 amount) external;

    function delegateWithdraw(address account, uint256 amount) external;

    function getTotalDelegateStaked(address account) external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function withdraw(uint256 amount) external;

    function exit(address recipient) external;
}

/**
 * @title IRewardsVaultFactory
 * @notice Interface for the RewardsVaultFactory contract
 */
interface IRewardsVaultFactory {
    function createRewardVault(address stakingToken) external returns (address);
}
