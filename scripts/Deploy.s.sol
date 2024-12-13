// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Script} from "forge-std/Script.sol";
import {Shiva} from "../src/Shiva.sol";
import {Constants} from "./Constants.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

abstract contract DeployScript is Script {
    function setUp() public {}

    // function run() public {
    //     uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    //     vm.startBroadcast(deployerPrivateKey);

    //     // Deploy `Shiva` as a transparent proxy using the Upgrades Plugin
    //     address transparentProxy = Upgrades.deployTransparentProxy(
    //         "Shiva.sol",
    //         msg.sender,
    //         abi.encodeCall(Shiva.initialize, Constants.getOVTokenAddress(), Constants.getOVStateAddress(), Constants.getVaultFactoryAddress())
    //     );
    // }

    function _deploy() internal {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        /*Proxy initialize data*/
        string memory functionName = "initialize(address,address,address)";
        bytes memory data = abi.encodeWithSignature(functionName, Constants.getOVTokenAddress(), Constants.getOVStateAddress(), Constants.getVaultFactoryAddress());

        vm.startBroadcast(deployerPrivateKey);
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
