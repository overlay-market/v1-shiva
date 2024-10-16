// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {IOverlayV1Market} from "./v1-core/IOverlayV1Market.sol";
import {Risk} from "./v1-core/Risk.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IShiva} from "./IShiva.sol";

contract Shiva is IShiva {
    IERC20 public ovlToken;
    mapping(IOverlayV1Market => mapping(uint256 => address)) public positionOwners;

    constructor(address _ovlToken) {
        ovlToken = IERC20(_ovlToken);
    }

    modifier onlyPositionOwner(IOverlayV1Market market, uint256 positionId) {
        if (positionOwners[market][positionId] != msg.sender) {
            revert NotPositionOwner();
        }
        _;
    }

    // Function to get the owner of a position
    function ownerOf(IOverlayV1Market market, uint256 positionId) public view returns (address) {
        return positionOwners[market][positionId];
    }

    // Function to build a position in the market for a user
    function build(
        IOverlayV1Market market,
        uint256 collateral,
        uint256 leverage,
        bool isLong,
        uint256 priceLimit
    ) external returns (uint256 positionId) {
        uint256 tradingFee = market.params(uint256(Risk.Parameters.TradingFeeRate));
        // Transfer OVL from user to this contract
        ovlToken.transferFrom(msg.sender, address(this), collateral + tradingFee);

        // Approve the market contract to spend OVL
        ovlToken.approve(address(market), collateral + tradingFee);

        // Build position in the market
        positionId = market.build(collateral, leverage, isLong, priceLimit);

        // Store position ownership
        positionOwners[market][positionId] = msg.sender;
    }

    // Function to unwind a position for the user
    function unwind(
        IOverlayV1Market market,
        uint256 positionId,
        uint256 fraction,
        uint256 priceLimit
    ) external onlyPositionOwner(market, positionId) {
        // Unwind position in the market
        market.unwind(positionId, fraction, priceLimit);

        // Transfer OVL back to the owner
        ovlToken.transfer(msg.sender, ovlToken.balanceOf(address(this)));

        // Clear position ownership if its fully unwound
        if (fraction == 1e18) {
            delete positionOwners[market][positionId];
        }
    }

    // Function to build a position on behalf of a user (with signature verification)
    function buildOnBehalfOf(
        IOverlayV1Market market,
        address owner,
        bytes calldata signature,
        uint256 deadline,
        uint256 collateral,
        uint256 leverage,
        bool isLong,
        uint256 priceLimit
    ) external returns (uint256 positionId) {
      // TODO: Implement this function
    }

    // Function to unwind a position on behalf of a user (with signature verification)
    function unwindOnBehalfOf(
        IOverlayV1Market market,
        address owner,
        bytes calldata signature,
        uint256 deadline,
        uint256 positionId,
        uint256 fraction,
        uint256 priceLimit
    ) external {
        // TODO: Implement this function
    }
}
