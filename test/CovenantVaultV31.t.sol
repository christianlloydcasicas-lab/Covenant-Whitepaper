// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CovToken} from "../src/CovToken.sol";
import {CovenantVaultV31} from "../src/CovenantVaultV31.sol";
import {MockPriceSource, MockBuybackRouter} from "../src/mocks/MockBuyback.sol";

contract TestUSDC31 is ERC20 {
    constructor() ERC20("Test USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CovenantVaultV31Test is Test {
    TestUSDC31 usdc;
    CovToken cov;
    CovenantVaultV31 vault;
    MockPriceSource price;
    MockBuybackRouter router;

    address owner = address(this);
    address treasury = makeAddr("treasury");
    address stabilization = makeAddr("stabilization");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address attacker = makeAddr("attacker");

    uint256 constant SUPPLY = 10_000_000 ether;
    uint256 constant COV_PER_USDC = 10 ether; // $COV = $0.10

    function setUp() public {
        usdc = new TestUSDC31();
        cov = new CovToken(owner, SUPPLY);
        vault = new CovenantVaultV31(address(usdc), treasury, stabilization);
        vault.setCovUtilityToken(address(cov));

        price = new MockPriceSource(COV_PER_USDC);
        router = new MockBuybackRouter(address(usdc), address(cov), address(price));
        vault.setPriceSource(address(price));
        vault.setBuybackRouter(address(router));

        cov.transfer(address(router), 1_000_000 ether); // buyback reserve

        address[4] memory users = [alice, bob, carol, dave];
        for (uint256 i; i < users.length; ++i) {
            usdc.mint(users[i], 10_000e6);
            cov.transfer(users[i], 100_000 ether);
            vm.startPrank(users[i]);
            usdc.approve(address(vault), type(uint256).max);
            cov.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _household(address a, address b) internal returns (uint256 id) {
        vm.prank(a);
        id = vault.initializeCovenant(b);
    }

    // ------------------------------------------------------------------
    // Fixed fees: the caller cannot choose the amount
    // ------------------------------------------------------------------

    function test_trustFee_isFixed_andSplitBetweenTreasuryAndBuyback() public {
        uint256 id = _household(alice, bob);
        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        vault.initializeGenerationalTrust(id, false);

        assertEq(aliceBefore - usdc.balanceOf(alice), 20e6);   // exactly the fixed fee
        assertEq(usdc.balanceOf(treasury), 12e6);               // 60%
        assertEq(vault.pendingBuybackUsdc(), 8e6);              // 40%
        assertEq(usdc.balanceOf(address(vault)), 8e6);
    }

    function test_trustFee_cannotBeSkippedWithoutAllowance() public {
        uint256 id = _household(alice, bob);
        vm.prank(alice);
        usdc.approve(address(vault), 0);

        vm.prank(alice);
        vm.expectRevert();
        vault.initializeGenerationalTrust(id, false);
    }

    function test_trustFee_cov_discountAndBurn() public {
        uint256 id = _household(alice, bob);
        uint256 aliceCovBefore = cov.balanceOf(alice);
        uint256 supplyBefore = cov.totalSupply();

        // 20 USDC less 25% = 15 USDC = 150 COV at 10 COV per USDC
        assertEq(vault.feeQuote(20e6, true), 150 ether);

        vm.prank(alice);
        vault.initializeGenerationalTrust(id, true);

        assertEq(aliceCovBefore - cov.balanceOf(alice), 150 ether);
        assertEq(supplyBefore - cov.totalSupply(), 105 ether);   // 70% burned
        assertEq(cov.balanceOf(stabilization), 45 ether);        // 30% recycled
        assertEq(cov.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(treasury), 0);                   // no USDC revenue when paying in COV
    }

    function test_covFee_lowSupply_burnsOnly20Percent() public {
        cov.burn(8_500_000 ether); // owner burns supply down to 1.5M
        assertLt(cov.totalSupply(), 5_000_000 ether);

        uint256 id = _household(alice, bob);
        uint256 supplyBefore = cov.totalSupply();

        vm.prank(alice);
        vault.initializeGenerationalTrust(id, true);

        assertEq(supplyBefore - cov.totalSupply(), 30 ether);    // 20% of 150
        assertEq(cov.balanceOf(stabilization), 120 ether);       // 80% recycled
        assertEq(cov.balanceOf(address(vault)), 0);
    }

    function test_trustFee_addsChildAndMultiplier() public {
        uint256 id = _household(alice, bob);
        vm.prank(alice);
        vault.initializeGenerationalTrust(id, false);

        assertEq(vault.childTrusts(id, 1), block.timestamp + 18 * 365 days);
        (,,, uint256 tenure,,,, uint256 kids,) = vault.households(id);
        assertEq(tenure, 2);
        assertEq(kids, 1);
    }

    // ------------------------------------------------------------------
    // Token-free mode
    // ------------------------------------------------------------------

    function test_tokenFreeMode_usdcFeesWorkWithoutCov() public {
        CovenantVaultV31 fresh = new CovenantVaultV31(address(usdc), treasury, stabilization);
        vm.prank(alice);
        uint256 id = fresh.initializeCovenant(bob);
        vm.prank(alice);
        usdc.approve(address(fresh), type(uint256).max);

        vm.prank(alice);
        fresh.initializeGenerationalTrust(id, false);
        assertEq(usdc.balanceOf(treasury), 12e6);

        vm.prank(alice);
        vm.expectRevert("COV token not set");
        fresh.initializeGenerationalTrust(id, true);
    }

    // ------------------------------------------------------------------
    // Divorce split
    // ------------------------------------------------------------------

    function _dissolve(uint256 id, address initiator) internal {
        vm.prank(initiator);
        vault.initiateDissolution(id);
        vm.warp(block.timestamp + 90 days);
    }

    function test_split_usdcFee_halvesBalance_andChargesCaller() public {
        uint256 id = _household(alice, bob);
        vm.prank(alice);
        vault.depositStablecoin(id, 1_000e6);
        _dissolve(id, alice);

        uint256 aBefore = usdc.balanceOf(alice);
        uint256 bBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        vault.executeAlgorithmicDivorceSplit(id, false);

        assertEq(usdc.balanceOf(alice) - aBefore, 500e6);
        assertEq(usdc.balanceOf(bob), bBefore + 500e6 - 50e6);   // bob pays the fixed 50 USDC fee
        assertEq(usdc.balanceOf(treasury), 30e6);
        assertEq(vault.pendingBuybackUsdc(), 20e6);
        assertEq(usdc.balanceOf(address(vault)), 20e6);          // only queued buyback USDC remains

        (,, bool active,,,, bool dissolving,, uint256 bal) = vault.households(id);
        assertFalse(active);
        assertFalse(dissolving);
        assertEq(bal, 0);
    }

    function test_split_covFee_discountAndBurn() public {
        uint256 id = _household(alice, bob);
        vm.prank(alice);
        vault.depositStablecoin(id, 1_000e6);
        _dissolve(id, alice);

        uint256 supplyBefore = cov.totalSupply();
        vm.prank(bob);
        vault.executeAlgorithmicDivorceSplit(id, true);

        // 50 USDC less 25% = 37.5 USDC = 375 COV; 70% burned
        assertEq(supplyBefore - cov.totalSupply(), 262.5 ether);
        assertEq(cov.balanceOf(stabilization), 112.5 ether);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_split_revertsDuringCooldown() public {
        uint256 id = _household(alice, bob);
        vm.prank(alice);
        vault.depositStablecoin(id, 1_000e6);
        vm.prank(alice);
        vault.initiateDissolution(id);
        vm.warp(block.timestamp + 90 days - 1);

        vm.prank(bob);
        vm.expectRevert("Cool-down lock is firmly active");
        vault.executeAlgorithmicDivorceSplit(id, false);
    }

    function test_split_onlyPaysOwnHouseholdFunds() public {
        uint256 idAB = _household(alice, bob);
        uint256 idCD = _household(carol, dave);
        vm.prank(alice);
        vault.depositStablecoin(idAB, 1_000e6);
        vm.prank(carol);
        vault.depositStablecoin(idCD, 5_000e6);
        _dissolve(idAB, alice);

        vm.prank(bob);
        vault.executeAlgorithmicDivorceSplit(idAB, false);

        (,,,,,,,, uint256 balCD) = vault.households(idCD);
        assertEq(balCD, 5_000e6);
        // vault holds household C+D funds plus queued buyback USDC, nothing else
        assertEq(usdc.balanceOf(address(vault)), 5_000e6 + vault.pendingBuybackUsdc());
    }

    function test_split_nonSpouseRejected() public {
        uint256 id = _household(alice, bob);
        vm.prank(attacker);
        vm.expectRevert("Caller is not a registered cryptographic spouse in this household vault");
        vault.executeAlgorithmicDivorceSplit(id, false);
    }

    // ------------------------------------------------------------------
    // Buyback and burn
    // ------------------------------------------------------------------

    function _queueBuyback() internal returns (uint256 id) {
        id = _household(alice, bob);
        vm.prank(alice);
        vault.initializeGenerationalTrust(id, false); // queues 8 USDC
    }

    function test_buyback_burnsCov_andClearsQueue_whenCalledByAnyone() public {
        _queueBuyback();
        uint256 supplyBefore = cov.totalSupply();

        vm.prank(attacker);
        vault.executeBuyback(8e6);

        assertEq(vault.pendingBuybackUsdc(), 0);
        assertEq(supplyBefore - cov.totalSupply(), 80 ether);    // 8 USDC at 10 COV per USDC
        assertEq(cov.balanceOf(address(vault)), 0);
        assertEq(cov.balanceOf(attacker), 0);                    // caller gets nothing
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(router)), 8e6);
        assertEq(usdc.allowance(address(vault), address(router)), 0);
    }

    function test_buyback_revertsOnBadPrice() public {
        _queueBuyback();
        router.setDeliveryBps(9_000); // router delivers 90%, floor is 95%

        vm.expectRevert("Router: slippage");
        vault.executeBuyback(8e6);
        assertEq(vault.pendingBuybackUsdc(), 8e6); // queue unchanged after revert
    }

    function test_buyback_acceptsWithinSlippage() public {
        _queueBuyback();
        router.setDeliveryBps(9_600);

        uint256 supplyBefore = cov.totalSupply();
        vault.executeBuyback(8e6);
        assertEq(supplyBefore - cov.totalSupply(), 76.8 ether);
    }

    function test_buyback_cannotSpendMoreThanQueued_orHouseholdFunds() public {
        uint256 id = _household(alice, bob);
        vm.prank(alice);
        vault.depositStablecoin(id, 1_000e6);

        vm.expectRevert("Invalid buyback amount");
        vault.executeBuyback(1);

        _queueBuyback();
        vm.expectRevert("Invalid buyback amount");
        vault.executeBuyback(8e6 + 1);
    }

    function test_buyback_requiresRouterAndPriceSource() public {
        CovenantVaultV31 fresh = new CovenantVaultV31(address(usdc), treasury, stabilization);
        fresh.setCovUtilityToken(address(cov));
        vm.expectRevert("Router not set");
        fresh.executeBuyback(1);
    }

    function test_buyback_partialAmounts() public {
        _queueBuyback();
        vault.executeBuyback(3e6);
        assertEq(vault.pendingBuybackUsdc(), 5e6);
        vault.executeBuyback(5e6);
        assertEq(vault.pendingBuybackUsdc(), 0);
    }

    // ------------------------------------------------------------------
    // Owner configuration
    // ------------------------------------------------------------------

    function test_setters_onlyOwner() public {
        vm.startPrank(attacker);
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker);

        vm.expectRevert(err);
        vault.setFees(10e6, 10e6);
        vm.expectRevert(err);
        vault.setCovDiscountBps(1_000);
        vm.expectRevert(err);
        vault.setRevenueSplit(1_000, 100);
        vm.expectRevert(err);
        vault.setPriceSource(attacker);
        vm.expectRevert(err);
        vault.setBuybackRouter(attacker);
        vm.stopPrank();
    }

    function test_setFees_enforcesBounds() public {
        vm.expectRevert("Trust fee out of bounds");
        vault.setFees(0, 50e6);
        vm.expectRevert("Trust fee out of bounds");
        vault.setFees(1_001e6, 50e6);
        vm.expectRevert("Divorce fee out of bounds");
        vault.setFees(20e6, 0);

        vault.setFees(5e6, 100e6);
        assertEq(vault.trustFeeUsdc(), 5e6);
        assertEq(vault.divorceFeeUsdc(), 100e6);
    }

    function test_discountAndSplit_boundsEnforced() public {
        vm.expectRevert("Discount too high");
        vault.setCovDiscountBps(5_001);
        vm.expectRevert("Buyback share too high");
        vault.setRevenueSplit(10_001, 100);
        vm.expectRevert("Slippage too high");
        vault.setRevenueSplit(4_000, 1_001);
    }

    function test_zeroBuybackShare_sendsAllFeesToTreasury() public {
        vault.setRevenueSplit(0, 500);
        uint256 id = _household(alice, bob);
        vm.prank(alice);
        vault.initializeGenerationalTrust(id, false);

        assertEq(usdc.balanceOf(treasury), 20e6);
        assertEq(vault.pendingBuybackUsdc(), 0);
    }

    function test_setCovUtilityToken_onlyOnce() public {
        vm.expectRevert("Utility link already mapped");
        vault.setCovUtilityToken(address(cov));
    }

    // ------------------------------------------------------------------
    // Voluntary boost still works
    // ------------------------------------------------------------------

    function test_boostBurnsAndScalesMultiplier() public {
        uint256 id = _household(alice, bob);
        uint256 supplyBefore = cov.totalSupply();
        vm.prank(alice);
        vault.voluntaryCommitmentBoost(id, 300 ether);

        (,,, uint256 tenure,,,,,) = vault.households(id);
        assertEq(tenure, 4);
        assertEq(supplyBefore - cov.totalSupply(), 300 ether);
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    /// Every USDC fee is fully accounted for: treasury plus queued buyback equals the fee.
    function testFuzz_usdcFee_isConserved(uint256 buybackBps, uint256 fee) public {
        buybackBps = bound(buybackBps, 0, 10_000);
        fee = bound(fee, 1e6, 1_000e6);
        vault.setRevenueSplit(buybackBps, 500);
        vault.setFees(fee, 50e6);

        uint256 id = _household(alice, bob);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.initializeGenerationalTrust(id, false);

        assertEq(aliceBefore - usdc.balanceOf(alice), fee);
        assertEq(usdc.balanceOf(treasury) + vault.pendingBuybackUsdc(), fee);
        assertEq(usdc.balanceOf(address(vault)), vault.pendingBuybackUsdc());
    }

    /// Paying in COV is always cheaper than USDC value for any valid discount and price.
    function testFuzz_covFee_neverExceedsFullPrice(uint256 discountBps, uint256 covPerUsdc) public {
        discountBps = bound(discountBps, 0, 5_000);
        covPerUsdc = bound(covPerUsdc, 1 ether / 100, 1_000_000 ether);
        vault.setCovDiscountBps(discountBps);
        price.setCovPerUsdc(covPerUsdc);

        uint256 fullPriceInCov = price.usdcToCov(20e6);
        assertLe(vault.feeQuote(20e6, true), fullPriceInCov);
    }

    /// No $COV is ever left stranded in the vault after a COV-paid fee.
    function testFuzz_covFee_leavesNoStrandedCov(uint256 supplyBurn) public {
        supplyBurn = bound(supplyBurn, 0, 8_500_000 ether);
        cov.burn(supplyBurn);
        uint256 id = _household(alice, bob);
        vm.prank(alice);
        vault.initializeGenerationalTrust(id, true);
        assertEq(cov.balanceOf(address(vault)), 0);
    }

    // ------------------------------------------------------------------
    // v3.1: proportional decay threshold
    // ------------------------------------------------------------------

    function test_initialSupplyRecorded_andThresholdIsProportional() public view {
        assertEq(vault.initialCovSupply(), SUPPLY);
        assertEq(vault.decayThreshold(), SUPPLY / 2);
        assertFalse(vault.isDecayActive());
    }

    function test_threshold_scalesWithInitialSupply() public {
        CovToken big = new CovToken(owner, 20_000_000 ether);
        CovenantVaultV31 v = new CovenantVaultV31(address(usdc), treasury, stabilization);
        v.setCovUtilityToken(address(big));

        assertEq(v.decayThreshold(), 10_000_000 ether);
        big.burn(9_999_999 ether);          // supply 10,000,001
        assertFalse(v.isDecayActive());
        big.burn(2 ether);                  // supply 9,999,999
        assertTrue(v.isDecayActive());
    }

    function test_decay_boundary_exactlyAtThresholdIsNotActive() public {
        cov.burn(5_000_000 ether);
        assertEq(cov.totalSupply(), vault.decayThreshold());
        assertFalse(vault.isDecayActive());
        cov.burn(1);
        assertTrue(vault.isDecayActive());
    }

    function test_decayInactive_whenTokenUnset() public {
        CovenantVaultV31 fresh = new CovenantVaultV31(address(usdc), treasury, stabilization);
        assertFalse(fresh.isDecayActive());
        assertEq(fresh.decayThreshold(), 0);
    }

    function test_buyback_aboveThreshold_burnsEverything() public {
        _queueBuyback();
        uint256 supplyBefore = cov.totalSupply();
        vault.executeBuyback(8e6);
        assertEq(supplyBefore - cov.totalSupply(), 80 ether);
        assertEq(cov.balanceOf(stabilization), 0);
    }

    function test_buyback_belowThreshold_burnsOnly20Percent() public {
        _queueBuyback();
        cov.burn(6_000_000 ether); // supply 4M, under the 5M threshold
        assertTrue(vault.isDecayActive());

        uint256 supplyBefore = cov.totalSupply();
        vault.executeBuyback(8e6);

        assertEq(supplyBefore - cov.totalSupply(), 16 ether);  // 20% of 80
        assertEq(cov.balanceOf(stabilization), 64 ether);      // 80% recycled
        assertEq(cov.balanceOf(address(vault)), 0);
    }

    function test_boost_isNotAffectedByDecay() public {
        cov.burn(6_000_000 ether);
        uint256 id = _household(alice, bob);
        uint256 supplyBefore = cov.totalSupply();
        vm.prank(alice);
        vault.voluntaryCommitmentBoost(id, 300 ether);
        assertEq(supplyBefore - cov.totalSupply(), 300 ether);
    }

    /// Every $COV received from a buyback is either burned or recycled, at any supply level.
    function testFuzz_buyback_conservesCov(uint256 supplyBurn) public {
        supplyBurn = bound(supplyBurn, 0, 8_600_000 ether);
        cov.burn(supplyBurn);
        _queueBuyback();

        uint256 supplyBefore = cov.totalSupply();
        uint256 stabBefore = cov.balanceOf(stabilization);
        vault.executeBuyback(8e6);

        uint256 burned = supplyBefore - cov.totalSupply();
        uint256 recycled = cov.balanceOf(stabilization) - stabBefore;
        assertEq(burned + recycled, 80 ether);
        assertEq(cov.balanceOf(address(vault)), 0);
    }
}
