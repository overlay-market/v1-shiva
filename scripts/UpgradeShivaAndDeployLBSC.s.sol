// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Shiva} from "../src/Shiva.sol";
import {LoanBasedStableCollateral} from "../src/LoanBasedStableCollateral.sol";

/**
 * @notice Forge script that upgrades the Shiva proxy implementation and deploys/configures
 *         the LoanBasedStableCollateral contract in a single broadcast.
 *
 * Usage example:
 * forge script scripts/UpgradeShivaAndDeployLBSC.s.sol:UpgradeShivaAndDeployLBSC \
 *   --rpc-url $RPC_URL \
 *   --sig "run(address,address,address,address,uint256)" \
 *   $SHIVA_PROXY $STABLE $PRICE_FEED $LOSS_RECIPIENT $MAX_PRICE_AGE \
 *   --broadcast
 *
 * Environment:
 *   DEPLOYER_PK (must hold GOVERNOR_ROLE on OVL to pass onlyGovernor checks)
 */
contract UpgradeShivaAndDeployLBSC is Script {
    function run(
        address shivaProxy,
        address stableToken,
        address priceFeed,
        address lossRecipient,
        uint256 maxPriceAge
    ) external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PK");
        vm.startBroadcast(deployerPrivateKey);

        Shiva shiva = Shiva(shivaProxy);

        // Upgrade Shiva implementation (UUPS).
        Shiva newShivaImpl = new Shiva();
        shiva.upgradeTo(address(newShivaImpl));

        // Deploy LBSC behind an ERC1967 proxy and initialize it.
        LoanBasedStableCollateral lbscImpl = new LoanBasedStableCollateral();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address,uint256)",
            stableToken,
            shivaProxy,
            priceFeed,
            lossRecipient,
            maxPriceAge
        );
        ERC1967Proxy lbscProxy = new ERC1967Proxy(address(lbscImpl), initData);
        LoanBasedStableCollateral lbsc = LoanBasedStableCollateral(address(lbscProxy));

        // Wire Shiva to the freshly deployed LBSC instance.
        shiva.setLbsc(address(lbsc));

        vm.stopBroadcast();

        console2.log("Shiva proxy:", shivaProxy);
        console2.log("New Shiva implementation:", address(newShivaImpl));
        console2.log("LBSC implementation:", address(lbscImpl));
        console2.log("LBSC proxy:", address(lbsc));
    }
}
