// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IOverlayV1State} from "v1-periphery/contracts/interfaces/IOverlayV1State.sol";
import {IOverlayV1Market} from "v1-periphery/lib/v1-core/contracts/interfaces/IOverlayV1Market.sol";

library Constants {
    bool constant isBartio = true;
    function getOVTokenAddress() external pure returns (address) {
        return isBartio ? 0x97576e088f0d05EF68cac2EEc63d017FE90952a0 : 0x3E27fAe625f25291bFda517f74bf41DC40721dA2;
    }

    function getETHDominanceMarketAddress() external pure returns (address) {
        return isBartio ? 0x09E8641df1E963d0bB1267e51579fC2B4E3E60cd : 0x3a204d03e9B1fEE01b8989333665b6c46Cc1f79E;
    }

    function getOVStateAddress() external pure returns (address) {
        return isBartio ? 0x4f69Dfb24958fCf69b70BcA73c3E74F2c82BB405 : 0x2878837EA173e8BD40Db7CEE360b15c1C27dEB5A;
    }

    function getFactoryAddress() external pure returns (address) {
        return 0xa2dBe262D27647243Ac3187d05DBF6c3C6ECC14D;
    }

    function getForkedNetworkRPC() external pure returns (string memory) {
        return isBartio ? "BARTIO_RPC" : "ARBITRUM_SEPOLIA_RPC";
    }

    function getForkBlock() external pure returns (uint256) {
        return isBartio ? 6319332 : 92984086;
    }

    function getSequencer() external pure returns (address) {
        return isBartio ? 0xC35093f76fF3D31Af27A893CDcec585F1899eE54 : address(0);
    }

    function getFeedFactory() external pure returns (address) {
        return isBartio ? 0xc0dE47Cbb26C2e19B82f9E205b0b0FfcD7947290 : address(0);
    }

    function getEthdFeed() external pure returns (address) {
        return isBartio ? 0x1f70F47D649Efa6106aEec4a0d7E46377D71b11f : address(0);
    }

    function getGuardianAddress() external pure returns (address) {
        return 0xc946446711eE82b87cc34611810B0f2DD14c15DD;
    }

    function getGovernorAddress() external pure returns (address) {
        return 0xc946446711eE82b87cc34611810B0f2DD14c15DD;
    }
}
