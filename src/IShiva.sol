// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IOverlayV1Market} from "v1-core/contracts/interfaces/IOverlayV1Market.sol";
import {ShivaStructs} from "./ShivaStructs.sol";

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
     * @notice Emitted when an emergency withdrawal is performed through Shiva.
     * @param owner Address of the position owner who performed the withdrawal.
     * @param market Address of the market from which funds were withdrawn.
     * @param performer Address of the account that called the emergencyWithdraw function.
     * @param positionId Unique ID of the withdrawn position.
     */
    event ShivaEmergencyWithdraw(
        address indexed owner,
        address indexed market,
        address performer,
        uint256 positionId
    );

    /**
     * @notice Emitted when tokens are staked through Shiva.
     * @param owner Address of the user who performed the stake.
     * @param amount Amount of tokens staked.
     */
    event ShivaStake(
        address indexed owner,
        uint256 amount
    );

    /**
     * @notice Emitted when staked tokens are withdrawn through Shiva.
     * @param owner Address of the user who performed the unstake.
     * @param amount Amount of tokens unstaked.
     */
    event ShivaUnstake(
        address indexed owner,
        uint256 amount
    );

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

    error NotPositionOwner();
    error ExpiredDeadline();
    error InvalidSignature();
    error MarketNotValid();

    function build(
        ShivaStructs.Build calldata params
    ) external returns (uint256 positionId);

    function build(
        ShivaStructs.Build calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    ) external returns (uint256 positionId);

    function buildSingle(
        ShivaStructs.BuildSingle calldata params
    ) external returns (uint256 positionId);

    function buildSingle(
        ShivaStructs.BuildSingle calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    ) external returns (uint256 positionId);

    function unwind(
        ShivaStructs.Unwind calldata params
    ) external;

    function unwind(
        ShivaStructs.Unwind calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    ) external;

    function emergencyWithdraw(
        IOverlayV1Market market,
        uint256 positionId,
        address owner
    ) external;
}
