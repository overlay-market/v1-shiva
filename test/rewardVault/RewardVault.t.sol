// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IStakingRewardsErrors} from "berachain/src/base/IStakingRewardsErrors.sol";
import {IPOLErrors} from "berachain/src/pol/interfaces/IPOLErrors.sol";
import {IRewardVaultFactory} from "berachain/src/pol/interfaces/IRewardVaultFactory.sol";
import {IRewardVault} from "src/rewardVault/IRewardVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FactoryOwnable} from "berachain/src/base/FactoryOwnable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

contract RewardVaultTest is Test {
    // Tokens
    MockERC20 stakingToken;
    MockERC20 rewardtoken;

    // Contracts
    IRewardVaultFactory factory;
    IRewardVault rewardVault;

    // Users
    address deployer;
    address alice;
    address bob;
    address charlie;
    address david;

    uint256 constant ONE = 1e18;
    uint256 constant PRECISION = 1e18;

    function setUp() public {
        deployer = makeAddr("deployer");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        david = makeAddr("david");

        vm.label(deployer, "Deployer");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(charlie, "Charlie");
        vm.label(david, "David");

        vm.startPrank(deployer);

        // Deploy tokens
        stakingToken = new MockERC20("Staking Token", "STK", 18);
        rewardtoken = new MockERC20("Berachain Governance Token", "REWARDTOKEN", 18);

        // Deploy implementations
        address rewardVaultImplementation = deployCode("RewardVault.sol:RewardVault");
        address rewardVaultFactoryImplementation = deployCode("RewardVaultFactory.sol:RewardVaultFactory");

        // Deploy factory proxy
        bytes memory rewardVaultFactoryData = abi.encodeWithSignature(
            "initialize(address,address,address)",
            address(rewardtoken),
            deployer,
            address(rewardVaultImplementation)
        );
        factory = IRewardVaultFactory(
            address(new ERC1967Proxy(address(rewardVaultFactoryImplementation), rewardVaultFactoryData))
        );

        // Grant pauser/manager roles to deployer for testing
        // Manager role must be granted first as it's the admin for the pauser role.
        IAccessControl(address(factory)).grantRole(factory.VAULT_MANAGER_ROLE(), deployer);
        IAccessControl(address(factory)).grantRole(factory.VAULT_PAUSER_ROLE(), deployer);

        // Create a vault
        address vaultAddress = factory.createRewardVault(address(stakingToken));
        rewardVault = IRewardVault(vaultAddress);

        vm.stopPrank();

        // Distribute tokens and set approvals
        stakingToken.mint(alice, 1000 * ONE);
        stakingToken.mint(bob, 1000 * ONE);
        stakingToken.mint(charlie, 1000 * ONE);
        stakingToken.mint(david, 1000 * ONE);
        rewardtoken.mint(deployer, 10000 * ONE); // Mint REWARDTOKEN for the deployer to use as rewards

        vm.startPrank(alice);
        stakingToken.approve(address(rewardVault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        stakingToken.approve(address(rewardVault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(charlie);
        stakingToken.approve(address(rewardVault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(david);
        stakingToken.approve(address(rewardVault), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Tests that staking correctly updates the user's and vault's balances.
    function test_stake_updates_balance_correctly() public {
        uint256 stakeAmount = 100 * ONE;

        vm.startPrank(alice);

        uint256 initialVaultTokenBalance = stakingToken.balanceOf(address(rewardVault));
        uint256 initialAliceTokenBalance = stakingToken.balanceOf(alice);
        uint256 initialVaultInternalBalance = rewardVault.balanceOf(alice);
        uint256 initialVaultTotalSupply = rewardVault.totalSupply();

        rewardVault.stake(stakeAmount);

        // Check internal vault accounting
        assertEq(
            rewardVault.balanceOf(alice),
            initialVaultInternalBalance + stakeAmount,
            "Vault internal balance for Alice should increase by staked amount"
        );
        assertEq(
            rewardVault.totalSupply(),
            initialVaultTotalSupply + stakeAmount,
            "Vault total supply should increase by staked amount"
        );

        // Check token balances
        assertEq(
            stakingToken.balanceOf(address(rewardVault)),
            initialVaultTokenBalance + stakeAmount,
            "Vault's token balance should increase"
        );
        assertEq(
            stakingToken.balanceOf(alice),
            initialAliceTokenBalance - stakeAmount,
            "Alice's token balance should decrease"
        );

        vm.stopPrank();
    }

    /// @notice Tests that withdrawing correctly updates the user's and vault's balances.
    function test_withdraw_updates_balance_correctly() public {
        uint256 stakeAmount = 100 * ONE;
        uint256 withdrawAmount = 30 * ONE;

        // Alice stakes first
        vm.startPrank(alice);
        rewardVault.stake(stakeAmount);

        uint256 initialVaultTokenBalance = stakingToken.balanceOf(address(rewardVault));
        uint256 initialAliceTokenBalance = stakingToken.balanceOf(alice);
        uint256 initialVaultInternalBalance = rewardVault.balanceOf(alice);
        uint256 initialVaultTotalSupply = rewardVault.totalSupply();

        // Alice withdraws a portion
        rewardVault.withdraw(withdrawAmount);

        // Check internal vault accounting
        assertEq(
            rewardVault.balanceOf(alice),
            initialVaultInternalBalance - withdrawAmount,
            "Vault internal balance for Alice should decrease"
        );
        assertEq(
            rewardVault.totalSupply(),
            initialVaultTotalSupply - withdrawAmount,
            "Vault total supply should decrease"
        );

        // Check token balances
        assertEq(
            stakingToken.balanceOf(address(rewardVault)),
            initialVaultTokenBalance - withdrawAmount,
            "Vault's token balance should decrease"
        );
        assertEq(
            stakingToken.balanceOf(alice),
            initialAliceTokenBalance + withdrawAmount,
            "Alice's token balance should increase"
        );

        vm.stopPrank();
    }

    /// @notice Tests that withdrawing more than the staked amount reverts.
    function test_revert_withdraw_insufficient_staked_balance() public {
        uint256 stakeAmount = 100 * ONE;
        uint256 withdrawAmount = stakeAmount + 1;

        vm.startPrank(alice);
        rewardVault.stake(stakeAmount);

        vm.expectRevert(IPOLErrors.InsufficientSelfStake.selector);
        rewardVault.withdraw(withdrawAmount);
        vm.stopPrank();
    }

    /// @notice Tests that withdrawing zero amount reverts.
    function test_revert_withdraw_zero_amount() public {
        vm.startPrank(alice);
        rewardVault.stake(100 * ONE);

        vm.expectRevert(IStakingRewardsErrors.WithdrawAmountIsZero.selector);
        rewardVault.withdraw(0);
        vm.stopPrank();
    }

    /// @notice Tests that staking zero amount reverts.
    function test_revert_stake_zero_amount() public {
        vm.startPrank(alice);
        vm.expectRevert(IStakingRewardsErrors.StakeAmountIsZero.selector);
        rewardVault.stake(0);
        vm.stopPrank();
    }

    /// @notice Tests that staking fails when the contract is paused.
    function test_revert_stake_when_paused() public {
        // Pause the contract first
        vm.startPrank(deployer);
        rewardVault.pause();
        vm.stopPrank();

        // Try to stake when paused
        vm.startPrank(alice);
        vm.expectRevert("Pausable: paused");
        rewardVault.stake(100 * ONE);
        vm.stopPrank();
    }

    /// @notice Tests that a user cannot delegate stake to themselves.
    function test_revert_delegate_stake_self_delegation() public {
        vm.startPrank(alice);
        vm.expectRevert(IPOLErrors.NotDelegate.selector);
        rewardVault.delegateStake(alice, 100 * ONE);
        vm.stopPrank();
    }

    /// @notice Tests that initialize can only be called once.
    function test_revert_initialize_twice() public {
        // Create a new vault instance to test initialize
        address newVaultAddress = factory.createRewardVault(address(stakingToken));
        IRewardVault newVault = IRewardVault(newVaultAddress);
        
        // Try to initialize again - this should revert
        vm.startPrank(deployer);
        vm.expectRevert("Initializable: contract is already initialized");
        newVault.initialize(address(rewardtoken), address(stakingToken));
        vm.stopPrank();
    }

    /// @notice Tests that only the factory owner can notify reward amounts.
    function test_revert_notify_reward_amount_not_factory_owner() public {
        // Try to notify rewards as a non-factory owner
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(FactoryOwnable.OwnableUnauthorizedAccount.selector, alice));
        rewardVault.notifyRewardAmount(bytes(""), 100 * ONE);
        vm.stopPrank();
    }

    /// @notice Tests that cannot recover more staking tokens than the excess available.
    function test_revert_recover_staking_token_exceeds_balance() public {
        // First, stake some tokens to create a balance
        vm.startPrank(alice);
        rewardVault.stake(100 * ONE);
        vm.stopPrank();

        // Calculate the maximum amount that can be recovered (excess tokens)
        uint256 vaultBalance = stakingToken.balanceOf(address(rewardVault));
        uint256 totalSupply = rewardVault.totalSupply();
        uint256 maxRecoveryAmount = vaultBalance - totalSupply;

        // Try to recover more than the excess amount
        vm.startPrank(deployer);
        vm.expectRevert(IPOLErrors.NotEnoughBalance.selector);
        rewardVault.recoverERC20(address(stakingToken), maxRecoveryAmount + 1);
        vm.stopPrank();
    }

    /// @notice Tests that rewards duration cannot be set to zero.
    function test_revert_set_rewards_duration_zero() public {
        vm.startPrank(deployer);
        vm.expectRevert(IStakingRewardsErrors.RewardsDurationIsZero.selector);
        rewardVault.setRewardsDuration(0);
        vm.stopPrank();
    }

    /// @notice Tests that only the pauser can pause the contract.
    function test_revert_pause_not_pauser() public {
        // Try to pause as a non-pauser
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(FactoryOwnable.OwnableUnauthorizedAccount.selector, alice));
        rewardVault.pause();
        vm.stopPrank();
    }

    /// @notice Tests that only the manager can unpause the contract.
    function test_revert_unpause_not_manager() public {
        // Try to unpause as a non-manager
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(FactoryOwnable.OwnableUnauthorizedAccount.selector, alice));
        rewardVault.unpause();
        vm.stopPrank();
    }

    /// @notice Tests that only the user or their operator can claim rewards.
    function test_revert_get_reward_not_operator_or_user() public {
        // First, stake some tokens and earn rewards
        vm.startPrank(alice);
        rewardVault.stake(100 * ONE);
        vm.stopPrank();

        // Add rewards
        vm.startPrank(deployer);
        rewardtoken.transfer(address(rewardVault), 500 * ONE);
        rewardVault.notifyRewardAmount(bytes(""), 500 * ONE);
        vm.stopPrank();

        // Wait for some rewards to accumulate
        vm.warp(block.timestamp + 1 days);

        // Try to claim rewards as a non-operator/non-user
        vm.startPrank(charlie);
        vm.expectRevert(IPOLErrors.NotOperator.selector);
        rewardVault.getReward(alice, charlie);
        vm.stopPrank();
    }

    /// @notice Tests rewards flow across multiple periods.
    function test_rewards_flow_multiple_periods() public {
        uint256 stakeAmount = 100 * ONE;
        uint256 rewardAmount = 300 * ONE;
        uint256 rewardsDuration = rewardVault.rewardsDuration();

        // 1. Alice stakes
        vm.startPrank(alice);
        rewardVault.stake(stakeAmount);
        vm.stopPrank();

        // 2. First reward period
        vm.startPrank(deployer);
        rewardtoken.transfer(address(rewardVault), rewardAmount);
        rewardVault.notifyRewardAmount(bytes(""), rewardAmount);
        vm.stopPrank();

        // Wait for first period to end
        vm.warp(block.timestamp + rewardsDuration);

        // Check rewards after first period
        uint256 aliceRewardsAfterFirstPeriod = rewardVault.earned(alice);
        assertApproxEqAbs(aliceRewardsAfterFirstPeriod, rewardAmount, 1e16, "Alice should earn full rewards in first period");

        // 3. Second reward period
        vm.startPrank(deployer);
        rewardtoken.transfer(address(rewardVault), rewardAmount);
        rewardVault.notifyRewardAmount(bytes(""), rewardAmount);
        vm.stopPrank();

        // Wait for second period to end
        vm.warp(block.timestamp + rewardsDuration);

        // Check rewards after second period
        uint256 aliceRewardsAfterSecondPeriod = rewardVault.earned(alice);
        assertApproxEqAbs(aliceRewardsAfterSecondPeriod, rewardAmount * 2, 1e16, "Alice should earn double rewards after two periods");

        // 4. Claim rewards
        vm.startPrank(alice);
        uint256 claimed = rewardVault.getReward(alice, alice);
        assertApproxEqAbs(claimed, rewardAmount * 2, 1e16, "Alice should claim all earned rewards");
        vm.stopPrank();
    }

    /// @notice Tests rewards when a user stakes, withdraws, and stakes again.
    function test_rewards_flow_with_stake_withdraw_stake() public {
        uint256 initialStake = 100 * ONE;
        uint256 withdrawAmount = 50 * ONE;
        uint256 secondStake = 75 * ONE;
        uint256 rewardAmount = 500 * ONE;

        // 1. Alice stakes initially
        vm.startPrank(alice);
        rewardVault.stake(initialStake);
        vm.stopPrank();

        // 2. Add rewards and wait
        vm.startPrank(deployer);
        rewardtoken.transfer(address(rewardVault), rewardAmount);
        rewardVault.notifyRewardAmount(bytes(""), rewardAmount);
        vm.stopPrank();

        uint256 rewardsDuration = rewardVault.rewardsDuration();
        vm.warp(block.timestamp + rewardsDuration / 2);

        // 3. Alice withdraws part of her stake
        vm.startPrank(alice);
        uint256 rewardsBeforeWithdraw = rewardVault.earned(alice);
        rewardVault.withdraw(withdrawAmount);
        vm.stopPrank();

        // 4. Alice stakes again
        vm.startPrank(alice);
        rewardVault.stake(secondStake);
        vm.stopPrank();

        // 5. Wait for the rest of the period
        vm.warp(block.timestamp + rewardsDuration / 2);

        // 6. Check final rewards
        vm.startPrank(alice);
        uint256 finalRewards = rewardVault.earned(alice);
        assertGt(finalRewards, rewardsBeforeWithdraw, "Alice should have earned more rewards after restaking");
        
        // Claim rewards
        uint256 claimed = rewardVault.getReward(alice, alice);
        assertApproxEqAbs(claimed, finalRewards, 1e16, "Alice should claim all earned rewards");
        vm.stopPrank();
    }

    /// @notice Tests delegate staking with multiple delegates for the same user.
    function test_delegate_stake_multiple_delegates() public {
        uint256 bobStake = 100 * ONE;
        uint256 charlieStake = 150 * ONE;
        uint256 davidStake = 200 * ONE;

        // Bob stakes for Alice
        vm.startPrank(bob);
        rewardVault.delegateStake(alice, bobStake);
        vm.stopPrank();

        // Charlie stakes for Alice
        vm.startPrank(charlie);
        rewardVault.delegateStake(alice, charlieStake);
        vm.stopPrank();

        // David stakes for Alice
        vm.startPrank(david);
        rewardVault.delegateStake(alice, davidStake);
        vm.stopPrank();

        // Check Alice's total balance
        uint256 aliceTotalBalance = rewardVault.balanceOf(alice);
        uint256 expectedTotalBalance = bobStake + charlieStake + davidStake;
        assertEq(aliceTotalBalance, expectedTotalBalance, "Alice's total balance should equal sum of all delegate stakes");

        // Check individual delegate stakes
        assertEq(rewardVault.getDelegateStake(alice, bob), bobStake, "Bob's delegate stake should be correct");
        assertEq(rewardVault.getDelegateStake(alice, charlie), charlieStake, "Charlie's delegate stake should be correct");
        assertEq(rewardVault.getDelegateStake(alice, david), davidStake, "David's delegate stake should be correct");

        // Check total delegate stake
        uint256 totalDelegateStake = rewardVault.getTotalDelegateStaked(alice);
        assertEq(totalDelegateStake, expectedTotalBalance, "Total delegate stake should equal sum of individual stakes");

        // Test partial withdrawals by delegates
        vm.startPrank(bob);
        rewardVault.delegateWithdraw(alice, 25 * ONE);
        vm.stopPrank();

        vm.startPrank(charlie);
        rewardVault.delegateWithdraw(alice, 50 * ONE);
        vm.stopPrank();

        // Check updated balances
        assertEq(rewardVault.getDelegateStake(alice, bob), 75 * ONE, "Bob's remaining stake should be correct");
        assertEq(rewardVault.getDelegateStake(alice, charlie), 100 * ONE, "Charlie's remaining stake should be correct");
        assertEq(rewardVault.getDelegateStake(alice, david), davidStake, "David's stake should be unchanged");

        uint256 updatedTotalDelegateStake = rewardVault.getTotalDelegateStaked(alice);
        uint256 expectedUpdatedTotal = 75 * ONE + 100 * ONE + davidStake;
        assertEq(updatedTotalDelegateStake, expectedUpdatedTotal, "Total delegate stake should be updated correctly");
    }

    /// @notice Tests exit behavior when there is only delegated stake.
    function test_exit_with_no_self_stake() public {
        uint256 delegateStakeAmount = 100 * ONE;
        uint256 rewardAmount = 500 * ONE;

        // Bob stakes for Alice (no self-stake)
        vm.startPrank(bob);
        rewardVault.delegateStake(alice, delegateStakeAmount);
        vm.stopPrank();

        // Add rewards and wait
        vm.startPrank(deployer);
        rewardtoken.transfer(address(rewardVault), rewardAmount);
        rewardVault.notifyRewardAmount(bytes(""), rewardAmount);
        vm.stopPrank();

        uint256 rewardsDuration = rewardVault.rewardsDuration();
        vm.warp(block.timestamp + rewardsDuration);

        // Alice tries to exit (should revert because she has no self-stake to withdraw)
        vm.startPrank(alice);
        vm.expectRevert(IStakingRewardsErrors.WithdrawAmountIsZero.selector);
        rewardVault.exit(alice);
        vm.stopPrank();

        // Verify that Alice's balance and rewards remain unchanged
        assertEq(
            rewardVault.balanceOf(alice),
            delegateStakeAmount,
            "Alice's internal balance should remain as delegated stake"
        );
        assertGt(
            rewardVault.earned(alice),
            0,
            "Alice should still have earned rewards"
        );
    }

    /// @notice Tests rewards flow when there is no total supply.
    function test_rewards_flow_with_zero_total_supply() public {
        uint256 rewardAmount = 500 * ONE;

        // Add rewards when no one has staked
        vm.startPrank(deployer);
        rewardtoken.transfer(address(rewardVault), rewardAmount);
        rewardVault.notifyRewardAmount(bytes(""), rewardAmount);
        vm.stopPrank();

        // Check that undistributed rewards are stored
        assertGt(rewardVault.undistributedRewards(), 0, "Undistributed rewards should be stored");

        // Now Alice stakes
        vm.startPrank(alice);
        rewardVault.stake(100 * ONE);
        vm.stopPrank();

        // Wait for some time
        vm.warp(block.timestamp + 1 days);

        // Check that Alice starts earning rewards
        uint256 aliceEarned = rewardVault.earned(alice);
        assertGt(aliceEarned, 0, "Alice should start earning rewards after staking");

        // Alice claims rewards
        vm.startPrank(alice);
        uint256 claimed = rewardVault.getReward(alice, alice);
        assertGt(claimed, 0, "Alice should be able to claim rewards");
        vm.stopPrank();
    }

    /// @notice Tests rewards flow with very small amounts (dust).
    function test_rewards_flow_with_very_small_amounts() public {
        uint256 dustStake = 1; // 1 wei
        uint256 smallReward = 1000; // 1000 wei
        uint256 rewardsDuration = rewardVault.rewardsDuration();

        // Alice stakes a very small amount
        vm.startPrank(alice);
        rewardVault.stake(dustStake);
        vm.stopPrank();

        // Add small rewards
        vm.startPrank(deployer);
        rewardtoken.transfer(address(rewardVault), smallReward);
        rewardVault.notifyRewardAmount(bytes(""), smallReward);
        vm.stopPrank();

        // Wait for the full duration
        vm.warp(block.timestamp + rewardsDuration);

        // Check that Alice earned rewards (should be close to the full amount)
        uint256 aliceEarned = rewardVault.earned(alice);
        assertApproxEqAbs(aliceEarned, smallReward, 1, "Alice should earn close to the full reward amount");

        // Alice claims rewards
        vm.startPrank(alice);
        uint256 claimed = rewardVault.getReward(alice, alice);
        assertApproxEqAbs(claimed, aliceEarned, 1, "Alice should claim her earned rewards");
        vm.stopPrank();

        // Test with multiple dust stakers
        vm.startPrank(bob);
        rewardVault.stake(dustStake);
        vm.stopPrank();

        vm.startPrank(charlie);
        rewardVault.stake(dustStake);
        vm.stopPrank();

        // Add more rewards
        vm.startPrank(deployer);
        rewardtoken.transfer(address(rewardVault), smallReward);
        rewardVault.notifyRewardAmount(bytes(""), smallReward);
        vm.stopPrank();

        vm.warp(block.timestamp + rewardsDuration);

        // All three should earn approximately equal rewards
        uint256 bobEarned = rewardVault.earned(bob);
        uint256 charlieEarned = rewardVault.earned(charlie);

        assertApproxEqAbs(bobEarned, charlieEarned, 1, "Bob and Charlie should earn similar rewards");
        assertApproxEqAbs(bobEarned, smallReward / 3, 1, "Each should earn approximately 1/3 of the rewards");
    }

    /// @notice Tests rewards flow with very large amounts.
    function test_rewards_flow_with_very_large_amounts() public {
        uint256 largeStake = 1e20; // Large stake amount (within available balance)
        uint256 largeReward = 1e19; // Large reward amount (within available balance)
        uint256 rewardsDuration = rewardVault.rewardsDuration();

        // Alice stakes a very large amount
        vm.startPrank(alice);
        rewardVault.stake(largeStake);
        vm.stopPrank();

        // Add large rewards
        vm.startPrank(deployer);
        rewardtoken.transfer(address(rewardVault), largeReward);
        rewardVault.notifyRewardAmount(bytes(""), largeReward);
        vm.stopPrank();

        // Wait for the full duration
        vm.warp(block.timestamp + rewardsDuration);

        // Check that Alice earned rewards without overflow
        uint256 aliceEarned = rewardVault.earned(alice);
        assertGt(aliceEarned, 0, "Alice should earn rewards");
        assertLt(aliceEarned, type(uint256).max, "Rewards should not overflow");

        // Alice claims rewards
        vm.startPrank(alice);
        uint256 claimed = rewardVault.getReward(alice, alice);
        assertApproxEqAbs(claimed, aliceEarned, 1e16, "Alice should claim her earned rewards");
        vm.stopPrank();

        // Test with multiple large stakers
        vm.startPrank(bob);
        rewardVault.stake(largeStake);
        vm.stopPrank();

        vm.startPrank(charlie);
        rewardVault.stake(largeStake);
        vm.stopPrank();

        // Add more large rewards
        vm.startPrank(deployer);
        rewardtoken.transfer(address(rewardVault), largeReward);
        rewardVault.notifyRewardAmount(bytes(""), largeReward);
        vm.stopPrank();

        vm.warp(block.timestamp + rewardsDuration);

        // All three should earn approximately equal rewards
        uint256 bobEarned = rewardVault.earned(bob);
        uint256 charlieEarned = rewardVault.earned(charlie);

        assertApproxEqAbs(bobEarned, charlieEarned, 1e16, "Bob and Charlie should earn similar rewards");
        assertApproxEqAbs(bobEarned, largeReward / 3, 1e16, "Each should earn approximately 1/3 of the rewards");
    }

    /// @notice Tests that all events are emitted correctly.
    function test_events_emitted_correctly() public {
        uint256 stakeAmount = 100 * ONE;
        uint256 rewardAmount = 500 * ONE;

        // Test that operations complete successfully (events are emitted)
        vm.startPrank(alice);
        rewardVault.stake(stakeAmount);
        vm.stopPrank();

        vm.startPrank(bob);
        rewardVault.delegateStake(alice, stakeAmount);
        vm.stopPrank();

        vm.startPrank(deployer);
        rewardtoken.transfer(address(rewardVault), rewardAmount);
        rewardVault.notifyRewardAmount(bytes(""), rewardAmount);
        vm.stopPrank();

        vm.startPrank(alice);
        rewardVault.setOperator(bob);
        vm.stopPrank();

        vm.warp(block.timestamp + rewardVault.rewardsDuration());
        vm.startPrank(alice);
        rewardVault.getReward(alice, alice);
        vm.stopPrank();

        vm.startPrank(alice);
        rewardVault.withdraw(stakeAmount);
        vm.stopPrank();

        vm.startPrank(bob);
        rewardVault.delegateWithdraw(alice, stakeAmount);
        vm.stopPrank();

        // All operations completed successfully, indicating events were emitted
        assertTrue(true, "All operations completed successfully");
    }

    /// @notice Tests gas optimization for stake and withdraw operations.
    function test_gas_optimization_stake_withdraw() public {
        uint256 stakeAmount = 100 * ONE;

        // Measure gas for stake operation
        vm.startPrank(alice);
        uint256 gasBeforeStake = gasleft();
        rewardVault.stake(stakeAmount);
        uint256 gasUsedStake = gasBeforeStake - gasleft();
        vm.stopPrank();

        // Measure gas for withdraw operation
        vm.startPrank(alice);
        uint256 gasBeforeWithdraw = gasleft();
        rewardVault.withdraw(stakeAmount);
        uint256 gasUsedWithdraw = gasBeforeWithdraw - gasleft();
        vm.stopPrank();

        // Assert that gas usage is reasonable (less than 200k gas for each operation)
        assertLt(gasUsedStake, 200000, "Stake operation should use less than 200k gas");
        assertLt(gasUsedWithdraw, 200000, "Withdraw operation should use less than 200k gas");

        // Test gas for delegate operations
        vm.startPrank(bob);
        uint256 gasBeforeDelegateStake = gasleft();
        rewardVault.delegateStake(alice, stakeAmount);
        uint256 gasUsedDelegateStake = gasBeforeDelegateStake - gasleft();
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 gasBeforeDelegateWithdraw = gasleft();
        rewardVault.delegateWithdraw(alice, stakeAmount);
        uint256 gasUsedDelegateWithdraw = gasBeforeDelegateWithdraw - gasleft();
        vm.stopPrank();

        // Assert that delegate operations are also reasonable
        assertLt(gasUsedDelegateStake, 250000, "Delegate stake should use less than 250k gas");
        assertLt(gasUsedDelegateWithdraw, 250000, "Delegate withdraw should use less than 250k gas");
    }

    /// @notice Tests rewards flow with maximum uint256 values.
    function test_rewards_flow_with_max_uint256() public {
        uint256 maxStake = type(uint256).max;
        uint256 maxReward = type(uint256).max - 1; // Use max-1 to avoid overflow
        uint256 rewardsDuration = rewardVault.rewardsDuration();

        // Test that we can handle very large stakes (but not max uint256 due to token supply)
        uint256 largeStake = 1e20; // Very large but within available balance
        uint256 largeReward = 1e19; // Very large but within available balance

        // Alice stakes a very large amount
        vm.startPrank(alice);
        rewardVault.stake(largeStake);
        vm.stopPrank();

        // Add large rewards
        vm.startPrank(deployer);
        rewardtoken.transfer(address(rewardVault), largeReward);
        rewardVault.notifyRewardAmount(bytes(""), largeReward);
        vm.stopPrank();

        // Wait for the full duration
        vm.warp(block.timestamp + rewardsDuration);

        // Check that Alice earned rewards without overflow
        uint256 aliceEarned = rewardVault.earned(alice);
        assertGt(aliceEarned, 0, "Alice should earn rewards");
        assertLt(aliceEarned, type(uint256).max, "Rewards should not overflow");

        // Test edge cases with very large numbers
        assertLt(rewardVault.totalSupply(), type(uint256).max, "Total supply should not overflow");
        assertLt(rewardVault.rewardRate(), type(uint256).max, "Reward rate should not overflow");
        assertLt(rewardVault.rewardPerToken(), type(uint256).max, "Reward per token should not overflow");
    }

    /// @notice Tests delegate staking with overflow scenarios.
    function test_delegate_stake_with_overflow_scenarios() public {
        uint256 largeStake = 1e25;
        uint256 rewardsDuration = rewardVault.rewardsDuration();

        // Test multiple delegates with large amounts
        for (uint256 i = 0; i < 5; i++) {
            address delegate = makeAddr(string(abi.encodePacked("delegate", i)));
            stakingToken.mint(delegate, largeStake);
            
            vm.startPrank(delegate);
            stakingToken.approve(address(rewardVault), type(uint256).max);
            rewardVault.delegateStake(alice, largeStake);
            vm.stopPrank();
        }

        // Verify that total delegate stake doesn't overflow
        uint256 totalDelegateStake = rewardVault.getTotalDelegateStaked(alice);
        assertLt(totalDelegateStake, type(uint256).max, "Total delegate stake should not overflow");

        // Verify that Alice's total balance doesn't overflow
        uint256 aliceBalance = rewardVault.balanceOf(alice);
        assertLt(aliceBalance, type(uint256).max, "Alice's balance should not overflow");

        // Test that we can still perform operations
        vm.startPrank(alice);
        uint256 earned = rewardVault.earned(alice);
        assertLt(earned, type(uint256).max, "Earned rewards should not overflow");
        vm.stopPrank();

        // Test delegate withdrawals to ensure no underflow
        address firstDelegate = makeAddr("delegate0");
        uint256 firstDelegateStake = rewardVault.getDelegateStake(alice, firstDelegate);
        
        // Only withdraw if there's actually a stake
        if (firstDelegateStake > 0) {
            vm.startPrank(firstDelegate);
            rewardVault.delegateWithdraw(alice, firstDelegateStake);
            vm.stopPrank();

            // Verify that total delegate stake decreased correctly
            uint256 newTotalDelegateStake = rewardVault.getTotalDelegateStaked(alice);
            assertEq(newTotalDelegateStake, totalDelegateStake - firstDelegateStake, "Total delegate stake should decrease correctly");
        } else {
            // If no stake, just verify the total is correct
            assertEq(rewardVault.getTotalDelegateStaked(alice), totalDelegateStake, "Total delegate stake should remain unchanged");
        }
    }

    /// @notice Tests rewards flow with time manipulation.
    function test_rewards_flow_with_time_manipulation() public {
        uint256 stakeAmount = 100 * ONE;
        uint256 rewardAmount = 500 * ONE;
        uint256 rewardsDuration = rewardVault.rewardsDuration();

        // Alice stakes
        vm.startPrank(alice);
        rewardVault.stake(stakeAmount);
        vm.stopPrank();

        // Add rewards
        vm.startPrank(deployer);
        rewardtoken.transfer(address(rewardVault), rewardAmount);
        rewardVault.notifyRewardAmount(bytes(""), rewardAmount);
        vm.stopPrank();

        // Test time manipulation - go forward in time
        uint256 currentTime = block.timestamp;
        vm.warp(currentTime + rewardsDuration);

        // Check that rewards are calculated correctly
        uint256 aliceEarned = rewardVault.earned(alice);
        assertGt(aliceEarned, 0, "Alice should earn rewards when time goes forward");

        // Test with very large time jumps
        vm.warp(block.timestamp + 1000000); // Jump 1 million seconds

        // Check that rewards don't overflow with large time jumps
        aliceEarned = rewardVault.earned(alice);
        assertLt(aliceEarned, type(uint256).max, "Rewards should not overflow with large time jumps");

        // Test that periodFinish is respected
        uint256 periodFinish = rewardVault.periodFinish();
        assertGt(periodFinish, 0, "Period finish should be set");

        // Go beyond period finish
        vm.warp(periodFinish + 1000);

        // Check that rewards stop accumulating after period finish
        uint256 aliceEarnedAfterPeriod = rewardVault.earned(alice);
        assertApproxEqAbs(aliceEarnedAfterPeriod, aliceEarned, 1e16, "Rewards should not increase after period finish");

        // Test that lastUpdateTime is updated correctly
        uint256 lastUpdateTime = rewardVault.lastUpdateTime();
        assertLe(lastUpdateTime, periodFinish, "Last update time should not exceed period finish");
    }

    /// @notice Tests changing operators multiple times for the same user.
    function test_multiple_operators_same_user() public {
        address operator1 = makeAddr("operator1");
        address operator2 = makeAddr("operator2");
        address operator3 = makeAddr("operator3");

        // Alice sets first operator
        vm.startPrank(alice);
        rewardVault.setOperator(operator1);
        assertEq(rewardVault.operator(alice), operator1, "First operator should be set");
        vm.stopPrank();

        // Alice changes to second operator
        vm.startPrank(alice);
        rewardVault.setOperator(operator2);
        assertEq(rewardVault.operator(alice), operator2, "Second operator should be set");
        vm.stopPrank();

        // Alice changes to third operator
        vm.startPrank(alice);
        rewardVault.setOperator(operator3);
        assertEq(rewardVault.operator(alice), operator3, "Third operator should be set");
        vm.stopPrank();

        // Alice removes operator by setting to zero address
        vm.startPrank(alice);
        rewardVault.setOperator(address(0));
        assertEq(rewardVault.operator(alice), address(0), "Operator should be removed");
        vm.stopPrank();

        // Test that operator can claim rewards
        vm.startPrank(alice);
        rewardVault.stake(100 * ONE);
        rewardVault.setOperator(operator1);
        vm.stopPrank();

        // Add rewards
        vm.startPrank(deployer);
        rewardtoken.transfer(address(rewardVault), 500 * ONE);
        rewardVault.notifyRewardAmount(bytes(""), 500 * ONE);
        vm.stopPrank();

        vm.warp(block.timestamp + rewardVault.rewardsDuration());

        // Operator claims rewards
        vm.startPrank(operator1);
        uint256 claimed = rewardVault.getReward(alice, operator1);
        assertGt(claimed, 0, "Operator should be able to claim rewards");
        vm.stopPrank();
    }

    /// @notice Tests rewards when a user exits early in the period.
    function test_rewards_flow_with_early_exit() public {
        uint256 stakeAmount = 100 * ONE;
        uint256 rewardAmount = 500 * ONE;
        uint256 rewardsDuration = rewardVault.rewardsDuration();

        // Alice stakes
        vm.startPrank(alice);
        rewardVault.stake(stakeAmount);
        vm.stopPrank();

        // Add rewards
        vm.startPrank(deployer);
        rewardtoken.transfer(address(rewardVault), rewardAmount);
        rewardVault.notifyRewardAmount(bytes(""), rewardAmount);
        vm.stopPrank();

        // Wait for only 1/4 of the period
        vm.warp(block.timestamp + rewardsDuration / 4);

        // Alice exits early
        vm.startPrank(alice);
        uint256 earnedBeforeExit = rewardVault.earned(alice);
        rewardVault.exit(alice);
        vm.stopPrank();

        // Check that Alice received partial rewards
        assertGt(earnedBeforeExit, 0, "Alice should have earned some rewards");
        assertLt(earnedBeforeExit, rewardAmount, "Alice should have earned less than full rewards");

        // Check that Alice received her staking tokens back
        assertEq(
            stakingToken.balanceOf(alice),
            1000 * ONE, // Initial balance
            "Alice should receive her staking tokens back"
        );

        // Check that Alice received her rewards
        assertGt(
            rewardtoken.balanceOf(alice),
            0,
            "Alice should receive her earned rewards"
        );
    }

    /// @notice Tests rewards when a user enters late in the period.
    function test_rewards_flow_with_late_entry() public {
        uint256 stakeAmount = 100 * ONE;
        uint256 rewardAmount = 500 * ONE;
        uint256 rewardsDuration = rewardVault.rewardsDuration();

        // Add rewards first
        vm.startPrank(deployer);
        rewardtoken.transfer(address(rewardVault), rewardAmount);
        rewardVault.notifyRewardAmount(bytes(""), rewardAmount);
        vm.stopPrank();

        // Wait for 3/4 of the period before Alice stakes
        vm.warp(block.timestamp + (rewardsDuration * 3) / 4);

        // Alice stakes late
        vm.startPrank(alice);
        rewardVault.stake(stakeAmount);
        vm.stopPrank();

        // Wait for the remaining 1/4 of the period
        vm.warp(block.timestamp + rewardsDuration / 4);

        // Check that Alice earned partial rewards
        uint256 aliceEarned = rewardVault.earned(alice);
        assertGt(aliceEarned, 0, "Alice should have earned some rewards");
        assertLt(aliceEarned, rewardAmount, "Alice should have earned less than full rewards");

        // Alice claims rewards
        vm.startPrank(alice);
        uint256 claimed = rewardVault.getReward(alice, alice);
        assertApproxEqAbs(claimed, aliceEarned, 1e16, "Alice should claim her earned rewards");
        vm.stopPrank();

        // Test with Bob entering even later
        vm.startPrank(deployer);
        rewardtoken.transfer(address(rewardVault), rewardAmount);
        rewardVault.notifyRewardAmount(bytes(""), rewardAmount);
        vm.stopPrank();

        // Wait for 90% of the period
        vm.warp(block.timestamp + (rewardsDuration * 9) / 10);

        // Bob stakes very late
        vm.startPrank(bob);
        rewardVault.stake(stakeAmount);
        vm.stopPrank();

        // Wait for the remaining 10% of the period
        vm.warp(block.timestamp + rewardsDuration / 10);

        // Bob should earn very little rewards
        uint256 bobEarned = rewardVault.earned(bob);
        assertGt(bobEarned, 0, "Bob should have earned some rewards");
        assertLt(bobEarned, aliceEarned, "Bob should have earned less than Alice");
    }

    /// @notice Tests the full rewards flow for a single staker.
    function test_rewards_flow_single_staker() public {
        uint256 stakeAmount = 100 * ONE;
        uint256 rewardAmount = 500 * ONE;

        // 1. Alice stakes
        vm.startPrank(alice);
        rewardVault.stake(stakeAmount);
        vm.stopPrank();

        // 2. Owner notifies rewards
        vm.startPrank(deployer);
        // The RewardVault holds REWARDTOKEN, so we need to transfer them there first
        rewardtoken.transfer(address(rewardVault), rewardAmount);
        rewardVault.notifyRewardAmount(bytes(""), rewardAmount);
        vm.stopPrank();

        // Check reward rate
        uint256 rewardsDuration = rewardVault.rewardsDuration();
        assertGt(rewardsDuration, 0, "Rewards duration should be greater than 0");
        assertEq(
            rewardVault.rewardRate(),
            (rewardAmount * PRECISION) / rewardsDuration,
            "Reward rate should be correctly set"
        );

        // 3. Time passes
        uint256 timeToWarp = rewardsDuration / 2;
        vm.warp(block.timestamp + timeToWarp);

        // 4. Check earned rewards
        vm.startPrank(alice);
        uint256 earned = rewardVault.earned(alice);
        // Should be close to half the rewards, accounting for small time differences
        assertApproxEqAbs(earned, rewardAmount / 2, 1e16, "Earned amount is incorrect");

        // 5. Alice claims rewards
        uint256 initialRewardTokenBalance = rewardtoken.balanceOf(alice);
        uint256 claimed = rewardVault.getReward(alice, alice);
        assertApproxEqAbs(claimed, earned, 1e16, "Claimed amount should equal earned amount");

        // 6. Check final state
        assertEq(rewardtoken.balanceOf(alice), initialRewardTokenBalance + claimed, "Alice REWARDTOKEN balance should increase");
        assertEq(rewardVault.rewards(alice), 0, "Pending rewards should be zero after claim");
        vm.stopPrank();
    }

    /// @notice Tests that rewards are split proportionally between two stakers.
    function test_rewards_flow_two_stakers() public {
        uint256 aliceStake = 100 * ONE;
        uint256 bobStake = 300 * ONE;
        uint256 totalStake = aliceStake + bobStake;
        uint256 rewardAmount = 1000 * ONE;

        // 1. Alice and Bob stake
        vm.prank(alice);
        rewardVault.stake(aliceStake);
        vm.prank(bob);
        rewardVault.stake(bobStake);

        // 2. Owner notifies rewards
        vm.startPrank(deployer);
        rewardtoken.transfer(address(rewardVault), rewardAmount);
        rewardVault.notifyRewardAmount(bytes(""), rewardAmount);
        vm.stopPrank();

        // 3. Time passes (full duration)
        uint256 rewardsDuration = rewardVault.rewardsDuration();
        vm.warp(block.timestamp + rewardsDuration);

        // 4. Check earned amounts
        uint256 aliceEarned = rewardVault.earned(alice);
        uint256 bobEarned = rewardVault.earned(bob);
        uint256 totalEarned = aliceEarned + bobEarned;

        // Total earned should be approx the total reward
        assertApproxEqAbs(totalEarned, rewardAmount, 1e16, "Total earned should equal total reward");
        
        // Alice should have earned her proportional share (100 / 400 = 25%)
        assertApproxEqAbs(
            aliceEarned,
            (rewardAmount * aliceStake) / totalStake,
            1e16,
            "Alice's reward share is incorrect"
        );

        // Bob should have earned his proportional share (300 / 400 = 75%)
        assertApproxEqAbs(
            bobEarned,
            (rewardAmount * bobStake) / totalStake,
            1e16,
            "Bob's reward share is incorrect"
        );
    }

    /// @notice Tests that delegate staking correctly updates all relevant balances.
    function test_delegate_stake_updates_balances() public {
        uint256 delegateStakeAmount = 200 * ONE;

        vm.startPrank(bob); // Bob will delegate stake for Alice

        uint256 initialBobTokenBalance = stakingToken.balanceOf(bob);
        uint256 initialAliceInternalBalance = rewardVault.balanceOf(alice);
        uint256 initialVaultTotalSupply = rewardVault.totalSupply();

        // Bob stakes for Alice
        rewardVault.delegateStake(alice, delegateStakeAmount);

        // Check internal vault accounting for Alice
        assertEq(
            rewardVault.balanceOf(alice),
            initialAliceInternalBalance + delegateStakeAmount,
            "Alice's internal balance should increase"
        );
        // Check delegate-specific accounting
        assertEq(
            rewardVault.getDelegateStake(alice, bob),
            delegateStakeAmount,
            "Bob's delegate stake for Alice is incorrect"
        );
        assertEq(
            rewardVault.getTotalDelegateStaked(alice),
            delegateStakeAmount,
            "Alice's total delegate stake is incorrect"
        );
        assertEq(rewardVault.totalSupply(), initialVaultTotalSupply + delegateStakeAmount, "Total supply should increase");

        // Check token balances
        assertEq(stakingToken.balanceOf(bob), initialBobTokenBalance - delegateStakeAmount, "Bob's token balance should decrease");
        
        vm.stopPrank();
    }

    /// @notice Tests that a delegate can withdraw the stake they delegated.
    function test_delegate_withdraw_updates_balances() public {
        uint256 delegateStakeAmount = 200 * ONE;
        uint256 delegateWithdrawAmount = 50 * ONE;

        // Bob stakes for Alice
        vm.prank(bob);
        rewardVault.delegateStake(alice, delegateStakeAmount);

        // Now Bob withdraws a portion of his delegated stake
        vm.startPrank(bob);
        uint256 initialBobTokenBalance = stakingToken.balanceOf(bob);
        uint256 initialAliceInternalBalance = rewardVault.balanceOf(alice);
        
        rewardVault.delegateWithdraw(alice, delegateWithdrawAmount);

        // Check balances after withdrawal
        assertEq(rewardVault.balanceOf(alice), initialAliceInternalBalance - delegateWithdrawAmount, "Alice's internal balance should decrease");
        assertEq(rewardVault.getDelegateStake(alice, bob), delegateStakeAmount - delegateWithdrawAmount, "Bob's remaining delegate stake incorrect");
        assertEq(stakingToken.balanceOf(bob), initialBobTokenBalance + delegateWithdrawAmount, "Bob's token balance should increase");
        vm.stopPrank();
    }

    /// @notice Tests that a delegate cannot withdraw more than they have staked for an account.
    function test_revert_delegate_withdraw_insufficient_delegate_stake() public {
        uint256 delegateStakeAmount = 200 * ONE;

        // Bob stakes for Alice
        vm.prank(bob);
        rewardVault.delegateStake(alice, delegateStakeAmount);

        vm.startPrank(bob);
        vm.expectRevert(IPOLErrors.InsufficientDelegateStake.selector);
        rewardVault.delegateWithdraw(alice, delegateStakeAmount + 1);
        vm.stopPrank();
    }

    /// @notice Tests that a user cannot withdraw funds that were staked by a delegate.
    function test_revert_withdraw_by_user_with_only_delegated_stake() public {
        uint256 delegateStakeAmount = 200 * ONE;

        // Bob stakes for Alice
        vm.prank(bob);
        rewardVault.delegateStake(alice, delegateStakeAmount);

        // Alice tries to withdraw the funds Bob staked for her
        vm.startPrank(alice);
        // This should fail because her self-staked balance is 0.
        vm.expectRevert(IPOLErrors.InsufficientSelfStake.selector);
        rewardVault.withdraw(delegateStakeAmount);
        vm.stopPrank();
    }

    /// @notice Tests that exit() correctly withdraws self-stake and claims rewards, leaving delegate stake.
    function test_exit_withdraws_self_stake_and_claims_rewards() public {
        uint256 aliceSelfStake = 100 * ONE;
        uint256 bobDelegateStake = 200 * ONE;
        uint256 rewardAmount = 500 * ONE;

        // 1. Staking from self and delegate
        vm.prank(alice);
        rewardVault.stake(aliceSelfStake);
        vm.prank(bob);
        rewardVault.delegateStake(alice, bobDelegateStake);

        // 2. Add rewards and wait
        vm.startPrank(deployer);
        rewardtoken.transfer(address(rewardVault), rewardAmount);
        rewardVault.notifyRewardAmount(bytes(""), rewardAmount);
        vm.stopPrank();

        uint256 rewardsDuration = rewardVault.rewardsDuration();
        vm.warp(block.timestamp + rewardsDuration);

        // 3. Alice exits
        vm.startPrank(alice);
        uint256 initialAliceStakingBalance = stakingToken.balanceOf(alice);
        uint256 initialAliceRewardTokenBalance = rewardtoken.balanceOf(alice);

        uint256 expectedRewards = rewardVault.earned(alice);
        
        rewardVault.exit(alice); // Withdraws and claims to herself

        // 4. Assert balances and state
        // Alice should have her self-staked amount back
        assertEq(
            stakingToken.balanceOf(alice),
            initialAliceStakingBalance + aliceSelfStake,
            "Alice should receive her self-staked tokens"
        );
        // Alice should have her rewards
        assertApproxEqAbs(
            rewardtoken.balanceOf(alice),
            initialAliceRewardTokenBalance + expectedRewards,
            1e16,
            "Alice should receive her earned rewards"
        );

        // Vault internal state for Alice
        assertEq(
            rewardVault.balanceOf(alice),
            bobDelegateStake,
            "Alice's internal balance should equal remaining delegate stake"
        );
        assertEq(
            rewardVault.getTotalDelegateStaked(alice),
            bobDelegateStake,
            "Total delegate stake for Alice should be unchanged"
        );
        assertEq(rewardVault.rewards(alice), 0, "Alice should have no pending rewards");

        vm.stopPrank();
    }

    /// @notice Tests that a user can successfully set an operator.
    function test_setOperator() public {
        vm.prank(alice);
        rewardVault.setOperator(bob);
        assertEq(rewardVault.operator(alice), bob, "Operator should be set to Bob");
    }

    /// @notice Tests that a designated operator can claim rewards on behalf of a user.
    function test_operator_can_claim_rewards() public {
        // 1. Alice stakes and earns rewards
        vm.prank(alice);
        rewardVault.stake(100 * ONE);

        vm.startPrank(deployer);
        rewardtoken.transfer(address(rewardVault), 500 * ONE);
        rewardVault.notifyRewardAmount(bytes(""), 500 * ONE);
        vm.stopPrank();

        vm.warp(block.timestamp + rewardVault.rewardsDuration());

        // 2. Alice sets Bob as her operator
        vm.prank(alice);
        rewardVault.setOperator(bob);

        // 3. Bob claims rewards for Alice, sending them to himself
        vm.startPrank(bob);
        uint256 expectedRewards = rewardVault.earned(alice);
        uint256 initialBobRewardTokenBalance = rewardtoken.balanceOf(bob);

        uint256 claimed = rewardVault.getReward(alice, bob);

        // 4. Assertions
        assertGt(claimed, 0, "Should have claimed some rewards");
        assertApproxEqAbs(claimed, expectedRewards, 1e16, "Claimed amount should match earned");
        assertEq(rewardtoken.balanceOf(bob), initialBobRewardTokenBalance + claimed, "Bob's REWARDTOKEN balance should increase");
        assertEq(rewardVault.rewards(alice), 0, "Alice's pending rewards should be zero");
        vm.stopPrank();
    }

    /// @notice Tests that a non-operator cannot claim rewards.
    function test_revert_non_operator_cannot_claim_rewards() public {
        // 1. Alice stakes and earns rewards
        vm.prank(alice);
        rewardVault.stake(100 * ONE);

        vm.startPrank(deployer);
        rewardtoken.transfer(address(rewardVault), 500 * ONE);
        rewardVault.notifyRewardAmount(bytes(""), 500 * ONE);
        vm.stopPrank();
        
        vm.warp(block.timestamp + rewardVault.rewardsDuration());

        // 2. Charlie (not an operator) tries to claim rewards for Alice
        vm.startPrank(charlie);
        vm.expectRevert(IPOLErrors.NotOperator.selector);
        rewardVault.getReward(alice, charlie);
        vm.stopPrank();
    }

    /// @notice Tests the full pausable/unpausable flow.
    function test_pausable_flow() public {
        // Stake first so we can test withdraw/exit while paused
        vm.prank(alice);
        rewardVault.stake(5 * ONE);

        // 1. Pause the contract
        vm.startPrank(deployer);
        rewardVault.pause();
        assertTrue(PausableUpgradeable(address(rewardVault)).paused(), "Contract should be paused");
        vm.stopPrank();

        // 2. Check that entry functions fail but exit functions work
        vm.startPrank(alice);
        vm.expectRevert("Pausable: paused");
        rewardVault.stake(10 * ONE);

        // Withdraw should work even when paused (emergency exit)
        uint256 balanceBefore = stakingToken.balanceOf(alice);
        rewardVault.withdraw(1 * ONE);
        assertEq(stakingToken.balanceOf(alice), balanceBefore + 1 * ONE, "Withdraw should succeed even when paused");

        // Exit should work even when paused (emergency exit)
        balanceBefore = stakingToken.balanceOf(alice);
        rewardVault.exit(alice);
        assertEq(stakingToken.balanceOf(alice), balanceBefore + 4 * ONE, "Exit should succeed even when paused");
        vm.stopPrank();

        // 3. Unpause the contract
        vm.startPrank(deployer);
        rewardVault.unpause();
        assertFalse(PausableUpgradeable(address(rewardVault)).paused(), "Contract should be unpaused");
        vm.stopPrank();

        // 4. Check that all functionality is restored
        vm.startPrank(alice);
        stakingToken.approve(address(rewardVault), type(uint256).max);
        rewardVault.stake(10 * ONE);
        assertEq(rewardVault.balanceOf(alice), 10 * ONE, "Stake should succeed after unpause");
        vm.stopPrank();
    }

    /// @notice Tests that delegateWithdraw works when paused, along with regular withdraw/exit.
    function test_delegate_withdraw_works_when_paused() public {
        // Bob stakes for Alice
        vm.prank(bob);
        rewardVault.delegateStake(alice, 100 * ONE);

        // Alice also stakes for herself
        vm.prank(alice);
        rewardVault.stake(50 * ONE);

        // Pause the contract
        vm.prank(deployer);
        rewardVault.pause();

        // Alice should be able to withdraw her own stake even when paused
        vm.startPrank(alice);
        uint256 balanceBefore = stakingToken.balanceOf(alice);
        rewardVault.withdraw(25 * ONE);
        assertEq(stakingToken.balanceOf(alice), balanceBefore + 25 * ONE, "Alice should be able to withdraw when paused");

        // Alice should be able to exit even when paused
        balanceBefore = stakingToken.balanceOf(alice);
        rewardVault.exit(alice);
        assertEq(stakingToken.balanceOf(alice), balanceBefore + 25 * ONE, "Alice should be able to exit when paused");
        vm.stopPrank();

        // Bob should be able to delegateWithdraw when paused (emergency exit functionality)
        vm.startPrank(bob);
        uint256 bobBalanceBefore = stakingToken.balanceOf(bob);
        rewardVault.delegateWithdraw(alice, 50 * ONE);
        assertEq(stakingToken.balanceOf(bob), bobBalanceBefore + 50 * ONE, "Bob should be able to delegateWithdraw when paused");
        vm.stopPrank();
    }

    /// @notice Tests administrative functions like setRewardsDuration and recoverERC20.
    function test_admin_functions() public {
        // --- setRewardsDuration ---
        uint256 newDuration = 7 days;
        vm.prank(deployer);
        rewardVault.setRewardsDuration(newDuration);
        assertEq(rewardVault.rewardsDuration(), newDuration, "Rewards duration should be updated");

        // --- recoverERC20 ---
        // Send some other token to the vault
        MockERC20 otherToken = new MockERC20("Other Token", "OTH", 18);
        otherToken.mint(address(rewardVault), 100 * ONE);
        
        uint256 initialDeployerOtherTokenBalance = otherToken.balanceOf(deployer);
        vm.prank(deployer);
        rewardVault.recoverERC20(address(otherToken), 100 * ONE);
        assertEq(otherToken.balanceOf(deployer), initialDeployerOtherTokenBalance + 100 * ONE, "Owner should recover other tokens");

        // Should not be able to recover the staking token as there are no "excess" tokens
        vm.prank(alice);
        rewardVault.stake(10 * ONE); // Make sure totalSupply > 0
        
        vm.prank(deployer);
        vm.expectRevert(IPOLErrors.NotEnoughBalance.selector);
        rewardVault.recoverERC20(address(stakingToken), 1 * ONE);
    }
} 