// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Script} from "forge-std/Script.sol";
import {Shiva} from "../src/Shiva.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Constants} from "./Constants.sol";

contract UpgradesScript is Script {
    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Deploy `Shiva` as a transparent proxy using the Upgrades Plugin
        address transparentProxy = Upgrades.deployTransparentProxy(
            "Shiva.sol",
            msg.sender,
            abi.encodeCall(Shiva.initialize, Constants.getOVTokenAddress(), Constants.getOVStateAddress(), Constants.getVaultFactoryAddress())
        );
    }
}
