// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {RewardVaultFactory} from "../src/rewardVault/RewardVaultFactory.sol";
import {RewardVault} from "../src/rewardVault/RewardVault.sol";
import {RewardToken} from "../src/rewardVault/RewardToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

abstract contract DeployRewardVaultFactoryAndTokenScript is Script {
    uint256 deployerPrivateKey;

    function setUp() public {}

    function _deployRewardToken() internal returns (address rewardToken_) {
        vm.startBroadcast(deployerPrivateKey);
        rewardToken_ = address(new RewardToken());
        vm.stopBroadcast();
    }

    function _deployVaultImpl() internal returns (address rewardToken_) {
        vm.startBroadcast(deployerPrivateKey);
        rewardToken_ = address(new RewardVault());
        vm.stopBroadcast();
    }

    function _deployRewardVaultFactory(address _bgt, address _owner, address _vaultImpl) internal returns (RewardVaultFactory rewardVaultFactoryProxy) {
        /*Proxy initialize data*/
        string memory functionName = "initialize(address,address,address)";
        bytes memory data = abi.encodeWithSignature(functionName, _bgt, _owner, _vaultImpl);

        vm.startBroadcast(deployerPrivateKey);
        RewardVaultFactory impl = new RewardVaultFactory();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        rewardVaultFactoryProxy = RewardVaultFactory(address(proxy));

        vm.stopBroadcast();
    }
}

contract DeployRewardVaultFactoryAndToken is DeployRewardVaultFactoryAndTokenScript {
    /* 
        source .env && forge script\
        --rpc-url bsc-testnet\
        scripts/DeployRewardVaultFactoryAndToken.s.sol:DeployRewardVaultFactoryAndToken\
        bsc-testnet\
        --sig 'run(string)'\
        -vvvv
    */
    function run(string calldata _network) external {
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
        address deployer = vm.addr(deployerPrivateKey);

        address rewardToken_ = _deployRewardToken();
        address vaultImpl_ = _deployVaultImpl();
        RewardVaultFactory RewardVaultFactory_ = _deployRewardVaultFactory(rewardToken_, deployer, vaultImpl_);

        console2.log("rewardToken_: ", rewardToken_);
        console2.log("vaultImpl_: ", vaultImpl_);
        console2.log("RewardVaultFactory_: ", address(RewardVaultFactory_));
    }

    function compareStrings(string memory a, string memory b) public pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }
}
