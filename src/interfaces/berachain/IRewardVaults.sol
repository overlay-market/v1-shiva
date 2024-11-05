pragma solidity ^0.8.10;

interface IBerachainRewardsVault {
    function delegateStake(address account, uint256 amount) external;

    function delegateWithdraw(address account, uint256 amount) external;

    function getTotalDelegateStaked(
        address account
    ) external view returns (uint256);

    function balanceOf(address account) external returns (uint256);
}

interface IBerachainRewardsVaultFactory {
    function createRewardsVault(
        address stakingToken
    ) external returns (address);
}
