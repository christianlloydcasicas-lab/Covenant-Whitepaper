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

/**
 * @title CovenantVault
 * @author Christian Lloyd Casicas
 * @notice 2-of-2 state-gated multi-signature relational lifecycle treasury engine.
 * Incorporates a 4-Tier Burn model, Dynamic Decay, and Stablecoin-Denominated access logic.
 */
contract CovenantVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for ICovToken;

    // ------------------------------------------------------------------
    // Token anchors
    // ------------------------------------------------------------------
    IERC20 public immutable baseStablecoin; // Official testnet USDC
    ICovToken public covUtilityToken;       // Hard-capped $COV utility asset (set once by owner)

    // ------------------------------------------------------------------
    // Protocol parameters
    // ------------------------------------------------------------------
    uint256 public constant COOL_DOWN_PERIOD = 90 days;
    uint256 public constant BASE_ENTRY_USD_VALUE = 100 * 10 ** 6; // $100 USDC benchmark
    uint256 public constant LOW_SUPPLY_THRESHOLD = 5_000_000 * 10 ** 18;
    uint256 public constant LOW_SUPPLY_BURN_PERCENT = 20; // Tier 3 decay burn share
    uint256 public constant DIVORCE_BURN_PERCENT = 70;    // Tier 1 & 2 burn share
    uint256 public constant BOOST_UNIT = 100 * 10 ** 18;  // $COV burned per +1 multiplier
    uint256 public constant TRUST_MATURITY = 18 * 365 days;

    address public immutable stabilizationVault; // Recycles fractional liquidity back to network

    // ------------------------------------------------------------------
    // Storage
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
        uint256 stablecoinBalance; // USDC owned by this household only
    }

    mapping(uint256 => Household) public households;

    // HouseholdId -> ChildId -> ReleaseTimestamp
    mapping(uint256 => mapping(uint256 => uint256)) public childTrusts;

    uint256 public totalHouseholdsInitialized;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------
    event RelationalVaultInitialized(
        uint256 indexed householdId,
        address indexed partnerA,
        address indexed partnerB
    );
    event CovUtilityTokenSet(address indexed token);
    event StablecoinDeposited(uint256 indexed householdId, address indexed from, uint256 amount);
    event DissolutionStateTriggered(
        uint256 indexed householdId,
        address indexed initiator,
        uint256 lockReleaseTimestamp
    );
    event ReconciliationExecuted(uint256 indexed householdId);
    event AlgorithmicPartitionFinalized(
        uint256 indexed householdId,
        uint256 totalBurnedCOV,
        uint256 routedToStabilization
    );
    event GenerationalTrustInitialized(
        uint256 indexed householdId,
        uint256 indexed childId,
        uint256 maturationTimestamp
    );
    event CommitmentBoostApplied(uint256 indexed householdId, uint256 tokensBurned);

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
    // Constructor / configuration
    // ------------------------------------------------------------------
    constructor(address _stablecoinAddress, address _stabilizationVault) Ownable(msg.sender) {
        require(_stablecoinAddress != address(0), "Invalid baseline asset layout mapping");
        require(_stabilizationVault != address(0), "Invalid asset recycling pool endpoint");

        baseStablecoin = IERC20(_stablecoinAddress);
        stabilizationVault = _stabilizationVault;
    }

    /**
     * @notice Sets the native $COV token address once. Owner only.
     */
    function setCovUtilityToken(address _covTokenAddress) external onlyOwner {
        require(address(covUtilityToken) == address(0), "Utility link already mapped");
        require(_covTokenAddress != address(0), "Zero token address");
        covUtilityToken = ICovToken(_covTokenAddress);
        emit CovUtilityTokenSet(_covTokenAddress);
    }

    // ------------------------------------------------------------------
    // Household lifecycle
    // ------------------------------------------------------------------

    /**
     * @notice Cryptographically binds two partner wallets into an active household multi-sig state.
     */
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

    /**
     * @notice Deposits USDC into this household's own balance. Requires prior USDC approval.
     */
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

    /**
     * @notice Burn Tier 4: Voluntary Commitment Boost.
     * Couples voluntarily burn $COV to scale up their Tenure Multiplier without waiting for time accumulation.
     */
    function voluntaryCommitmentBoost(uint256 _householdId, uint256 _covAmountToBurn)
        external
        nonReentrant
        tokenConfigured
        onlyHouseholdSpouse(_householdId)
    {
        Household storage household = households[_householdId];
        require(household.isActive, "Household vault is not active");
        require(_covAmountToBurn > 0, "Amount must be greater than zero");

        // Algorithmic multiplier scale based on volume burned
        household.tenureMultipliers += _covAmountToBurn / BOOST_UNIT;

        covUtilityToken.safeTransferFrom(msg.sender, address(this), _covAmountToBurn);
        covUtilityToken.burn(_covAmountToBurn);

        emit CommitmentBoostApplied(_householdId, _covAmountToBurn);
    }

    /**
     * @notice Burn Tier 3: Generational Trust Initialization.
     * Spins off a child trust record maturing in 18 years.
     * @dev The original design says this is triggered via a verified ZK oracle; that
     * verification is not implemented yet, so any spouse can currently call it.
     * Under the low-supply threshold only 20% is burned and the rest is routed to the
     * stabilization vault; otherwise the full cost is burned.
     */
    function initializeGenerationalTrust(uint256 _householdId, uint256 _covAccessCost)
        external
        nonReentrant
        tokenConfigured
        onlyHouseholdSpouse(_householdId)
    {
        Household storage household = households[_householdId];
        require(household.isActive, "Target environment is completely dead");

        // Dynamic Burn Decay: burn factor depends on current supply
        uint256 burnAllocation = _covAccessCost;
        if (covUtilityToken.totalSupply() < LOW_SUPPLY_THRESHOLD) {
            burnAllocation = (_covAccessCost * LOW_SUPPLY_BURN_PERCENT) / 100;
        }
        uint256 toStabilization = _covAccessCost - burnAllocation;

        // Effects
        uint256 currentChildId = ++household.childTrustCount;
        uint256 maturation = block.timestamp + TRUST_MATURITY;
        childTrusts[_householdId][currentChildId] = maturation;
        household.tenureMultipliers += 1; // Generational scaling reward

        // Interactions
        covUtilityToken.safeTransferFrom(msg.sender, address(this), _covAccessCost);
        if (burnAllocation > 0) {
            covUtilityToken.burn(burnAllocation);
        }
        if (toStabilization > 0) {
            covUtilityToken.safeTransfer(stabilizationVault, toStabilization);
        }

        emit GenerationalTrustInitialized(_householdId, currentChildId, maturation);
    }

    // ------------------------------------------------------------------
    // Dissolution flow
    // ------------------------------------------------------------------

    /**
     * @notice Enforces a mandatory 90-day time freeze block to protect household capital assets.
     */
    function initiateDissolution(uint256 _householdId) external onlyHouseholdSpouse(_householdId) {
        Household storage household = households[_householdId];
        require(household.isActive, "Relational registry is already terminated");
        require(!household.isDissolutionActive, "Cool-down lock is already active");

        household.isDissolutionActive = true;
        household.dissolutionTriggerTime = block.timestamp;
        household.dissolutionInitiator = msg.sender;

        emit DissolutionStateTriggered(_householdId, msg.sender, block.timestamp + COOL_DOWN_PERIOD);
    }

    /**
     * @notice Escape Valve: the non-initiating spouse can drop the conflict state.
     */
    function cancelDissolution(uint256 _householdId) external onlyHouseholdSpouse(_householdId) {
        Household storage household = households[_householdId];
        require(household.isDissolutionActive, "No active relational freeze block found");
        require(
            msg.sender != household.dissolutionInitiator,
            "Mutual verification constraint check failed"
        );

        household.isDissolutionActive = false;
        household.dissolutionTriggerTime = 0;
        household.dissolutionInitiator = address(0);

        emit ReconciliationExecuted(_householdId);
    }

    /**
     * @notice Burn Tier 1 & 2: Volatility Divorce Burn & Anniversary Longevity Settlement Fee.
     * After the cool-down, splits this household's USDC 50/50 and settles the $COV fee
     * (70% burned, 30% routed to the stabilization vault).
     */
    function executeAlgorithmicDivorceSplit(uint256 _householdId, uint256 _covFeeImpact)
        external
        nonReentrant
        tokenConfigured
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

        uint256 tokensToBurn = (_covFeeImpact * DIVORCE_BURN_PERCENT) / 100;
        uint256 tokensToStabilization = _covFeeImpact - tokensToBurn;

        // Effects first
        household.isActive = false;
        household.isDissolutionActive = false;
        household.stablecoinBalance = 0;

        uint256 shareA = totalBalance / 2;
        uint256 shareB = totalBalance - shareA; // odd unit goes to partner B

        // Interactions
        covUtilityToken.safeTransferFrom(msg.sender, address(this), _covFeeImpact);
        if (tokensToBurn > 0) {
            covUtilityToken.burn(tokensToBurn);
        }
        if (tokensToStabilization > 0) {
            covUtilityToken.safeTransfer(stabilizationVault, tokensToStabilization);
        }

        baseStablecoin.safeTransfer(household.partnerA, shareA);
        baseStablecoin.safeTransfer(household.partnerB, shareB);

        emit AlgorithmicPartitionFinalized(_householdId, tokensToBurn, tokensToStabilization);
    }
}
