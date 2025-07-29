// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { FixedPointMathLib } from "solady/src/utils/FixedPointMathLib.sol";

import { Utils } from "berachain/src/libraries/Utils.sol";
import { IRewardVault } from "./IRewardVault.sol";
import { FactoryOwnable } from "berachain/src/base/FactoryOwnable.sol";
import { StakingRewards } from "berachain/src/base/StakingRewards.sol";

/// @title Rewards Vault
/// @author Overlay Team
/// @notice This contract is the vault for the Overlay rewards, it handles the staking and rewards accounting of rewardToken.
/// @dev This contract is taken from the stable and tested:
/// https://github.com/Synthetixio/synthetix/blob/develop/contracts/StakingRewards.sol
/// We are using this model instead of 4626 because we want to incentivize staying in the vault for x period of time to
/// to be considered a 'miner' and not a 'trader'.
contract RewardVault is
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    FactoryOwnable,
    StakingRewards,
    IRewardVault
{
    using Utils for bytes4;
    using SafeERC20 for IERC20;
    using Utils for address;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STRUCTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Struct to hold delegate stake data.
    /// @param delegateTotalStaked The total amount staked by delegates.
    /// @param stakedByDelegate The mapping of the amount staked by each delegate.
    struct DelegateStake {
        uint256 delegateTotalStaked;
        mapping(address delegate => uint256 amount) stakedByDelegate;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STORAGE                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    mapping(address account => DelegateStake) internal _delegateStake;

    /// @notice The mapping of accounts to their operators.
    mapping(address account => address operator) internal _operators;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IRewardVault
    function initialize(
        address _rewardToken,
        address _stakingToken
    )
        external
        initializer
    {
        __FactoryOwnable_init(msg.sender);
        __Pausable_init();
        __ReentrancyGuard_init();
        __StakingRewards_init(_stakingToken, _rewardToken, 3 days);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         MODIFIERS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    modifier onlyOperatorOrUser(address account) {
        if (msg.sender != account) {
            if (msg.sender != _operators[account]) NotOperator.selector.revertWith();
        }
        _;
    }

    modifier checkSelfStakedBalance(address account, uint256 amount) {
        _checkSelfStakedBalance(account, amount);
        _;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       ADMIN FUNCTIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @inheritdoc IRewardVault
    function notifyRewardAmount(bytes calldata, uint256 reward) external onlyFactoryOwner {
        _notifyRewardAmount(reward);
    }

    /// @inheritdoc IRewardVault
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyFactoryOwner {
        if (tokenAddress == address(stakeToken)) {
            uint256 maxRecoveryAmount = IERC20(stakeToken).balanceOf(address(this)) - totalSupply;
            if (tokenAmount > maxRecoveryAmount) {
                NotEnoughBalance.selector.revertWith();
            }
        }
        IERC20(tokenAddress).safeTransfer(msg.sender, tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    /// @inheritdoc IRewardVault
    function setRewardsDuration(uint256 _rewardsDuration) external onlyFactoryOwner {
        _setRewardsDuration(_rewardsDuration);
    }

    /// @inheritdoc IRewardVault
    function pause() external onlyFactoryVaultPauser {
        _pause();
    }

    /// @inheritdoc IRewardVault
    function unpause() external onlyFactoryVaultManager {
        _unpause();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          GETTERS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @inheritdoc IRewardVault
    function operator(address account) external view returns (address) {
        return _operators[account];
    }

    /// @inheritdoc IRewardVault
    function getTotalDelegateStaked(address account) external view returns (uint256) {
        return _delegateStake[account].delegateTotalStaked;
    }

    /// @inheritdoc IRewardVault
    function getDelegateStake(address account, address delegate) external view returns (uint256) {
        return _delegateStake[account].stakedByDelegate[delegate];
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          WRITES                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @inheritdoc IRewardVault
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        _stake(msg.sender, amount);
    }

    /// @inheritdoc IRewardVault
    function delegateStake(address account, uint256 amount) external nonReentrant whenNotPaused {
        if (msg.sender == account) NotDelegate.selector.revertWith();

        _stake(account, amount);
        unchecked {
            DelegateStake storage info = _delegateStake[account];
            // Overflow is not possible for `delegateTotalStaked` as it is bounded by the `totalSupply` which has
            // been incremented in `_stake`.
            info.delegateTotalStaked += amount;

            // If the total staked by all delegates does not overflow, this increment is safe.
            info.stakedByDelegate[msg.sender] += amount;
        }
        emit DelegateStaked(account, msg.sender, amount);
    }

    /// @inheritdoc IRewardVault
    function withdraw(uint256 amount) external nonReentrant checkSelfStakedBalance(msg.sender, amount) {
        _withdraw(msg.sender, amount);
    }

    /// @inheritdoc IRewardVault
    function delegateWithdraw(address account, uint256 amount) external nonReentrant {
        if (msg.sender == account) NotDelegate.selector.revertWith();

        unchecked {
            DelegateStake storage info = _delegateStake[account];
            uint256 stakedByDelegate = info.stakedByDelegate[msg.sender];
            if (stakedByDelegate < amount) InsufficientDelegateStake.selector.revertWith();
            info.stakedByDelegate[msg.sender] = stakedByDelegate - amount;
            // underflow is impossible because `info.delegateTotalStaked` >= `stakedByDelegate` >= `amount`
            info.delegateTotalStaked -= amount;
        }
        _withdraw(account, amount);
        emit DelegateWithdrawn(account, msg.sender, amount);
    }

    /// @inheritdoc IRewardVault
    function getReward(
        address account,
        address recipient
    )
        external
        nonReentrant
        onlyOperatorOrUser(account)
        returns (uint256)
    {
        return _getReward(account, recipient);
    }

    /// @inheritdoc IRewardVault
    function exit(address recipient) external nonReentrant {
        // self-staked amount
        uint256 amount = _accountInfo[msg.sender].balance - _delegateStake[msg.sender].delegateTotalStaked;
        _withdraw(msg.sender, amount);
        _getReward(msg.sender, recipient);
    }

    /// @inheritdoc IRewardVault
    function setOperator(address _operator) external {
        _operators[msg.sender] = _operator;
        emit OperatorSet(msg.sender, _operator);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        INTERNAL FUNCTIONS                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Check if the account has enough self-staked balance.
    /// @param account The account to check the self-staked balance for.
    /// @param amount The amount being withdrawn.
    function _checkSelfStakedBalance(address account, uint256 amount) internal view {
        unchecked {
            uint256 selfStaked = _accountInfo[account].balance - _delegateStake[account].delegateTotalStaked;
            if (selfStaked < amount) InsufficientSelfStake.selector.revertWith();
        }
    }
}