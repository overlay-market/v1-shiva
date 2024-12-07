// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IOverlayV1State} from "v1-periphery/contracts/interfaces/IOverlayV1State.sol";
import {IOverlayV1Market} from "v1-periphery/lib/v1-core/contracts/interfaces/IOverlayV1Market.sol";

library Constants {
    function getOVTokenAddress() external pure returns (address) {
        return 0x97576e088f0d05EF68cac2EEc63d017FE90952a0;
    }

    function getETHDominanceMarketAddress() external pure returns (address) {
        return 0x09E8641df1E963d0bB1267e51579fC2B4E3E60cd;
    }

    function getOVStateAddress() external pure returns (address) {
        return 0x4f69Dfb24958fCf69b70BcA73c3E74F2c82BB405;
    }

    function getFactoryAddress() external pure returns (address) {
        return 0xBe048017966c2787f548De1Df5834449eC4c4f50;
    }

    function getForkedNetworkRPC() external pure returns (string memory) {
        return "BARTIO_RPC";
    }

    function getForkBlock() external pure returns (uint256) {
        return 6319332;
    }

    function getSequencer() external pure returns (address) {
        return 0xC35093f76fF3D31Af27A893CDcec585F1899eE54;
    }

    function getFeedFactory() external pure returns (address) {
        return 0xc0dE47Cbb26C2e19B82f9E205b0b0FfcD7947290;
    }

    function getEthdFeed() external pure returns (address) {
        return 0x1f70F47D649Efa6106aEec4a0d7E46377D71b11f;
    }

    function getGuardianAddress() external pure returns (address) {
        return 0x85f66DBe1ed470A091d338CFC7429AA871720283;
    }

    function getGovernorAddress() external pure returns (address) {
        return 0x85f66DBe1ed470A091d338CFC7429AA871720283;
    }

    function getPauserAddress() external pure returns (address) {
        return 0x85f66DBe1ed470A091d338CFC7429AA871720283;
    }

    function getDeployerAddress() external pure returns (address) {
        return 0x85f66DBe1ed470A091d338CFC7429AA871720283;
    }
}
