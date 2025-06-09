// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RewardVault} from "src/rewardVault/RewardVault.sol";
import {RewardVaultFactory} from "src/rewardVault/RewardVaultFactory.sol";
import {IStakingRewardsErrors} from "src/rewardVault/berachain/IStakingRewardsErrors.sol";
import {IPOLErrors} from "src/rewardVault/berachain/IPOLErrors.sol";
import {IRewardVault} from "src/rewardVault/IRewardVault.sol";
import {IRewardVaultFactory} from "src/rewardVault/berachain/IRewardVaultFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract RewardVaultTest is Test {
    // Tokens
    MockERC20 stakingToken;
    MockERC20 bgt;

    // Contracts
    RewardVaultFactory factory;
    RewardVault rewardVault;

    // Users
    address deployer;
    address alice;
    address bob;
    address charlie;

    uint256 constant ONE = 1e18;
    uint256 constant PRECISION = 1e18;

    function setUp() public {
        deployer = makeAddr("deployer");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        vm.label(deployer, "Deployer");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(charlie, "Charlie");

        vm.startPrank(deployer);

        // Deploy tokens
        stakingToken = new MockERC20("Staking Token", "STK", 18);
        bgt = new MockERC20("Berachain Governance Token", "BGT", 18);

        // Deploy implementations
        RewardVault rewardVaultImplementation = new RewardVault();
        RewardVaultFactory rewardVaultFactoryImplementation = new RewardVaultFactory();

        // Deploy factory proxy
        bytes memory rewardVaultFactoryData = abi.encodeWithSignature(
            "initialize(address,address,address)",
            address(bgt),
            deployer,
            address(rewardVaultImplementation)
        );
        factory = RewardVaultFactory(
            address(new ERC1967Proxy(address(rewardVaultFactoryImplementation), rewardVaultFactoryData))
        );

        // Grant pauser/manager roles to deployer for testing
        // Manager role must be granted first as it's the admin for the pauser role.
        factory.grantRole(factory.VAULT_MANAGER_ROLE(), deployer);
        factory.grantRole(factory.VAULT_PAUSER_ROLE(), deployer);

        // Create a vault
        address vaultAddress = factory.createRewardVault(address(stakingToken));
        rewardVault = RewardVault(vaultAddress);

        vm.stopPrank();

        // Distribute tokens and set approvals
        stakingToken.mint(alice, 1000 * ONE);
        stakingToken.mint(bob, 1000 * ONE);
        bgt.mint(deployer, 10000 * ONE); // Mint BGT for the deployer to use as rewards

        vm.startPrank(alice);
        stakingToken.approve(address(rewardVault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
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
        // The RewardVault holds BGT, so we need to transfer them there first
        bgt.transfer(address(rewardVault), rewardAmount);
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
        uint256 initialBgtBalance = bgt.balanceOf(alice);
        uint256 claimed = rewardVault.getReward(alice, alice);
        assertApproxEqAbs(claimed, earned, 1e16, "Claimed amount should equal earned amount");

        // 6. Check final state
        assertEq(bgt.balanceOf(alice), initialBgtBalance + claimed, "Alice BGT balance should increase");
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
        bgt.transfer(address(rewardVault), rewardAmount);
        rewardVault.notifyRewardAmount(bytes(""), rewardAmount);
        vm.stopPrank();

        // 3. Time passes (full duration)
        uint256 rewardsDuration = rewardVault.rewardsDuration();
        vm.warp(block.timestamp + rewardsDuration);

        // 4. Check earned amounts
        uint256 aliceEarned = rewardVault.earned(alice);
        uint256 bobEarned = rewardVault.earned(bob);
        uint256 totalEarned = aliceEarned + bobEarned;

        uint256 totalRewardWithPrecision = rewardAmount * PRECISION;

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
        bgt.transfer(address(rewardVault), rewardAmount);
        rewardVault.notifyRewardAmount(bytes(""), rewardAmount);
        vm.stopPrank();

        uint256 rewardsDuration = rewardVault.rewardsDuration();
        vm.warp(block.timestamp + rewardsDuration);

        // 3. Alice exits
        vm.startPrank(alice);
        uint256 initialAliceStakingBalance = stakingToken.balanceOf(alice);
        uint256 initialAliceBgtBalance = bgt.balanceOf(alice);
        uint256 totalAliceStakeBefore = rewardVault.balanceOf(alice);

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
            bgt.balanceOf(alice),
            initialAliceBgtBalance + expectedRewards,
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
        bgt.transfer(address(rewardVault), 500 * ONE);
        rewardVault.notifyRewardAmount(bytes(""), 500 * ONE);
        vm.stopPrank();

        vm.warp(block.timestamp + rewardVault.rewardsDuration());

        // 2. Alice sets Bob as her operator
        vm.prank(alice);
        rewardVault.setOperator(bob);

        // 3. Bob claims rewards for Alice, sending them to himself
        vm.startPrank(bob);
        uint256 expectedRewards = rewardVault.earned(alice);
        uint256 initialBobBgtBalance = bgt.balanceOf(bob);

        uint256 claimed = rewardVault.getReward(alice, bob);

        // 4. Assertions
        assertGt(claimed, 0, "Should have claimed some rewards");
        assertApproxEqAbs(claimed, expectedRewards, 1e16, "Claimed amount should match earned");
        assertEq(bgt.balanceOf(bob), initialBobBgtBalance + claimed, "Bob's BGT balance should increase");
        assertEq(rewardVault.rewards(alice), 0, "Alice's pending rewards should be zero");
        vm.stopPrank();
    }

    /// @notice Tests that a non-operator cannot claim rewards.
    function test_revert_non_operator_cannot_claim_rewards() public {
        // 1. Alice stakes and earns rewards
        vm.prank(alice);
        rewardVault.stake(100 * ONE);

        vm.startPrank(deployer);
        bgt.transfer(address(rewardVault), 500 * ONE);
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
        assertTrue(rewardVault.paused(), "Contract should be paused");
        vm.stopPrank();

        // 2. Check that critical functions fail
        vm.startPrank(alice);
        vm.expectRevert("Pausable: paused");
        rewardVault.stake(10 * ONE);

        vm.expectRevert("Pausable: paused");
        rewardVault.withdraw(1 * ONE);

        vm.expectRevert("Pausable: paused");
        rewardVault.exit(alice);
        vm.stopPrank();

        // 3. Unpause the contract
        vm.startPrank(deployer);
        rewardVault.unpause();
        assertFalse(rewardVault.paused(), "Contract should be unpaused");
        vm.stopPrank();

        // 4. Check that functionality is restored
        vm.startPrank(alice);
        uint256 balanceBefore = stakingToken.balanceOf(alice);
        rewardVault.withdraw(1 * ONE);
        assertEq(stakingToken.balanceOf(alice), balanceBefore + 1 * ONE, "Withdraw should succeed after unpause");
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