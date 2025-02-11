// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BaseSetup} from "@chimera/BaseSetup.sol";

import {Constants} from "./utils/Constants.sol";
import {Utils} from "src/utils/Utils.sol";
import {Shiva} from "src/Shiva.sol";
import {ShivaStructs} from "src/ShivaStructs.sol";
import {
    IBerachainRewardsVault,
    IBerachainRewardsVaultFactory
} from "src/interfaces/berachain/IRewardVaults.sol";

import {
    IOverlayV1Token,
    GOVERNOR_ROLE,
    PAUSER_ROLE,
    GUARDIAN_ROLE,
    MINTER_ROLE
} from "v1-core/contracts/interfaces/IOverlayV1Token.sol";
import {IOverlayV1Market} from "v1-core/contracts/interfaces/IOverlayV1Market.sol";
import {IOverlayV1Factory} from "v1-core/contracts/interfaces/IOverlayV1Factory.sol";
import {IOverlayV1State} from "v1-periphery/contracts/interfaces/IOverlayV1State.sol";
import {OverlayV1Token} from "v1-core/contracts/OverlayV1Token.sol";
import {OverlayV1Factory} from "v1-core/contracts/OverlayV1Factory.sol";
import {OverlayV1State} from "v1-periphery/contracts/OverlayV1State.sol";
import {MockSequencerOracle} from "./mocks/MockSequencerOracle.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {OverlayV1ChainlinkFeedFactory} from
    "v1-core/contracts/feeds/chainlink/OverlayV1ChainlinkFeedFactory.sol";
import {IOverlayV1ChainlinkFeed} from
    "v1-core/contracts/interfaces/feeds/chainlink/IOverlayV1ChainlinkFeed.sol";

/**
 * @title ShivaTestBase
 * @dev Base contract for Shiva tests, inherits from the Test contract.
 */
contract ShivaTestBase is Test, BaseSetup {
    using ECDSA for bytes32;

    /// @notice Represents one unit in the system (1e18)
    uint256 constant ONE = 1e18;

    /// @notice Basic slippage percentage (1%)
    uint16 constant BASIC_SLIPPAGE = 100;

    /// @notice For testing purposes we use fixed nonce
    uint16 constant FIXED_NONCE = 12345;

    /// @notice Broker ID used in the system
    uint32 constant BROKER_ID = 0;

    /**
     * @notice Shiva test contracts
     */
    Shiva shiva;
    IOverlayV1Market ovlMarket;
    IOverlayV1Market otherOvlMarket;
    IOverlayV1State ovlState;
    OverlayV1Factory ovlFactory;
    IOverlayV1Token ovlToken;
    IBerachainRewardsVault rewardVault;

    MockSequencerOracle sequencerOracle;
    MockAggregator aggregator;
    OverlayV1ChainlinkFeedFactory feedFactory;
    IOverlayV1ChainlinkFeed feed;

    /**
     * @notice Test addresses
     */
    address alice;
    address bob;
    address charlie;
    address automator;
    address guardian;
    address pauser;
    address deployer = Constants.getDeployerAddress();

    /**
     * @notice Test private keys
     */
    uint256 alicePk = 0x123;
    uint256 bobPk = 0x456;
    uint256 charliePk = 0x789;

    /**
     * @notice OVL token symbol differs between fork instance and local
     */
    bool isOV = true;

    function setup() internal virtual override {
        /**
         * MAINNET FORKING SETUP
         *     // Creates a fork of the blockchain using the specified RPC and block number
         *     vm.createSelectFork(vm.envString(Constants.getForkedNetworkRPC()), Constants.getForkBlock());
         *
         *     // Initialize contract instances
         *     ovlToken = IOverlayV1Token(Constants.getOVLTokenAddress());
         *     ovlMarket = IOverlayV1Market(Constants.getETHDominanceMarketAddress());
         *     otherOvlMarket = IOverlayV1Market(Constants.getBTCDominanceMarketAddress());
         *     ovlState = IOverlayV1State(Constants.getOVLStateAddress());
         *     ovlFactory = OverlayV1Factory(ovlMarket.factory());
         *
         *     // Grant roles to specified addresses
         *     vm.startPrank(Constants.getDeployerAddress());
         *     ovlToken.grantRole(GOVERNOR_ROLE, Constants.getGovernorAddress());
         *     ovlToken.grantRole(PAUSER_ROLE, Constants.getPauserAddress());
         *     ovlToken.grantRole(GUARDIAN_ROLE, Constants.getGuardianAddress());
         *     vm.stopPrank();
         *
         *     // Set Vault Factory
         *     IBerachainRewardsVaultFactory vaultFactory =
         *         IBerachainRewardsVaultFactory(Constants.getVaultFactoryAddress());
         *
         *     // Deploy Shiva contract using ERC1967Proxy pattern and initialize it with necessary parameters
         *     Shiva shivaImplementation = new Shiva();
         *     string memory functionName = "initialize(address,address)";
         *     bytes memory data =
         *         abi.encodeWithSignature(functionName, address(ovlToken), address(vaultFactory));
         *
         *     // Set up shiva contract and reward vault
         *     shiva = Shiva(address(new ERC1967Proxy(address(shivaImplementation), data)));
         *     rewardVault = shiva.rewardVault();
         */

        /**
         * MAINNET FORKING SETUP
         */
        vm.createSelectFork(
            vm.envString(Constants.getForkedMainnetNetworkRPC()), Constants.getForkMainnetBlock()
        );

        // Deploy the contracts
        vm.startPrank(deployer);
        ovlToken = deployToken();

        // Deploy aggregator
        aggregator = deployAggregator();

        // Deploy feed factory and feed
        feedFactory = new OverlayV1ChainlinkFeedFactory(
            address(ovlToken),
            600, // microWindow (10 minutes)
            3600 // macroWindow (1 hour)
        );
        feed = IOverlayV1ChainlinkFeed(
            feedFactory.deployFeed(address(aggregator), 172800) // 2 days window
        );

        // Deploy factory
        ovlFactory = deployFactory();

        ovlState = deployPeriphery(ovlFactory);
        ovlMarket = deployMarket(ovlFactory, address(feed));
        otherOvlMarket = deployMarket(
            ovlFactory,
            address(
                feedFactory.deployFeed(address(deployAggregator()), 172800) // 2 days window
            )
        );

        // Set Vault Factory
        IBerachainRewardsVaultFactory vaultFactory =
            IBerachainRewardsVaultFactory(Constants.getMainnetVaultFactoryAddress());

        // Deploy Shiva contract using ERC1967Proxy pattern and initialize it with necessary parameters
        Shiva shivaImplementation = new Shiva();
        string memory functionName = "initialize(address,address)";
        bytes memory data =
            abi.encodeWithSignature(functionName, address(ovlToken), address(vaultFactory));

        // Set up shiva contract and reward vault
        shiva = Shiva(address(new ERC1967Proxy(address(shivaImplementation), data)));
        rewardVault = shiva.rewardVault();

        vm.stopPrank();

        // Change the token name
        isOV = false;

        // Set up test addresses
        alice = vm.addr(alicePk);
        bob = vm.addr(bobPk);
        charlie = vm.addr(charliePk);
        automator = makeAddr("automator");
        guardian = Constants.getGuardianAddress();
        pauser = Constants.getPauserAddress();

        // Call helper functions
        labelAddresses();
        setInitialBalancesAndApprovals();
        addAuthorizedFactory();
    }

    /**
     * @dev Sets up the initial state for the ShivaBase test contract.
     */
    function setUp() public virtual {
        setup();
    }

    /**
     * @dev Labels the addresses for easier identification in logs and traces.
     */
    function labelAddresses() internal {
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(charlie, "Charlie");
        vm.label(automator, "Automator");
        vm.label(guardian, "Guardian");
        vm.label(pauser, "Pauser");
        vm.label(address(ovlMarket), "Market");
        vm.label(address(shiva), "Shiva");
        vm.label(address(ovlToken), "OVL");
    }

    /**
     * @dev Sets initial token balances and approvals for Alice and Bob.
     */
    function setInitialBalancesAndApprovals() internal {
        // Deal tokens and set approvals
        deal(address(ovlToken), alice, 1000e18);
        deal(address(ovlToken), bob, 100000e18);
        approveToken(alice);
        approveToken(bob);
    }

    /**
     * @dev Deploys a new OverlayV1Token contract and returns its interface.
     * @return ovlToken_ The deployed OverlayV1Token contract.
     */
    function deployToken() public returns (IOverlayV1Token ovlToken_) {
        OverlayV1Token ovlToken = new OverlayV1Token();

        ovlToken.grantRole(GOVERNOR_ROLE, deployer);
        ovlToken.grantRole(GUARDIAN_ROLE, deployer);
        ovlToken.grantRole(PAUSER_ROLE, deployer);
        ovlToken.grantRole(0x00, deployer); // DEFAULT_ADMIN_ROLE

        ovlToken_ = IOverlayV1Token(address(ovlToken));
    }

    /**
     * @dev Deploys a new OverlayV1Factory contract and returns its interface.
     * @return factory_ The deployed OverlayV1Factory contract.
     */
    function deployFactory() public returns (OverlayV1Factory factory_) {
        // Deploy MockSequencerOracle
        sequencerOracle = new MockSequencerOracle();

        factory_ = new OverlayV1Factory(
            address(ovlToken),
            address(this), // fee recipient
            address(sequencerOracle),
            3600
        );

        // Grant factory admin role so that it can grant minter + burner roles to markets
        ovlToken.grantRole(0x00, address(factory_)); // DEFAULT_ADMIN_ROLE

        factory_.addFeedFactory(address(feedFactory));
    }

    /**
     * @dev Deploys a new OverlayV1Market contract and returns its interface.
     * @param _factory The OverlayV1Factory contract to be used for deploying the market.
     * @param _feed The address of the feed to be used by the market.
     * @return ovlMarket_ The deployed OverlayV1Market contract.
     */
    function deployMarket(
        IOverlayV1Factory _factory,
        address _feed
    ) public returns (IOverlayV1Market ovlMarket_) {
        uint256[15] memory MARKET_PARAMS = [
            uint256(122000000000), // k
            500000000000000000, // lmbda
            2500000000000000, // delta
            5000000000000000000, // capPayoff
            8e23, // capNotional
            5000000000000000000, // capLeverage
            2592000, // circuitBreakerWindow
            66670000000000000000000, // circuitBreakerMintTarget
            100000000000000000, // maintenanceMargin
            100000000000000000, // maintenanceMarginBurnRate
            50000000000000000, // liquidationFeeRate
            750000000000000, // tradingFeeRate
            1e14, // minCollateral
            25000000000000, // priceDriftUpperLimit
            250 // averageBlockTime
        ];
        ovlMarket_ =
            IOverlayV1Market(_factory.deployMarket(address(feedFactory), _feed, MARKET_PARAMS));
    }

    /**
     * @dev Deploys a new OverlayV1State contract and returns its interface.
     * @param _factory The OverlayV1Factory contract to be used by the state.
     * @return ovlState_ The deployed OverlayV1State contract.
     */
    function deployPeriphery(
        IOverlayV1Factory _factory
    ) public returns (IOverlayV1State ovlState_) {
        ovlState_ = new OverlayV1State(_factory);
    }

    /**
     * @dev Deploys a new MockAggregator contract and returns its interface.
     * @return aggregator_ The deployed MockAggregator contract.
     */
    function deployAggregator() public returns (MockAggregator aggregator_) {
        // Deploy MockAggregator with initial price
        aggregator_ = new MockAggregator();

        // Set up initial rounds of price data
        vm.warp(block.timestamp + 60 * 60);
        aggregator_.submit(2, 979701714); // ~$9.79 with 8 decimals
        vm.warp(block.timestamp + 60 * 60);
        aggregator_.submit(3, 979701714);
        vm.warp(block.timestamp + 60 * 60);
        aggregator_.submit(4, 979701714);
    }

    /**
     * @dev Adds an authorized factory to the Shiva contract.
     */
    function addAuthorizedFactory() internal {
        vm.startPrank(guardian);
        shiva.addFactory(IOverlayV1Factory(address(ovlFactory)));
        vm.stopPrank();
    }

    /**
     * @dev Removes an authorized factory from the Shiva contract.
     */
    function removeAuthorizedFactory() internal {
        vm.startPrank(guardian);
        shiva.removeFactory(IOverlayV1Factory(address(ovlFactory)));
        vm.stopPrank();
    }

    /**
     * @dev Pauses the Shiva contract.
     */
    function pauseShiva() internal {
        vm.startPrank(pauser);
        shiva.pause();
        vm.stopPrank();
    }

    /**
     * @dev Unpauses the Shiva contract.
     */
    function unpauseShiva() internal {
        vm.startPrank(pauser);
        shiva.unpause();
        vm.stopPrank();
    }

    /**
     * @dev Approves the Shiva contract to spend the maximum amount of tokens on behalf of the user.
     * @param user The address of the user who is approving the token transfer.
     */
    function approveToken(
        address user
    ) internal {
        vm.prank(user);
        ovlToken.approve(address(shiva), type(uint256).max);
    }

    /**
     * @dev Shuts down the OverlayV1Market contract.
     * Ensures that the market is properly shut down by the guardian.
     */
    function shutDownMarket() internal {
        vm.startPrank(guardian);
        ovlFactory.shutdown(ovlMarket.feed());
        vm.stopPrank();
        assertEq(ovlMarket.isShutdown(), true, "Market should be shutdown");
    }

    /**
     * @dev Utility functions for the ShivaBase contract.
     *
     * This section contains helper functions that assist with various
     * operations within the ShivaBase contract. These functions are
     * designed to be reusable and provide common functionality needed
     * throughout the contract.
     */

    /**
     * @dev Builds a new position in the market.
     * @param collateral The amount of collateral to be used.
     * @param leverage The leverage to be applied.
     * @param slippage The acceptable slippage for the position.
     * @param isLong Whether the position is long or short.
     * @return The ID of the newly created position.
     */
    function buildPosition(
        uint256 collateral,
        uint256 leverage,
        uint16 slippage,
        bool isLong
    ) public returns (uint256) {
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovlState, ovlMarket, collateral, leverage, slippage, isLong);
        return shiva.build(
            ShivaStructs.Build(ovlMarket, BROKER_ID, isLong, collateral, leverage, priceLimit)
        );
    }

    /**
     * @dev Unwinds an existing position in the market.
     * @param posId The ID of the position to be unwound.
     * @param fraction The fraction of the position to be unwound.
     * @param slippage The acceptable slippage for the unwind.
     */
    function unwindPosition(uint256 posId, uint256 fraction, uint16 slippage) public {
        uint256 priceLimit =
            Utils.getUnwindPrice(ovlState, ovlMarket, posId, address(shiva), fraction, slippage);
        shiva.unwind(ShivaStructs.Unwind(ovlMarket, BROKER_ID, posId, fraction, priceLimit));
    }

    /**
     * @dev Builds a single position in the market.
     * @param collateral The amount of collateral to be used.
     * @param leverage The leverage to be applied.
     * @param posId1 The ID of the first position.
     * @param unwindPriceLimit The price limit for the unwind.
     * @param buildPriceLimit The price limit for the position.
     * @return The ID of the newly created position.
     */
    function buildSinglePosition(
        uint256 collateral,
        uint256 leverage,
        uint256 posId1,
        uint256 unwindPriceLimit,
        uint256 buildPriceLimit
    ) public returns (uint256) {
        return shiva.buildSingle(
            ShivaStructs.BuildSingle(
                ovlMarket,
                BROKER_ID,
                unwindPriceLimit,
                buildPriceLimit,
                collateral,
                leverage,
                posId1
            )
        );
    }

    /**
     * @dev Gets the digest for building a position on behalf of another user.
     * @param collateral The amount of collateral to be used.
     * @param leverage The leverage to be applied.
     * @param priceLimit The price limit for the position.
     * @param nonce The nonce for the transaction.
     * @param deadline The deadline for the transaction.
     * @param isLong Whether the position is long or short.
     * @return The digest for the build on behalf of transaction.
     */
    function getBuildOnBehalfOfDigest(
        uint256 collateral,
        uint256 leverage,
        uint256 priceLimit,
        uint256 nonce,
        uint48 deadline,
        bool isLong,
        uint32 brokerId
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                shiva.BUILD_ON_BEHALF_OF_TYPEHASH(),
                ovlMarket,
                deadline,
                collateral,
                leverage,
                isLong,
                priceLimit,
                nonce,
                brokerId
            )
        );
        return shiva.getDigest(structHash);
    }

    /**
     * @dev Gets the digest for unwinding a position on behalf of another user.
     * @param posId The ID of the position to be unwound.
     * @param fraction The fraction of the position to be unwound.
     * @param priceLimit The price limit for the unwind.
     * @param nonce The nonce for the transaction.
     * @param deadline The deadline for the transaction.
     * @return The digest for the unwind on behalf of transaction.
     */
    function getUnwindOnBehalfOfDigest(
        uint256 posId,
        uint256 fraction,
        uint256 priceLimit,
        uint256 nonce,
        uint48 deadline,
        uint32 brokerId
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                shiva.UNWIND_ON_BEHALF_OF_TYPEHASH(),
                ovlMarket,
                deadline,
                posId,
                fraction,
                priceLimit,
                nonce,
                brokerId
            )
        );
        return shiva.getDigest(structHash);
    }

    /**
     * @dev Gets the digest for building a single position on behalf of another user.
     * @param collateral The amount of collateral to be used.
     * @param leverage The leverage to be applied.
     * @param previousPositionId The ID of the previous position.
     * @param nonce The nonce for the transaction.
     * @param deadline The deadline for the transaction.
     * @return The digest for the build single on behalf of transaction.
     */
    function getBuildSingleOnBehalfOfDigest(
        uint256 collateral,
        uint256 leverage,
        uint256 previousPositionId,
        uint256 nonce,
        uint256 unwindPriceLimit,
        uint256 buildPriceLimit,
        uint48 deadline,
        uint32 brokerId
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                shiva.BUILD_SINGLE_ON_BEHALF_OF_TYPEHASH(),
                ovlMarket,
                deadline,
                collateral,
                leverage,
                previousPositionId,
                unwindPriceLimit,
                buildPriceLimit,
                nonce,
                brokerId
            )
        );
        return shiva.getDigest(structHash);
    }

    /**
     * @dev Gets the signature for a given digest using the user's private key.
     * @param digest The digest to be signed.
     * @param userPk The private key of the user.
     * @return The signature for the given digest.
     */
    function getSignature(bytes32 digest, uint256 userPk) public pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        return abi.encodePacked(r, s, v);
    }

    /**
     * @dev Builds a new position in the market on behalf of another user.
     * @param collateral The amount of collateral to be used.
     * @param leverage The leverage to be applied.
     * @param priceLimit The price limit for the position.
     * @param deadline The deadline for the transaction.
     * @param isLong Whether the position is long or short.
     * @param signature The signature of the owner authorizing the transaction.
     * @param owner The address of the owner on whose behalf the position is being built.
     * @return The ID of the newly created position.
     */
    function buildPositionOnBehalfOf(
        uint256 collateral,
        uint256 leverage,
        uint256 priceLimit,
        uint48 deadline,
        bool isLong,
        bytes memory signature,
        address owner
    ) public returns (uint256) {
        return shiva.build(
            ShivaStructs.Build(ovlMarket, BROKER_ID, isLong, collateral, leverage, priceLimit),
            ShivaStructs.OnBehalfOf(owner, deadline, FIXED_NONCE, signature)
        );
    }

    /**
     * @dev Unwinds an existing position in the market on behalf of another user.
     * @param positionId The ID of the position to be unwound.
     * @param fraction The fraction of the position to be unwound.
     * @param priceLimit The price limit for the unwind.
     * @param deadline The deadline for the transaction.
     * @param signature The signature of the owner authorizing the transaction.
     * @param owner The address of the owner on whose behalf the position is being unwound.
     */
    function unwindPositionOnBehalfOf(
        uint256 positionId,
        uint256 fraction,
        uint256 priceLimit,
        uint48 deadline,
        bytes memory signature,
        address owner
    ) public {
        shiva.unwind(
            ShivaStructs.Unwind(ovlMarket, BROKER_ID, positionId, fraction, priceLimit),
            ShivaStructs.OnBehalfOf(owner, deadline, FIXED_NONCE, signature)
        );
    }

    /**
     * @dev Builds a single position in the market on behalf of another user.
     * @param collateral The amount of collateral to be used.
     * @param leverage The leverage to be applied.
     * @param previousPositionId The ID of the previous position.
     * @param unwindPriceLimit The price limit for the unwind.
     * @param buildPriceLimit The price limit for the position.
     * @param deadline The deadline for the transaction.
     * @param signature The signature of the owner authorizing the transaction.
     * @param owner The address of the owner on whose behalf the position is being built.
     * @return The ID of the newly created position.
     */
    function buildSinglePositionOnBehalfOf(
        uint256 collateral,
        uint256 leverage,
        uint256 previousPositionId,
        uint256 unwindPriceLimit,
        uint256 buildPriceLimit,
        uint48 deadline,
        bytes memory signature,
        address owner
    ) public returns (uint256) {
        return shiva.buildSingle(
            ShivaStructs.BuildSingle(
                ovlMarket,
                BROKER_ID,
                unwindPriceLimit,
                buildPriceLimit,
                collateral,
                leverage,
                previousPositionId
            ),
            ShivaStructs.OnBehalfOf(owner, deadline, FIXED_NONCE, signature)
        );
    }

    /**
     * @dev Assertion functions
     * This section contains assertion functions that are used to validate
     * the state of the system during testing.
     */

    /**
     * @dev Asserts that the fraction remaining of a position is zero.
     * @param user The address of the user.
     * @param posId The ID of the position.
     */
    function assertFractionRemainingIsZero(address user, uint256 posId) public view {
        (,,,,,,, uint16 fractionRemaining) =
            ovlMarket.positions(keccak256(abi.encodePacked(user, posId)));
        assertEq(fractionRemaining, 0);
    }

    /**
     * @dev Asserts that the fraction remaining of a position is greater than zero.
     * @param user The address of the user.
     * @param posId The ID of the position.
     */
    function assertFractionRemainingIsGreaterThanZero(address user, uint256 posId) public view {
        (,,,,,,, uint16 fractionRemaining) =
            ovlMarket.positions(keccak256(abi.encodePacked(user, posId)));
        assertGt(fractionRemaining, 0);
    }

    /**
     * @dev Asserts that the fraction remaining of a position matches the expected value.
     * @param user The address of the user.
     * @param posId The ID of the position.
     * @param expected The expected fraction remaining.
     */
    function assertFractionRemaining(address user, uint256 posId, uint16 expected) public view {
        (,,,,,,, uint16 fractionRemaining) =
            ovlMarket.positions(keccak256(abi.encodePacked(user, posId)));
        assertEq(fractionRemaining, expected);
    }

    /**
     * @dev Asserts that the OVLToken balance of a user is zero.
     * @param user The address of the user.
     */
    function assertOVLTokenBalanceIsZero(
        address user
    ) public view {
        assertEq(ovlToken.balanceOf(user), 0);
    }

    /**
     * @dev Asserts that a user is the owner of a position in the Shiva contract.
     * @param user The address of the user.
     * @param posId The ID of the position.
     */
    function assertUserIsPositionOwnerInShiva(address user, uint256 posId) public view {
        assertEq(shiva.positionOwners(ovlMarket, posId), user);
    }
}
