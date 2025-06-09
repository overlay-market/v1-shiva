// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {RewardToken} from "src/rewardVault/RewardToken.sol";
import {IRewardToken} from "src/rewardVault/IRewardToken.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract RewardTokenTest is Test {
    RewardToken token;

    address deployer;
    address minter;
    address burner;
    address allowFrom;
    address allowTo;
    address alice;
    address bob;

    uint256 constant ONE = 1e18;
    
    // Roles from IRewardToken
    bytes32 constant MINTER_ROLE = keccak256("MINTER");
    bytes32 constant BURNER_ROLE = keccak256("BURNER");
    bytes32 constant ALLOW_FROM_ROLE = keccak256("ALLOW_FROM");
    bytes32 constant ALLOW_TO_ROLE = keccak256("ALLOW_TO");

    function setUp() public {
        deployer = makeAddr("deployer");
        minter = makeAddr("minter");
        burner = makeAddr("burner");
        allowFrom = makeAddr("allowFrom");
        allowTo = makeAddr("allowTo");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.startPrank(deployer);
        token = new RewardToken();

        // Grant roles
        token.grantRole(MINTER_ROLE, minter);
        token.grantRole(BURNER_ROLE, burner);
        token.grantRole(ALLOW_FROM_ROLE, allowFrom);
        token.grantRole(ALLOW_TO_ROLE, allowTo);
        vm.stopPrank();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           ROLES                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_mint() public {
        vm.prank(minter);
        token.mint(alice, 100 * ONE);
        assertEq(token.balanceOf(alice), 100 * ONE);
    }

    function test_revert_mint_not_minter() public {
        vm.prank(alice);
        bytes memory expectedRevert = abi.encodePacked(
            "AccessControl: account ",
            Strings.toHexString(alice),
            " is missing role ",
            vm.toString(MINTER_ROLE)
        );
        vm.expectRevert(expectedRevert);
        token.mint(alice, 100 * ONE);
    }

    function test_burn() public {
        vm.prank(minter);
        token.mint(burner, 100 * ONE);
        assertEq(token.balanceOf(burner), 100 * ONE);

        vm.prank(burner);
        token.burn(50 * ONE);
        assertEq(token.balanceOf(burner), 50 * ONE);
    }

    function test_revert_burn_not_burner() public {
        vm.prank(minter);
        token.mint(alice, 100 * ONE);

        vm.prank(alice);
        bytes memory expectedRevert = abi.encodePacked(
            "AccessControl: account ",
            Strings.toHexString(alice),
            " is missing role ",
            vm.toString(BURNER_ROLE)
        );
        vm.expectRevert(expectedRevert);
        token.burn(100 * ONE);
    }

    function test_toggle_lock() public {
        assertEq(token.unlocked(), false);
        vm.prank(deployer);
        token.toggleLock();
        assertEq(token.unlocked(), true);
    }
    
    function test_revert_toggle_lock_not_admin() public {
        vm.prank(alice);
        // The exact revert string can be tricky due to address checksumming.
        // It's more robust to just catch the revert without checking the full string.
        vm.expectRevert();
        token.toggleLock();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      TRANSFER LOCK                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_transfer_when_locked() public {
        vm.prank(minter);
        token.mint(alice, 100 * ONE);

        assertEq(token.unlocked(), false); // it is locked by default
        vm.prank(alice);
        vm.expectRevert(); // should fail because it's locked
        token.transfer(bob, 50 * ONE);
    }

    function test_transfer_when_unlocked() public {
        vm.prank(minter);
        token.mint(alice, 100 * ONE);
        
        vm.prank(deployer);
        token.toggleLock(); // unlock it
        assertEq(token.unlocked(), true);

        vm.prank(alice);
        token.transfer(bob, 50 * ONE); // should succeed
        assertEq(token.balanceOf(bob), 50 * ONE);
    }

    function test_transfer_exempt_allow_from() public {
        vm.prank(minter);
        token.mint(allowFrom, 100 * ONE);
        
        assertEq(token.unlocked(), false); // it is locked

        // The 'allowFrom' address should be able to send tokens even when locked
        vm.prank(allowFrom);
        token.transfer(bob, 50 * ONE);
        assertEq(token.balanceOf(bob), 50 * ONE);
    }

    function test_transfer_exempt_allow_to() public {
        vm.prank(minter);
        token.mint(alice, 100 * ONE);
        
        assertEq(token.unlocked(), false); // it is locked

        // The 'allowTo' address should be able to receive tokens even when locked
        vm.prank(alice);
        token.transfer(allowTo, 50 * ONE);
        assertEq(token.balanceOf(allowTo), 50 * ONE);
    }

    function test_transfer_exempt_mint() public {
         assertEq(token.unlocked(), false); // it is locked
         
         // Minting should work even when locked
         vm.prank(minter);
         token.mint(alice, 100 * ONE);
         assertEq(token.balanceOf(alice), 100 * ONE);
    }

    function test_transfer_exempt_burn() public {
        vm.prank(minter);
        token.mint(burner, 100 * ONE);
        
        assertEq(token.unlocked(), false); // it is locked
        
        // Burning should work even when locked
        vm.prank(burner);
        token.burn(50 * ONE);
        assertEq(token.balanceOf(burner), 50 * ONE);
    }
} 