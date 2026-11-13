// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev $COV needs a burn function on top of the standard ERC20 interface.
interface ICovToken is IERC20 {
    function burn(uint256 amount) external;
}

/// @dev Converts a USDC amount (6 decimals) into $COV (18 decimals).
/// Testnet uses an owner-set mock. Mainnet must use a manipulation-resistant
/// source (TWAP or oracle), because fee discounts and buyback slippage floors read from it.
interface IPriceSource {
    function usdcToCov(uint256 usdcAmount) external view returns (uint256 covAmount);
}

/// @dev DEX adapter. Pulls `usdcIn` from the caller, sends $COV to the caller.
interface IBuybackRouter {
    function swapUsdcForCov(uint256 usdcIn, uint256 minCovOut) external returns (uint256 covOut);
}

/**
 * @title CovenantVaultV3
 * @author Christian Lloyd Casicas
 * @notice 2-of-2 household vault with a revenue-backed $COV token model.
 *
 * Fee model:
 *  - Fees are FIXED by the contract (bounded, owner-adjustable), never chosen by the caller.
 *  - Users pay in USDC, or in $COV at a discount.
 *  - USDC fees: a share is queued for buyback-and-burn of $COV, the rest goes to the treasury.
 *  - $COV fees: burned (70%, or 20% when supply is under the low-supply threshold),
 *    the remainder goes to the stabilization vault.
 *  - Everything except the buyback works without $COV configured ("token-free mode").
 */
contract CovenantVaultV3 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for ICovToken;

    // ------------------------------------------------------------------
    // Immutable anchors
    // ------------------------------------------------------------------
    IERC20 public immutable baseStablecoin;
    address public immutable treasury;
    address public immutable stabilizationVault;

    // ------------------------------------------------------------------
    // Configured later by the owner
    // ------------------------------------------------------------------
    ICovToken public covUtilityToken;
    IPriceSource public priceSource;
    IBuybackRouter public buybackRouter;

    // ------------------------------------------------------------------
    // Fee parameters (USDC has 6 decimals)
    // ------------------------------------------------------------------
    uint256 public constant MIN_FEE_USDC = 1e6;
    uint256 public constant MAX_FEE_USDC = 1_000e6;
    uint256 public constant MAX_DISCOUNT_BPS = 5_000;  // up to 50% off for paying in $COV
    uint256 public constant MAX_SLIPPAGE_BPS = 1_000;  // up to 10% buyback slippage
    uint256 public constant BPS = 10_000;

    uint256 public trustFeeUsdc = 20e6;
    uint256 public divorceFeeUsdc = 50e6;
    uint256 public covDiscountBps = 2_500;  // 25% off when paying in $COV
    uint256 public buybackBps = 4_000;      // 40% of USDC fees queued for buyback-and-burn
    uint256 public maxSlippageBps = 500;    // 5% floor against the price source

    // $COV fee burn shares
    uint256 public constant NORMAL_COV_BURN_PERCENT = 70;
    uint256 public constant LOW_SUPPLY_COV_BURN_PERCENT = 20;
    uint256 public constant LOW_SUPPLY_THRESHOLD = 5_000_000 * 10 ** 18;

    // Voluntary boost and trust parameters
    uint256 public constant BOOST_UNIT = 100 * 10 ** 18;
    uint256 public constant COOL_DOWN_PERIOD = 90 days;
    uint256 public constant TRUST_MATURITY = 18 * 365 days;

    /// @notice USDC fees queued for buyback-and-burn. Never touches household balances.
    uint256 public pendingBuybackUsdc;

    // ------------------------------------------------------------------
    // Household storage
    // ------------------------------------------------------------------
    struct Household {
        address partnerA;
        address partnerB;
        bool isActive;
        uint256 tenureMultipliers;
        uint256 dissolutionTriggerTime;
        address dissolutionInitiator;
        bool isDissolutionActive;
        uint256 childTrustCount;
        uint256 stablecoinBalance;
    }

    mapping(uint256 => Household) public households;
    mapping(uint256 => mapping(uint256 => uint256)) public childTrusts; // household -> child -> release time
    uint256 public totalHouseholdsInitialized;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------
    event RelationalVaultInitialized(uint256 indexed householdId, address indexed partnerA, address indexed partnerB);
    event StablecoinDeposited(uint256 indexed householdId, address indexed from, uint256 amount);
    event DissolutionStateTriggered(uint256 indexed householdId, address indexed initiator, uint256 lockReleaseTimestamp);
    event ReconciliationExecuted(uint256 indexed householdId);
    event AlgorithmicPartitionFinalized(uint256 indexed householdId, uint256 shareA, uint256 shareB);
    event GenerationalTrustInitialized(uint256 indexed householdId, uint256 indexed childId, uint256 maturationTimestamp);
    event CommitmentBoostApplied(uint256 indexed householdId, uint256 tokensBurned);

    event FeePaidUsdc(address indexed payer, uint256 amount, uint256 toTreasury, uint256 toBuyback);
    event FeePaidCov(address indexed payer, uint256 amount, uint256 burned, uint256 toStabilization);
    event BuybackExecuted(uint256 usdcSpent, uint256 covBurned);

    event CovUtilityTokenSet(address indexed token);
    event PriceSourceSet(address indexed source);
    event BuybackRouterSet(address indexed router);
    event FeesUpdated(uint256 trustFeeUsdc, uint256 divorceFeeUsdc);
    event CovDiscountUpdated(uint256 discountBps);
    event RevenueSplitUpdated(uint256 buybackBps, uint256 maxSlippageBps);

    // ------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------
    modifier onlyHouseholdSpouse(uint256 _householdId) {
        Household storage h = households[_householdId];
        require(
            msg.sender == h.partnerA || msg.sender == h.partnerB,
            "Caller is not a registered cryptographic spouse in this household vault"
        );
        _;
    }

    modifier tokenConfigured() {
        require(address(covUtilityToken) != address(0), "COV token not set");
        _;
    }

    // ------------------------------------------------------------------
    // Constructor and owner configuration
    // ------------------------------------------------------------------
    constructor(address _stablecoin, address _treasury, address _stabilizationVault) Ownable(msg.sender) {
        require(_stablecoin != address(0), "Invalid stablecoin");
        require(_treasury != address(0), "Invalid treasury");
        require(_stabilizationVault != address(0), "Invalid stabilization vault");
        baseStablecoin = IERC20(_stablecoin);
        treasury = _treasury;
        stabilizationVault = _stabilizationVault;
    }

    /// @notice Sets the $COV token once.
    function setCovUtilityToken(address _token) external onlyOwner {
        require(address(covUtilityToken) == address(0), "Utility link already mapped");
        require(_token != address(0), "Zero token address");
        covUtilityToken = ICovToken(_token);
        emit CovUtilityTokenSet(_token);
    }

    function setPriceSource(address _source) external onlyOwner {
        require(_source != address(0), "Zero source");
        priceSource = IPriceSource(_source);
        emit PriceSourceSet(_source);
    }

    function setBuybackRouter(address _router) external onlyOwner {
        require(_router != address(0), "Zero router");
        buybackRouter = IBuybackRouter(_router);
        emit BuybackRouterSet(_router);
    }

    /// @notice Adjust fees within hard bounds. Use a multisig plus timelock as owner on mainnet.
    function setFees(uint256 _trustFeeUsdc, uint256 _divorceFeeUsdc) external onlyOwner {
        require(_trustFeeUsdc >= MIN_FEE_USDC && _trustFeeUsdc <= MAX_FEE_USDC, "Trust fee out of bounds");
        require(_divorceFeeUsdc >= MIN_FEE_USDC && _divorceFeeUsdc <= MAX_FEE_USDC, "Divorce fee out of bounds");
        trustFeeUsdc = _trustFeeUsdc;
        divorceFeeUsdc = _divorceFeeUsdc;
        emit FeesUpdated(_trustFeeUsdc, _divorceFeeUsdc);
    }

    function setCovDiscountBps(uint256 _discountBps) external onlyOwner {
        require(_discountBps <= MAX_DISCOUNT_BPS, "Discount too high");
        covDiscountBps = _discountBps;
        emit CovDiscountUpdated(_discountBps);
    }

    function setRevenueSplit(uint256 _buybackBps, uint256 _maxSlippageBps) external onlyOwner {
        require(_buybackBps <= BPS, "Buyback share too high");
        require(_maxSlippageBps <= MAX_SLIPPAGE_BPS, "Slippage too high");
        buybackBps = _buybackBps;
        maxSlippageBps = _maxSlippageBps;
        emit RevenueSplitUpdated(_buybackBps, _maxSlippageBps);
    }

    // ------------------------------------------------------------------
    // Fee helpers
    // ------------------------------------------------------------------

    /// @notice Amount the caller pays for a fee of `feeUsdc`: USDC units, or $COV wei with the discount.
    function feeQuote(uint256 feeUsdc, bool payInCov) public view returns (uint256 amount) {
        if (!payInCov) return feeUsdc;
        require(address(priceSource) != address(0), "Price source not set");
        uint256 discounted = (feeUsdc * (BPS - covDiscountBps)) / BPS;
        amount = priceSource.usdcToCov(discounted);
        require(amount > 0, "Zero COV quote");
    }

    function _collectFee(uint256 feeUsdc, bool payInCov) internal {
        if (!payInCov) {
            uint256 toBuyback = (feeUsdc * buybackBps) / BPS;
            uint256 toTreasury = feeUsdc - toBuyback;

            pendingBuybackUsdc += toBuyback;

            baseStablecoin.safeTransferFrom(msg.sender, address(this), feeUsdc);
            if (toTreasury > 0) {
                baseStablecoin.safeTransfer(treasury, toTreasury);
            }
            emit FeePaidUsdc(msg.sender, feeUsdc, toTreasury, toBuyback);
        } else {
            require(address(covUtilityToken) != address(0), "COV token not set");
            uint256 covAmount = feeQuote(feeUsdc, true);

            uint256 burnPercent = covUtilityToken.totalSupply() < LOW_SUPPLY_THRESHOLD
                ? LOW_SUPPLY_COV_BURN_PERCENT
                : NORMAL_COV_BURN_PERCENT;
            uint256 toBurn = (covAmount * burnPercent) / 100;
            uint256 toStabilization = covAmount - toBurn;

            covUtilityToken.safeTransferFrom(msg.sender, address(this), covAmount);
            covUtilityToken.burn(toBurn);
            if (toStabilization > 0) {
                covUtilityToken.safeTransfer(stabilizationVault, toStabilization);
            }
            emit FeePaidCov(msg.sender, covAmount, toBurn, toStabilization);
        }
    }

    // ------------------------------------------------------------------
    // Household lifecycle
    // ------------------------------------------------------------------
    function initializeCovenant(address _partnerB) external returns (uint256) {
        require(_partnerB != address(0), "Target mapping cannot point to dead zero configuration");
        require(msg.sender != _partnerB, "Self-linking configuration is programmatically restricted");

        uint256 id = ++totalHouseholdsInitialized;
        households[id] = Household({
            partnerA: msg.sender,
            partnerB: _partnerB,
            isActive: true,
            tenureMultipliers: 1,
            dissolutionTriggerTime: 0,
            dissolutionInitiator: address(0),
            isDissolutionActive: false,
            childTrustCount: 0,
            stablecoinBalance: 0
        });

        emit RelationalVaultInitialized(id, msg.sender, _partnerB);
        return id;
    }

    function depositStablecoin(uint256 _householdId, uint256 _amount)
        external
        nonReentrant
        onlyHouseholdSpouse(_householdId)
    {
        Household storage household = households[_householdId];
        require(household.isActive, "Household vault is not active");
        require(_amount > 0, "Amount must be greater than zero");

        household.stablecoinBalance += _amount;
        baseStablecoin.safeTransferFrom(msg.sender, address(this), _amount);

        emit StablecoinDeposited(_householdId, msg.sender, _amount);
    }

    /// @notice Voluntary commitment boost: burns $COV for a higher Tenure Multiplier.
    function voluntaryCommitmentBoost(uint256 _householdId, uint256 _covAmountToBurn)
        external
        nonReentrant
        tokenConfigured
        onlyHouseholdSpouse(_householdId)
    {
        Household storage household = households[_householdId];
        require(household.isActive, "Household vault is not active");
        require(_covAmountToBurn > 0, "Amount must be greater than zero");

        household.tenureMultipliers += _covAmountToBurn / BOOST_UNIT;

        covUtilityToken.safeTransferFrom(msg.sender, address(this), _covAmountToBurn);
        covUtilityToken.burn(_covAmountToBurn);

        emit CommitmentBoostApplied(_householdId, _covAmountToBurn);
    }

    /// @notice Creates a child trust record. Pays the fixed trust fee in USDC or discounted $COV.
    /// @dev Birth verification (ZK or attester) is not implemented yet.
    function initializeGenerationalTrust(uint256 _householdId, bool _payInCov)
        external
        nonReentrant
        onlyHouseholdSpouse(_householdId)
    {
        Household storage household = households[_householdId];
        require(household.isActive, "Target environment is completely dead");

        uint256 childId = ++household.childTrustCount;
        uint256 maturation = block.timestamp + TRUST_MATURITY;
        childTrusts[_householdId][childId] = maturation;
        household.tenureMultipliers += 1;

        _collectFee(trustFeeUsdc, _payInCov);

        emit GenerationalTrustInitialized(_householdId, childId, maturation);
    }

    // ------------------------------------------------------------------
    // Dissolution flow
    // ------------------------------------------------------------------
    function initiateDissolution(uint256 _householdId) external onlyHouseholdSpouse(_householdId) {
        Household storage household = households[_householdId];
        require(household.isActive, "Relational registry is already terminated");
        require(!household.isDissolutionActive, "Cool-down lock is already active");

        household.isDissolutionActive = true;
        household.dissolutionTriggerTime = block.timestamp;
        household.dissolutionInitiator = msg.sender;

        emit DissolutionStateTriggered(_householdId, msg.sender, block.timestamp + COOL_DOWN_PERIOD);
    }

    function cancelDissolution(uint256 _householdId) external onlyHouseholdSpouse(_householdId) {
        Household storage household = households[_householdId];
        require(household.isDissolutionActive, "No active relational freeze block found");
        require(msg.sender != household.dissolutionInitiator, "Mutual verification constraint check failed");

        household.isDissolutionActive = false;
        household.dissolutionTriggerTime = 0;
        household.dissolutionInitiator = address(0);

        emit ReconciliationExecuted(_householdId);
    }

    /// @notice After the 90-day freeze, splits the household's USDC 50/50.
    /// The caller pays the fixed divorce fee in USDC or discounted $COV.
    function executeAlgorithmicDivorceSplit(uint256 _householdId, bool _payInCov)
        external
        nonReentrant
        onlyHouseholdSpouse(_householdId)
    {
        Household storage household = households[_householdId];
        require(household.isDissolutionActive, "Escrow barrier is not initialized");
        require(
            block.timestamp >= household.dissolutionTriggerTime + COOL_DOWN_PERIOD,
            "Cool-down lock is firmly active"
        );
        require(household.isActive, "Vault is already empty and inactive");

        uint256 totalBalance = household.stablecoinBalance;
        require(totalBalance > 0, "No family assets found in vault to split");

        // Effects
        household.isActive = false;
        household.isDissolutionActive = false;
        household.stablecoinBalance = 0;

        uint256 shareA = totalBalance / 2;
        uint256 shareB = totalBalance - shareA; // odd unit goes to partner B

        // Interactions
        _collectFee(divorceFeeUsdc, _payInCov);
        baseStablecoin.safeTransfer(household.partnerA, shareA);
        baseStablecoin.safeTransfer(household.partnerB, shareB);

        emit AlgorithmicPartitionFinalized(_householdId, shareA, shareB);
    }

    // ------------------------------------------------------------------
    // Buyback and burn
    // ------------------------------------------------------------------

    /**
     * @notice Spends queued USDC fees to buy $COV and burn it. Anyone may call.
     * @dev Safety: spends only `pendingBuybackUsdc` (never household funds), enforces a
     * slippage floor against the price source, and measures the $COV actually received.
     */
    function executeBuyback(uint256 _usdcAmount) external nonReentrant tokenConfigured {
        require(address(buybackRouter) != address(0), "Router not set");
        require(address(priceSource) != address(0), "Price source not set");
        require(_usdcAmount > 0 && _usdcAmount <= pendingBuybackUsdc, "Invalid buyback amount");

        pendingBuybackUsdc -= _usdcAmount;

        uint256 minCovOut = (priceSource.usdcToCov(_usdcAmount) * (BPS - maxSlippageBps)) / BPS;

        uint256 covBefore = covUtilityToken.balanceOf(address(this));
        baseStablecoin.forceApprove(address(buybackRouter), _usdcAmount);
        buybackRouter.swapUsdcForCov(_usdcAmount, minCovOut);
        baseStablecoin.forceApprove(address(buybackRouter), 0);
        uint256 received = covUtilityToken.balanceOf(address(this)) - covBefore;

        require(received >= minCovOut, "Buyback slippage");
        covUtilityToken.burn(received);

        emit BuybackExecuted(_usdcAmount, received);
    }
}
