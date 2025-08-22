// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IOverlayV1Market} from "v1-core/contracts/interfaces/IOverlayV1Market.sol";
import {IOverlayV1Feed} from "v1-core/contracts/interfaces/feeds/IOverlayV1Feed.sol";
import {ShivaStructs} from "./ShivaStructs.sol";

/**
 * @title IShiva
 * @notice Interface for the Shiva contract
 */
interface IShiva {
    /**
     * @notice Emitted when a position is built through Shiva.
     * @param owner Address of the position owner.
     * @param market Address of the market where the position was built.
     * @param performer Address of the account that called the build function.
     * @param positionId Unique ID of the built position.
     * @param collateral Amount of collateral used to build the position.
     * @param leverage Leverage applied to the position.
     * @param brokerId ID of the broker used to build the position.
     * @param isLong Indicates whether the position is long or short.
     */
    event ShivaBuild(
        address indexed owner,
        address indexed market,
        address performer,
        uint256 positionId,
        uint256 collateral,
        uint256 leverage,
        uint32 brokerId,
        bool isLong
    );

    /**
     * @notice Emitted when a position is unwound through Shiva.
     * @param owner Address of the position owner.
     * @param market Address of the market where the position was unwound.
     * @param performer Address of the account that called the unwind function.
     * @param positionId Unique ID of the unwound position.
     * @param fraction Fraction of the position unwound.
     * @param brokerId ID of the broker used to unwind the position.
     */
    event ShivaUnwind(
        address indexed owner,
        address indexed market,
        address performer,
        uint256 positionId,
        uint256 fraction,
        uint32 brokerId
    );

    /**
     * @notice Emitted when a stop loss is executed through Shiva.
     * @param owner Address of the position owner.
     * @param market Address of the market where the position was unwound.
     * @param performer Address of the account that called the unwind function.
     * @param positionId Unique ID of the unwound position.
     * @param fraction Fraction of the position unwound.
     * @param triggerPrice The price at which the stop loss was triggered.
     * @param brokerId ID of the broker used to unwind the position.
     * @param keeperFee Fee paid to the keeper for executing the transaction.
     */
    event StopLossExecuted(
        address indexed owner,
        address indexed market,
        address performer,
        uint256 positionId,
        uint256 fraction,
        uint256 triggerPrice,
        uint32 brokerId,
        uint256 keeperFee
    );

    /**
     * @notice Emitted when a take profit is executed through Shiva.
     * @param owner Address of the position owner.
     * @param market Address of the market where the position was unwound.
     * @param performer Address of the account that called the unwind function.
     * @param positionId Unique ID of the unwound position.
     * @param fraction Fraction of the position unwound.
     * @param brokerId ID of the broker used to unwind the position.
     * @param keeperFee Fee paid to the keeper for executing the transaction.
     */
    event TakeProfitExecuted(
        address indexed owner,
        address indexed market,
        address performer,
        uint256 positionId,
        uint256 fraction,
        uint32 brokerId,
        uint256 keeperFee
    );

    /**
     * @notice Emitted when a limit order is executed through Shiva.
     * @param owner Address of the position owner.
     * @param market Address of the market where the position was built.
     * @param performer Address of the account that called the build function.
     * @param positionId Unique ID of the built position.
     * @param collateral Amount of collateral used to build the position.
     * @param leverage Leverage applied to the position.
     * @param brokerId ID of the broker used to build the position.
     * @param isLong Indicates whether the position is long or short.
     * @param keeperFee Fee paid to the keeper for executing the transaction.
     */
    event LimitOrderExecuted(
        address indexed owner,
        address indexed market,
        address performer,
        uint256 positionId,
        uint256 collateral,
        uint256 leverage,
        uint32 brokerId,
        bool isLong,
        uint256 keeperFee
    );

    /**
     * @notice Emitted when an emergency withdrawal is performed through Shiva.
     * @param owner Address of the position owner who performed the withdrawal.
     * @param market Address of the market from which funds were withdrawn.
     * @param performer Address of the account that called the emergencyWithdraw function.
     * @param positionId Unique ID of the withdrawn position.
     */
    event ShivaEmergencyWithdraw(
        address indexed owner, address indexed market, address performer, uint256 positionId
    );

    /**
     * @notice Emitted when tokens are staked through Shiva.
     * @param owner Address of the user who performed the stake.
     * @param amount Amount of tokens staked.
     */
    event ShivaStake(address indexed owner, uint256 amount);

    /**
     * @notice Emitted when staked tokens are withdrawn through Shiva.
     * @param owner Address of the user who performed the unstake.
     * @param amount Amount of tokens unstaked.
     */
    event ShivaUnstake(address indexed owner, uint256 amount);

    /**
     * @notice Emitted when an authorized factory is added to Shiva.
     * @param factory Address of the added factory.
     */
    event FactoryAdded(address indexed factory);

    /**
     * @notice Emitted when an authorized factory is removed from Shiva.
     * @param factory Address of the removed factory.
     */
    event FactoryRemoved(address indexed factory);

    /**
     * @notice Emitted when a market is dynamically validated by Shiva.
     * @param market Address of the validated market.
     */
    event MarketValidated(address indexed market);

    /**
     * @notice Emitted when a nonce is cancelled.
     * @param owner Address of the owner of the nonce.
     * @param nonce The nonce that was cancelled.
     */
    event NonceCancelled(address indexed owner, uint256 nonce);

    /**
     * @notice Error emitted when the caller is not the owner of the position.
     */
    error NotPositionOwner();

    /**
     * @notice Error emitted when the on behalf of signature is expired.
     */
    error ExpiredDeadline();

    /**
     * @notice Error emitted when the on behalf of signature is invalid.
     */
    error InvalidSignature();

    /**
     * @notice Error emitted when the market is not valid.
     */
    error MarketNotValid();

    /**
     * @notice Error emitted when the nonce is invalid.
     */
    error InvalidNonce();
    
    /**
     * @notice Thrown when the trigger condition for a conditional order has not been met
     */
    error TriggerNotMet();

    /**
     * @notice Error emitted when the user has an insufficient balance to pay the keeper fee.
     * @param ownerBalance The available balance of the user.
     * @param keeperFee The required fee for the keeper.
     */
    error InsufficientBalanceForKeeperFee(uint256 ownerBalance, uint256 keeperFee);

    /**
     * @notice Thrown when the calculated keeper fee exceeds the maximum specified amount.
     * @param calculatedFee The fee calculated based on gas usage and other factors.
     * @param maxFee The maximum fee allowed by the user.
     */
    error KeeperFeeExceedsMax(uint256 calculatedFee, uint256 maxFee);

    /**
     * @dev Functions that Shiva should implement.
     */

    /**
     * @notice Builds a new position.
     * @param params Parameters to build the position.
     * @return positionId Unique ID of the built position.
     */
    function build(ShivaStructs.Build calldata params) external returns (uint256 positionId);

    /**
     * @notice Builds a new position on behalf of an owner.
     * @param params Parameters to build the position.
     * @param onBehalfOf Parameters to perform the action on behalf of an owner.
     * @return positionId Unique ID of the built position.
     */
    function build(
        ShivaStructs.Build calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    ) external returns (uint256 positionId);

    /**
     * @notice Builds a new position with a single transaction.
     * @param params Parameters to build the position.
     * @return positionId Unique ID of the built position.
     */
    function buildSingle(ShivaStructs.BuildSingle calldata params)
        external
        returns (uint256 positionId);

    /**
     * @notice Builds a new position with a single transaction on behalf of an owner.
     * @param params Parameters to build the position.
     * @param onBehalfOf Parameters to perform the action on behalf of an owner.
     * @return positionId Unique ID of the built position.
     */
    function buildSingle(
        ShivaStructs.BuildSingle calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    ) external returns (uint256 positionId);

    /**
     * @notice Unwinds a position.
     * @param params Parameters to unwind the position.
     */
    function unwind(ShivaStructs.Unwind calldata params) external;

    /**
     * @notice Unwinds a position on behalf of an owner.
     * @param params Parameters to unwind the position.
     * @param onBehalfOf Parameters to perform the action on behalf of an owner.
     */
    function unwind(
        ShivaStructs.Unwind calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    ) external;

    /**
     * @notice Unwinds a position if the stop loss condition is met.
     * @param params The parameters for the stop loss order based on the
     * ShivaStructs.StopLoss struct.
     * @param onBehalfOf The parameters for acting on behalf of a user.
     */
    function stopLoss(
        ShivaStructs.StopLoss calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    ) external;

    /**
     * @notice Unwinds a position to take profit on behalf of an owner.
     * @param params Parameters to unwind the position.
     * @param onBehalfOf Parameters to perform the action on behalf of an owner.
     */
    function takeProfit(
        ShivaStructs.TakeProfit calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    ) external;

    /**
     * @notice Builds a new limit order position on behalf of an owner.
     * @param params Parameters to build the position.
     * @param onBehalfOf Parameters to perform the action on behalf of an owner.
     * @return positionId Unique ID of the built position.
     */
    function limitOrderBuild(
        ShivaStructs.LimitOrder calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    ) external returns (uint256 positionId);

    /**
     * @notice Withdraws funds from a position in case of market is shutdown.
     * @param market Address of the market where the position was built.
     * @param positionId Unique ID of the position to withdraw funds from.
     * @param owner Address of the position owner.
     */
    function emergencyWithdraw(
        IOverlayV1Market market,
        uint256 positionId,
        address owner
    ) external;

    /**
     * @notice Sets the keeper fee feed.
     * @param _feed The new feed for keeper fees.
     */
    function setKeeperFeeFeed(IOverlayV1Feed _feed) external;
}
