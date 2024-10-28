// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {IOverlayV1Market} from "./v1-core/IOverlayV1Market.sol";
import {IOverlayV1State} from "./v1-core/IOverlayV1State.sol";
import {Risk} from "./v1-core/Risk.sol";
import {FixedPoint} from "./v1-core/libraries/FixedPoint.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IShiva} from "./IShiva.sol";
import {Utils} from "./utils/Utils.sol";

contract Shiva is IShiva {
    using FixedPoint for uint256;

    IERC20 public ovToken;
    IOverlayV1State public ovState;

    mapping(IOverlayV1Market => mapping(uint256 => address)) internal positionOwners;
    mapping(IOverlayV1Market => bool) public marketAllowance;

    constructor(address _ovToken, address _ovState) {
        ovToken = IERC20(_ovToken);
        ovState = IOverlayV1State(_ovState);
    }

    modifier onlyPositionOwner(IOverlayV1Market ovMarket, uint256 positionId) {
        if (positionOwners[ovMarket][positionId] != msg.sender) {
            revert NotPositionOwner();
        }
        _;
    }

    // Function to get the owner of a position
    function ownerOf(IOverlayV1Market ovMarket, uint256 positionId) public view returns (address) {
        return positionOwners[ovMarket][positionId];
    }

    function _getTradingFee(IOverlayV1Market ovMarket, uint256 collateral, uint256 leverage) internal view returns (uint256) {
        uint256 notional = collateral.mulUp(leverage);
        return notional.mulUp(ovMarket.params(uint256(Risk.Parameters.TradingFeeRate)));
    }

    // Function to build a position in the ovMarket for a user
    function build(
        IOverlayV1Market ovMarket,
        uint256 collateral,
        uint256 leverage,
        bool isLong,
        uint256 priceLimit
    ) public returns (uint256 positionId) {
        require(leverage >= 1e18, "Shiva:lev<min");
        uint256 tradingFee = _getTradingFee(ovMarket, collateral, leverage);

        // Transfer OV from user to this contract
        ovToken.transferFrom(msg.sender, address(this), collateral + tradingFee);

        // Approve the ovMarket contract to spend OV
        if (!marketAllowance[ovMarket]) {
            ovToken.approve(address(ovMarket), type(uint256).max);
            marketAllowance[ovMarket] = true;
        }

        // Build position in the ovMarket
        positionId = ovMarket.build(collateral, leverage, isLong, priceLimit);

        // Store position ownership
        positionOwners[ovMarket][positionId] = msg.sender;

        // TODO - Emit event? because market contract will emit event

        return positionId;
    }

    // Function to unwind a position for the user
    function unwind(
        IOverlayV1Market ovMarket,
        uint256 positionId,
        uint256 fraction,
        uint256 priceLimit
    ) public onlyPositionOwner(ovMarket, positionId) {
        ovMarket.unwind(positionId, fraction, priceLimit);

        ovToken.transfer(msg.sender, ovToken.balanceOf(address(this)));

        // TODO - Emit event? because market contract will emit event
    }

    // Function to build and keep a single position in the ovMarket for a user.
    // If the user already has a position in the ovMarket, it will be unwound before building a new one
    // and previous collateral and new collateral will be used to build the new position.
    function buildSingle(
        IOverlayV1Market ovMarket,
        uint256 collateral,
        uint256 leverage,
        bool isLong,
        uint8 slippage,
        uint256 previousPositionId
    ) external onlyPositionOwner(ovMarket, previousPositionId) returns (uint256 positionId) {
        require(leverage >= 1e18, "Shiva:lev<min");

        uint256 unwindPriceLimit = Utils.getUnwindPrice(ovState, ovMarket, previousPositionId, msg.sender, 1e18, slippage, isLong);
        ovMarket.unwind(previousPositionId, 1e18, unwindPriceLimit);

        // TODO calculate fees
        uint256 totalCollateral = collateral + ovToken.balanceOf(address(this));
        uint256 tradingFee = _getTradingFee(ovMarket, totalCollateral, leverage);

        // transfer from OVL from user to this contract
        ovToken.transferFrom(msg.sender, address(this), collateral + tradingFee);

        // Approve the ovMarket contract to spend OV
        // TODO - Allowance check?
        if (!marketAllowance[ovMarket]) {
            ovToken.approve(address(ovMarket), type(uint256).max);
            marketAllowance[ovMarket] = true;
        }

        // Build new position
        uint256 buildPriceLimit = Utils.getEstimatedPrice(ovState, ovMarket, totalCollateral, leverage, slippage, isLong);
        positionId = build(ovMarket, collateral, leverage, isLong, buildPriceLimit);

        // Store position ownership
        positionOwners[ovMarket][positionId] = msg.sender;

        emit BuildSingle(msg.sender, address(ovMarket), previousPositionId, positionId, collateral, totalCollateral);

        return positionId;
    }

    // Function to build a position on behalf of a user (with signature verification)
    function buildOnBehalfOf(
        IOverlayV1Market ovMarket,
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
        IOverlayV1Market ovMarket,
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
