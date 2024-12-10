// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IShiva} from "./IShiva.sol";
import {IOverlayV1Market} from "v1-core/contracts/interfaces/IOverlayV1Market.sol";
import {IOverlayMarketLiquidateCallback} from
    "v1-core/contracts/interfaces/callback/IOverlayMarketLiquidateCallback.sol";
import {IOverlayV1Factory} from "v1-core/contracts/interfaces/IOverlayV1Factory.sol";
import {IOverlayV1Token, GOVERNOR_ROLE, PAUSER_ROLE} from "v1-core/contracts/interfaces/IOverlayV1Token.sol";
import {IOverlayV1State} from "v1-periphery/contracts/interfaces/IOverlayV1State.sol";
import {IBerachainRewardsVault, IBerachainRewardsVaultFactory} from "./interfaces/berachain/IRewardVaults.sol";

import "./PolStakingToken.sol";
import {ShivaStructs} from "./ShivaStructs.sol";
import {Utils} from "./utils/Utils.sol";
import {Risk} from "v1-core/contracts/libraries/Risk.sol";
import {Position} from "v1-core/contracts/libraries/Position.sol";
import {FixedPoint} from "v1-core/contracts/libraries/FixedPoint.sol";
import {FixedCast} from "v1-core/contracts/libraries/FixedCast.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract Shiva is IShiva, EIP712, IOverlayMarketLiquidateCallback {
    using FixedPoint for uint256;
    using FixedCast for uint16;
    using Position for Position.Info;
    using ECDSA for bytes32;

    uint256 public constant ONE = 1e18;

    bytes32 public constant BUILD_ON_BEHALF_OF_TYPEHASH = keccak256(
        "BuildOnBehalfOfParams(IOverlayV1Market ovMarket,uint48 deadline,uint256 collateral,uint256 leverage,bool isLong,uint256 priceLimit,uint256 nonce)"
    );

    bytes32 public constant UNWIND_ON_BEHALF_OF_TYPEHASH = keccak256(
        "UnwindOnBehalfOfParams(IOverlayV1Market ovMarket,uint48 deadline,uint256 positionId,uint256 fraction,uint256 priceLimit,uint256 nonce)"
    );

    bytes32 public constant BUILD_SINGLE_ON_BEHALF_OF_TYPEHASH = keccak256(
        "BuildSingleOnBehalfOf(address ovMarket,uint48 deadline,uint256 collateral,uint256 leverage,uint256 previousPositionId,uint256 nonce)"
    );

    IOverlayV1Token public constant ovToken;
    IOverlayV1State public constant ovState;
    StakingToken public constant stakingToken;
    IBerachainRewardsVault public constant rewardVault;

    IOverlayV1Factory[] public authorizedFactories;

    mapping(IOverlayV1Market => mapping(uint256 => address)) public positionOwners;
    mapping(IOverlayV1Market => bool) public marketAllowance;
    mapping(address => uint256) public nonces;
    mapping(address => bool) public validMarkets;

    constructor(address _ovToken, address _ovState, address _vaultFactory) EIP712("Shiva", "0.1.0") {
        ovToken = IOverlayV1Token(_ovToken);
        ovState = IOverlayV1State(_ovState);

        // Create new staking token
        stakingToken = new StakingToken();

        // Create vault for newly created token
        address vaultAddress = IBerachainRewardsVaultFactory(_vaultFactory)
            .createRewardsVault(address(stakingToken));

        rewardVault = IBerachainRewardsVault(vaultAddress);
    }

    // governor modifier for governance sensitive functions
    modifier onlyGovernor(address _msgSender) {
        require(ovToken.hasRole(GOVERNOR_ROLE, _msgSender), "Shiva: !governor");
        _;
    }

    // pauser modifier for pausable functions
    modifier onlyPauser(address _msgSender) {
        require(ovToken.hasRole(PAUSER_ROLE, _msgSender), "Shiva: !pauser");
        _;
    }

    modifier onlyPositionOwner(IOverlayV1Market ovMarket, uint256 positionId, address owner) {
        if (positionOwners[ovMarket][positionId] != owner) {
            revert NotPositionOwner();
        }
        _;
    }

    modifier validDeadline(
        uint48 deadline
    ) {
        if (block.timestamp > deadline) {
            revert ExpiredDeadline();
        }
        _;
    }

    modifier validMarket(
        IOverlayV1Market market
    ) {
        if (!_checkIsValidMarket(address(market))) {
            revert MarketNotValid();
        }
        _;
    }

    function addFactory(IOverlayV1Factory _factory) external onlyGovernor(msg.sender) {
        authorizedFactories.push(_factory);
    }

    function removeFactory(IOverlayV1Factory _factory) external onlyGovernor(msg.sender) {
        for (uint256 i = 0; i < authorizedFactories.length; i++) {
            if (authorizedFactories[i] == _factory) {
                authorizedFactories[i] = authorizedFactories[authorizedFactories.length - 1];
                authorizedFactories.pop();
                break;
            }
        }
    }

    // Function to build a position in the ovMarket for a user
    function build(
        ShivaStructs.Build calldata params
    ) external validMarket(params.ovMarket) returns (uint256) {
        return _buildLogic(params, msg.sender);
    }

    // Function to unwind a position for the user
    function unwind(
        ShivaStructs.Unwind calldata params
    ) external onlyPositionOwner(params.ovMarket, params.positionId, msg.sender) {
        _unwindLogic(params, msg.sender);
    }

    // Function to build and keep a single position in the ovMarket for a user.
    // If the user already has a position in the ovMarket, it will be unwound before building a new one
    // and previous collateral and new collateral will be used to build the new position.
    function buildSingle(
        ShivaStructs.BuildSingle calldata params
    )
        external
        onlyPositionOwner(params.ovMarket, params.previousPositionId, msg.sender)
        returns (uint256)
    {
        return _buildSingleLogic(params, msg.sender);
    }

    // Function to withdraw all the collateral from a position in a shutdown market
    function emergencyWithdraw(
        IOverlayV1Market market,
        uint256 positionId,
        address owner
    ) external onlyPositionOwner(market, positionId, owner) {
        _emergencyWithdrawLogic(market, positionId, owner);
    }

    // Function to build a position on behalf of a user (with signature verification)
    function build(
        ShivaStructs.Build calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    )
        external
        validMarket(params.ovMarket)
        validDeadline(onBehalfOf.deadline)
        returns (uint256)
    {
        // build typed data hash
        bytes32 structHash = keccak256(
            abi.encode(
                BUILD_ON_BEHALF_OF_TYPEHASH,
                params.ovMarket,
                onBehalfOf.deadline,
                params.collateral,
                params.leverage,
                params.isLong,
                params.priceLimit,
                nonces[onBehalfOf.owner]
            )
        );
        _checkIsValidSignature(structHash, onBehalfOf.signature, onBehalfOf.owner);

        return _buildLogic(params, onBehalfOf.owner);
    }

    // Function to unwind a position on behalf of a user (with signature verification)
    function unwind(
        ShivaStructs.Unwind calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    )
        external
        validDeadline(onBehalfOf.deadline)
        onlyPositionOwner(params.ovMarket, params.positionId, onBehalfOf.owner)
    {
        // build typed data hash
        bytes32 structHash = keccak256(
            abi.encode(
                UNWIND_ON_BEHALF_OF_TYPEHASH,
                params.ovMarket,
                onBehalfOf.deadline,
                params.positionId,
                params.fraction,
                params.priceLimit,
                nonces[onBehalfOf.owner]
            )
        );
        _checkIsValidSignature(structHash, onBehalfOf.signature, onBehalfOf.owner);

        _unwindLogic(params, onBehalfOf.owner);
    }

    // Function to build and keep a single position on behalf of a user (with signature verification)
    function buildSingle(
        ShivaStructs.BuildSingle calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    )
        external
        validDeadline(onBehalfOf.deadline)
        onlyPositionOwner(params.ovMarket, params.previousPositionId, onBehalfOf.owner)
        returns (uint256)
    {
        // build typed data hash
        bytes32 structHash = keccak256(
            abi.encode(
                BUILD_SINGLE_ON_BEHALF_OF_TYPEHASH,
                params.ovMarket,
                onBehalfOf.deadline,
                params.collateral,
                params.leverage,
                params.previousPositionId,
                nonces[onBehalfOf.owner]
            )
        );
        _checkIsValidSignature(structHash, onBehalfOf.signature, onBehalfOf.owner);

        return _buildSingleLogic(params, onBehalfOf.owner);
    }

    function getDigest(
        bytes32 structHash
    ) external view returns (bytes32) {
        return _hashTypedDataV4(structHash);
    }

    function _buildLogic(
        ShivaStructs.Build calldata _params,
        address _owner
    ) internal returns (uint256) {
        require(_params.leverage >= ONE, "Shiva:lev<min");
        uint256 tradingFee = _getTradingFee(_params.ovMarket, _params.collateral, _params.leverage);

        // Transfer OV from user to this contract
        ovToken.transferFrom(_owner, address(this), _params.collateral + tradingFee);

        // Approve the ovMarket contract to spend OV
        _approveMarket(_params.ovMarket);

        return _onBuildPosition(
            _owner,
            _params.ovMarket,
            _params.collateral,
            _params.leverage,
            _params.isLong,
            _params.priceLimit
        );
    }

    function _unwindLogic(
        ShivaStructs.Unwind calldata _params,
        address _owner
    ) internal {
        _onUnwindPosition(_params.ovMarket, _params.positionId, _params.fraction, _params.priceLimit);

        ovToken.transfer(_owner, ovToken.balanceOf(address(this)));
    }

    function _buildSingleLogic(
        ShivaStructs.BuildSingle calldata _params,
        address _owner
    ) internal returns (uint256 positionId) {
        require(_params.leverage >= ONE, "Shiva:lev<min");

        (uint256 unwindPriceLimit, bool isLong) = Utils.getUnwindPrice(
            ovState, _params.ovMarket, _params.previousPositionId, address(this), ONE, _params.slippage
        );
        _onUnwindPosition(_params.ovMarket, _params.previousPositionId, ONE, unwindPriceLimit);

        uint256 totalCollateral = _params.collateral + ovToken.balanceOf(address(this));
        uint256 tradingFee = _getTradingFee(_params.ovMarket, totalCollateral, _params.leverage);

        // transfer from OVL from user to this contract
        ovToken.transferFrom(_owner, address(this), _params.collateral + tradingFee);

        // Approve the ovMarket contract to spend OV
        _approveMarket(_params.ovMarket);

        // Build new position
        uint256 buildPriceLimit = Utils.getEstimatedPrice(
            ovState, _params.ovMarket, totalCollateral, _params.leverage, _params.slippage, isLong
        );

        positionId =
            _onBuildPosition(_owner, _params.ovMarket, totalCollateral, _params.leverage, isLong, buildPriceLimit);

        emit BuildSingle(
            _owner,
            address(_params.ovMarket),
            _params.previousPositionId,
            positionId,
            _params.collateral,
            totalCollateral
        );
    }

    function _emergencyWithdrawLogic(
        IOverlayV1Market _market,
        uint256 _positionId,
        address _owner
    ) internal {
        _market.emergencyWithdraw(_positionId);

        ovToken.transfer(_owner, ovToken.balanceOf(address(this)));
    }

    function overlayMarketLiquidateCallback(uint256 positionId) external {
        // TODO verify that the caller is a market
        IOverlayV1Market marketAddress = IOverlayV1Market(msg.sender);

        // Calculate remaining of initialNotional of the position to unwind
        uint256 intialNotional;
        //     // TODO make this more efficient, and nice looking
        {
            (
                uint96 notionalInitial_,
                , // uint96 debtInitial_,
                , // int24 midTick_,
                , // int24 entryTick_,
                , // bool isLong_,
                , // bool liquidated_,
                , // uint240 oiShares_,
                uint16 fractionRemaining_
            ) = marketAddress.positions(keccak256(abi.encodePacked(address(this), positionId)));
            intialNotional = uint256(notionalInitial_).mulUp(fractionRemaining_.toUint256Fixed());
        }

        // Withdraw tokens from the RewardVault
        rewardVault.delegateWithdraw(positionOwners[marketAddress][positionId], intialNotional);
        // Burn the withdrawn StakingTokens
        stakingToken.burn(address(this), intialNotional);
    }

    function _onBuildPosition(
        address _owner,
        IOverlayV1Market _market,
        uint256 _collateral,
        uint256 _leverage,
        bool _isLong,
        uint256 _priceLimit
    ) internal returns (uint256 positionId) {
        // calculate the notional of the position to build
        uint256 notional = _collateral.mulUp(_leverage);
        // Mint StakingTokens
        stakingToken.mint(address(this), notional);

        // Stake tokens in RewardVault on behalf of user
        stakingToken.approve(address(rewardVault), notional);
        rewardVault.delegateStake(_owner, notional);

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
        _fraction -= _fraction % 1e14;
        // Calculate fraction of initialNotional of the position to unwind
        uint256 intialNotionalFractionBefore;
        uint256 intialNotionalFraction;
        //     // TODO make this more efficient, and nice looking
        {
            (
                uint96 notionalInitial_,
                , // uint96 debtInitial_,
                , // int24 midTick_,
                , // int24 entryTick_,
                , // bool isLong_,
                , // bool liquidated_,
                , // uint240 oiShares_,
                uint16 fractionRemaining_
            ) = _market.positions(keccak256(abi.encodePacked(address(this), _positionId)));
            intialNotionalFractionBefore = uint256(notionalInitial_).mulUp(fractionRemaining_.toUint256Fixed());
        }

        _market.unwind(_positionId, _fraction, _priceLimit);

        {
            (
                uint96 notionalInitial_,
                , // uint96 debtInitial_,
                , // int24 midTick_,
                , // int24 entryTick_,
                , // bool isLong_,
                , // bool liquidated_,
                , // uint240 oiShares_,
                uint16 fractionRemaining_
            ) = _market.positions(keccak256(abi.encodePacked(address(this), _positionId)));
            intialNotionalFraction = intialNotionalFractionBefore - uint256(notionalInitial_).mulUp(fractionRemaining_.toUint256Fixed());
        }

        // Withdraw tokens from the RewardVault
        rewardVault.delegateWithdraw(positionOwners[_market][_positionId], intialNotionalFraction);
        // Burn the withdrawn StakingTokens
        stakingToken.burn(address(this), intialNotionalFraction);
    }

    function _getTradingFee(
        IOverlayV1Market _ovMarket,
        uint256 _collateral,
        uint256 _leverage
    ) internal view returns (uint256) {
        uint256 notional = _collateral.mulUp(_leverage);
        return notional.mulUp(_ovMarket.params(uint256(Risk.Parameters.TradingFeeRate)));
    }

    function _approveMarket(
        IOverlayV1Market _ovMarket
    ) internal {
        if (!marketAllowance[_ovMarket]) {
            ovToken.approve(address(_ovMarket), type(uint256).max);
            marketAllowance[_ovMarket] = true;
        }
    }

    function _checkIsValidSignature(
        bytes32 _structHash,
        bytes calldata _signature,
        address _owner
    ) internal {
        bytes32 digest = _hashTypedDataV4(_structHash);
        address signer = digest.recover(_signature);

        if (signer != _owner) {
            revert InvalidSignature();
        }

        nonces[_owner]++;
    }

    function _checkIsValidMarket(address _market) internal returns (bool) {
        if (validMarkets[_market]) {
            return true;
        }

        for (uint256 i = 0; i < authorizedFactories.length; i++) {
            if (authorizedFactories[i].isMarket(_market)) {
                validMarkets[_market] = true;
                return true;
            }
        }

        return false;
    }
}
