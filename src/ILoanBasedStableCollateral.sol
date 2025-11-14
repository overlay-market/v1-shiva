// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

interface ILoanBasedStableCollateral {
    /**
     * @notice Emitted when a new loan is opened.
     * @param loanId Identifier of the new loan.
     * @param borrower Address that supplied the collateral.
     * @param stableAmount Amount of stable tokens locked.
     * @param ovlAmount Amount of OVL made available to Shiva.
     * @param price Price used for the conversion (scaled to 1e18).
     */
    event LoanOpened(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 stableAmount,
        uint256 ovlAmount,
        uint256 price
    );

    /**
     * @notice Emitted when an existing loan is settled.
     * @param loanId Identifier of the settled loan.
     * @param borrower Address that supplied the collateral.
     * @param ovlRepaid Amount of OVL pulled from Shiva.
     * @param collateralReturned Stable collateral returned to the borrower.
     * @param collateralSeized Stable collateral retained by LBSC (optionally streamed to the lossRecipient).
     */
    event LoanSettled(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 ovlRepaid,
        uint256 collateralReturned,
        uint256 collateralSeized
    );

    event ShivaUpdated(address indexed previousShiva, address indexed newShiva);
    event PriceFeedUpdated(address indexed previousFeed, address indexed newFeed);
    event TwapOracleUpdated(address indexed previousOracle, address indexed newOracle);
    event TwapPeriodUpdated(uint32 previousPeriod, uint32 newPeriod);
    event MaxPriceAgeUpdated(uint256 previousMaxAge, uint256 newMaxAge);
    event LossRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    event StableSurplusWithdrawn(address indexed to, uint256 amount);
    event OvlWithdrawn(address indexed to, uint256 amount);

    function borrow(uint256 amount, address borrower)
        external
        returns (uint256 ovlAmount, uint256 loanId);

    function settle(uint256 loanId, uint256 ovlAmount) external;

    function totalActiveCollateral() external returns (uint256);
}
