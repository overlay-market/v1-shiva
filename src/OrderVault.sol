// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IOverlayV1Token, GOVERNOR_ROLE} from "v1-core/contracts/interfaces/IOverlayV1Token.sol";
import {IOrderVault} from "./interfaces/shiva/IOrderVault.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title OrderVault
 * @author Overlay team
 * @notice This contract securely holds collateral and execution fees for pending advanced orders.
 * @dev It isolates funds to ensure keepers are paid and users can be refunded.
 *      It uses ReentrancyGuard to protect the pay function.
 */
contract OrderVault is IOrderVault, ReentrancyGuard {
    /// @notice The OVL token used for paying fees and holding collateral.
    IOverlayV1Token public immutable ovlToken;

    /// @notice Mapping to store which addresses are authorized to perform actions (call pay).
    mapping(address => bool) public authorizations;

    /**
     * @dev Ensures the caller is authorized to perform an action.
     */
    modifier onlyAuthorized() {
        if (!authorizations[msg.sender]) revert Unauthorized(msg.sender);
        _;
    }

    /**
     * @dev Ensures the caller has the governor role.
     */
    modifier onlyGovernor() {
        if (!ovlToken.hasRole(GOVERNOR_ROLE, msg.sender)) revert Unauthorized(msg.sender);
        _;
    }

    /**
     * @param _ovlToken The address of the OVL token contract.
     */
    constructor(address _ovlToken) {
        ovlToken = IOverlayV1Token(_ovlToken);
    }

    /**
     * @notice Sets or revokes authorization for an address to call `pay`.
     * @dev Only callable by the governor.
     * @param _account The address to authorize or revoke.
     * @param _isAuthorized The authorization status to set.
     */
    function setAuthorizations(address _account, bool _isAuthorized) external onlyGovernor {
        authorizations[_account] = _isAuthorized;
    }

    /**
     * @notice Transfers a specified amount of OVL to a recipient.
     * @dev This function is protected against re-entrancy attacks.
     * @param _to The recipient's address.
     * @param _amount The amount of OVL to transfer.
     */
    function pay(address _to, uint256 _amount) external onlyAuthorized nonReentrant {
        ovlToken.transfer(_to, _amount);
    }
} 