// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.10;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { FixedPointMathLib } from "solady/src/utils/FixedPointMathLib.sol";

import { Utils } from "./berachain/Utils.sol";
import { IRewardVault } from "./IRewardVault.sol";
import { FactoryOwnable } from "./berachain/FactoryOwnable.sol";
import { StakingRewards } from "./berachain/StakingRewards.sol";

/// @title Rewards Vault
/// @author Berachain Team
/// @notice This contract is the vault for the Berachain rewards, it handles the staking and rewards accounting of BGT.
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
        mapping(address => uint256) stakedByDelegate;
    }

    /// @notice Struct to hold an incentive data.
    /// @param minIncentiveRate The minimum amount of the token to incentivize per BGT emission.
    /// @param incentiveRate The amount of the token to incentivize per BGT emission.
    /// @param amountRemaining The amount of the token remaining to incentivize.
    /// @param manager The address of the manager that can addIncentive for this incentive token.
    struct Incentive {
        uint256 minIncentiveRate;
        uint256 incentiveRate;
        uint256 amountRemaining;
        address manager;
    }

    uint256 private constant MAX_INCENTIVE_RATE = 1e36; // for 18 decimal token, this will mean 1e18 incentiveTokens
        // per BGT emission.

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STORAGE                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice The maximum count of incentive tokens that can be stored.
    uint8 public maxIncentiveTokensCount;

    mapping(address => DelegateStake) internal _delegateStake;

    /// @notice The mapping of accounts to their operators.
    mapping(address => address) internal _operators;

    /// @notice the mapping of incentive token to its incentive data.
    mapping(address => Incentive) public incentives;

    /// @notice The list of whitelisted tokens.
    address[] public whitelistedTokens;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IRewardVault
    function initialize(
        address _bgt,
        address _stakingToken
    )
        external
        initializer
    {
        __FactoryOwnable_init(msg.sender);
        __Pausable_init();
        __ReentrancyGuard_init();
        __StakingRewards_init(_stakingToken, _bgt, 3 days);
        maxIncentiveTokensCount = 3;
        emit MaxIncentiveTokensCountUpdated(maxIncentiveTokensCount);
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

    modifier onlyWhitelistedToken(address token) {
        if (incentives[token].minIncentiveRate == 0) TokenNotWhitelisted.selector.revertWith();
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
        if (incentives[tokenAddress].minIncentiveRate != 0) CannotRecoverIncentiveToken.selector.revertWith();
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
    function whitelistIncentiveToken(
        address token,
        uint256 minIncentiveRate,
        address manager
    )
        external
        onlyFactoryOwner
    {
        // validate `minIncentiveRate` value
        if (minIncentiveRate == 0) MinIncentiveRateIsZero.selector.revertWith();
        if (minIncentiveRate > MAX_INCENTIVE_RATE) IncentiveRateTooHigh.selector.revertWith();

        // validate token and manager address
        if (token == address(0) || manager == address(0)) ZeroAddress.selector.revertWith();

        Incentive storage incentive = incentives[token];
        if (whitelistedTokens.length == maxIncentiveTokensCount || incentive.minIncentiveRate != 0) {
            TokenAlreadyWhitelistedOrLimitReached.selector.revertWith();
        }
        whitelistedTokens.push(token);
        //set the incentive rate to the minIncentiveRate.
        incentive.incentiveRate = minIncentiveRate;
        incentive.minIncentiveRate = minIncentiveRate;
        // set the manager
        incentive.manager = manager;
        emit IncentiveTokenWhitelisted(token, minIncentiveRate, manager);
    }

    /// @inheritdoc IRewardVault
    function removeIncentiveToken(address token) external onlyFactoryVaultManager onlyWhitelistedToken(token) {
        delete incentives[token];
        // delete the token from the list.
        _deleteWhitelistedTokenFromList(token);
        emit IncentiveTokenRemoved(token);
    }

    /// @inheritdoc IRewardVault
    function updateIncentiveManager(
        address token,
        address newManager
    )
        external
        onlyFactoryOwner
        onlyWhitelistedToken(token)
    {
        if (newManager == address(0)) ZeroAddress.selector.revertWith();
        Incentive storage incentive = incentives[token];
        // cache the current manager
        address currentManager = incentive.manager;
        incentive.manager = newManager;
        emit IncentiveManagerChanged(token, newManager, currentManager);
    }

    /// @inheritdoc IRewardVault
    function setMaxIncentiveTokensCount(uint8 _maxIncentiveTokensCount) external onlyFactoryOwner {
        if (_maxIncentiveTokensCount < whitelistedTokens.length) {
            InvalidMaxIncentiveTokensCount.selector.revertWith();
        }
        maxIncentiveTokensCount = _maxIncentiveTokensCount;
        emit MaxIncentiveTokensCountUpdated(_maxIncentiveTokensCount);
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
    function getWhitelistedTokensCount() external view returns (uint256) {
        return whitelistedTokens.length;
    }

    /// @inheritdoc IRewardVault
    function getWhitelistedTokens() public view returns (address[] memory) {
        return whitelistedTokens;
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
    function withdraw(uint256 amount)
        external
        nonReentrant
        whenNotPaused
        checkSelfStakedBalance(msg.sender, amount)
    {
        _withdraw(msg.sender, amount);
    }

    /// @inheritdoc IRewardVault
    function delegateWithdraw(address account, uint256 amount) external nonReentrant whenNotPaused {
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
    function exit(address recipient) external nonReentrant whenNotPaused {
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

    /// @inheritdoc IRewardVault
    function addIncentive(
        address token,
        uint256 amount,
        uint256 incentiveRate
    )
        external
        nonReentrant
        onlyWhitelistedToken(token)
    {
        if (incentiveRate > MAX_INCENTIVE_RATE) IncentiveRateTooHigh.selector.revertWith();
        Incentive storage incentive = incentives[token];
        (uint256 minIncentiveRate, uint256 incentiveRateStored, uint256 amountRemainingBefore, address manager) =
            (incentive.minIncentiveRate, incentive.incentiveRate, incentive.amountRemaining, incentive.manager);

        // Only allow the incentive token manager to add incentive.
        if (msg.sender != manager) NotIncentiveManager.selector.revertWith();

        // The incentive amount should be equal to or greater than the `minIncentiveRate` to avoid spamming.
        // If the `minIncentiveRate` is 100 USDC/BGT, the amount should be at least 100 USDC.
        if (amount < minIncentiveRate) AmountLessThanMinIncentiveRate.selector.revertWith();

        // The incentive rate should be greater than or equal to the `minIncentiveRate`.
        if (incentiveRate < minIncentiveRate) InvalidIncentiveRate.selector.revertWith();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        incentive.amountRemaining = amountRemainingBefore + amount;
        // Allows updating the incentive rate if the remaining incentive amount is 0.
        // Allow to decrease the incentive rate when accounted incentives are finished.
        if (amountRemainingBefore == 0) {
            incentive.incentiveRate = incentiveRate;
        }
        // Always allow to increase the incentive rate.
        else if (incentiveRate >= incentiveRateStored) {
            incentive.incentiveRate = incentiveRate;
        }
        // If the remaining incentive amount is not 0 and the new rate is less than the current rate, revert.
        else {
            InvalidIncentiveRate.selector.revertWith();
        }

        emit IncentiveAdded(token, msg.sender, amount, incentive.incentiveRate);
    }

    /// @inheritdoc IRewardVault
    function accountIncentives(address token, uint256 amount) external nonReentrant onlyWhitelistedToken(token) {
        Incentive storage incentive = incentives[token];
        (uint256 minIncentiveRate, uint256 incentiveRateStored, uint256 amountRemainingBefore, address manager) =
            (incentive.minIncentiveRate, incentive.incentiveRate, incentive.amountRemaining, incentive.manager);

        // Only allow the incentive token manager to account for cumulated incentives.
        if (msg.sender != manager) NotIncentiveManager.selector.revertWith();

        if (amount < minIncentiveRate) AmountLessThanMinIncentiveRate.selector.revertWith();

        uint256 incentiveBalance = IERC20(token).balanceOf(address(this));
        if (token == address(stakeToken)) {
            incentiveBalance -= totalSupply;
        }

        if (amount > incentiveBalance - amountRemainingBefore) NotEnoughBalance.selector.revertWith();

        incentive.amountRemaining += amount;

        emit IncentiveAdded(token, msg.sender, amount, incentiveRateStored);
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

    function _deleteWhitelistedTokenFromList(address token) internal {
        uint256 activeTokens = whitelistedTokens.length;
        // The length of `whitelistedTokens` cannot be 0 because the `onlyWhitelistedToken` check has already been
        // performed.
        unchecked {
            for (uint256 i; i < activeTokens; ++i) {
                if (token == whitelistedTokens[i]) {
                    whitelistedTokens[i] = whitelistedTokens[activeTokens - 1];
                    whitelistedTokens.pop();
                    return;
                }
            }
        }
    }
}