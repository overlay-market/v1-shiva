// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Script} from "forge-std/Script.sol";
import {Shiva} from "../src/Shiva.sol";
import {Constants} from "./Constants.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RewardsVaultFactoryMock} from "src/mocks/RewardsVaultFactoryMock.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";


// $ source .env && forge script scripts/Deploy.s.sol:Deploy --rpc-url $RPC --verify -vvvv
abstract contract DeployScript is Script {
    function setUp() public {}

    function _deploy() internal {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PK");
        vm.startBroadcast(deployerPrivateKey);

        /* deploy mock vault factory */
        RewardsVaultFactoryMock rewardVaultFactory = new RewardsVaultFactoryMock();

        ERC20 ovl = ERC20(Constants.getOVLTokenAddress());

        require(ovl.decimals() == 18);

        /*Proxy initialize data*/
        string memory functionName = "initialize(address,address)";
        bytes memory data = abi.encodeWithSignature(
            functionName,
            address(ovl),
            address(rewardVaultFactory)
        );

        Shiva impl = new Shiva();
        new ERC1967Proxy(address(impl), data);

        vm.stopBroadcast();
    }
}

contract Deploy is DeployScript {
    function run() external {
        _deploy();
    }
}
