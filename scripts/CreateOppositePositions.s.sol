// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {Script, console} from "forge-std/Script.sol";
import {Shiva} from "../src/Shiva.sol";
import {ShivaStructs} from "../src/ShivaStructs.sol";
import {Utils} from "../src/utils/Utils.sol";
import {IOverlayV1Market} from "v1-core/contracts/interfaces/IOverlayV1Market.sol";
import {IOverlayV1Token} from "v1-core/contracts/interfaces/IOverlayV1Token.sol";
import {IOverlayV1State} from "v1-periphery/contracts/interfaces/IOverlayV1State.sol";

/**
 * @title CreateOppositePositions
 * @notice Script to create opposite positions (long and short) for an array of markets
 * @dev This script creates two positions for each market - one long and one short with configurable parameters
 */
contract CreateOppositePositions is Script {
    // =============================================================================
    // CONFIGURABLE PARAMETERS
    // =============================================================================
    
    /// @notice Amount of collateral to use for each position (in wei, 1e18 = 1 OVL)
    uint256 public COLLATERAL = 1e18; // 1 OVL
    
    /// @notice Leverage multiplier for each position (in wei, 1e18 = 1x leverage)
    uint256 public LEVERAGE = 2e18; // 2x leverage
    
    /// @notice Slippage tolerance in basis points (100 = 1%)
    uint16 public SLIPPAGE = 100; // 1%
    
    /// @notice Broker ID to use for positions
    uint32 public BROKER_ID = 0;
    
    // =============================================================================
    // CONTRACT ADDRESSES
    // =============================================================================
    
    /// @notice Shiva contract address
    address public SHIVA_ADDRESS = 0xeB497c228F130BD91E7F13f81c312243961d894A;
    
    /// @notice OVL Token address
    address public OVL_TOKEN_ADDRESS = 0x1F34c87ded863Fe3A3Cd76FAc8adA9608137C8c3;
    
    /// @notice OVL State contract address  
    address public OVL_STATE_ADDRESS = 0x10575a9C8F36F9F42D7DB71Ef179eD9BEf8Df238;
    
    // =============================================================================
    // CONTRACT INSTANCES
    // =============================================================================
    
    Shiva public shiva;
    IOverlayV1Token public ovlToken;
    IOverlayV1State public ovlState;
    
    // =============================================================================
    // STRUCTS FOR TRACKING
    // =============================================================================
    
    struct PositionInfo {
        address market;
        uint256 longPositionId;
        uint256 shortPositionId;
        uint256 collateral;
        uint256 leverage;
    }
    
    // =============================================================================
    // MAIN SCRIPT FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Main script execution function
     * @dev Creates opposite positions for the provided array of markets
     */
    function run() external {
        // Fill in market addresses
        address[] memory markets = new address[](2);
        markets[0] = 0x5B6a02E0Bd8Ed1D6d58368D60275F60D26e0FB55;
        markets[1] = 0x204b281d5f5a504043Ae2D91f3CF79bbBC1F6E09;
        
        createOppositePositions(markets);
    }
    
    /**
     * @notice Creates opposite positions for an array of market addresses
     * @param markets Array of market addresses to create positions for
     */
    function createOppositePositions(address[] memory markets) public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // Initialize contract instances
        _initializeContracts();
        
        vm.startBroadcast(deployerPrivateKey);
        
        address broadcaster = vm.addr(deployerPrivateKey);
        
        // Approve Shiva to spend OVL tokens for all positions
        _approveTokens(markets.length, broadcaster);
        
        PositionInfo[] memory positionInfos = new PositionInfo[](markets.length);
        
        console.log("Creating opposite positions for %d markets", markets.length);
        console.log("Collateral per position: %e OVL", COLLATERAL);
        console.log("Leverage: %dx", LEVERAGE / 1e18);
        console.log("Slippage tolerance: %d bps", SLIPPAGE);
        console.log("----------------------------------------");
        
        // Create positions for each market
        for (uint256 i = 0; i < markets.length; i++) {
            IOverlayV1Market market = IOverlayV1Market(markets[i]);
            
            console.log("Market %d: %s", i + 1, address(market));
            
            // Create long position
            uint256 longPositionId = _buildPosition(market, true);
            console.log("  Long position created: ID %d", longPositionId);
            
            // Create short position
            uint256 shortPositionId = _buildPosition(market, false);
            console.log("  Short position created: ID %d", shortPositionId);
            
            // Store position info
            positionInfos[i] = PositionInfo({
                market: address(market),
                longPositionId: longPositionId,
                shortPositionId: shortPositionId,
                collateral: COLLATERAL,
                leverage: LEVERAGE
            });
            
            console.log("----------------------------------------");
        }
        
        vm.stopBroadcast();
        
        // Print summary
        _printSummary(positionInfos);
    }
    
    // =============================================================================
    // INTERNAL HELPER FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Initialize contract instances
     */
    function _initializeContracts() internal {
        require(SHIVA_ADDRESS != address(0), "SHIVA_ADDRESS not set");
        require(OVL_TOKEN_ADDRESS != address(0), "OVL_TOKEN_ADDRESS not set");
        require(OVL_STATE_ADDRESS != address(0), "OVL_STATE_ADDRESS not set");
        
        shiva = Shiva(SHIVA_ADDRESS);
        ovlToken = IOverlayV1Token(OVL_TOKEN_ADDRESS);
        ovlState = IOverlayV1State(OVL_STATE_ADDRESS);
    }
    
    /**
     * @notice Approve OVL tokens for Shiva contract
     * @param numMarkets Number of markets to create positions for
     * @param broadcaster Address of the broadcaster
     */
    function _approveTokens(uint256 numMarkets, address broadcaster) internal {
        uint256 totalCollateralNeeded = COLLATERAL * numMarkets * 2; // 2 positions per market
        
        uint256 currentAllowance = ovlToken.allowance(broadcaster, address(shiva));
        
        if (currentAllowance < totalCollateralNeeded) {
            console.log("Approving %e OVL tokens for Shiva contract", totalCollateralNeeded);
            ovlToken.approve(address(shiva), type(uint256).max);
        }
        
        // Check balance
        uint256 balance = ovlToken.balanceOf(broadcaster);
        require(balance >= totalCollateralNeeded, "Insufficient OVL balance");
        console.log("User OVL balance: %e", balance);
    }
    
    /**
     * @notice Build a position (long or short) for a given market
     * @param market The market to build position in
     * @param isLong Whether to build a long (true) or short (false) position
     * @return positionId The ID of the created position
     */
    function _buildPosition(
        IOverlayV1Market market,
        bool isLong
    ) internal returns (uint256 positionId) {
        // Calculate price limit using Utils library
        uint256 priceLimit = Utils.getEstimatedPrice(
            ovlState,
            market,
            COLLATERAL,
            LEVERAGE,
            SLIPPAGE,
            isLong
        );
        
        // Build the position
        positionId = shiva.build(
            ShivaStructs.Build({
                ovlMarket: market,
                brokerId: BROKER_ID,
                isLong: isLong,
                collateral: COLLATERAL,
                leverage: LEVERAGE,
                priceLimit: priceLimit
            })
        );
    }
    
    /**
     * @notice Print summary of all created positions
     * @param positionInfos Array of position information
     */
    function _printSummary(PositionInfo[] memory positionInfos) internal view {
        console.log("\n=== POSITION CREATION SUMMARY ===");
        console.log("Total markets: %d", positionInfos.length);
        console.log("Total positions: %d", positionInfos.length * 2);
        console.log("Total collateral used: %e OVL", positionInfos.length * 2 * COLLATERAL);
        
        for (uint256 i = 0; i < positionInfos.length; i++) {
            PositionInfo memory info = positionInfos[i];
            console.log("\nMarket %d: %s", i + 1, info.market);
            console.log("  Long Position ID: %d", info.longPositionId);
            console.log("  Short Position ID: %d", info.shortPositionId);
            console.log("  Collateral: %e OVL", info.collateral);
            console.log("  Leverage: %dx", info.leverage / 1e18);
        }
        
        console.log("\n=== END SUMMARY ===\n");
    }
    
    // =============================================================================
    // UTILITY FUNCTIONS FOR EXTERNAL CALLS
    // =============================================================================
    
    /**
     * @notice Update collateral amount (call before running script)
     * @param newCollateral New collateral amount in wei
     */
    function setCollateral(uint256 newCollateral) external {
        COLLATERAL = newCollateral;
        console.log("Collateral updated to: %e OVL", COLLATERAL);
    }
    
    /**
     * @notice Update leverage amount (call before running script)
     * @param newLeverage New leverage amount in wei (1e18 = 1x)
     */
    function setLeverage(uint256 newLeverage) external {
        LEVERAGE = newLeverage;
        console.log("Leverage updated to: %dx", LEVERAGE / 1e18);
    }
    
    /**
     * @notice Update slippage tolerance (call before running script)
     * @param newSlippage New slippage in basis points (100 = 1%)
     */
    function setSlippage(uint16 newSlippage) external {
        require(newSlippage <= 10000, "Slippage cannot exceed 100%");
        SLIPPAGE = newSlippage;
        console.log("Slippage updated to: %d bps", SLIPPAGE);
    }
    
    /**
     * @notice Update contract addresses (call before running script)
     * @param shivaAddr Shiva contract address
     * @param ovlTokenAddr OVL token address
     * @param ovlStateAddr OVL state address
     */
    function setAddresses(
        address shivaAddr,
        address ovlTokenAddr,
        address ovlStateAddr
    ) external {
        SHIVA_ADDRESS = shivaAddr;
        OVL_TOKEN_ADDRESS = ovlTokenAddr;
        OVL_STATE_ADDRESS = ovlStateAddr;
        console.log("Contract addresses updated");
    }
}