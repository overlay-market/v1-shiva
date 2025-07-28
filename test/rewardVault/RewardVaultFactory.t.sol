// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RewardVault} from "src/rewardVault/RewardVault.sol";
import {RewardVaultFactory} from "src/rewardVault/RewardVaultFactory.sol";
import {IRewardVaultFactory} from "src/rewardVault/berachain/IRewardVaultFactory.sol";
import {IPOLErrors} from "src/rewardVault/berachain/IPOLErrors.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract RewardVaultFactoryTest is Test {
    // Contracts
    RewardVaultFactory factory;
    RewardVault rewardVaultImplementation;
    MockERC20 bgt;
    MockERC20 stakingToken;

    // Users
    address deployer;
    address admin;
    address alice;

    function setUp() public {
        deployer = makeAddr("deployer");
        admin = makeAddr("admin");
        alice = makeAddr("alice");

        vm.startPrank(deployer);
        
        bgt = new MockERC20("BGT", "BGT", 18);
        stakingToken = new MockERC20("Staking Token", "STK", 18);
        rewardVaultImplementation = new RewardVault();
        
        RewardVaultFactory factoryImplementation = new RewardVaultFactory();
        
        bytes memory factoryData = abi.encodeWithSignature(
            "initialize(address,address,address)",
            address(bgt),
            admin,
            address(rewardVaultImplementation)
        );

        factory = RewardVaultFactory(address(new ERC1967Proxy(address(factoryImplementation), factoryData)));
        vm.stopPrank();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     VAULT CREATION                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_create_vault() public {
        assertEq(factory.allVaultsLength(), 0, "Initial vault count should be 0");

        vm.prank(deployer); // anyone can create a vault
        address vaultAddress = factory.createRewardVault(address(stakingToken));
        
        assertEq(factory.allVaultsLength(), 1, "Vault count should be 1");
        assertEq(factory.getVault(address(stakingToken)), vaultAddress, "Vault address mismatch in mapping");
        assertEq(factory.allVaults(0), vaultAddress, "Vault address mismatch in array");

        // Check if vault is initialized correctly
        RewardVault vault = RewardVault(vaultAddress);
        assertEq(address(vault.stakeToken()), address(stakingToken));
        assertEq(address(vault.rewardToken()), address(bgt));
        assertEq(vault.factory(), address(factory));
    }

    function test_create_vault_twice_returns_cached() public {
        vm.prank(deployer);
        address vaultAddress1 = factory.createRewardVault(address(stakingToken));
        assertEq(factory.allVaultsLength(), 1);

        // Calling again should return the same address and not create a new one
        address vaultAddress2 = factory.createRewardVault(address(stakingToken));
        assertEq(vaultAddress1, vaultAddress2, "Should return cached vault address");
        assertEq(factory.allVaultsLength(), 1, "Vault count should not increase");
    }

    function test_revert_create_vault_for_non_contract() public {
        vm.prank(deployer);
        vm.expectRevert(IPOLErrors.NotAContract.selector);
        factory.createRewardVault(alice);
    }

    function test_predict_and_create() public {
        address predictedAddress = factory.predictRewardVaultAddress(address(stakingToken));

        vm.prank(deployer);
        address createdAddress = factory.createRewardVault(address(stakingToken));

        assertEq(predictedAddress, createdAddress, "Predicted address does not match created address");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       ADMIN / ROLES                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_setBGTIncentiveDistributor() public {
        address newDistributor = makeAddr("distributor");
        vm.prank(admin);
        factory.setBGTIncentiveDistributor(newDistributor);
        assertEq(factory.bgtIncentiveDistributor(), newDistributor);
    }

    function test_revert_setBGTIncentiveDistributor_not_admin() public {
        address newDistributor = makeAddr("distributor");
        vm.prank(alice);
        vm.expectRevert();
        factory.setBGTIncentiveDistributor(newDistributor);
    }

    function test_revert_setBGTIncentiveDistributor_zero_address() public {
        vm.prank(admin);
        vm.expectRevert(IPOLErrors.ZeroAddress.selector);
        factory.setBGTIncentiveDistributor(address(0));
    }

    function test_upgrade_implementation() public {
        RewardVaultFactory newImplementation = new RewardVaultFactory();
        
        vm.prank(admin);
        factory.upgradeTo(address(newImplementation));
    }

    function test_revert_upgrade_implementation_not_admin() public {
        RewardVaultFactory newImplementation = new RewardVaultFactory();
        
        vm.prank(alice);
        // Expect any revert since only admin can upgrade.
        // This is more robust than checking for a specific string.
        vm.expectRevert();
        factory.upgradeTo(address(newImplementation));
    }
} 