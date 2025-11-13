// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {StakingToken} from "./StakingTokenMock.sol";
import {ShivaStructs} from "../ShivaStructs.sol";

import {IOverlayV1Market} from "v1-core/contracts/interfaces/IOverlayV1Market.sol";
import {IOverlayMarketLiquidateCallback} from
    "v1-core/contracts/interfaces/callback/IOverlayMarketLiquidateCallback.sol";
import {IOverlayV1Factory} from "v1-core/contracts/interfaces/IOverlayV1Factory.sol";
import {IOverlayV1Token} from "v1-core/contracts/interfaces/IOverlayV1Token.sol";
import {IRewardsVault, IRewardsVaultFactory} from "../interfaces/rewardVault/IRewardVaults.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EIP712Upgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

/**
 * @title ShivaV1Mock
 * @author Overlay team
 * @notice Simplified mock contract that simulates the V1 version of Shiva
 * @dev This is used for testing upgrade compatibility
 * @dev This contract only implements the essential functions for testing
 */
contract ShivaV1Mock is
    Initializable,
    UUPSUpgradeable,
    EIP712Upgradeable,
    IOverlayMarketLiquidateCallback,
    PausableUpgradeable
{
    uint256 public constant ONE = 1e18;

    /// @notice The Overlay V1 Token contract
    IOverlayV1Token public ovlToken;

    /// @notice The StakingToken contract
    StakingToken public stakingToken;

    /// @notice The RewardsVault contract
    IRewardsVault public rewardVault;

    /// @notice List of authorized factories
    IOverlayV1Factory[] public authorizedFactories;

    /// @notice Mapping from market and position ID to the address of the position owner
    mapping(IOverlayV1Market => mapping(uint256 => address)) public positionOwners;

    /// @notice Mapping to check if a market is allowed to spend OVL on behalf of this contract
    mapping(IOverlayV1Market => bool) public marketAllowance;

    /// @notice Mapping from performer address and nonce to boolean indicating if it's used
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    /// @notice Mapping to check if an address is a valid market
    mapping(address => bool) private validMarkets;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the Shiva contract
     * @param _ovlToken The address of the Overlay V1 Token contract
     * @param _vaultFactory The address of the Rewards Vault Factory contract
     */
    function initialize(
        address _ovlToken,
        address _vaultFactory
    ) external initializer {
        __EIP712_init("Shiva", "0.1.0");
        __Pausable_init();

        ovlToken = IOverlayV1Token(_ovlToken);

        // Create new staking token
        stakingToken = new StakingToken();

        // Create vault for newly created token
        address vaultAddress =
            IRewardsVaultFactory(_vaultFactory).createRewardVault(address(stakingToken));

        rewardVault = IRewardsVault(vaultAddress);

        // Approve rewardVault to spend max amount of stakingToken
        stakingToken.approve(address(rewardVault), type(uint256).max);
    }

    /**
     * @notice Adds a new factory to the list of authorized factories
     * @param _factory The address of the factory to add
     */
    function addFactory(IOverlayV1Factory _factory) external {
        authorizedFactories.push(_factory);
    }

    /**
     * @notice Removes a factory from the list of authorized factories
     * @param _factory The address of the factory to remove
     */
    function removeFactory(IOverlayV1Factory _factory) external {
        for (uint256 i = 0; i < authorizedFactories.length; i++) {
            if (authorizedFactories[i] == _factory) {
                authorizedFactories[i] = authorizedFactories[authorizedFactories.length - 1];
                authorizedFactories.pop();
                break;
            }
        }
    }

    /**
     * @notice Pauses the contract, preventing certain actions
     */
    function pause() external {
        _pause();
    }

    /**
     * @notice Unpauses the contract, allowing actions to be performed
     */
    function unpause() external {
        _unpause();
    }

    /**
     * @notice Builds a position in the ovlMarket for a user
     */
    function build(ShivaStructs.Build calldata params) external returns (uint256) {
        return 1; // Mock implementation
    }

    /**
     * @notice Builds a position on behalf of a user
     */
    function build(
        ShivaStructs.Build calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    ) external returns (uint256) {
        return 1; // Mock implementation
    }

    /**
     * @notice Builds and keeps a single position
     */
    function buildSingle(ShivaStructs.BuildSingle calldata params) external returns (uint256) {
        return 1; // Mock implementation
    }

    /**
     * @notice Builds and keeps a single position on behalf of a user
     */
    function buildSingle(
        ShivaStructs.BuildSingle calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    ) external returns (uint256) {
        return 1; // Mock implementation
    }

    /**
     * @notice Unwinds a position for the user
     */
    function unwind(ShivaStructs.Unwind calldata params) external {
        // Mock implementation
    }

    /**
     * @notice Unwinds a position on behalf of a user
     */
    function unwind(
        ShivaStructs.Unwind calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    ) external {
        // Mock implementation
    }

    /**
     * @notice Withdraws all the collateral from a position in a shutdown market
     */
    function emergencyWithdraw(
        IOverlayV1Market market,
        uint256 positionId,
        address owner
    ) external {
        // Mock implementation
    }

    /**
     * @notice Callback function for market liquidation
     */
    function overlayMarketLiquidateCallback(uint256 positionId) external {
        // Mock implementation
    }

    /**
     * @notice Returns the digest of the typed data hash
     */
    function getDigest(bytes32 structHash) external view returns (bytes32) {
        return _hashTypedDataV4(structHash);
    }

    /**
     * @notice Authorizes an upgrade to the contract
     */
    function _authorizeUpgrade(address) internal override {}

    /**
     * @notice Cancels a specific nonce for the caller
     */
    function cancelNonce(uint256 nonce) external {
        usedNonces[msg.sender][nonce] = true;
    }

    // ===== MISSING FUNCTIONS IN V1 (should revert) =====

    /**
     * @notice Unwinds a position if the stop loss condition is met
     * @dev NOT IMPLEMENTED IN V1 - should revert
     */
    function stopLoss(
        ShivaStructs.StopLoss calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    ) external pure {
        revert("Function not implemented in V1");
    }

    /**
     * @notice Unwinds a position to take profit on behalf of an owner
     * @dev NOT IMPLEMENTED IN V1 - should revert
     */
    function takeProfit(
        ShivaStructs.TakeProfit calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    ) external pure {
        revert("Function not implemented in V1");
    }

    /**
     * @notice Builds a new limit order position on behalf of an owner
     * @dev NOT IMPLEMENTED IN V1 - should revert
     */
    function limitOrderBuild(
        ShivaStructs.LimitOrder calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    ) external pure returns (uint256) {
        revert("Function not implemented in V1");
    }

    /**
     * @notice Sets the keeper fee feed
     * @dev NOT IMPLEMENTED IN V1 - should revert
     */
    function setKeeperFeeFeed(address _feed) external pure {
        revert("Function not implemented in V1");
    }
}
