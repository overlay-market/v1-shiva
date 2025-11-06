// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Script} from "forge-std/Script.sol";
import {Shiva} from "../src/Shiva.sol";
import {Constants} from "./Constants.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RewardsVaultFactoryMock} from "src/mocks/RewardsVaultFactoryMock.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IOverlayV1Factory} from "v1-core/contracts/interfaces/IOverlayV1Factory.sol";
import {IOverlayV1Token} from "v1-core/contracts/interfaces/IOverlayV1Token.sol";
import {IOverlayV1Market} from "v1-core/contracts/interfaces/IOverlayV1Market.sol";
import {ShivaStructs} from "src/ShivaStructs.sol";


// $ source .env && forge script scripts/ShivaInteractions.s.sol:Interact --rpc-url $RPC
abstract contract InteractScript is Script {
    function setUp() public {}

    function _interact() internal {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PK");
        vm.startBroadcast(deployerPrivateKey);

        IOverlayV1Token ovl = IOverlayV1Token(0x1A0eF183D548405705bb9B00E8b4ef3524AE090E);

        Shiva shiva = Shiva(0x9fB7D92526Fc13bB3c0603d39E55e5C371c26Ce6);

        // ovl.grantRole(0x1a6838efa4183e08fe3607359d1259272af9d4716f65e1a7b5921f78fd5a3c6a, 0x85f66DBe1ed470A091d338CFC7429AA871720283);

        // shiva.addFactory(IOverlayV1Factory(0xb5F885b61e2cC1515a66A2E6636FCAA43daBf044));

        // ovl.approve(address(shiva), type(uint256).max);

        /**
         * @notice Represents the parameters to build a position through the Shiva contract
         * @param ovlMarket The market interface
         * @param brokerId The ID of the broker; 0 in most cases
         * @param isLong Indicates if the position is long
         * @param collateral The amount of collateral
         * @param leverage The leverage applied
         * @param priceLimit The price limit for the position
         */
        // IOverlayV1Market ovlMarket = IOverlayV1Market(0xBE9070F0AB6d255C1110c1983cF3e18A8C0eD2C0); // MrBeast
        IOverlayV1Market ovlMarket = IOverlayV1Market(0x4290ab292560d27B605da10c24FBCDeda434697c); // Double or Nothing
        bool isLong = false;
        uint256 priceLimit = isLong ? type(uint256).max : 0;

        ShivaStructs.Build memory buildParams = ShivaStructs.Build({
            ovlMarket: ovlMarket,
            brokerId: 0,
            isLong: isLong,
            collateral: 1e18,
            leverage: 1e18,
            priceLimit: priceLimit
        });
        shiva.build(buildParams);

        vm.stopBroadcast();
    }
}

contract Interact is InteractScript {
    function run() external {
        _interact();
    }
}
