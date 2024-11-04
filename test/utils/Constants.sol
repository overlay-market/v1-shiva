// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IOverlayV1State} from "../../src/v1-core/IOverlayV1State.sol";
import {IOverlayV1Market} from "v1-core/contracts/interfaces/IOverlayV1Market.sol";

library Constants {
    function getOVTokenAddress() external pure returns (address) {
        return 0x3E27fAe625f25291bFda517f74bf41DC40721dA2;
    }

    function getETHDominanceMarketAddress() external pure returns (address) {
        return 0x3a204d03e9B1fEE01b8989333665b6c46Cc1f79E;
    }

    function getOVStateAddress() external pure returns (address) {
        return 0x2878837EA173e8BD40Db7CEE360b15c1C27dEB5A;
    }

    function getForkedNetworkRPC() external pure returns (string memory) {
        return "ARBITRUM_SEPOLIA_RPC";
    }
}
