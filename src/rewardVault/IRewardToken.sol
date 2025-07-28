// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";

bytes32 constant MINTER_ROLE = keccak256("MINTER");
bytes32 constant BURNER_ROLE = keccak256("BURNER");
bytes32 constant ALLOW_FROM_ROLE = keccak256("ALLOW_FROM");
bytes32 constant ALLOW_TO_ROLE = keccak256("ALLOW_TO");

interface IRewardToken is IAccessControl, IERC20 {
    // mint/burn
    function mint(address _recipient, uint256 _amount) external;

    function burn(uint256 _amount) external;
}
