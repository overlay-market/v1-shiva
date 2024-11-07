// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IOverlayV1Market} from "v1-periphery/lib/v1-core/contracts/interfaces/IOverlayV1Market.sol";
import {IOverlayV1State} from "v1-periphery/contracts/interfaces/IOverlayV1State.sol";
import {Risk} from "v1-periphery/lib/v1-core/contracts/libraries/Risk.sol";
import {FixedPoint} from "v1-periphery/lib/v1-core/contracts/libraries/FixedPoint.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IShiva} from "./IShiva.sol";
import {Utils} from "./utils/Utils.sol";
import {ShivaStructs} from "./ShivaStructs.sol";

contract Shiva is IShiva, EIP712 {
    using FixedPoint for uint256;
    using ECDSA for bytes32;

    uint256 public constant ONE = 1e18;

    bytes32 public constant BUILD_ON_BEHALF_OF_TYPEHASH = keccak256(
        "BuildOnBehalfOfParams(IOverlayV1Market ovMarket,uint48 deadline,uint256 collateral,uint256 leverage,bool isLong,uint256 priceLimit,uint256 nonce)"
    );

    bytes32 public constant UNWIND_ON_BEHALF_OF_TYPEHASH = keccak256(
        "UnwindOnBehalfOfParams(IOverlayV1Market ovMarket,uint48 deadline,uint256 positionId,uint256 fraction,uint256 priceLimit,uint256 nonce)"
    );

    IERC20 public ovToken;
    IOverlayV1State public ovState;

    mapping(IOverlayV1Market => mapping(uint256 => address)) public positionOwners;
    mapping(IOverlayV1Market => bool) public marketAllowance;
    mapping(address => uint256) public nonces;

    constructor(address _ovToken, address _ovState) EIP712("Shiva", "0.1.0") {
        ovToken = IERC20(_ovToken);
        ovState = IOverlayV1State(_ovState);
    }

    modifier onlyPositionOwner(IOverlayV1Market ovMarket, uint256 positionId, address owner) {
        if (positionOwners[ovMarket][positionId] != owner) {
            revert NotPositionOwner();
        }
        _;
    }

    modifier validDeadline(uint48 deadline) {
        if (block.timestamp > deadline) {
            revert ExpiredDeadline();
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
        _approveMarket(ovMarket);

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
    ) public onlyPositionOwner(ovMarket, positionId, msg.sender) {
        _onUnwindPosition(ovMarket, positionId, fraction, priceLimit);

        ovToken.transfer(msg.sender, ovToken.balanceOf(address(this)));

        // TODO - Emit event? because market contract will emit event
    }

    // Function to build and keep a single position in the ovMarket for a user.
    // If the user already has a position in the ovMarket, it will be unwound before building a new one
    // and previous collateral and new collateral will be used to build the new position.
    function buildSingle(
        ShivaStructs.BuildSingle memory params
    )
        external
        onlyPositionOwner(params.ovMarket, params.previousPositionId, msg.sender)
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

        // Approve the ovMarket contract to spend OV
        _approveMarket(params.ovMarket);

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
        ShivaStructs.BuildOnBehalfOf memory params
    ) external validDeadline(params.deadline) returns (uint256 positionId) {
        // build typed data hash
        bytes32 structHash = keccak256(abi.encode(
            BUILD_ON_BEHALF_OF_TYPEHASH,
            params.ovMarket,
            params.deadline,
            params.collateral,
            params.leverage,
            params.isLong,
            params.priceLimit,
            nonces[params.owner]
        ));
        _checkIsValidSignature(structHash, params.signature, params.owner);

        require(params.leverage >= ONE, "Shiva:lev<min");
        uint256 tradingFee = _getTradingFee(params.ovMarket, params.collateral, params.leverage);

        // Transfer OVL from owner to this contract
        ovToken.transferFrom(params.owner, address(this), params.collateral + tradingFee);

        // Approve the ovMarket contract to spend OV
        _approveMarket(params.ovMarket);

        positionId = _onBuildPosition(params.owner, params.ovMarket, params.collateral, params.leverage, params.isLong, params.priceLimit);
    }

    // Function to unwind a position on behalf of a user (with signature verification)
    function unwindOnBehalfOf(
        ShivaStructs.UnwindOnBehalfOf memory params
    ) external validDeadline(params.deadline) onlyPositionOwner(params.ovMarket, params.positionId, params.owner) {
        // build typed data hash
        bytes32 structHash = keccak256(abi.encode(
            UNWIND_ON_BEHALF_OF_TYPEHASH,
            params.ovMarket,
            params.deadline,
            params.positionId,
            params.fraction,
            params.priceLimit,
            nonces[params.owner]
        ));
        _checkIsValidSignature(structHash, params.signature, params.owner);

        _onUnwindPosition(params.ovMarket, params.positionId, params.fraction, params.priceLimit);

        ovToken.transfer(params.owner, ovToken.balanceOf(address(this)));
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

    function _approveMarket(IOverlayV1Market ovMarket) internal {
        if (!marketAllowance[ovMarket]) {
            ovToken.approve(address(ovMarket), type(uint256).max);
            marketAllowance[ovMarket] = true;
        }
    }

    function _checkIsValidSignature(bytes32 structHash, bytes memory signature, address owner) internal {
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = digest.recover(signature);

        if (signer != owner) {
            revert InvalidSignature();
        }

        nonces[owner]++;
    }
}
