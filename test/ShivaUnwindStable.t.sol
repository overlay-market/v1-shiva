// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Shiva} from "src/Shiva.sol";
import {ShivaStructs} from "src/ShivaStructs.sol";
import {IShiva} from "src/IShiva.sol";
import {ILoanBasedStableCollateral} from "src/ILoanBasedStableCollateral.sol";
import {LoanBasedStableCollateral} from "src/LoanBasedStableCollateral.sol";
import {PancakeSwapV3TWAPOracle} from "src/PancakeSwapV3TWAPOracle.sol";
import {StakingToken} from "src/mocks/StakingTokenMock.sol";
import {Utils} from "src/utils/Utils.sol";
import {IAggregationRouterV6} from "src/interfaces/oneInch/IAggregationRouterV6.sol";
import {IRewardsVault} from "src/interfaces/rewardVault/IRewardVaults.sol";
import {
    IOverlayV1Token,
    GOVERNOR_ROLE,
    PAUSER_ROLE
} from "v1-core/contracts/interfaces/IOverlayV1Token.sol";
import {IOverlayV1Market} from "v1-core/contracts/interfaces/IOverlayV1Market.sol";

import {ShivaTestBase} from "./ShivaBase.t.sol";
import {MockAggregationRouterV6} from "./mocks/MockAggregationRouterV6.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {Constants as ScriptConstants} from "../scripts/Constants.sol";
import {IFluxAggregator} from "src/interfaces/aggregator/IFluxAggregator.sol";
import {IOverlayV1ChainlinkFeed} from
    "v1-core/contracts/interfaces/feeds/chainlink/IOverlayV1ChainlinkFeed.sol";
import {IOverlayV1PositionState} from "v1-periphery/contracts/interfaces/state/IOverlayV1PositionState.sol";

contract ShivaUnwindStableUnitTest is Test, ShivaTestBase {
    address constant ONE_INCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;

    function _installAggregatorMock() internal returns (MockAggregationRouterV6 router) {
        MockAggregationRouterV6 impl = new MockAggregationRouterV6();
        bytes32 codeHash = keccak256(address(impl).code);
        vm.etch(ONE_INCH_ROUTER, address(impl).code);
        router = MockAggregationRouterV6(ONE_INCH_ROUTER);
        require(address(router).code.length > 0, "router code missing");
        require(keccak256(address(router).code) == codeHash, "router code mismatch");
    }

    function _buildSwapData(
        address srcToken,
        address dstToken,
        address receiver,
        uint256 minReturn
    ) internal pure returns (bytes memory) {
        IAggregationRouterV6.SwapDescription memory desc = IAggregationRouterV6.SwapDescription({
            srcToken: srcToken,
            dstToken: dstToken,
            srcReceiver: payable(receiver),
            dstReceiver: payable(receiver),
            amount: 0,
            minReturnAmount: minReturn,
            flags: 0
        });

        return abi.encodeWithSelector(
            IAggregationRouterV6.swap.selector, address(0xDEAD), desc, bytes("")
        );
    }

    function _priceLimit(uint256 positionId) internal view returns (uint256) {
        return Utils.getUnwindPrice(
            ovlState, ovlMarket, positionId, address(shiva), ONE, BASIC_SLIPPAGE
        );
    }

    function test_unwindStable_swapsOvlForStableAndForwardsToOwner() public {
        vm.startPrank(alice);
        uint256 positionId = buildPosition(10e18, 2e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        uint256 minOut = 1e18;

        MockAggregationRouterV6 router = _installAggregatorMock();
        router.setMint(address(stableToken), minOut + 1);
        router.setReturnAmount(minOut + 1);
        router.setUseDescAmountAsSpent(true);

        bytes memory swapData =
            _buildSwapData(address(ovlToken), address(stableToken), address(shiva), minOut);

        vm.prank(address(shiva));
        ovlToken.approve(address(router), type(uint256).max);

        uint256 aliceStableBefore = stableToken.balanceOf(alice);

        vm.prank(alice);
        shiva.unwindStable(
            ShivaStructs.Unwind(ovlMarket, BROKER_ID, positionId, ONE, _priceLimit(positionId)),
            swapData,
            minOut
        );

        assertGt(stableToken.balanceOf(alice), aliceStableBefore, "stable should increase");
        assertEq(stableToken.balanceOf(address(shiva)), 0, "Shiva should forward stables");
        assertEq(ovlToken.balanceOf(address(shiva)), 0, "OVL should be spent");

        IAggregationRouterV6.SwapDescription memory calledDesc = router.getLastDesc();
        assertEq(calledDesc.srcToken, address(ovlToken), "src token mismatch");
        assertEq(calledDesc.dstToken, address(stableToken), "dst token mismatch");
        assertEq(calledDesc.dstReceiver, address(shiva), "dst receiver mismatch");
        assertGt(router.lastAmountIn(), 0, "no OVL swapped");
    }

    function test_unwindStable_revertsWhenSwapReturnsTooLittle() public {
        vm.startPrank(alice);
        uint256 positionId = buildPosition(7e18, 2e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        uint256 minOut = 5e17;
        MockAggregationRouterV6 router = _installAggregatorMock();
        router.setMint(address(stableToken), minOut - 1);
        router.setReturnAmount(minOut - 1);
        router.setUseDescAmountAsSpent(true);
        assertEq(router.returnAmount(), minOut - 1, "return amount not set");

        bytes memory swapData =
            _buildSwapData(address(ovlToken), address(stableToken), address(shiva), minOut);

        vm.prank(address(shiva));
        ovlToken.approve(address(router), type(uint256).max);

        vm.expectRevert(IShiva.SwapFailed.selector);
        vm.prank(alice);
        shiva.unwindStable(
            ShivaStructs.Unwind(ovlMarket, BROKER_ID, positionId, ONE, _priceLimit(positionId)),
            swapData,
            minOut
        );
    }

    function test_unwindStable_revertsWhenSpentAmountMismatch() public {
        vm.startPrank(alice);
        uint256 positionId = buildPosition(7e18, 2e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        uint256 minOut = 5e17;
        MockAggregationRouterV6 router = _installAggregatorMock();
        router.setMint(address(stableToken), minOut + 1);
        router.setReturnAmount(minOut + 1);
        router.setUseDescAmountAsSpent(false);
        router.setSpentAmount(0);

        bytes memory swapData =
            _buildSwapData(address(ovlToken), address(stableToken), address(shiva), minOut);

        vm.prank(address(shiva));
        ovlToken.approve(address(router), type(uint256).max);

        vm.expectRevert(IShiva.SwapFailed.selector);
        vm.prank(alice);
        shiva.unwindStable(
            ShivaStructs.Unwind(ovlMarket, BROKER_ID, positionId, ONE, _priceLimit(positionId)),
            swapData,
            minOut
        );
    }
}

contract ShivaUnwindStableBscForkTest is Test {
    using stdJson for string;

    address constant ONE_INCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;
    address constant SHIVA_PROXY = 0xeB497c228F130BD91E7F13f81c312243961d894A;
    address constant DOUBLE_OR_NOTHING = 0xfFaDA7c70c2868FD0Fe9BE85D326317923BaA0a8;
    address constant CS2 = 0x5Ec437121a47B86B40FdF1aB4eF95806e60a9247;
    address constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant STATE = 0x10575a9C8F36F9F42D7DB71Ef179eD9BEf8Df238;
    address constant PANCAKEV3POOL = 0x927aE3c2cd88717a1525a55021AF9612C3F04583;

    uint256 constant ONE = 1e18;

    Shiva shiva;
    IOverlayV1Token ovl;
    LoanBasedStableCollateral lbsc;
    IERC20 stableToken;
    IOverlayV1Market market;
    IRewardsVault rewardVault;
    StakingToken stakingToken;

    function setUp() public {
        vm.createSelectFork(vm.envString("BSC_RPC"));

        shiva = Shiva(SHIVA_PROXY);
        ovl = IOverlayV1Token(ScriptConstants.getOVLTokenAddress());
        address governor = _governor();

        vm.startPrank(governor);
        shiva.upgradeTo(address(new Shiva()));

        // Deploy fresh LBSC behind a proxy (mirrors UpgradeShivaAndDeployLBSC)
        LoanBasedStableCollateral lbscImpl = new LoanBasedStableCollateral();
        address priceFeed = address(new MockAggregator());
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address,uint256)",
            BSC_USDT,
            address(shiva),
            priceFeed,
            address(0),
            2 days
        );
        ERC1967Proxy lbscProxy = new ERC1967Proxy(address(lbscImpl), initData);
        lbsc = LoanBasedStableCollateral(address(lbscProxy));
        lbsc.setTwapOracle(address(new PancakeSwapV3TWAPOracle(PANCAKEV3POOL)));

        shiva.setLbsc(address(lbsc));
        deal(address(ovl), address(lbsc), 1_000_000e18);
        vm.stopPrank();

        if (shiva.paused()) {
            vm.prank(_pauser());
            shiva.unpause();
        }

        stableToken = IERC20(BSC_USDT);
        market = IOverlayV1Market(CS2);
        rewardVault = IRewardsVault(shiva.rewardVault());
        stakingToken = StakingToken(shiva.stakingToken());
    }

    function testFork_buildStable_and_unwindStable_realCalls() public {
        address user = makeAddr("user");
        uint256 stableCollateral = 10e18;
        uint256 leverage = 1e18;
        bool isLong = true;
        uint256 deltaQuoteVsUnwindOVl = 100;

        deal(address(stableToken), user, stableCollateral);

        vm.startPrank(user);
        stableToken.approve(address(lbsc), type(uint256).max);
        uint256 positionId = shiva.buildStable(
            ShivaStructs.BuildStable({
                ovlMarket: market,
                brokerId: 0,
                isLong: isLong,
                stableCollateral: stableCollateral,
                leverage: leverage,
                priceLimit: isLong ? type(uint256).max : 0,
                minOvl: 0
            })
        );
        vm.stopPrank();

        uint256 loanId = shiva.loanIds(market, positionId);
        (,,,,uint256 debt) = LoanBasedStableCollateral(address(lbsc)).loans(loanId);

        // move market price favorable to the user so it has ovl as profit to swap
        {
            IFluxAggregator aggregator =
                IFluxAggregator(IOverlayV1ChainlinkFeed(market.feed()).aggregator());
            address oracle = aggregator.getOracles()[0];
            int256 halfPrice = aggregator.latestAnswer() / 2;
            int256 twicePrice = aggregator.latestAnswer() * 2;

            int256 targetPrice = isLong ? twicePrice : halfPrice;

            vm.startPrank(oracle);
            aggregator.submit(aggregator.latestRound() + 1, targetPrice);
            vm.warp(block.timestamp + 60 * 60);
            aggregator.submit(aggregator.latestRound() + 1, targetPrice);
            vm.warp(block.timestamp + 60 * 60);
            vm.stopPrank();
        }

        uint256 currentValue = IOverlayV1PositionState(STATE).value(market, address(shiva), positionId);
        console.log("currentValue (OVL):");
        console.log(currentValue);
        uint256 unwindFee = IOverlayV1PositionState(STATE).tradingFee(market, address(shiva), positionId);
        console.log("unwindFee (OVL):");
        console.log(unwindFee);
        uint256 quoteAmount = currentValue - debt - unwindFee;
        console.log("quoteAmount (OVL):");
        console.log(quoteAmount);
        (bytes memory swapData, uint256 minOut) = _fetchSwapData(quoteAmount*deltaQuoteVsUnwindOVl/100);

        uint256 stableBeforeUnwind = stableToken.balanceOf(user);

        vm.prank(user);
        shiva.unwindStable(
            ShivaStructs.Unwind(market, 0, positionId, ONE, isLong ? 0 : type(uint256).max),
            swapData,
            minOut
        );

        uint256 stableAfter = stableToken.balanceOf(user);

        console.log("stableCollateral");
        console.log(stableCollateral);
        console.log("Initial loan debt (OVL):");
        console.log(debt);
        console.log("Stables received after unwind:");
        console.log(stableAfter - stableBeforeUnwind);
    }

    function testFuzzFork_buildStable_and_unwindStable_realCalls(
        bool isLong,
        uint256 stableCollateral,
        uint256 leverage,
        uint256 deltaQuoteVsUnwindOVl
    ) public {
        address user = makeAddr("user");
        uint256 maxStableCollateral = 500e18;
        stableCollateral = bound(stableCollateral, 1e18, maxStableCollateral);
        leverage = bound(leverage, ONE, 5e18);
        deltaQuoteVsUnwindOVl = bound(deltaQuoteVsUnwindOVl, 95, 103);

        deal(address(stableToken), user, stableCollateral);

        vm.startPrank(user);
        stableToken.approve(address(lbsc), type(uint256).max);
        uint256 positionId = shiva.buildStable(
            ShivaStructs.BuildStable({
                ovlMarket: market,
                brokerId: 0,
                isLong: isLong,
                stableCollateral: stableCollateral,
                leverage: leverage,
                priceLimit: isLong ? type(uint256).max : 0,
                minOvl: 0
            })
        );
        vm.stopPrank();

        uint256 loanId = shiva.loanIds(market, positionId);
        (,,,,uint256 debt) = LoanBasedStableCollateral(address(lbsc)).loans(loanId);

        // move market price favorable to the user so it has ovl as profit to swap
        {
            IFluxAggregator aggregator =
                IFluxAggregator(IOverlayV1ChainlinkFeed(market.feed()).aggregator());
            address oracle = aggregator.getOracles()[0];
            int256 halfPrice = aggregator.latestAnswer() / 2;
            int256 twicePrice = aggregator.latestAnswer() * 2;

            int256 targetPrice = isLong ? twicePrice : halfPrice;

            vm.startPrank(oracle);
            aggregator.submit(aggregator.latestRound() + 1, targetPrice);
            vm.warp(block.timestamp + 60 * 60);
            aggregator.submit(aggregator.latestRound() + 1, targetPrice);
            vm.warp(block.timestamp + 60 * 60);
            vm.stopPrank();
        }

        uint256 currentValue = IOverlayV1PositionState(STATE).value(market, address(shiva), positionId);
        console.log("currentValue (OVL):");
        console.log(currentValue);
        uint256 unwindFee = IOverlayV1PositionState(STATE).tradingFee(market, address(shiva), positionId);
        console.log("unwindFee (OVL):");
        console.log(unwindFee);
        uint256 quoteAmount = currentValue - debt - unwindFee;
        console.log("quoteAmount (OVL):");
        console.log(quoteAmount);
        (bytes memory swapData, uint256 minOut) = _fetchSwapData(quoteAmount*deltaQuoteVsUnwindOVl/100);

        uint256 stableBeforeUnwind = stableToken.balanceOf(user);

        vm.prank(user);
        shiva.unwindStable(
            ShivaStructs.Unwind(market, 0, positionId, ONE, isLong ? 0 : type(uint256).max),
            swapData,
            minOut
        );

        uint256 stableAfter = stableToken.balanceOf(user);

        console.log("stableCollateral");
        console.log(stableCollateral);
        console.log("Initial loan debt (OVL):");
        console.log(debt);
        console.log("Stables received after unwind:");
        console.log(stableAfter - stableBeforeUnwind);
    }

    function _governor() internal view returns (address) {
        address primary = 0x85f66DBe1ed470A091d338CFC7429AA871720283;
        if (ovl.hasRole(GOVERNOR_ROLE, primary)) return primary;

        address fallbackGov = 0x4e5cf176f5ae854a933D1c120033d08E13a034AD;
        require(ovl.hasRole(GOVERNOR_ROLE, fallbackGov), "no governor role");
        return fallbackGov;
    }

    function _pauser() internal view returns (address) {
        address candidate = 0x85f66DBe1ed470A091d338CFC7429AA871720283;
        if (ovl.hasRole(PAUSER_ROLE, candidate)) return candidate;
        address fallbackGov =  _governor();
        return fallbackGov;
    }

    function _setPositionOwner(address marketAddr, uint256 positionId, address owner) internal {
        bytes32 outer = keccak256(abi.encode(marketAddr, uint256(257))); // positionOwners slot
        bytes32 slot = keccak256(abi.encode(positionId, outer));
        vm.store(address(shiva), slot, bytes32(uint256(uint160(owner))));
    }

    function _mockUnwindExternalCalls(address owner, uint256 positionId) internal {
        bytes32 key = keccak256(abi.encodePacked(address(shiva), positionId));
        bytes memory positionsReturn =
            abi.encode(uint96(0), uint96(0), int24(0), int24(0), false, false, uint240(0), uint16(0));

        vm.mockCall(
            address(market),
            abi.encodeWithSelector(IOverlayV1Market.positions.selector, key),
            positionsReturn
        );
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(IOverlayV1Market.unwind.selector, positionId, ONE, uint256(0)),
            ""
        );
        vm.mockCall(
            address(rewardVault),
            abi.encodeWithSelector(IRewardsVault.balanceOf.selector, owner),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            address(rewardVault),
            abi.encodeWithSelector(IRewardsVault.delegateWithdraw.selector, owner, uint256(0)),
            ""
        );
        vm.mockCall(
            address(stakingToken),
            abi.encodeWithSelector(StakingToken.burn.selector, address(shiva), uint256(0)),
            ""
        );
    }

    function _fetchSwapData(uint256 amount)
        internal
        returns (bytes memory swapData, uint256 minReturnAmount)
    {
        string memory token = vm.envString("ONEINCH_API");
        string memory shivaStr = vm.toString(address(shiva));
        string memory cmd = string(
            abi.encodePacked(
                "curl -s -X GET \"https://api.1inch.com/swap/v6.1/56/swap?",
                "src=",
                vm.toString(address(ovl)),
                "&dst=",
                vm.toString(address(stableToken)),
                "&amount=",
                vm.toString(amount),
                "&from=",
                shivaStr,
                "&receiver=",
                shivaStr,
                "&origin=",
                shivaStr,
                "&includeTokensInfo=true&includeProtocols=true&slippage=5&disableEstimate=true\" ",
                "-H \"Authorization: Bearer ",
                token,
                "\" -H \"accept: application/json\" -H \"content-type: application/json\""
            )
        );

        string[] memory inputs = new string[](3);
        inputs[0] = "bash";
        inputs[1] = "-lc";
        inputs[2] = cmd;

        bytes memory res = vm.ffi(inputs);
        string memory json = string(res);

        vm.assumeNoRevert();
        string memory dataField = json.readString(".tx.data");
        swapData = vm.parseBytes(dataField);

        (, IAggregationRouterV6.SwapDescription memory desc,) = _decodeSwapData(swapData);

        require(desc.srcToken == address(ovl), "api src token mismatch");
        require(desc.dstToken == address(stableToken), "api dst token mismatch");
        require(desc.dstReceiver == address(shiva), "api receiver mismatch");
        minReturnAmount = desc.minReturnAmount;
    }

    function _decodeSwapData(bytes memory swapData)
        internal
        pure
        returns (address executor, IAggregationRouterV6.SwapDescription memory desc, bytes memory data)
    {
        bytes memory payload = new bytes(swapData.length - 4);
        for (uint256 i = 0; i < swapData.length - 4; i++) {
            payload[i] = swapData[i + 4];
        }
        return abi.decode(payload, (address, IAggregationRouterV6.SwapDescription, bytes));
    }

    function testFork_unwindStable_withOneInchSwap() public {

        if (shiva.paused()) {
            vm.prank(_pauser());
            shiva.unpause();
        }

        address owner = address(0xBEEF);
        uint256 positionId = 42;
        uint256 ovlAmount = 1e16; // 0.01 OVL

        _setPositionOwner(address(market), positionId, owner);
        _mockUnwindExternalCalls(owner, positionId);

        deal(address(ovl), address(shiva), ovlAmount);

        vm.prank(address(shiva));
        ovl.approve(ONE_INCH_ROUTER, type(uint256).max);

        (bytes memory swapData, uint256 minOut) = _fetchSwapData(ovlAmount);

        uint256 ownerStableBefore = stableToken.balanceOf(owner);

        ShivaStructs.Unwind memory params =
            ShivaStructs.Unwind(market, 0, positionId, ONE, uint256(0));

        vm.deal(owner, 1 ether);
        vm.prank(owner);
        shiva.unwindStable(params, swapData, minOut);

        uint256 ownerStableAfter = stableToken.balanceOf(owner);

        assertGe(ownerStableAfter, ownerStableBefore + minOut, "stable output too low");
        assertEq(ovl.balanceOf(address(shiva)), 0, "OVL should be swapped out");
    }
}
