// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Shiva} from "src/Shiva.sol";
import {IOverlayV1Token, GOVERNOR_ROLE, PAUSER_ROLE, GUARDIAN_ROLE, MINTER_ROLE} from "v1-periphery/lib/v1-core/contracts/interfaces/IOverlayV1Token.sol";
import {IOverlayV1Market} from "v1-periphery/lib/v1-core/contracts/interfaces/IOverlayV1Market.sol";
import {IOverlayV1Factory} from "v1-periphery/lib/v1-core/contracts/interfaces/IOverlayV1Factory.sol";
import {IOverlayV1State} from "v1-periphery/contracts/interfaces/IOverlayV1State.sol";
import {OverlayV1Token} from "v1-periphery/lib/v1-core/contracts/OverlayV1Token.sol";
import {OverlayV1State} from "v1-periphery/contracts/OverlayV1State.sol";
import {Constants} from "./utils/Constants.sol";
import {Utils} from "src/utils/Utils.sol";
import {OverlayV1Factory} from "v1-periphery/lib/v1-core/contracts/OverlayV1Factory.sol";
import {Risk} from "v1-periphery/lib/v1-core/contracts/libraries/Risk.sol";
import {ShivaStructs} from "src/ShivaStructs.sol";
import {IBerachainRewardsVault, IBerachainRewardsVaultFactory} from "../src/interfaces/berachain/IRewardVaults.sol";

contract ShivaTestBase is Test {
    using ECDSA for bytes32;

    uint256 constant ONE = 1e18;
    uint16 constant BASIC_SLIPPAGE = 100; // 1%

    Shiva shiva;
    IOverlayV1Market ovMarket;
    IOverlayV1State ovState;
    OverlayV1Factory ovFactory;
    IOverlayV1Token ovToken;
    IBerachainRewardsVault public rewardVault;

    address alice;
    address bob;
    address charlie;
    address automator;
    address guardian;
    address deployer = Constants.getDeployerAddress();

    uint256 alicePk = 0x123;
    uint256 bobPk = 0x456;
    uint256 charliePk = 0x789;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString(Constants.getForkedNetworkRPC()), Constants.getForkBlock());

        ovToken = IOverlayV1Token(Constants.getOVTokenAddress());
        ovMarket = IOverlayV1Market(Constants.getETHDominanceMarketAddress());
        ovState = IOverlayV1State(Constants.getOVStateAddress());
        ovFactory = OverlayV1Factory(ovMarket.factory());

        vm.startPrank(Constants.getDeployerAddress());
        ovToken.grantRole(GOVERNOR_ROLE, Constants.getGovernorAddress());
        ovToken.grantRole(PAUSER_ROLE, Constants.getPauserAddress());
        ovToken.grantRole(GUARDIAN_ROLE, Constants.getGuardianAddress());
        vm.stopPrank();

        IBerachainRewardsVaultFactory vaultFactory = IBerachainRewardsVaultFactory(
            0x2B6e40f65D82A0cB98795bC7587a71bfa49fBB2B
        );
        shiva = new Shiva();
        shiva.initialize(address(ovToken), address(ovState), address(vaultFactory));
        rewardVault = shiva.rewardVault();

        alice = vm.addr(alicePk);
        bob = vm.addr(bobPk);
        charlie = vm.addr(charliePk);
        automator = makeAddr("automator");
        guardian = Constants.getGuardianAddress();

        labelAddresses();
        setInitialBalancesAndApprovals();
        addAuthorizedFactory();
    }

    function labelAddresses() internal {
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(charlie, "Charlie");
        vm.label(automator, "Automator");
        vm.label(guardian, "Guardian");
        vm.label(address(ovMarket), "Market");
        vm.label(address(shiva), "Shiva");
        vm.label(address(ovToken), "OVL");
    }

    function setInitialBalancesAndApprovals() internal {
        // Deal tokens and set approvals
        deal(address(ovToken), alice, 1000e18);
        deal(address(ovToken), bob, 1000e18);
        approveToken(alice);
        approveToken(bob);
    }

    function deployToken() public returns (IOverlayV1Token ovToken_) {
        OverlayV1Token ovToken = new OverlayV1Token();
        ovToken_ = IOverlayV1Token(address(ovToken));
    }

    function deployFactory(IOverlayV1Token _ovToken) public returns (OverlayV1Factory factory_) {
        factory_ = new OverlayV1Factory(
            address(_ovToken),
            deployer,
            Constants.getSequencer(),
            1 hours
        );

        // 3. Grant factory admin role so that it can grant minter + burner roles to markets
        _ovToken.grantRole(0x00, address(factory_)); // admin role = 0x00
        _ovToken.grantRole(MINTER_ROLE, deployer);
        _ovToken.grantRole(GOVERNOR_ROLE, deployer);
        _ovToken.grantRole(GUARDIAN_ROLE, deployer);
        _ovToken.grantRole(PAUSER_ROLE, deployer);

        factory_.addFeedFactory(Constants.getFeedFactory());
    }

    function deployMarket(IOverlayV1Factory _factory, address _feed) public returns (IOverlayV1Market ovMarket_) {
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
        ovMarket_ = IOverlayV1Market(_factory.deployMarket(Constants.getFeedFactory(), _feed, MARKET_PARAMS));
    }

    function deployPeriphery(IOverlayV1Factory _factory) public returns (IOverlayV1State ovState_) {
        ovState_ = new OverlayV1State(_factory);
    }

    function addAuthorizedFactory() internal {
        IOverlayV1Factory factory = IOverlayV1Factory(Constants.getFactoryAddress());
        vm.startPrank(guardian);
        shiva.addFactory(factory);
        vm.stopPrank();
    }

    function removeAuthorizedFactory() internal {
        IOverlayV1Factory factory = IOverlayV1Factory(Constants.getFactoryAddress());
        vm.startPrank(guardian);
        shiva.removeFactory(factory);
        vm.stopPrank();
    }

    function approveToken(
        address user
    ) internal {
        vm.prank(user);
        ovToken.approve(address(shiva), type(uint256).max);
    }

    function shutDownMarket() internal {
        vm.startPrank(guardian);
        ovFactory.shutdown(ovMarket.feed());
        vm.stopPrank();
        assertEq(ovMarket.isShutdown(), true, "Market should be shutdown");
    }

    /**
     * Utility functions
     */
    function buildPosition(
        uint256 collateral,
        uint256 leverage,
        uint16 slippage,
        bool isLong
    ) public returns (uint256) {
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovState, ovMarket, collateral, leverage, slippage, isLong);
        return shiva.build(ShivaStructs.Build(ovMarket, isLong, collateral, leverage, priceLimit));
    }

    function unwindPosition(uint256 posId, uint256 fraction, uint16 slippage) public {
        (uint256 priceLimit,) =
            Utils.getUnwindPrice(ovState, ovMarket, posId, address(shiva), fraction, slippage);
        shiva.unwind(ShivaStructs.Unwind(ovMarket, posId, fraction, priceLimit));
    }

    function buildSinglePosition(
        uint256 collateral,
        uint256 leverage,
        uint256 posId1,
        uint16 slippage
    ) public returns (uint256) {
        return shiva.buildSingle(
            ShivaStructs.BuildSingle(ovMarket, slippage, collateral, leverage, posId1)
        );
    }

    function getBuildOnBehalfOfDigest(
        uint256 collateral,
        uint256 leverage,
        uint256 priceLimit,
        uint256 nonce,
        uint48 deadline,
        bool isLong
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                shiva.BUILD_ON_BEHALF_OF_TYPEHASH(),
                ovMarket,
                deadline,
                collateral,
                leverage,
                isLong,
                priceLimit,
                nonce
            )
        );
        return shiva.getDigest(structHash);
    }

    function getUnwindOnBehalfOfDigest(
        uint256 posId,
        uint256 fraction,
        uint256 priceLimit,
        uint256 nonce,
        uint48 deadline
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                shiva.UNWIND_ON_BEHALF_OF_TYPEHASH(),
                ovMarket,
                deadline,
                posId,
                fraction,
                priceLimit,
                nonce
            )
        );
        return shiva.getDigest(structHash);
    }

    function getBuildSingleOnBehalfOfDigest(
        uint256 collateral,
        uint256 leverage,
        uint256 previousPositionId,
        uint256 nonce,
        uint48 deadline
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                shiva.BUILD_SINGLE_ON_BEHALF_OF_TYPEHASH(),
                ovMarket,
                deadline,
                collateral,
                leverage,
                previousPositionId,
                nonce
            )
        );
        return shiva.getDigest(structHash);
    }

    function getSignature(bytes32 digest, uint256 userPk) public pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        return abi.encodePacked(r, s, v);
    }

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
            ShivaStructs.Build(ovMarket, isLong, collateral, leverage, priceLimit),
            ShivaStructs.OnBehalfOf(owner, deadline, signature)
        );
    }

    function unwindPositionOnBehalfOf(
        uint256 positionId,
        uint256 fraction,
        uint256 priceLimit,
        uint48 deadline,
        bytes memory signature,
        address owner
    ) public {
        shiva.unwind(
            ShivaStructs.Unwind(ovMarket, positionId, fraction, priceLimit),
            ShivaStructs.OnBehalfOf(owner, deadline, signature)
        );
    }

    function buildSinglePositionOnBehalfOf(
        uint256 collateral,
        uint256 leverage,
        uint256 previousPositionId,
        uint16 slippage,
        uint48 deadline,
        bytes memory signature,
        address owner
    ) public returns (uint256) {
        return shiva.buildSingle(
            ShivaStructs.BuildSingle(ovMarket, slippage, collateral, leverage, previousPositionId),
            ShivaStructs.OnBehalfOf(owner, deadline, signature)
        );
    }

    /**
     * Assertion functions
     */
    function assertFractionRemainingIsZero(address user, uint256 posId) public view {
        (,,,,,,, uint16 fractionRemaining) =
            ovMarket.positions(keccak256(abi.encodePacked(user, posId)));
        assertEq(fractionRemaining, 0);
    }

    function assertFractionRemainingIsGreaterThanZero(address user, uint256 posId) public view {
        (,,,,,,, uint16 fractionRemaining) =
            ovMarket.positions(keccak256(abi.encodePacked(user, posId)));
        assertGt(fractionRemaining, 0);
    }

    function assertFractionRemaining(address user, uint256 posId, uint16 expected) public view {
        (,,,,,,, uint16 fractionRemaining) =
            ovMarket.positions(keccak256(abi.encodePacked(user, posId)));
        assertEq(fractionRemaining, expected);
    }

    function assertOVTokenBalanceIsZero(
        address user
    ) public view {
        assertEq(ovToken.balanceOf(user), 0);
    }

    function assertUserIsPositionOwnerInShiva(address user, uint256 posId) public view {
        assertEq(shiva.positionOwners(ovMarket, posId), user);
    }
}
