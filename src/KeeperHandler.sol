// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IKeeperHandler} from "./interfaces/shiva/IKeeperHandler.sol";
import {IOrderStore} from "./interfaces/shiva/IOrderStore.sol";
import {IOrderVault} from "./interfaces/shiva/IOrderVault.sol";
import {IShiva} from "./IShiva.sol";
import {ShivaStructs} from "./ShivaStructs.sol";
import {IOverlayV1Market} from "v1-core/contracts/interfaces/IOverlayV1Market.sol";
import {IOverlayV1Feed} from "v1-core/contracts/interfaces/feeds/IOverlayV1Feed.sol";
import {Oracle} from "v1-core/contracts/libraries/Oracle.sol";
import {IOverlayV1Token, GOVERNOR_ROLE} from "v1-core/contracts/interfaces/IOverlayV1Token.sol";
import {Utils} from "./utils/Utils.sol";

/**
 * @title KeeperHandler
 * @author Overlay team
 * @notice This contract is the sole entry point for keepers to execute advanced orders.
 * @dev It contains the logic for verifying and triggering the execution of pending orders.
 */
contract KeeperHandler is IKeeperHandler {
    IOverlayV1Token public ovlToken;
    IShiva public shiva;
    IOrderStore public orderStore;
    IOrderVault public orderVault;

    /**
     * @dev Ensures the caller has the governor role.
     */
    modifier onlyGovernor() {
        if (!ovlToken.hasRole(GOVERNOR_ROLE, msg.sender)) {
            // A direct revert is used here to avoid an error type dependency.
            revert("KeeperHandler: not governor");
        }
        _;
    }

    constructor(
        address _ovlToken,
        address _shiva,
        address _orderStore,
        address _orderVault
    ) {
        ovlToken = IOverlayV1Token(_ovlToken);
        shiva = IShiva(_shiva);
        orderStore = IOrderStore(_orderStore);
        orderVault = IOrderVault(_orderVault);
    }

    /*
     * @notice Updates the address of the OVL token contract.
     * @dev Only callable by the governor.
     * @param _ovlToken The new address for the OVL token.
     */
    function setOvlToken(address _ovlToken) external onlyGovernor {
        ovlToken = IOverlayV1Token(_ovlToken);
    }

    /*
     * @notice Updates the address of the Shiva contract.
     * @dev Only callable by the governor.
     * @param _shiva The new address for the Shiva contract.
     */
    function setShiva(address _shiva) external onlyGovernor {
        shiva = IShiva(_shiva);
    }

    /*
     * @notice Updates the address of the OrderStore contract.
     * @dev Only callable by the governor.
     * @param _orderStore The new address for the OrderStore contract.
     */
    function setOrderStore(address _orderStore) external onlyGovernor {
        orderStore = IOrderStore(_orderStore);
    }

    /*
     * @notice Updates the address of the OrderVault contract.
     * @dev Only callable by the governor.
     * @param _orderVault The new address for the OrderVault contract.
     */
    function setOrderVault(address _orderVault) external onlyGovernor {
        orderVault = IOrderVault(_orderVault);
    }

    function executeOrder(uint256 _requestId) external {
        ShivaStructs.OrderRequest memory request = orderStore.getRequest(_requestId);

        // 1. Check if the order is pending
        if (request.status != ShivaStructs.OrderStatus.PENDING) {
            revert IShiva.InvalidOrderStatus(
                _requestId,
                request.status,
                ShivaStructs.OrderStatus.PENDING
            );
        }

        // 2. Check if the trigger condition is met
        if (!_checkTrigger(request)) {
            // This is a simplified error, we'll refine it later
            revert IShiva.TriggerNotMet(_requestId, 0, 0);
        }

        // 3. If checks pass, execute the order via Shiva
        shiva.executeAdvancedOrder(_requestId);

        // 4. Mark the request as executed to prevent re-entrancy
        orderStore.updateRequestStatus(_requestId, ShivaStructs.OrderStatus.EXECUTED);

        // 5. Pay the keeper
        orderVault.pay(msg.sender, request.executionFee);
    }

    function _checkTrigger(
        ShivaStructs.OrderRequest memory _request
    ) private view returns (bool) {
        IOverlayV1Market market = _request.market;
        IOverlayV1Feed feed = IOverlayV1Feed(market.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice;

        if (_request.orderType == ShivaStructs.OrderType.LIMIT_OPEN) {
            if (_request.isLong) {
                // For a buy limit (long), we check the ask price. Trigger when price <= target.
                currentPrice = market.ask(data, 0);
                return currentPrice <= _request.triggerPrice;
            } else {
                // For a sell limit (short), we check the bid price. Trigger when price >= target.
                currentPrice = market.bid(data, 0);
                return currentPrice >= _request.triggerPrice;
            }
        } else { // STOP_LOSS or TAKE_PROFIT
            bool isLong = Utils.getPositionSide(market, _request.positionId, address(shiva));

            if (isLong) {
                // For closing a long, we check the bid price.
                currentPrice = market.bid(data, 0);
                if (_request.orderType == ShivaStructs.OrderType.TAKE_PROFIT) {
                    // TP for long: price >= trigger
                    return currentPrice >= _request.triggerPrice;
                } else { // STOP_LOSS
                    // SL for long: price <= trigger
                    return currentPrice <= _request.triggerPrice;
                }
            } else {
                // For closing a short, we check the ask price.
                currentPrice = market.ask(data, 0);
                if (_request.orderType == ShivaStructs.OrderType.TAKE_PROFIT) {
                    // TP for short: price <= trigger
                    return currentPrice <= _request.triggerPrice;
                } else { // STOP_LOSS
                    // SL for short: price >= trigger
                    return currentPrice >= _request.triggerPrice;
                }
            }
        }
    }
} 