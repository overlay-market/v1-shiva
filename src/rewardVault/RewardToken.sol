// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

import "./IRewardToken.sol";

contract RewardToken is IRewardToken, AccessControl, ERC20("Reward Overlay Protocol", "rOVL") {
    bool public unlocked;

    event Unlocked(bool indexed _status);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function mint(address _recipient, uint256 _amount) external onlyRole(MINTER_ROLE) {
        _mint(_recipient, _amount);
    }

    function burn(uint256 _amount) external onlyRole(BURNER_ROLE) {
        _burn(msg.sender, _amount);
    }

    function toggleLock() external onlyRole(DEFAULT_ADMIN_ROLE) {
        bool status = !unlocked;
        unlocked = status;
        emit Unlocked(status);
    }

    /// @notice Pre-transfer hook to apply transfer lock and exempt mints and burns from it
    /// @param _from sender address (address(0) for mints)
    /// @param _to recipient address (address(0) for burns)
    function _beforeTokenTransfer(address _from, address _to, uint256) internal view override {
        // Revert when transfers are locked (mints/burns always exempt)
        if (_from == address(0)) return; // mint exemption
        if (_to == address(0)) return; // burn exemption
        if (hasRole(ALLOW_FROM_ROLE, _from)) return; // sender exemption
        if (hasRole(ALLOW_TO_ROLE, _to)) return; // recipient exemption
        if (!unlocked) revert(
            string(
                abi.encodePacked(
                    "RewardToken: Locked address from ",
                    Strings.toHexString(_from),
                    " and address to ",
                    Strings.toHexString(_to),
                    " are not exempt"
                )
            )
        ); // Impose transfer lock on everyone else if enabled
    }
}
