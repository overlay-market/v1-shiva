pragma solidity ^0.8.10;

import "../interfaces/rewardVault/IRewardVaults.sol";

contract RewardsVaultMock is IRewardsVault {
    function delegateStake(address account, uint256 amount) external {}

    function delegateWithdraw(address account, uint256 amount) external {}

    function getTotalDelegateStaked(address ) external pure returns (uint256) {
        return 0;
    }

    function balanceOf(address ) external pure returns (uint256) {
        return 0;
    }

    function withdraw(uint256 amount) external {}

    function exit(address recipient) external {}
}

contract RewardsVaultFactoryMock is IRewardsVaultFactory{
    function createRewardVault(address ) external returns (address) {
        return address(new RewardsVaultMock());
    }
}