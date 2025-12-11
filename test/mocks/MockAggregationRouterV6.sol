// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IAggregationRouterV6} from "src/interfaces/oneInch/IAggregationRouterV6.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

/**
 * @notice Lightweight 1inch Aggregation Router mock.
 * @dev Records the last swap call, optionally pulls src tokens from the caller,
 *      and mints dst tokens to the provided receiver.
 */
contract MockAggregationRouterV6 is IAggregationRouterV6 {
    SwapDescription public lastDesc;
    address public lastExecutor;
    bytes public lastData;
    uint256 public lastAmountIn;

    uint256 public returnAmount;
    uint256 public spentAmount;
    bool public useDescAmountAsSpent = true;

    address public mintToken;
    uint256 public mintAmount;

    bool public shouldRevert;

    address public expectedSrcToken;
    address public expectedDstToken;
    address public expectedDstReceiver;
    uint256 public expectedMinReturn;

    function setReturnAmount(uint256 _returnAmount) external {
        returnAmount = _returnAmount;
    }

    function setSpentAmount(uint256 _spentAmount) external {
        spentAmount = _spentAmount;
    }

    function setUseDescAmountAsSpent(bool value) external {
        useDescAmountAsSpent = value;
    }

    function setMint(address token, uint256 amount) external {
        mintToken = token;
        mintAmount = amount;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function setExpectations(
        address srcToken,
        address dstToken,
        address dstReceiver,
        uint256 minReturn
    ) external {
        expectedSrcToken = srcToken;
        expectedDstToken = dstToken;
        expectedDstReceiver = dstReceiver;
        expectedMinReturn = minReturn;
    }

    function swap(
        address executor,
        SwapDescription calldata desc,
        bytes calldata data
    ) external override returns (uint256, uint256) {
        if (shouldRevert) revert("MOCK_SWAP_REVERT");

        if (expectedSrcToken != address(0)) {
            require(desc.srcToken == expectedSrcToken, "MOCK_BAD_SRC");
        }
        if (expectedDstToken != address(0)) {
            require(desc.dstToken == expectedDstToken, "MOCK_BAD_DST");
        }
        if (expectedDstReceiver != address(0)) {
            require(desc.dstReceiver == expectedDstReceiver, "MOCK_BAD_DST_RECEIVER");
        }
        if (expectedMinReturn != 0) {
            require(desc.minReturnAmount == expectedMinReturn, "MOCK_BAD_MIN_RETURN");
        }

        lastExecutor = executor;
        lastDesc = desc;
        lastData = data;
        lastAmountIn = desc.amount;

        // Simulate transferring the src token from the caller into the router.
        if (desc.srcToken != address(0) && desc.amount > 0) {
            ERC20Mock(desc.srcToken).transferFrom(msg.sender, address(this), desc.amount);
        }

        // Mint destination tokens directly to the expected receiver.
        if (mintToken != address(0) && mintAmount > 0) {
            ERC20Mock(mintToken).mint(desc.dstReceiver, mintAmount);
        }

        uint256 spent = useDescAmountAsSpent ? desc.amount : spentAmount;
        return (returnAmount, spent);
    }

    function getLastDesc() external view returns (SwapDescription memory) {
        return lastDesc;
    }
}
