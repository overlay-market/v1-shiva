// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {ILoanBasedStableCollateral} from "./ILoanBasedStableCollateral.sol";
import {IShiva} from "./IShiva.sol";
import {IPancakeSwapV3TWAPOracle} from "./IPancakeSwapV3TWAPOracle.sol";

import {AggregatorV3Interface} from
    "v1-core/lib/chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {
    IERC20MetadataUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {SafeERC20Upgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {MathUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IOverlayV1Token} from "v1-core/contracts/interfaces/IOverlayV1Token.sol";

/**
 * @title LoanBasedStableCollateral
 * @notice Implements the LBSC flow for borrowing OVL using stable collateral (e.g. USDT)
 */
contract LoanBasedStableCollateral is
    ILoanBasedStableCollateral,
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /// @notice Precision used to normalize price feed responses
    uint256 private constant WAD = 1e18;

    /**
     * @notice Represents a debt position funded through LBSC.
     * @param borrower Address that supplied the stable collateral.
     * @param collateral Amount of stable tokens held as collateral.
     * @param debt Amount of OVL (collateral + trading fees) lent out.
     * @param createdAt Timestamp when the loan was created.
     * @param settled Whether the loan has been closed.
     */
    struct LoanPosition {
        address borrower;
        uint256 collateral;
        uint256 debt;
        uint48 createdAt;
        bool settled;
    }

    /// @notice Stable token used as collateral (USDT)
    IERC20Upgradeable public stableToken;

    /// @notice OVL token lent out to Shiva
    IOverlayV1Token public ovlToken;

    /// @notice Oracle providing the OVL price in stable terms
    AggregatorV3Interface public priceFeed;

    /// @notice PancakeSwap V3 TWAP oracle (primary price source)
    IPancakeSwapV3TWAPOracle public twapOracle;

    /// @notice TWAP period in seconds for oracle queries
    uint32 public twapPeriod;

    /// @notice Address of the Shiva contract
    address public shiva;

    /// @notice Address receiving seized collateral on underwater settlements
    address public lossRecipient;

    /// @notice Maximum allowed oracle staleness (seconds)
    uint256 public maxPriceAge;

    /// @notice Next loan identifier
    uint256 public nextLoanId;

    /// @notice Total collateral locked across active loans
    uint256 public totalActiveCollateral;

    /// @notice Total outstanding OVL debt across active loans
    uint256 public totalOutstandingDebt;

    /// @notice Scaling factor derived from the stable token decimals
    uint256 private stableTokenUnit;

    /// @notice Mapping of loanId to LoanPosition
    mapping(uint256 => LoanPosition) public loans;

    modifier onlyShiva() {
        require(msg.sender == shiva, "LBSC: only Shiva");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the LBSC contract
     * @param _stableToken Address of the stablecoin used as collateral (USDT)
     * @param _shiva Address of the Shiva contract
     * @param _priceFeed Address of the oracle returning OVL price in stable terms
     * @param _lossRecipient Address that receives seized collateral (can be zero)
     * @param _maxPriceAge Maximum staleness allowed for oracle prices
     */
    function initialize(
        address _stableToken,
        address _shiva,
        address _priceFeed,
        address _lossRecipient,
        uint256 _maxPriceAge
    ) external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();

        require(_stableToken != address(0), "LBSC: stable token is zero");
        stableToken = IERC20Upgradeable(_stableToken);
        stableTokenUnit = 10 ** uint256(IERC20MetadataUpgradeable(_stableToken).decimals());
        require(stableTokenUnit > 0, "LBSC: invalid decimals");

        nextLoanId = 1;

        require(_maxPriceAge > 0, "LBSC: invalid max price age");
        maxPriceAge = _maxPriceAge;
        emit MaxPriceAgeUpdated(0, _maxPriceAge);

        require(_priceFeed != address(0), "LBSC: oracle is zero");
        priceFeed = AggregatorV3Interface(_priceFeed);
        emit PriceFeedUpdated(address(0), _priceFeed);

        lossRecipient = _lossRecipient;
        emit LossRecipientUpdated(address(0), _lossRecipient);

        _updateShiva(_shiva);

        ovlToken = IShiva(shiva).ovlToken();
        require(IERC20MetadataUpgradeable(address(ovlToken)).decimals() == 18, "LBSC: OVL token decimals != 18");

        // Set default TWAP period to 30 minutes
        twapPeriod = 1800;
    }

    /// @inheritdoc ILoanBasedStableCollateral
    function borrow(uint256 stableAmount, address borrower)
        external
        override
        nonReentrant
        onlyShiva
        returns (uint256 ovlAmount, uint256 loanId)
    {
        require(stableAmount > 0, "LBSC: zero collateral");

        uint256 price = _getPrice();
        ovlAmount = _calculateOvlAmount(stableAmount, price);
        require(ovlAmount > 0, "LBSC: zero OVL");

        uint256 availableOvl = ovlToken.balanceOf(address(this));
        require(availableOvl >= ovlAmount, "LBSC: insufficient OVL liquidity");

        stableToken.safeTransferFrom(borrower, address(this), stableAmount);
        totalActiveCollateral += stableAmount;
        totalOutstandingDebt += ovlAmount;

        require(block.timestamp <= type(uint48).max, "LBSC: timestamp overflow");

        loanId = nextLoanId++;
        uint48 createdAt = uint48(block.timestamp);
        loans[loanId] = LoanPosition({
            borrower: borrower,
            collateral: stableAmount,
            debt: ovlAmount,
            createdAt: createdAt,
            settled: false
        });

        // Approve Shiva to pull the freshly borrowed OVL amount only for this tx.
        ovlToken.approve(shiva, ovlAmount);

        emit LoanOpened(loanId, borrower, stableAmount, ovlAmount, price);
    }

    /// @inheritdoc ILoanBasedStableCollateral
    function settle(uint256 loanId, uint256 ovlAmount) external override nonReentrant onlyShiva {
        LoanPosition storage loan = loans[loanId];
        require(loan.borrower != address(0), "LBSC: invalid loan");
        require(!loan.settled, "LBSC: already settled");

        uint256 debt = loan.debt;
        uint256 collateral = loan.collateral;

        totalOutstandingDebt -= debt;
        totalActiveCollateral -= collateral;

        uint256 repayAmount = ovlAmount >= debt ? debt : ovlAmount;
        uint256 loss = debt - repayAmount;

        if (repayAmount > 0) {
            ovlToken.transferFrom(shiva, address(this), repayAmount);
        }

        uint256 collateralSeized = 0;
        uint256 collateralReturned = 0;

        if (loss == 0) {
            collateralReturned = collateral;
            stableToken.safeTransfer(loan.borrower, collateralReturned);
        } else {
            collateralSeized = MathUpgradeable.mulDiv(collateral, loss, debt);
            collateralReturned = collateral - collateralSeized;

            if (collateralReturned > 0) {
                stableToken.safeTransfer(loan.borrower, collateralReturned);
            }

            if (collateralSeized > 0) {
                if (lossRecipient != address(0)) {
                    stableToken.safeTransfer(lossRecipient, collateralSeized);
                }
            }
        }

        loan.settled = true;

        emit LoanSettled(loanId, loan.borrower, repayAmount, collateralReturned, collateralSeized);
    }

    /**
     * @notice Returns the amount of OVL that would be borrowed for a given stable amount.
     */
    function previewBorrow(uint256 stableAmount) external view returns (uint256) {
        require(stableAmount > 0, "LBSC: zero collateral");
        uint256 price = _getPrice();
        return _calculateOvlAmount(stableAmount, price);
    }

    /**
     * @notice Returns the latest oracle price used for conversions.
     */
    function currentPrice() external view returns (uint256) {
        return _getPrice();
    }

    /**
     * @notice Returns the surplus amount of stable tokens (not backing loans) that can be withdrawn.
     */
    function availableStableSurplus() public view returns (uint256) {
        uint256 balance = stableToken.balanceOf(address(this));
        if (balance <= totalActiveCollateral) {
            return 0;
        }
        return balance - totalActiveCollateral;
    }

    /**
     * @notice Withdraws surplus stable tokens that are not backing any active loan.
     * @param amount Amount of stable tokens to withdraw.
     * @param to Recipient of the withdrawn funds.
     */
    function withdrawStableSurplus(uint256 amount, address to) external onlyOwner {
        require(to != address(0), "LBSC: zero address");
        uint256 available = availableStableSurplus();
        require(amount <= available, "LBSC: insufficient surplus");
        stableToken.safeTransfer(to, amount);
        emit StableSurplusWithdrawn(to, amount);
    }

    /**
     * @notice Withdraws OVL liquidity (e.g. in emergencies).
     * @param amount Amount of OVL to withdraw.
     * @param to Recipient of the OVL.
     */
    function withdrawOvl(uint256 amount, address to) external onlyOwner {
        require(to != address(0), "LBSC: zero address");
        ovlToken.transfer(to, amount);
        emit OvlWithdrawn(to, amount);
    }

    /**
     * @notice Updates the Shiva contract.
     * @param newShiva Address of the new Shiva contract.
     */
    function setShiva(address newShiva) external onlyOwner {
        _updateShiva(newShiva);
    }

    /**
     * @notice Updates the price feed contract.
     * @param newFeed Address of the new oracle feed.
     */
    function setPriceFeed(address newFeed) external onlyOwner {
        require(newFeed != address(0), "LBSC: oracle is zero");
        address previous = address(priceFeed);
        priceFeed = AggregatorV3Interface(newFeed);
        emit PriceFeedUpdated(previous, newFeed);
    }

    /**
     * @notice Updates the TWAP oracle contract.
     * @param newOracle Address of the new TWAP oracle (can be zero to disable).
     */
    function setTwapOracle(address newOracle) external onlyOwner {
        address previous = address(twapOracle);
        twapOracle = IPancakeSwapV3TWAPOracle(newOracle);
        emit TwapOracleUpdated(previous, newOracle);
    }

    /**
     * @notice Updates the TWAP period used for oracle queries.
     * @param newPeriod New TWAP period in seconds.
     */
    function setTwapPeriod(uint32 newPeriod) external onlyOwner {
        require(newPeriod > 0, "LBSC: period is zero");
        require(newPeriod <= 7 days, "LBSC: period too long");
        uint32 previousPeriod = twapPeriod;
        twapPeriod = newPeriod;
        emit TwapPeriodUpdated(previousPeriod, newPeriod);
    }

    /**
     * @notice Updates the maximum allowed price age.
     * @param newMaxAge New maximum staleness in seconds.
     */
    function setMaxPriceAge(uint256 newMaxAge) external onlyOwner {
        require(newMaxAge > 0, "LBSC: invalid max price age");
        emit MaxPriceAgeUpdated(maxPriceAge, newMaxAge);
        maxPriceAge = newMaxAge;
    }

    /**
     * @notice Updates the address receiving seized collateral.
     * @param newRecipient Address of the new recipient (can be zero).
     */
    function setLossRecipient(address newRecipient) external onlyOwner {
        emit LossRecipientUpdated(lossRecipient, newRecipient);
        lossRecipient = newRecipient;
    }

    /**
     * @dev Internal helper to update Shiva reference.
     */
    function _updateShiva(address newShiva) internal {
        require(newShiva != address(0), "LBSC: Shiva is zero");
        address previousShiva = shiva;
        shiva = newShiva;

        emit ShivaUpdated(previousShiva, newShiva);
    }

    /**
     * @dev Returns the latest oracle price scaled to 1e18.
     * @dev Uses hybrid approach: TWAP as primary, Chainlink as fallback
     */
    function _getPrice() internal view returns (uint256) {
        // Try TWAP oracle first if configured
        if (address(twapOracle) != address(0)) {
            try twapOracle.getPrice(twapPeriod) returns (uint256 twapPrice) {
                // TWAP succeeded, return the price
                return twapPrice;
            } catch {
                // TWAP failed (insufficient cardinality or other error)
                // Fall through to Chainlink
            }
        }

        // Fallback to Chainlink oracle
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        require(answer > 0, "LBSC: invalid price");
        require(updatedAt != 0, "LBSC: incomplete price");
        require(answeredInRound >= roundId, "LBSC: stale round");
        if (maxPriceAge > 0) {
            require(block.timestamp - updatedAt <= maxPriceAge, "LBSC: price too old");
        }

        uint256 unsignedPrice = uint256(answer);
        uint256 decimals = priceFeed.decimals();

        if (decimals == 18) {
            return unsignedPrice;
        } else if (decimals > 18) {
            return unsignedPrice / (10 ** (decimals - 18));
        } else {
            return unsignedPrice * (10 ** (18 - decimals));
        }
    }

    /**
     * @dev Computes the amount of OVL to lend for a given stable amount/price.
     */
    function _calculateOvlAmount(uint256 stableAmount, uint256 price)
        internal
        view
        returns (uint256)
    {
        uint256 stableInWad = MathUpgradeable.mulDiv(stableAmount, WAD, stableTokenUnit);
        uint256 ovlAmount = MathUpgradeable.mulDiv(stableInWad, WAD, price);
        return ovlAmount;
    }

    /**
     * @dev Authorizes contract upgrades.
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
