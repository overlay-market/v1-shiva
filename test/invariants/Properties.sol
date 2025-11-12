// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Asserts} from "@chimera/Asserts.sol";
import {BaseSetup} from "@chimera/BaseSetup.sol";
import {ShivaTestBase} from "../ShivaBase.t.sol";

abstract contract Properties is BaseSetup, ShivaTestBase, Asserts {
    // Makes sure that no OVL token stays on Shiva contract
    function property_shiva_dont_have_ovl() public view returns (bool result) {
        if (ovlToken.balanceOf(address(shiva)) == 0) {
            result = true;
        }
    }

    function property_staking_balance_matches_notional() public view returns (bool result) {
        uint256 totalNotionalRemaining = _calculateTotalNotionalRemaining();
        uint256 stakingBalance = shiva.stakingToken().balanceOf(address(shiva.rewardVault()));

        if (stakingBalance == totalNotionalRemaining) {
            result = true;
        }
    }

    function property_lbsc_collateral_accounting() public view returns (bool result) {
        (
            uint256 sumCollateral,
            uint256 sumDebt,
            ,
            bool invalidLoanFound
        ) = _getLbscOpenLoanStats();
        if (invalidLoanFound) {
            return false;
        }

        uint256 stableBalance = stableToken.balanceOf(address(lbsc));
        uint256 surplus = lbsc.availableStableSurplus();

        if (
            stableBalance >= surplus
                && sumCollateral == lbsc.totalActiveCollateral()
                && sumCollateral == stableBalance - surplus
                && sumDebt == lbsc.totalOutstandingDebt()
        ) {
            result = true;
        }
    }

    function property_stable_builds_have_valid_loans() public view returns (bool result) {
        if (!_hasStablePositionTracking()) {
            return true;
        }

        result = true;
        uint256 stableCount = _trackedStablePositionCount();
        if (stableCount == 0) {
            return true;
        }

        uint256 maxLoanId = lbsc.nextLoanId();

        for (uint256 i = 0; i < stableCount; i++) {
            uint256 positionId = _trackedStablePositionId(i);
            uint256 loanId = shiva.loanIds(ovlMarket, positionId);
            if (loanId == 0 || loanId >= maxLoanId) {
                result = false;
                break;
            }

            (address borrower,, , , bool settled) = lbsc.loans(loanId);
            if (borrower == address(0) || borrower != alice || settled) {
                result = false;
                break;
            }
        }
    }

    function property_no_residual_funds_after_settle() public view returns (bool result) {
        if (!_hasStablePositionTracking()) {
            return true;
        }

        if (_trackedPositionCount() > 0 || _trackedStablePositionCount() > 0) {
            return true;
        }

        (
            uint256 sumCollateral,
            ,
            uint256 openLoans,
            bool invalidLoanFound
        ) = _getLbscOpenLoanStats();
        if (invalidLoanFound) {
            return false;
        }

        if (openLoans > 0 || sumCollateral > 0) {
            return true;
        }

        uint256 stableBalance = stableToken.balanceOf(address(lbsc));
        uint256 surplus = lbsc.availableStableSurplus();

        if (
            lbsc.totalActiveCollateral() == 0 && lbsc.totalOutstandingDebt() == 0
                && stableBalance == surplus && ovlToken.balanceOf(address(shiva)) == 0
        ) {
            result = true;
        }
    }

    // Helper function to calculate total notional remaining
    // We are override this method in TargetFunctions to get access to positionIds
    function _calculateTotalNotionalRemaining() internal view virtual returns (uint256) {}

    function _trackedPositionCount() internal view virtual returns (uint256) {
        return 0;
    }

    function _trackedStablePositionCount() internal view virtual returns (uint256) {
        return 0;
    }

    function _hasStablePositionTracking() internal view virtual returns (bool) {
        return false;
    }

    function _trackedStablePositionId(uint256) internal view virtual returns (uint256) {}

    function _getLbscOpenLoanStats()
        internal
        view
        returns (uint256 sumCollateral, uint256 sumDebt, uint256 openLoans, bool invalidLoanFound)
    {
        uint256 nextLoanId = lbsc.nextLoanId();
        for (uint256 loanId = 1; loanId < nextLoanId; loanId++) {
            (address borrower, uint256 collateral, uint256 debt,, bool settled) = lbsc.loans(loanId);
            if (!settled) {
                if (borrower == address(0) || collateral == 0) {
                    invalidLoanFound = true;
                    break;
                }
                sumCollateral += collateral;
                sumDebt += debt;
                openLoans++;
            }
        }
    }
}
