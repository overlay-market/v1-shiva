// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IOverlayV1Market} from "v1-periphery/lib/v1-core/contracts/interfaces/IOverlayV1Market.sol";
import {IOverlayV1State} from "v1-periphery/contracts/interfaces/IOverlayV1State.sol";
import {Risk} from "v1-periphery/lib/v1-core/contracts/libraries/Risk.sol";
import {FixedPoint} from "v1-periphery/lib/v1-core/contracts/libraries/FixedPoint.sol";
import {FixedCast} from "v1-periphery/lib/v1-core/contracts/libraries/FixedCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IShiva} from "./IShiva.sol";
import {Utils} from "./utils/Utils.sol";
import {IOverlayMarketLiquidateCallback} from
    "v1-periphery/lib/v1-core/contracts/interfaces/callback/IOverlayMarketLiquidateCallback.sol";
import "./PolStakingToken.sol";
import {IBerachainRewardsVault, IBerachainRewardsVaultFactory} from "./interfaces/berachain/IRewardVaults.sol";
import {Position} from "v1-periphery/lib/v1-core/contracts/libraries/Position.sol";

contract Shiva is IShiva, IOverlayMarketLiquidateCallback {
    using FixedPoint for uint256;
    using FixedCast for uint16;
    using Position for Position.Info;

    uint256 internal constant ONE = 1e18;

    IERC20 public ovToken;
    IOverlayV1State public ovState;

    mapping(IOverlayV1Market => mapping(uint256 => address)) public positionOwners;
    mapping(IOverlayV1Market => bool) public marketAllowance;

    StakingToken public stakingToken;
    IBerachainRewardsVault public rewardVault;

    constructor(address _ovToken, address _ovState, address _vaultFactory) {
        ovToken = IERC20(_ovToken);
        ovState = IOverlayV1State(_ovState);

        // Create new staking token
        stakingToken = new StakingToken();

        // Create vault for newly created token
        address vaultAddress = IBerachainRewardsVaultFactory(_vaultFactory)
            .createRewardsVault(address(stakingToken));

        rewardVault = IBerachainRewardsVault(vaultAddress);
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
        uint16 slippage;
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
}
