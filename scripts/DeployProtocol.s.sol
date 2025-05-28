// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Script, console2} from "forge-std/Script.sol";
import {Shiva} from "../src/Shiva.sol";
import {Constants} from "./Constants.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OverlayV1Factory} from "v1-core/contracts/OverlayV1Factory.sol";
import {IOverlayV1Factory} from "v1-core/contracts/interfaces/IOverlayV1Factory.sol";
import {OverlayV1Token} from "v1-core/contracts/OverlayV1Token.sol";
import {OverlayV1State} from "v1-periphery/contracts/OverlayV1State.sol";
import {MINTER_ROLE, GOVERNOR_ROLE, GUARDIAN_ROLE, PAUSER_ROLE, RISK_MANAGER_ROLE, LIQUIDATE_CALLBACK_ROLE} from "v1-core/contracts/interfaces/IOverlayV1Token.sol";

abstract contract DeployProtocolScript is Script {
    uint256 deployerPrivateKey;
    bytes32 constant ADMIN_ROLE = 0x00;

    function setUp() public {}

    function _deployShiva(address _ovl, address _vaultFactory) internal returns (Shiva shivaProxy) {
        /*Proxy initialize data*/
        string memory functionName = "initialize(address,address)";
        bytes memory data = abi.encodeWithSignature(functionName, _ovl, _vaultFactory);

        vm.startBroadcast(deployerPrivateKey);
        Shiva impl = new Shiva();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        shivaProxy = Shiva(address(proxy));

        OverlayV1Token ovl = OverlayV1Token(_ovl);
        ovl.grantRole(LIQUIDATE_CALLBACK_ROLE, address(shivaProxy));

        vm.stopBroadcast();
    }

    function _setupShiva(Shiva shiva_, address factory_) internal {
        vm.startBroadcast(deployerPrivateKey);
        shiva_.addFactory(IOverlayV1Factory(address(factory_)));
        vm.stopBroadcast();
    }
}


contract DeployProtocol is DeployProtocolScript {
    /* 
        source .env && forge script\
        --rpc-url bsc-testnet\
        scripts/DeployProtocol.s.sol:DeployProtocol\
        bsc-testnet\
        0xb880E767739A82Eb716780BDfdbC1eD7b23BDB38\
        0xB49a63B267515FC1D8232604d05Db4D8Daf00648\
        0xF1e276bf93C2e743E74b58B3347344D9B2f0fdB6\
        --sig 'run(string,address,address,address)'\
        --broadcast\
        -vvvv
    */
    function run(string calldata _network, address _ovl, address _factory, address _vaultFactory) external {
        // NOTE: this should be the private key of the GOVERNOR
        uint256 DEPLOYER_PK;
        // Select the correct DEPLOYER_PK based on the network
        if (compareStrings(_network, "local")) {
            DEPLOYER_PK = vm.envUint("DEPLOYER_PK");
        } else if (compareStrings(_network, "bartio")) {
            DEPLOYER_PK = vm.envUint("DEPLOYER_PK_BARTIO");
        } else if (compareStrings(_network, "imola")) {
            DEPLOYER_PK = vm.envUint("DEPLOYER_PK_IMOLA");
        } else if (compareStrings(_network, "arbitrum-sepolia")) {
            DEPLOYER_PK = vm.envUint("DEPLOYER_PK_ARB_SEPOLIA");
        } else if (compareStrings(_network, "bsc-testnet")) {
            DEPLOYER_PK = vm.envUint("DEPLOYER_PK_BSC_TESTNET");
        } else {
            revert("Unsupported network");
        }
        deployerPrivateKey = DEPLOYER_PK;

        Shiva shiva_ = _deployShiva(_ovl, _vaultFactory);
        _setupShiva(shiva_, _factory);

        console2.log("shiva: ", address(shiva_));
    }

    function compareStrings(string memory a, string memory b) public pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }
}
