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

    function _deployFactory(address _ovl, address _sequencerOracle) internal returns (OverlayV1Factory factory) {
        address deployer = vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);
        factory = new OverlayV1Factory(
            _ovl,
            deployer, // fee recipient
            _sequencerOracle,
            1 hours // grace period
        );

        OverlayV1Token ovl = OverlayV1Token(_ovl);
        ovl.grantRole(ADMIN_ROLE, address(factory));
        
        vm.stopBroadcast();
    }

    function _deployState(OverlayV1Factory _factory) internal returns (OverlayV1State state) {
        address deployer = vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);

        state = new OverlayV1State(_factory);

        vm.stopBroadcast();
    }

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

    function _setupShiva(Shiva shiva_, OverlayV1Factory factory_) internal {
        vm.startBroadcast(deployerPrivateKey);
        shiva_.addFactory(IOverlayV1Factory(address(factory_)));
        vm.stopBroadcast();
    }
}


contract DeployProtocol is DeployProtocolScript {
    /* 
        source .env && forge script\
        --rpc-url bartio\
        scripts/DeployProtocol.s.sol:DeployProtocol\
        bartio\
        0x97576e088f0d05EF68cac2EEc63d017FE90952a0\
        0xC35093f76fF3D31Af27A893CDcec585F1899eE54\
        0x2B6e40f65D82A0cB98795bC7587a71bfa49fBB2B\
        --sig 'run(string,address,address,address)'\
        -vvvv
    */
    function run(string calldata _network, address _ovl, address _sequencerOracle, address _vaultFactory) external {
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
        } else {
            revert("Unsupported network");
        }
        deployerPrivateKey = DEPLOYER_PK;

        OverlayV1Factory factory_ = _deployFactory(_ovl, _sequencerOracle);
        OverlayV1State state_ = _deployState(factory_);
        Shiva shiva_ = _deployShiva(_ovl, _vaultFactory);
        _setupShiva(shiva_, factory_);

        console2.log("factory: ", address(factory_));
        console2.log("state: ", address(state_));
        console2.log("shiva: ", address(shiva_));
    }

    function compareStrings(string memory a, string memory b) public pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }
}
