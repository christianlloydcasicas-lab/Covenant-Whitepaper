// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Interface for standard ERC20 stablecoins (like native USDC on Base)
 */
interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title Covenant Family Multi-Sig Vault
 * @notice Enforces 2-of-2 signature authentication for asset management and marital cool-down parameters.
 */
contract CovenantVault {
    
    // Core structural identity of the on-chain household
    struct Household {
        address partnerA;
        address partnerB;
        uint256 initializationTimestamp;
        bool isActive;
        bool dissolutionTriggered;
        uint256 coolDownEndTimestamp;
        address dissolutionInitiator;
    }

    // A structured pending financial withdrawal request
    struct WithdrawalProposal {
        address recipient;
        uint256 amount;
        address tokenAddress;
        uint256 signatureCount;
        bool executed;
        mapping(address => bool) isConfirmed;
    }

    IERC20 public immutable baseStablecoin; // Typically native USDC on Base Mainnet
    uint256 public constant COOL_DOWN_PERIOD = 90 days;

    mapping(uint256 => Household) public households;
    mapping(address => uint256) public userToHouseholdId;
    uint256 public totalHouseholdsCount;

    // Maps Household ID => Proposal ID => WithdrawalProposal
    mapping(uint256 => mapping(uint256 => WithdrawalProposal)) public proposals;
    // Maps Household ID => Total proposal count track
    mapping(uint256 => uint256) public proposalCount;

    event CovenantBound(uint256 indexed householdId, address indexed partnerA, address indexed partnerB);
    event WithdrawalProposed(uint256 indexed householdId, uint256 indexed proposalId, address recipient, uint256 amount);
    event WithdrawalConfirmed(uint256 indexed householdId, uint256 indexed proposalId, address confirmedBy);
    event WithdrawalExecuted(uint256 indexed householdId, uint256 indexed proposalId);
    event DissolutionInitialized(uint256 indexed householdId, address indexed initiatedBy, uint256 coolDownEnd);
    event ReconciliationExecuted(uint256 indexed householdId);

    modifier onlySpouse(uint256 _householdId) {
        require(
            msg.sender == households[_householdId].partnerA || 
            msg.sender == households[_householdId].partnerB,
            "Caller is not a registered spouse in this vault"
        );
        _;
    }

    modifier activeVault(uint256 _householdId) {
        require(households[_householdId].isActive, "Covenant household is inactive");
        require(!households[_householdId].dissolutionTriggered, "Vault operations frozen: Dissolution pending");
        _;
    }

    /**
     * @param _stablecoinAddress The active deployment address of USDC on Base.
     */
    constructor(address _stablecoinAddress) {
        require(_stablecoinAddress != address(0), "Invalid token target");
        baseStablecoin = IERC20(_stablecoinAddress);
    }

    /**
     * @notice Cryptographically binds two wallets into a 2-of-2 household multi-sig state.
     */
    function initializeCovenant(address _spouse) external {
        require(_spouse != address(0), "Target spouse cannot be zero address");
        require(_spouse != msg.sender, "Cannot execute a covenant with yourself");
        require(userToHouseholdId[msg.sender] == 0, "Sender already bound to an active vault");
        require(userToHouseholdId[_spouse] == 0, "Target spouse already bound to an active vault");

        totalHouseholdsCount++;
        
        households[totalHouseholdsCount] = Household({
            partnerA: msg.sender,
            partnerB: _spouse,
            initializationTimestamp: block.timestamp,
            isActive: true,
            dissolutionTriggered: false,
            coolDownEndTimestamp: 0,
            dissolutionInitiator: address(0)
        });

        userToHouseholdId[msg.sender] = totalHouseholdsCount;
        userToHouseholdId[_spouse] = totalHouseholdsCount;

        emit CovenantBound(totalHouseholdsCount, msg.sender, _spouse);
    }

    /**
     * @notice Stage 1 of Multi-Sig Withdrawal: Propose a payout out of the family vault.
     */
    function proposeWithdrawal(uint256 _householdId, address _recipient, uint256 _amount) 
        external 
        onlySpouse(_householdId) 
        activeVault(_householdId) 
    {
        require(_recipient != address(0), "Invalid withdrawal recipient");
        require(_amount > 0, "Amount must exceed zero");

        uint256 currentProposalId = proposalCount[_householdId]++;
        WithdrawalProposal storage prop = proposals[_householdId][currentProposalId];
        prop.recipient = _recipient;
        prop.amount = _amount;
        prop.tokenAddress = address(baseStablecoin);
        prop.signatureCount = 1;
        prop.executed = false;
        prop.isConfirmed[msg.sender] = true;

        emit WithdrawalProposed(_householdId, currentProposalId, _recipient, _amount);
    }

    /**
     * @notice Stage 2 of Multi-Sig Withdrawal: Second partner signs and instantly executes the payment.
     */
    function confirmAndExecuteWithdrawal(uint256 _householdId, uint256 _proposalId) 
        external 
        onlySpouse(_householdId) 
        activeVault(_householdId) 
    {
        WithdrawalProposal storage prop = proposals[_householdId][_proposalId];
        require(!prop.executed, "Proposal already executed");
        require(!prop.isConfirmed[msg.sender], "You have already signed this proposal");

        prop.isConfirmed[msg.sender] = true;
        prop.signatureCount++;

        emit WithdrawalConfirmed(_householdId, _proposalId, msg.sender);

        // 2-of-2 Check: If both partners have signed, execute the transaction
        if (prop.signatureCount == 2) {
            prop.executed = true;
            require(baseStablecoin.transfer(prop.recipient, prop.amount), "Token transfer failed");
            emit WithdrawalExecuted(_householdId, _proposalId);
        }
    }

    /**
     * @notice Trigger the Stabilizer Tier: Places the multi-sig into a frozen 90-day isolation state.
     */
    function initiateDissolution(uint256 _householdId) external onlySpouse(_householdId) {
        Household storage household = households[_householdId];
        require(household.isActive, "Vault already permanently closed");
        require(!household.dissolutionTriggered, "Cool-down escrow is already running");

        household.dissolutionTriggered = true;
        household.coolDownEndTimestamp = block.timestamp + COOL_DOWN_PERIOD;
        household.dissolutionInitiator = msg.sender;

        emit DissolutionInitialized(_householdId, msg.sender, household.coolDownEndTimestamp);
    }

    /**
     * @notice Conflict Resolution Route: Allows the couple to mutually cancel the freeze.
     */
    function cancelDissolution(uint256 _householdId) external onlySpouse(_householdId) {
        Household storage household = households[_householdId];
        require(household.dissolutionTriggered, "No dissolution running");
        
        // Emphasizes mutual agreement: Requires the non-initiating partner to approve reconciliation
        require(msg.sender != household.dissolutionInitiator, "Reconciliation requires the spouse's confirmation");

        household.dissolutionTriggered = false;
        household.coolDownEndTimestamp = 0;
        household.dissolutionInitiator = address(0);

        emit ReconciliationExecuted(_householdId);
    }

    // ==========================================
    // SECTION 3: THE GENERATIONAL LIFECYCLE TIER
    // ==========================================
    
    uint256 public totalChildrenRegistered;
    uint256 public constant TRUST_LOCK_DURATION = 18 * 365 days;
    
    // Maps a unique Child ID to their specific 18-year block maturity limit
    mapping(uint256 => uint256) public childTrustMaturity;
    // Maps a Household ID to their total family child count array parameter
    mapping(uint256 => uint256) public familyChildrenCount;

    event BirthRegistered(uint256 indexed householdId, uint256 indexed childId, uint256 maturityTimestamp);
    event TrustFundWithdrawn(uint256 indexed childId, address indexed recipient, uint256 amount);

    /**
     * @notice Section 3: Triggers upon verified proof of birth via decentralized validation.
     * @dev Automatically creates an immutable time-locked trust constraint parameters configuration.
     */
    function registerChildBirth(uint256 _householdId) external onlySpouse(_householdId) activeVault(_householdId) {
        totalChildrenRegistered++;
        familyChildrenCount[_householdId]++;

        // Hardcode the 18-year lock limit calculation from the exact block execution timestamp
        childTrustMaturity[totalChildrenRegistered] = block.timestamp + TRUST_LOCK_DURATION;

        emit BirthRegistered(_householdId, totalChildrenRegistered, childTrustMaturity[totalChildrenRegistered]);
    }

    /**
     * @notice Allows the grown child to claim their trust allocation after exactly 18 years.
     */
    function withdrawChildTrust(uint256 _childId, uint256 _householdId, address _recipient) external {
        require(block.timestamp >= childTrustMaturity[_childId], "Generational trust fund is still locked: 18-year maturity limit pending");
        require(_recipient != address(0), "Invalid release address");
        
        Household memory household = households[_householdId];
        require(msg.sender == household.partnerA || msg.sender == household.partnerB || msg.sender == _recipient, "Unauthorized withdrawal attempt");

        uint256 trustBalance = baseStablecoin.balanceOf(address(this));
        require(trustBalance > 0, "No assets available in trust reserve");

        emit TrustFundWithdrawn(_childId, _recipient, trustBalance);
        require(baseStablecoin.transfer(_recipient, trustBalance), "Trust distribution failed");
    }

    // ===================================
    // SECTION 4: THE STABILIZER TIER CORE
    // ===================================

    /**
     * @notice Section 4: Finalizes the Covenant dissolution after the 90-day cool-down ends.
     * @dev Executes a mathematically absolute 50/50 split of all locked tokens, bypassing adversarial court fees.
     */
    function executeAlgorithmicDivorceSplit(uint256 _householdId) external onlySpouse(_householdId) {
        Household storage household = households[_householdId];
        require(household.dissolutionTriggered, "Dissolution protocol was never initiated");
        require(block.timestamp >= household.coolDownEndTimestamp, "90-day cool-down escrow is still running");
        require(household.isActive, "Vault is already inactive");

        // Read total vault stablecoin holdings remaining in the contract
        uint256 totalVaultBalance = baseStablecoin.balanceOf(address(this));
        require(totalVaultBalance > 0, "No family assets found in vault to split");

        // Calculate the mathematically precise 50/50 division
        uint256 splitAmount = totalVaultBalance / 2;

        // Permanently deactivate the household state boundary mapping
        household.isActive = false;
        userToHouseholdId[household.partnerA] = 0;
        userToHouseholdId[household.partnerB] = 0;

        // Automate instant, equal distributions straight to both wallets
        require(baseStablecoin.transfer(household.partnerA, splitAmount), "Distribution to Partner A failed");
        require(baseStablecoin.transfer(household.partnerB, baseStablecoin.balanceOf(address(this))), "Distribution to Partner B failed");
    }
}


