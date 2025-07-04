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
import {IOrderStore} from "./interfaces/shiva/IOrderStore.sol";
import {IOrderVault} from "./interfaces/shiva/IOrderVault.sol";
import {IKeeperHandler} from "./interfaces/shiva/IKeeperHandler.sol";

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
        "BuildOnBehalfOfParams(address ovlMarket,uint48 deadline,uint256 collateral,uint256 leverage,bool isLong,uint256 priceLimit,uint256 nonce,uint32 brokerId)"
    );

    /**
     * @notice Typehash for the UnwindOnBehalfOfParams struct
     * @dev Used for EIP-712 encoding of the unwind on behalf of parameters
     */
    bytes32 public constant UNWIND_ON_BEHALF_OF_TYPEHASH = keccak256(
        "UnwindOnBehalfOfParams(address ovlMarket,uint48 deadline,uint256 positionId,uint256 fraction,uint256 priceLimit,uint256 nonce,uint32 brokerId)"
    );

    /**
     * @notice Typehash for the BuildSingleOnBehalfOfParams struct
     * @dev Used for EIP-712 encoding of the build single on behalf of parameters
     */
    bytes32 public constant BUILD_SINGLE_ON_BEHALF_OF_TYPEHASH = keccak256(
        "BuildSingleOnBehalfOfParams(address ovlMarket,uint48 deadline,uint256 collateral,uint256 leverage,uint256 previousPositionId,uint256 unwindPriceLimit,uint256 buildPriceLimit,uint256 nonce,uint32 brokerId)"
    );

    /// @notice The Overlay V1 Token contract
    IOverlayV1Token public ovlToken;

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

    /// @notice Mapping to check if a market is allowed to spend OVL on behalf of this contract
    mapping(IOverlayV1Market => bool) public marketAllowance;

    /// @notice Mapping from performer address and nonce to boolean indicating if it's used
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    /// @notice Mapping to check if an address is a valid market
    mapping(address => bool) private validMarkets;

    /// @notice The OrderStore contract for advanced orders
    IOrderStore public orderStore;

    /// @notice The OrderVault contract for execution fees
    IOrderVault public orderVault;

    /// @notice The KeeperHandler contract for executing orders
    IKeeperHandler public keeperHandler;

    /**
     * @dev Modifiers section
     */

    /**
     * @notice Ensures the caller has the governor role
     * @param _msgSender The address of the caller
     */
    modifier onlyGovernor(address _msgSender) {
        require(ovlToken.hasRole(GOVERNOR_ROLE, _msgSender), "Shiva: !governor");
        _;
    }

    /**
     * @notice Ensures the caller has the pauser role
     * @param _msgSender The address of the caller
     */
    modifier onlyPauser(address _msgSender) {
        require(ovlToken.hasRole(PAUSER_ROLE, _msgSender), "Shiva: !pauser");
        _;
    }

    /**
     * @notice Ensures the caller is the authorized KeeperHandler contract.
     */
    modifier onlyKeeperHandler() {
        require(msg.sender == address(keeperHandler), "Shiva: not keeper handler");
        _;
    }

    /**
     * @notice Ensures the caller is the owner of the specified position
     * @param ovlMarket The market of the position
     * @param positionId The ID of the position
     * @param owner The address of the owner
     */
    modifier onlyPositionOwner(IOverlayV1Market ovlMarket, uint256 positionId, address owner) {
        if (positionOwners[ovlMarket][positionId] != owner) {
            revert NotPositionOwner();
        }
        _;
    }

    /**
     * @notice Ensures the deadline has not expired
     * @param deadline The deadline timestamp
     */
    modifier validDeadline(uint48 deadline) {
        if (block.timestamp > deadline) {
            revert ExpiredDeadline();
        }
        _;
    }

    /**
     * @notice Ensures the market is valid
     * @param market The market to check
     */
    modifier validMarket(IOverlayV1Market market) {
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
     * @param _ovlToken The address of the Overlay V1 Token contract
     * @param _vaultFactory The address of the Berachain Rewards Vault Factory contract
     * @param _orderStore The address of the OrderStore contract.
     * @param _orderVault The address of the OrderVault contract.
     * @param _keeperHandler The address of the KeeperHandler contract.
     */
    function initialize(
        address _ovlToken,
        address _vaultFactory,
        address _orderStore,
        address _orderVault,
        address _keeperHandler
    ) external initializer {
        __EIP712_init("Shiva", "0.1.0");
        __Pausable_init();

        ovlToken = IOverlayV1Token(_ovlToken);

        // Set advanced order contracts
        orderStore = IOrderStore(_orderStore);
        orderVault = IOrderVault(_orderVault);
        keeperHandler = IKeeperHandler(_keeperHandler);

        // Create new staking token
        stakingToken = new StakingToken();

        // Create vault for newly created token
        address vaultAddress =
            IBerachainRewardsVaultFactory(_vaultFactory).createRewardVault(address(stakingToken));

        rewardVault = IBerachainRewardsVault(vaultAddress);

        // Approve rewardVault to spend max amount of stakingToken
        stakingToken.approve(address(rewardVault), type(uint256).max);
    }

    /**
     * @notice Adds a new factory to the list of authorized factories
     * @param _factory The address of the factory to add
     */
    function addFactory(IOverlayV1Factory _factory) external onlyGovernor(msg.sender) {
        authorizedFactories.push(_factory);

        emit FactoryAdded(address(_factory));
    }

    /**
     * @notice Removes a factory from the list of authorized factories
     * @param _factory The address of the factory to remove
     */
    function removeFactory(IOverlayV1Factory _factory) external onlyGovernor(msg.sender) {
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
     * @notice Builds a position in the ovlMarket for a user
     * @param params The parameters for building the position based on the
     * ShivaStructs.Build struct
     * @return The ID of the newly created position
     * @dev Only callable when the contract is not paused and the market is valid
     */
    function build(ShivaStructs.Build calldata params)
        external
        whenNotPaused
        validMarket(params.ovlMarket)
        returns (uint256)
    {
        return _buildLogic(params, msg.sender);
    }

    /**
     * @notice Unwinds a position for the user
     * @param params The parameters for unwinding the position based on the
     * ShivaStructs.Unwind struct
     * @dev Only callable when the contract is not paused and the caller is the owner of
     * the position
     */
    function unwind(ShivaStructs.Unwind calldata params)
        external
        whenNotPaused
        onlyPositionOwner(params.ovlMarket, params.positionId, msg.sender)
    {
        _unwindLogic(params, msg.sender);
    }

    /**
     * @notice Builds and keeps a single position in the ovlMarket for a user
     * @dev If the user already has a position in the ovlMarket, it will be unwound before building
     * a new one and previous collateral and new collateral will be used to build the new position
     * @param params The parameters for building the single position based on the
     * ShivaStructs.BuildSingle struct
     * @return The ID of the newly created position
     */
    function buildSingle(ShivaStructs.BuildSingle calldata params)
        external
        whenNotPaused
        onlyPositionOwner(params.ovlMarket, params.previousPositionId, msg.sender)
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
        validMarket(params.ovlMarket)
        validDeadline(onBehalfOf.deadline)
        returns (uint256)
    {
        // build typed data hash
        bytes32 structHash = keccak256(
            abi.encode(
                BUILD_ON_BEHALF_OF_TYPEHASH,
                params.ovlMarket,
                onBehalfOf.deadline,
                params.collateral,
                params.leverage,
                params.isLong,
                params.priceLimit,
                onBehalfOf.nonce,
                params.brokerId
            )
        );
        _checkIsValidSignature(structHash, onBehalfOf.signature, onBehalfOf.owner, onBehalfOf.nonce);

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
        onlyPositionOwner(params.ovlMarket, params.positionId, onBehalfOf.owner)
    {
        // build typed data hash
        bytes32 structHash = keccak256(
            abi.encode(
                UNWIND_ON_BEHALF_OF_TYPEHASH,
                params.ovlMarket,
                onBehalfOf.deadline,
                params.positionId,
                params.fraction,
                params.priceLimit,
                onBehalfOf.nonce,
                params.brokerId
            )
        );
        _checkIsValidSignature(structHash, onBehalfOf.signature, onBehalfOf.owner, onBehalfOf.nonce);

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
        onlyPositionOwner(params.ovlMarket, params.previousPositionId, onBehalfOf.owner)
        returns (uint256)
    {
        // build typed data hash
        bytes32 structHash = _computeBuildSingleTypedDataHash(params, onBehalfOf);
        _checkIsValidSignature(structHash, onBehalfOf.signature, onBehalfOf.owner, onBehalfOf.nonce);

        return _buildSingleLogic(params, onBehalfOf.owner);
    }

    /**
     * @notice Callback function for market liquidation
     * @param positionId The ID of the position to liquidate
     * @dev Only callable by a valid market
     */
    function overlayMarketLiquidateCallback(uint256 positionId)
        external
        validMarket(IOverlayV1Market(msg.sender))
    {
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
    function getDigest(bytes32 structHash) external view returns (bytes32) {
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
        uint256 tradingFee = _getTradingFee(_params.ovlMarket, _params.collateral, _params.leverage);

        // Transfer OVL from user to this contract
        ovlToken.transferFrom(_owner, address(this), _params.collateral + tradingFee);

        // Approve the ovlMarket contract to spend OVL
        _approveMarket(_params.ovlMarket);

        return _onBuildPosition(
            _owner,
            _params.ovlMarket,
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
    function _unwindLogic(ShivaStructs.Unwind memory _params, address _owner) internal {
        _onUnwindPosition(
            _params.ovlMarket,
            _params.positionId,
            _params.fraction,
            _params.priceLimit,
            _params.brokerId
        );

        ovlToken.transfer(_owner, ovlToken.balanceOf(address(this)));
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

        // Track balance before unwinding
        uint256 balanceBefore = ovlToken.balanceOf(address(this));

        _onUnwindPosition(
            _params.ovlMarket,
            _params.previousPositionId,
            ONE,
            _params.unwindPriceLimit,
            _params.brokerId
        );

        // Calculate actual unwound amount
        uint256 unwindAmount = ovlToken.balanceOf(address(this)) - balanceBefore;
        uint256 totalCollateral = _params.collateral + unwindAmount;
        uint256 tradingFee = _getTradingFee(_params.ovlMarket, totalCollateral, _params.leverage);

        bool isLong =
            Utils.getPositionSide(_params.ovlMarket, _params.previousPositionId, address(this));

        // transfer OVL from user to this contract
        ovlToken.transferFrom(_owner, address(this), _params.collateral + tradingFee);

        // Approve the ovlMarket contract to spend OVL
        _approveMarket(_params.ovlMarket);

        positionId = _onBuildPosition(
            _owner,
            _params.ovlMarket,
            totalCollateral,
            _params.leverage,
            isLong,
            _params.buildPriceLimit,
            _params.brokerId
        );
    }

    /**
    * @dev Computes the struct hash for signature verification.
    */
    function _computeBuildSingleTypedDataHash(
        ShivaStructs.BuildSingle calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    ) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                BUILD_SINGLE_ON_BEHALF_OF_TYPEHASH,
                params.ovlMarket,
                onBehalfOf.deadline,
                params.collateral,
                params.leverage,
                params.previousPositionId,
                params.unwindPriceLimit,
                params.buildPriceLimit,
                onBehalfOf.nonce,
                params.brokerId
            )
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

        ovlToken.transfer(_owner, ovlToken.balanceOf(address(this)));

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
        // Get current balance on rewardVault
        uint256 currentBalance = rewardVault.balanceOf(_owner);
        // set _amount to min(currentBalance, _amount)
        _amount = currentBalance < _amount ? currentBalance : _amount;
        // Withdraw tokens from the RewardVault
        rewardVault.delegateWithdraw(_owner, _amount);
        // Burn the withdrawn StakingTokens
        stakingToken.burn(address(this), _amount);

        emit ShivaUnstake(_owner, _amount);
    }

    /**
     * @notice Calculates the trading fee for a position
     * @param _ovlMarket The market interface
     * @param _collateral The amount of collateral
     * @param _leverage The leverage applied
     * @return The trading fee
     */
    function _getTradingFee(
        IOverlayV1Market _ovlMarket,
        uint256 _collateral,
        uint256 _leverage
    ) internal view returns (uint256) {
        uint256 notional = _collateral.mulUp(_leverage);
        return notional.mulUp(_ovlMarket.params(uint256(Risk.Parameters.TradingFeeRate)));
    }

    /**
     * @notice Approves the market contract to spend OVL tokens
     * @param _ovlMarket The market interface
     */
    function _approveMarket(IOverlayV1Market _ovlMarket) internal {
        if (!marketAllowance[_ovlMarket]) {
            ovlToken.approve(address(_ovlMarket), type(uint256).max);
            marketAllowance[_ovlMarket] = true;
        }
    }

    /**
     * @notice Checks if the signature is valid and marks the nonce as used
     * @param _structHash The hash of the struct
     * @param _signature The signature to verify
     * @param _owner The address of the owner
     * @param _nonce The nonce used in the signature
     */
    function _checkIsValidSignature(
        bytes32 _structHash,
        bytes calldata _signature,
        address _owner,
        uint256 _nonce
    ) internal {
        bytes32 digest = _hashTypedDataV4(_structHash);
        address signer = digest.recover(_signature);

        if (signer != _owner) {
            revert InvalidSignature();
        }

        if (usedNonces[_owner][_nonce]) {
            revert InvalidNonce();
        }

        usedNonces[_owner][_nonce] = true;
    }

    /**
     * @notice Checks if the market is valid
     * @param _market The address of the market
     * @return True if the market is valid, false otherwise
     */
    function _checkIsValidMarket(address _market) internal returns (bool) {
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
    function _authorizeUpgrade(address) internal override onlyGovernor(msg.sender) {}

    /**
     * @notice Cancels a specific nonce for the caller
     * @param nonce The nonce to cancel
     */
    function cancelNonce(uint256 nonce) external {
        usedNonces[msg.sender][nonce] = true;
        emit NonceCancelled(msg.sender, nonce);
    }

    /**
     * @notice Creates a request for a limit order to open a new position.
     * @param params The parameters for the limit order.
     * @return requestId The unique ID of the order request.
     */
    function createLimitOrder(ShivaStructs.CreateLimitOrderParams calldata params)
        external
        whenNotPaused
        returns (uint256 requestId)
    {
        // 1. Transfer collateral and execution fee from the user to the vault.
        uint256 totalAmount = params.collateral + params.executionFee;
        ovlToken.transferFrom(msg.sender, address(orderVault), totalAmount);

        // 2. Create the request in the OrderStore
        requestId = orderStore.createRequest(
            ShivaStructs.CreateRequestParams({
                owner: msg.sender,
                orderType: ShivaStructs.OrderType.LIMIT_OPEN,
                market: params.market,
                positionId: 0, // Not applicable for LimitOpen
                collateral: params.collateral,
                leverage: params.leverage,
                isLong: params.isLong,
                fraction: 0, // Not applicable for LimitOpen
                triggerPrice: params.triggerPrice,
                slippageToleranceBps: params.slippageToleranceBps,
                executionFee: params.executionFee
            })
        );

        emit AdvancedOrderCreated(msg.sender, ShivaStructs.OrderType.LIMIT_OPEN, requestId);
    }

    /**
     * @notice Creates a request for a stop-loss order to close an existing position.
     * @param params The parameters for the stop-loss order.
     * @return requestId The unique ID of the order request.
     */
    function createStopLossOrder(ShivaStructs.CreateStopLossOrderParams calldata params)
        external
        whenNotPaused
        onlyPositionOwner(params.market, params.positionId, msg.sender)
        returns (uint256 requestId)
    {
        // 1. Transfer execution fee from the user to the vault.
        ovlToken.transferFrom(msg.sender, address(orderVault), params.executionFee);

        // 2. Create the request in the OrderStore
        requestId = orderStore.createRequest(
            ShivaStructs.CreateRequestParams({
                owner: msg.sender,
                orderType: ShivaStructs.OrderType.STOP_LOSS,
                market: params.market,
                positionId: params.positionId,
                collateral: 0, // Not applicable for StopLoss
                leverage: 0, // Not applicable for StopLoss
                isLong: false, // Not applicable for StopLoss
                fraction: params.fraction,
                triggerPrice: params.triggerPrice,
                slippageToleranceBps: params.slippageToleranceBps,
                executionFee: params.executionFee
            })
        );

        emit AdvancedOrderCreated(msg.sender, ShivaStructs.OrderType.STOP_LOSS, requestId);
    }

    /**
     * @notice Creates a request for a take-profit order to close an existing position.
     * @param params The parameters for the take-profit order.
     * @return requestId The unique ID of the order request.
     */
    function createTakeProfitOrder(ShivaStructs.CreateTakeProfitOrderParams calldata params)
        external
        whenNotPaused
        onlyPositionOwner(params.market, params.positionId, msg.sender)
        returns (uint256 requestId)
    {
        // 1. Transfer execution fee from the user to the vault.
        ovlToken.transferFrom(msg.sender, address(orderVault), params.executionFee);

        // 2. Create the request in the OrderStore
        requestId = orderStore.createRequest(
            ShivaStructs.CreateRequestParams({
                owner: msg.sender,
                orderType: ShivaStructs.OrderType.TAKE_PROFIT,
                market: params.market,
                positionId: params.positionId,
                collateral: 0, // Not applicable for TakeProfit
                leverage: 0, // Not applicable for TakeProfit
                isLong: false, // Not applicable for TakeProfit
                fraction: params.fraction,
                triggerPrice: params.triggerPrice,
                slippageToleranceBps: params.slippageToleranceBps,
                executionFee: params.executionFee
            })
        );

        emit AdvancedOrderCreated(msg.sender, ShivaStructs.OrderType.TAKE_PROFIT, requestId);
    }

    /**
     * @notice Cancels an advanced order that is currently in PENDING status.
     * @dev Can only be called by the owner of the order. Reverts if the order is not pending or not owned by the caller.
     *      Upon cancellation, the collateral (for limit orders) and execution fee are refunded to the user.
     * @param requestId The unique ID of the order request to cancel.
     */
    function cancelOrder(uint256 requestId) external {
        ShivaStructs.OrderRequest memory request = orderStore.getRequest(requestId);

        // 1. Validate ownership and status
        require(request.owner == msg.sender, "Shiva: not order owner");
        if (request.status != ShivaStructs.OrderStatus.PENDING) {
            revert InvalidOrderStatus(
                requestId,
                request.status,
                ShivaStructs.OrderStatus.PENDING
            );
        }

        // 2. Update status in the store
        orderStore.updateRequestStatus(requestId, ShivaStructs.OrderStatus.CANCELLED);

        // 3. Refund collateral and fees from the vault
        uint256 refundAmount = request.executionFee;
        if (request.orderType == ShivaStructs.OrderType.LIMIT_OPEN) {
            refundAmount += request.collateral;
        }
        orderVault.pay(msg.sender, refundAmount);

        emit AdvancedOrderCancelled(msg.sender, request.orderType, requestId);
    }

    /**
     * @notice Executes an advanced order (Limit, SL, TP) that has been previously created.
     * @dev This function is expected to be called only by the authorized KeeperHandler.
     *      It performs the final on-chain actions like building or unwinding a position.
     * @param requestId The unique ID of the order request to execute.
     */
    function executeAdvancedOrder(uint256 requestId) external onlyKeeperHandler {
        // 1. Fetch request from OrderStore.
        // The KeeperHandler has already verified that the status is PENDING.
        ShivaStructs.OrderRequest memory request = orderStore.getRequest(requestId);

        // 2. Dispatch to the appropriate internal execution function based on order type.
        if (request.orderType == ShivaStructs.OrderType.LIMIT_OPEN) {
            _executeLimitOpen(request);
        } else {
            // This covers both STOP_LOSS and TAKE_PROFIT orders.
            _executeStopLossOrTakeProfit(request);
        }

        // 3. Emit an event to log the successful execution.
        emit AdvancedOrderExecuted(request.owner, request.orderType, requestId);
    }

    /*********************************************************************************************
     *                                  INTERNAL EXECUTION LOGIC                                 *
     *********************************************************************************************/

    /**
     * @notice Internal logic for executing a limit open order.
     * @dev Calculates the appropriate price limit based on slippage and calls the internal build logic.
     * @param _request The order request data.
     */
    function _executeLimitOpen(ShivaStructs.OrderRequest memory _request) internal {
        // For a buy (long), we accept a higher price: trigger * (1 + slippage)
        // For a sell (short), we accept a lower price: trigger * (1 - slippage)
        uint256 priceLimit;
        uint256 slippageAmount =
            _request.triggerPrice.mulUp((_request.slippageToleranceBps * ONE) / 10000);

        if (_request.isLong) {
            priceLimit = _request.triggerPrice + slippageAmount;
        } else {
            priceLimit = _request.triggerPrice - slippageAmount;
        }

        // 1. Pull collateral from the vault into this contract
        orderVault.pay(address(this), _request.collateral);

        // 2. Approve market to spend the collateral
        _approveMarket(_request.market);

        // 3. Call internal build logic, which now assumes collateral is present
        _onBuildPosition(
            _request.owner,
            _request.market,
            _request.collateral,
            _request.leverage,
            _request.isLong,
            priceLimit,
            0 // brokerId
        );
    }

    /**
     * @notice Internal logic for executing a stop-loss or take-profit order.
     * @dev Calculates the appropriate price limit based on slippage and calls the internal unwind logic.
     * @param _request The order request data.
     */
    function _executeStopLossOrTakeProfit(ShivaStructs.OrderRequest memory _request) internal {
        // To close a long, we sell. We accept a price lower than trigger: priceLimit = trigger * (1 - slippage)
        // To close a short, we buy. We accept a price higher than trigger: priceLimit = trigger * (1 + slippage)
        bool isLong = Utils.getPositionSide(_request.market, _request.positionId, address(this));
        uint256 priceLimit;
        uint256 slippageAmount =
            _request.triggerPrice.mulUp((_request.slippageToleranceBps * ONE) / 10000);

        if (isLong) {
            priceLimit = _request.triggerPrice - slippageAmount;
        } else {
            priceLimit = _request.triggerPrice + slippageAmount;
        }

        // Use _unwindLogic which handles unwinding and transferring proceeds back to the owner.
        ShivaStructs.Unwind memory unwindParams = ShivaStructs.Unwind({
            ovlMarket: _request.market,
            positionId: _request.positionId,
            fraction: _request.fraction,
            priceLimit: priceLimit,
            brokerId: 0 // Not used in this context
        });

        // The owner of the request is the owner of the position
        _unwindLogic(unwindParams, _request.owner);
    }
}
