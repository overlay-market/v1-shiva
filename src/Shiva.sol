// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IOverlayV1Market} from "v1-core/contracts/interfaces/IOverlayV1Market.sol";
import {IOverlayV1State} from "./v1-core/IOverlayV1State.sol";
import {Risk} from "v1-core/contracts/libraries/Risk.sol";
import {FixedPoint} from "v1-core/contracts/libraries/FixedPoint.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IShiva} from "./IShiva.sol";
import {Utils} from "./utils/Utils.sol";

contract Shiva is IShiva {
    using FixedPoint for uint256;

    uint256 internal constant ONE = 1e18;

    IERC20 public ovToken;
    IOverlayV1State public ovState;

    mapping(IOverlayV1Market => mapping(uint256 => address)) public positionOwners;
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

    // Function to build a position in the ovMarket for a user
    function build(
        IOverlayV1Market ovMarket,
        uint256 collateral,
        uint256 leverage,
        bool isLong,
        uint256 priceLimit
    ) public returns (uint256 positionId) {
        require(leverage >= ONE, "Shiva:lev<min");
        uint256 tradingFee = _getTradingFee(ovMarket, collateral, leverage);

        // Transfer OV from user to this contract
        ovToken.transferFrom(msg.sender, address(this), collateral + tradingFee);

        // Approve the ovMarket contract to spend OV
        if (!marketAllowance[ovMarket]) {
            ovToken.approve(address(ovMarket), type(uint256).max);
            marketAllowance[ovMarket] = true;
        }

        positionId =
            _onBuildPosition(msg.sender, ovMarket, collateral, leverage, isLong, priceLimit);

        // TODO - Emit event? because market contract will emit event
    }

    // Function to unwind a position for the user
    function unwind(
        IOverlayV1Market ovMarket,
        uint256 positionId,
        uint256 fraction,
        uint256 priceLimit
    ) public onlyPositionOwner(ovMarket, positionId) {
        _onUnwindPosition(ovMarket, positionId, fraction, priceLimit);

        ovToken.transfer(msg.sender, ovToken.balanceOf(address(this)));

        // TODO - Emit event? because market contract will emit event
    }

    struct BuildSingleParams {
        uint256 collateral;
        uint256 leverage;
        uint256 previousPositionId;
        IOverlayV1Market ovMarket;
        uint8 slippage;
    }

    // Function to build and keep a single position in the ovMarket for a user.
    // If the user already has a position in the ovMarket, it will be unwound before building a new one
    // and previous collateral and new collateral will be used to build the new position.
    function buildSingle(
        BuildSingleParams memory params
    )
        external
        onlyPositionOwner(params.ovMarket, params.previousPositionId)
        returns (uint256 positionId)
    {
        require(params.leverage >= ONE, "Shiva:lev<min");

        (uint256 unwindPriceLimit, bool isLong) = Utils.getUnwindPrice(
            ovState, params.ovMarket, params.previousPositionId, address(this), ONE, params.slippage
        );
        _onUnwindPosition(params.ovMarket, params.previousPositionId, ONE, unwindPriceLimit);

        uint256 totalCollateral = params.collateral + ovToken.balanceOf(address(this));
        uint256 tradingFee = _getTradingFee(params.ovMarket, totalCollateral, params.leverage);

        // transfer from OVL from user to this contract
        ovToken.transferFrom(msg.sender, address(this), params.collateral + tradingFee);

        if (!marketAllowance[params.ovMarket]) {
            ovToken.approve(address(params.ovMarket), type(uint256).max);
            marketAllowance[params.ovMarket] = true;
        }

        // Build new position
        uint256 buildPriceLimit = Utils.getEstimatedPrice(
            ovState, params.ovMarket, totalCollateral, params.leverage, params.slippage, isLong
        );

        positionId = _onBuildPosition(
            msg.sender, params.ovMarket, totalCollateral, params.leverage, isLong, buildPriceLimit
        );

        emit BuildSingle(
            msg.sender,
            address(params.ovMarket),
            params.previousPositionId,
            positionId,
            params.collateral,
            totalCollateral
        );
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

    function _onBuildPosition(
        address _owner,
        IOverlayV1Market _market,
        uint256 _collateral,
        uint256 _leverage,
        bool _isLong,
        uint256 _priceLimit
    ) internal returns (uint256 positionId) {
        positionId = _market.build(_collateral, _leverage, _isLong, _priceLimit);

        // Store position ownership
        positionOwners[_market][positionId] = _owner;
    }

    function _onUnwindPosition(
        IOverlayV1Market _market,
        uint256 _positionId,
        uint256 _fraction,
        uint256 _priceLimit
    ) internal {
        _market.unwind(_positionId, _fraction, _priceLimit);
    }

    function _getTradingFee(
        IOverlayV1Market ovMarket,
        uint256 collateral,
        uint256 leverage
    ) internal view returns (uint256) {
        uint256 notional = collateral.mulUp(leverage);
        return notional.mulUp(ovMarket.params(uint256(Risk.Parameters.TradingFeeRate)));
    }
}
