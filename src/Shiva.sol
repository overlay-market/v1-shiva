// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IShiva} from "./IShiva.sol";
import {
    IBerachainRewardsVault,
    IBerachainRewardsVaultFactory
} from "./interfaces/berachain/IRewardVaults.sol";
import {StakingToken} from "./PolStakingToken.sol";
import {ShivaStructs} from "./ShivaStructs.sol";
import {Utils} from "./utils/Utils.sol";

import {IOverlayV1Market} from "v1-core/contracts/interfaces/IOverlayV1Market.sol";
import {IOverlayMarketLiquidateCallback} from
    "v1-core/contracts/interfaces/callback/IOverlayMarketLiquidateCallback.sol";
import {IOverlayV1Factory} from "v1-core/contracts/interfaces/IOverlayV1Factory.sol";
import {
    IOverlayV1Token,
    GOVERNOR_ROLE,
    PAUSER_ROLE
} from "v1-core/contracts/interfaces/IOverlayV1Token.sol";
import {IOverlayV1State} from "v1-periphery/contracts/interfaces/IOverlayV1State.sol";
import {Risk} from "v1-core/contracts/libraries/Risk.sol";
import {Position} from "v1-core/contracts/libraries/Position.sol";
import {FixedPoint} from "v1-core/contracts/libraries/FixedPoint.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EIP712Upgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

/**
 * @title Shiva
 * @author Overlay team
 * @notice Contract for interact with OverlayV1 protocol
 * @notice This contract is used to build, unwind and manage positions in OverlayV1 markets
 * @notice Stakes and unstakes the collateral in the BerachainRewardsVault
 * @notice Can be used to build, unwind and manage positions on behalf of users with
 * signature verification
 * @dev This contract is upgradable by using UUPS pattern
 * @dev Uses EIP712 for signature verification
 * @dev This contract is pausable
 */
contract Shiva is
    IShiva,
    Initializable,
    UUPSUpgradeable,
    EIP712Upgradeable,
    IOverlayMarketLiquidateCallback,
    PausableUpgradeable
{
    using FixedPoint for uint256;
    using Position for Position.Info;
    using ECDSA for bytes32;

    uint256 public constant ONE = 1e18;

    /**
     * @notice Typehash for the BuildOnBehalfOfParams struct
     * @dev Used for EIP-712 encoding of the build on behalf of parameters
     */
    bytes32 public constant BUILD_ON_BEHALF_OF_TYPEHASH = keccak256(
        "BuildOnBehalfOfParams(IOverlayV1Market ovMarket,uint48 deadline,uint256 collateral,uint256 leverage,bool isLong,uint256 priceLimit,uint256 nonce)"
    );

    /**
     * @notice Typehash for the UnwindOnBehalfOfParams struct
     * @dev Used for EIP-712 encoding of the unwind on behalf of parameters
     */
    bytes32 public constant UNWIND_ON_BEHALF_OF_TYPEHASH = keccak256(
        "UnwindOnBehalfOfParams(IOverlayV1Market ovMarket,uint48 deadline,uint256 positionId,uint256 fraction,uint256 priceLimit,uint256 nonce)"
    );

    /**
     * @notice Typehash for the BuildSingleOnBehalfOf struct
     * @dev Used for EIP-712 encoding of the build single on behalf of parameters
     */
    bytes32 public constant BUILD_SINGLE_ON_BEHALF_OF_TYPEHASH = keccak256(
        "BuildSingleOnBehalfOf(address ovMarket,uint48 deadline,uint256 collateral,uint256 leverage,uint256 previousPositionId,uint256 nonce)"
    );

    /// @notice The Overlay V1 Token contract
    IOverlayV1Token public ovToken;

    /// @notice The Overlay V1 State contract
    IOverlayV1State public ovState;

    /// @notice The StakingToken contract
    StakingToken public stakingToken;

    /// @notice The BerachainRewardsVault contract
    IBerachainRewardsVault public rewardVault;

    /// @notice List of authorized factories
    IOverlayV1Factory[] public authorizedFactories;

    /**
     * @dev Mappings section
     */

    /// @notice Mapping from market and position ID to the address of the position owner
    mapping(IOverlayV1Market => mapping(uint256 => address)) public positionOwners;

    /// @notice Mapping to check if a market is allowed to spend OV on behalf of this contract
    mapping(IOverlayV1Market => bool) public marketAllowance;

    /// @notice Mapping from performer address to nonce
    mapping(address => uint256) public nonces;

    /// @notice Mapping to check if an address is a valid market
    mapping(address => bool) public validMarkets;

    /**
     * @dev Modifiers section
     */

    /**
     * @notice Ensures the caller has the governor role
     * @param _msgSender The address of the caller
     */
    modifier onlyGovernor(
        address _msgSender
    ) {
        require(ovToken.hasRole(GOVERNOR_ROLE, _msgSender), "Shiva: !governor");
        _;
    }

    /**
     * @notice Ensures the caller has the pauser role
     * @param _msgSender The address of the caller
     */
    modifier onlyPauser(
        address _msgSender
    ) {
        require(ovToken.hasRole(PAUSER_ROLE, _msgSender), "Shiva: !pauser");
        _;
    }

    /**
     * @notice Ensures the caller is the owner of the specified position
     * @param ovMarket The market of the position
     * @param positionId The ID of the position
     * @param owner The address of the owner
     */
    modifier onlyPositionOwner(IOverlayV1Market ovMarket, uint256 positionId, address owner) {
        if (positionOwners[ovMarket][positionId] != owner) {
            revert NotPositionOwner();
        }
        _;
    }

    /**
     * @notice Ensures the deadline has not expired
     * @param deadline The deadline timestamp
     */
    modifier validDeadline(
        uint48 deadline
    ) {
        if (block.timestamp > deadline) {
            revert ExpiredDeadline();
        }
        _;
    }

    /**
     * @notice Ensures the market is valid
     * @param market The market to check
     */
    modifier validMarket(
        IOverlayV1Market market
    ) {
        if (!_checkIsValidMarket(address(market))) {
            revert MarketNotValid();
        }
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the Shiva contract
     * @param _ovToken The address of the Overlay V1 Token contract
     * @param _ovState The address of the Overlay V1 State contract
     * @param _vaultFactory The address of the Berachain Rewards Vault Factory contract
     */
    function initialize(
        address _ovToken,
        address _ovState,
        address _vaultFactory
    ) external initializer {
        __EIP712_init("Shiva", "0.1.0");
        __Pausable_init();

        ovToken = IOverlayV1Token(_ovToken);
        ovState = IOverlayV1State(_ovState);

        // Create new staking token
        stakingToken = new StakingToken();

        // Create vault for newly created token
        address vaultAddress =
            IBerachainRewardsVaultFactory(_vaultFactory).createRewardsVault(address(stakingToken));

        rewardVault = IBerachainRewardsVault(vaultAddress);

        // Approve rewardVault to spend max amount of stakingToken
        stakingToken.approve(address(rewardVault), type(uint256).max);
    }

    /**
     * @notice Adds a new factory to the list of authorized factories
     * @param _factory The address of the factory to add
     */
    function addFactory(
        IOverlayV1Factory _factory
    ) external onlyGovernor(msg.sender) {
        authorizedFactories.push(_factory);

        emit FactoryAdded(address(_factory));
    }

    /**
     * @notice Removes a factory from the list of authorized factories
     * @param _factory The address of the factory to remove
     */
    function removeFactory(
        IOverlayV1Factory _factory
    ) external onlyGovernor(msg.sender) {
        for (uint256 i = 0; i < authorizedFactories.length; i++) {
            if (authorizedFactories[i] == _factory) {
                authorizedFactories[i] = authorizedFactories[authorizedFactories.length - 1];
                authorizedFactories.pop();

                emit FactoryRemoved(address(_factory));
                break;
            }
        }
    }

    /**
     * @notice Pauses the contract, preventing certain actions
     * @dev Only callable by an address with the pauser role
     */
    function pause() external onlyPauser(msg.sender) {
        _pause();
    }

    /**
     * @notice Unpauses the contract, allowing actions to be performed
     * @dev Only callable by an address with the pauser role
     */
    function unpause() external onlyPauser(msg.sender) {
        _unpause();
    }

    /**
     * @notice Builds a position in the ovMarket for a user
     * @param params The parameters for building the position based on the
     * ShivaStructs.Build struct
     * @return The ID of the newly created position
     * @dev Only callable when the contract is not paused and the market is valid
     */
    function build(
        ShivaStructs.Build calldata params
    ) external whenNotPaused validMarket(params.ovMarket) returns (uint256) {
        return _buildLogic(params, msg.sender);
    }

    /**
     * @notice Unwinds a position for the user
     * @param params The parameters for unwinding the position based on the
     * ShivaStructs.Unwind struct
     * @dev Only callable when the contract is not paused and the caller is the owner of
     * the position
     */
    function unwind(
        ShivaStructs.Unwind calldata params
    ) external whenNotPaused onlyPositionOwner(params.ovMarket, params.positionId, msg.sender) {
        _unwindLogic(params, msg.sender);
    }

    /**
     * @notice Builds and keeps a single position in the ovMarket for a user
     * @dev If the user already has a position in the ovMarket, it will be unwound before building
     * a new one and previous collateral and new collateral will be used to build the new position
     * @param params The parameters for building the single position based on the
     * ShivaStructs.BuildSingle struct
     * @return The ID of the newly created position
     */
    function buildSingle(
        ShivaStructs.BuildSingle calldata params
    )
        external
        whenNotPaused
        onlyPositionOwner(params.ovMarket, params.previousPositionId, msg.sender)
        returns (uint256)
    {
        return _buildSingleLogic(params, msg.sender);
    }

    /**
     * @notice Withdraws all the collateral from a position in a shutdown market
     * @param market The market of the position
     * @param positionId The ID of the position
     * @param owner The address of the owner
     */
    function emergencyWithdraw(
        IOverlayV1Market market,
        uint256 positionId,
        address owner
    ) external whenNotPaused onlyPositionOwner(market, positionId, owner) {
        _emergencyWithdrawLogic(market, positionId, owner);
    }

    /**
     * @notice Builds a position on behalf of a user (with signature verification)
     * @param params The parameters for building the position based on the
     * ShivaStructs.Build struct
     * @param onBehalfOf The parameters for building on behalf of a user based on the
     * ShivaStructs.OnBehalfOf struct
     * @return The ID of the newly created position
     */
    function build(
        ShivaStructs.Build calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    )
        external
        whenNotPaused
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

    /**
     * @notice Unwinds a position on behalf of a user (with signature verification)
     * @param params The parameters for unwinding the position based on the
     * ShivaStructs.Unwind struct
     * @param onBehalfOf The parameters for unwinding on behalf of a user based on the
     * ShivaStructs.OnBehalfOf struct
     * @dev Only callable when the contract is not paused, the deadline is valid, and the caller
     * is the owner of the position
     */
    function unwind(
        ShivaStructs.Unwind calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    )
        external
        whenNotPaused
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

    /**
     * @notice Builds and keeps a single position on behalf of a user (with signature verification)
     * @param params The parameters for building the single position based on the
     * ShivaStructs.BuildSingle struct
     * @param onBehalfOf The parameters for building on behalf of a user based on the
     * ShivaStructs.OnBehalfOf struct
     * @return The ID of the newly created position
     * @dev Only callable when the contract is not paused, the deadline is valid, and the
     * caller is the owner of the previous position
     */
    function buildSingle(
        ShivaStructs.BuildSingle calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    )
        external
        whenNotPaused
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

    /**
     * @notice Callback function for market liquidation
     * @param positionId The ID of the position to liquidate
     * @dev Only callable by a valid market
     */
    function overlayMarketLiquidateCallback(
        uint256 positionId
    ) external validMarket(IOverlayV1Market(msg.sender)) {
        IOverlayV1Market market = IOverlayV1Market(msg.sender);

        // Calculate remaining of initialNotional of the position to unwind
        uint256 intialNotional = Utils.getNotionalRemaining(market, positionId, address(this));
        // Unstake the remaining of the position
        _onUnstake(positionOwners[market][positionId], intialNotional);
    }

    /**
     * @notice Returns the digest of the typed data hash
     * @param structHash The hash of the struct
     * @return The digest of the typed data hash
     */
    function getDigest(
        bytes32 structHash
    ) external view returns (bytes32) {
        return _hashTypedDataV4(structHash);
    }

    /**
     * @notice Internal logic for building a position
     * @param _params The parameters for building the position
     * @param _owner The address of the owner
     * @return The ID of the newly created position
     */
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
            _params.priceLimit,
            _params.brokerId
        );
    }

    /**
     * @notice Internal logic for unwinding a position
     * @param _params The parameters for unwinding the position
     * @param _owner The address of the owner
     */
    function _unwindLogic(ShivaStructs.Unwind calldata _params, address _owner) internal {
        _onUnwindPosition(
            _params.ovMarket,
            _params.positionId,
            _params.fraction,
            _params.priceLimit,
            _params.brokerId
        );

        ovToken.transfer(_owner, ovToken.balanceOf(address(this)));
    }

    /**
     * @notice Internal logic for building and keeping a single position
     * @param _params The parameters for building the single position
     * @param _owner The address of the owner
     * @return positionId The ID of the newly created position
     */
    function _buildSingleLogic(
        ShivaStructs.BuildSingle calldata _params,
        address _owner
    ) internal returns (uint256 positionId) {
        require(_params.leverage >= ONE, "Shiva:lev<min");

        _onUnwindPosition(
            _params.ovMarket,
            _params.previousPositionId,
            ONE,
            _params.unwindPriceLimit,
            _params.brokerId
        );

        uint256 totalCollateral = _params.collateral + ovToken.balanceOf(address(this));
        uint256 tradingFee = _getTradingFee(_params.ovMarket, totalCollateral, _params.leverage);

        bool isLong = Utils.getPositionSide(_params.ovMarket, _params.previousPositionId, address(this));

        // transfer from OVL from user to this contract
        ovToken.transferFrom(_owner, address(this), _params.collateral + tradingFee);

        // Approve the ovMarket contract to spend OV
        _approveMarket(_params.ovMarket);

        positionId = _onBuildPosition(
            _owner,
            _params.ovMarket,
            totalCollateral,
            _params.leverage,
            isLong,
            _params.buildPriceLimit,
            _params.brokerId
        );
    }

    /**
     * @notice Internal logic for emergency withdrawal of collateral from a position
     * in a shutdown market
     * @param _market The market of the position
     * @param _positionId The ID of the position
     * @param _owner The address of the owner
     */
    function _emergencyWithdrawLogic(
        IOverlayV1Market _market,
        uint256 _positionId,
        address _owner
    ) internal {
        uint256 intialNotionalFraction =
            Utils.getNotionalRemaining(_market, _positionId, address(this));

        _market.emergencyWithdraw(_positionId);

        _onUnstake(positionOwners[_market][_positionId], intialNotionalFraction);

        ovToken.transfer(_owner, ovToken.balanceOf(address(this)));

        emit ShivaEmergencyWithdraw(_owner, address(_market), msg.sender, _positionId);
    }

    /**
     * @notice Internal logic for building a position
     * @param _owner The address of the owner
     * @param _market The market interface
     * @param _collateral The amount of collateral
     * @param _leverage The leverage applied
     * @param _isLong Indicates if the position is long
     * @param _priceLimit The price limit for the position
     * @param _brokerId The ID of the broker; 0 in most cases
     * @return positionId The ID of the newly created position
     */
    function _onBuildPosition(
        address _owner,
        IOverlayV1Market _market,
        uint256 _collateral,
        uint256 _leverage,
        bool _isLong,
        uint256 _priceLimit,
        uint32 _brokerId
    ) internal returns (uint256 positionId) {
        // calculate the notional of the position to build
        uint256 notional = _collateral.mulUp(_leverage);
        // Stake the collateral
        _onStake(_owner, notional);

        // Build position in the market
        positionId = _market.build(_collateral, _leverage, _isLong, _priceLimit);

        // Store position ownership
        positionOwners[_market][positionId] = _owner;

        emit ShivaBuild(
            _owner,
            address(_market),
            msg.sender,
            positionId,
            _collateral,
            _leverage,
            _brokerId,
            _isLong
        );
    }

    /**
     * @notice Internal logic for staking tokens
     * @param _owner The address of the owner
     * @param _amount The amount to stake
     */
    function _onStake(address _owner, uint256 _amount) internal {
        // Mint StakingTokens
        stakingToken.mint(address(this), _amount);
        // Stake tokens in RewardVault on behalf of user
        rewardVault.delegateStake(_owner, _amount);

        emit ShivaStake(_owner, _amount);
    }

    /**
     * @notice Internal logic for unwinding a position
     * @param _market The market interface
     * @param _positionId The ID of the position to unwind
     * @param _fraction The fraction of the position to unwind
     * @param _priceLimit The price limit for the unwind
     * @param _brokerId The ID of the broker; 0 in most cases
     */
    function _onUnwindPosition(
        IOverlayV1Market _market,
        uint256 _positionId,
        uint256 _fraction,
        uint256 _priceLimit,
        uint32 _brokerId
    ) internal {
        _fraction -= _fraction % 1e14;
        // Calculate fraction of initialNotional of the position to unwind
        uint256 intialNotionalFractionBefore =
            Utils.getNotionalRemaining(_market, _positionId, address(this));

        // Unwind position in the market
        _market.unwind(_positionId, _fraction, _priceLimit);

        // Unstake the fraction of the position
        uint256 intialNotionalFraction = intialNotionalFractionBefore
            - Utils.getNotionalRemaining(_market, _positionId, address(this));
        _onUnstake(positionOwners[_market][_positionId], intialNotionalFraction);

        emit ShivaUnwind(
            positionOwners[_market][_positionId],
            address(_market),
            msg.sender,
            _positionId,
            _fraction,
            _brokerId
        );
    }

    /**
     * @notice Internal logic for unstaking tokens
     * @param _owner The address of the owner
     * @param _amount The amount to unstake
     */
    function _onUnstake(address _owner, uint256 _amount) internal {
        // Withdraw tokens from the RewardVault
        rewardVault.delegateWithdraw(_owner, _amount);
        // Burn the withdrawn StakingTokens
        stakingToken.burn(address(this), _amount);

        emit ShivaUnstake(_owner, _amount);
    }

    /**
     * @notice Calculates the trading fee for a position
     * @param _ovMarket The market interface
     * @param _collateral The amount of collateral
     * @param _leverage The leverage applied
     * @return The trading fee
     */
    function _getTradingFee(
        IOverlayV1Market _ovMarket,
        uint256 _collateral,
        uint256 _leverage
    ) internal view returns (uint256) {
        uint256 notional = _collateral.mulUp(_leverage);
        return notional.mulUp(_ovMarket.params(uint256(Risk.Parameters.TradingFeeRate)));
    }

    /**
     * @notice Approves the market contract to spend OV tokens
     * @param _ovMarket The market interface
     */
    function _approveMarket(
        IOverlayV1Market _ovMarket
    ) internal {
        if (!marketAllowance[_ovMarket]) {
            ovToken.approve(address(_ovMarket), type(uint256).max);
            marketAllowance[_ovMarket] = true;
        }
    }

    /**
     * @notice Checks if the signature is valid
     * @param _structHash The hash of the struct
     * @param _signature The signature to verify
     * @param _owner The address of the owner
     * @dev Increments the nonce if the signature is valid
     */
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

    /**
     * @notice Checks if the market is valid
     * @param _market The address of the market
     * @return True if the market is valid, false otherwise
     */
    function _checkIsValidMarket(
        address _market
    ) internal returns (bool) {
        if (validMarkets[_market]) {
            return true;
        }

        for (uint256 i = 0; i < authorizedFactories.length; i++) {
            if (authorizedFactories[i].isMarket(_market)) {
                validMarkets[_market] = true;

                emit MarketValidated(_market);
                return true;
            }
        }

        return false;
    }

    /**
     * @notice Authorizes an upgrade to the contract
     * @dev Only callable by the governor
     */
    function _authorizeUpgrade(
        address
    ) internal override onlyGovernor(msg.sender) {}
}
