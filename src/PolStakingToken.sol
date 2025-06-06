// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title StakingToken
 * @notice ERC20 token used for staking in BerachainRewardsVault contract
 */
contract StakingToken is ERC20, Ownable {
    constructor() ERC20("OverlayStakingToken", "OvlSTK") Ownable() {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}
