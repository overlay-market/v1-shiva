// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Shiva} from "src/Shiva.sol";
import {RewardsVaultFactoryMock} from "src/mocks/RewardsVaultFactoryMock.sol";
import {Constants} from "./utils/Constants.sol";
import {OverlayV1Token} from "v1-core/contracts/OverlayV1Token.sol";
import {IOverlayV1Feed} from "v1-core/contracts/interfaces/feeds/IOverlayV1Feed.sol";
import {GOVERNOR_ROLE} from "v1-core/contracts/interfaces/IOverlayV1Token.sol";

/// @dev inherit from previous implementation contract to prevent storage collisions
contract ShivaV1 is Shiva {
    uint256 public magicNumber;

    function version() external pure virtual returns (string memory) {
        return "V1";
    }

    function setMagicNumber(
        uint256 newMagicNumber
    ) public {
        magicNumber = newMagicNumber;
    }
}

/// @dev inherit from previous implementation contract to prevent storage collisions
contract ShivaV2 is ShivaV1 {
    string public magicString;

    function version() external pure override returns (string memory) {
        return "V2";
    }

    function setMagicString(
        string memory newMagicString
    ) public {
        magicString = newMagicString;
    }
}

contract ImplementationV1Test is Test {
    ShivaV1 shivaV1;
    ERC1967Proxy proxy;
    RewardsVaultFactoryMock vaultFactory;

    function setUp() public {
        vm.createSelectFork(
            vm.envString(Constants.getForkedMainnetNetworkRPC()),
            Constants.getForkMainnetBlock()
        );

        OverlayV1Token ovlToken = new OverlayV1Token();

        // Use RewardsVaultFactoryMock instead of real implementation
        vaultFactory = new RewardsVaultFactoryMock();

        // deploy logic contract
        shivaV1 = new ShivaV1();

        /*Proxy initialize data*/
        string memory functionName = "initialize(address,address,address)";
        bytes memory data = abi.encodeWithSignature(functionName, address(ovlToken), vaultFactory, address(0));

        proxy = new ERC1967Proxy(address(shivaV1), data);

        vm.expectRevert(); // logic contract shouldn't be initialized directly
        shivaV1.initialize(address(ovlToken), vaultFactory, IOverlayV1Feed(address(0)));
    }

    function testInitialized() public {
        (, bytes memory returnedData) = address(proxy).call(abi.encodeWithSignature("ovlToken()"));
        address ovlToken = abi.decode(returnedData, (address));

        // ovlToken should be this contract
        assertEq(ovlToken, address(ovlToken));
    }
}

contract ImplementationV2Test is Test {
    ShivaV1 shivaV1;
    ShivaV2 shivaV2;
    ERC1967Proxy proxy;

    RewardsVaultFactoryMock vaultFactory;
    address rewardVault;

    function setUp() public {
        vm.createSelectFork(
            vm.envString(Constants.getForkedMainnetNetworkRPC()),
            Constants.getForkMainnetBlock()
        );

        OverlayV1Token ovlToken = new OverlayV1Token();
        ovlToken.grantRole(GOVERNOR_ROLE, Constants.getDeployerAddress());

        // Use RewardsVaultFactoryMock instead of real implementation
        vaultFactory = new RewardsVaultFactoryMock();

        // deploy logic contract
        shivaV1 = new ShivaV1();

        /*Proxy initialize data*/
        string memory functionName = "initialize(address,address,address)";
        bytes memory data = abi.encodeWithSignature(functionName, address(ovlToken), vaultFactory, address(0));

        proxy = new ERC1967Proxy(address(shivaV1), data);

        (, bytes memory returnedRewardVault) =
            address(proxy).call(abi.encodeWithSignature("rewardVault()"));
        rewardVault = abi.decode(returnedRewardVault, (address));

        // set magic number via old impl contract for testing purposes
        address(proxy).call(abi.encodeWithSignature("setMagicNumber(uint256)", 42));

        vm.expectRevert(); // logic contract shouldn't be initialized directly
        shivaV1.initialize(address(ovlToken), vaultFactory, IOverlayV1Feed(address(0)));

        // deploy new logic contract
        shivaV2 = new ShivaV2();

        vm.expectRevert(); // logic contract shouldn't be initialized directly
        shivaV2.initialize(address(ovlToken), vaultFactory, IOverlayV1Feed(address(0)));

        vm.startPrank(address(0x123));

        vm.expectRevert(); // caller is not the owner
        address(proxy).call(abi.encodeWithSignature("upgradeTo(address)", address(shivaV2)));

        vm.stopPrank();
        vm.startPrank(Constants.getDeployerAddress());

        // update proxy to new implementation contract
        address(proxy).call(abi.encodeWithSignature("upgradeTo(address)", address(shivaV2)));
        vm.stopPrank();

        (, bytes memory returnedNewRewardVault) =
            address(proxy).call(abi.encodeWithSignature("rewardVault()"));
        address newRewardVault = abi.decode(returnedNewRewardVault, (address));
        assertEq(rewardVault, newRewardVault);
    }

    function testMagicNumber() public {
        // proxy points to implV2, but magic value set via impl should still be valid, since storage from proxy contract is read
        (, bytes memory data) = address(proxy).call(abi.encodeWithSignature("magicNumber()"));
        uint256 magicNumber = abi.decode(data, (uint256));
        assertEq(magicNumber, 42);
    }

    function testMagicString() public {
        // proxy points to implV2, so we should be able to call new functions
        address(proxy).call(abi.encodeWithSignature("setMagicString(string)", "Hello World"));
        (, bytes memory data) = address(proxy).call(abi.encodeWithSignature("magicString()"));
        string memory magicString = abi.decode(data, (string));
        assertEq(magicString, "Hello World");
    }

    function testVersion() public {
        // proxy points to implV2, so version should be V2
        (, bytes memory data) = address(proxy).call(abi.encodeWithSignature("version()"));
        string memory version = abi.decode(data, (string));
        assertEq(version, "V2");
    }
}
