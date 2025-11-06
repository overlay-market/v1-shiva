// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

interface ILoanBasedStableCollateral {
    function borrow(uint256 amount)
        external
        returns (uint256 ovlAmount, uint256 loanId);

    function settle(uint256 loanId) external;
}