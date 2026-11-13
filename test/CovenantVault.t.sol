// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CovToken} from "../src/CovToken.sol";
import {CovenantVault} from "../src/CovenantVault.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CovenantVaultTest is Test {
    MockUSDC usdc;
    CovToken cov;
    CovenantVault vault;

    address owner = address(this);
    address stabilization = makeAddr("stabilization");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address attacker = makeAddr("attacker");

    uint256 constant SUPPLY = 10_000_000 ether;

    function setUp() public {
        usdc = new MockUSDC();
        cov = new CovToken(owner, SUPPLY);
        vault = new CovenantVault(address(usdc), stabilization);
        vault.setCovUtilityToken(address(cov));

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

    // ---- configuration ----

    function test_setCovToken_onlyOwner() public {
        CovenantVault fresh = new CovenantVault(address(usdc), stabilization);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        fresh.setCovUtilityToken(address(cov));
    }

    function test_setCovToken_onlyOnce() public {
        vm.expectRevert("Utility link already mapped");
        vault.setCovUtilityToken(address(cov));
    }

    function test_tokenFunctionsRevertIfTokenUnset() public {
        CovenantVault fresh = new CovenantVault(address(usdc), stabilization);
        vm.prank(alice);
        uint256 id = fresh.initializeCovenant(bob);
        vm.prank(alice);
        vm.expectRevert("COV token not set");
        fresh.voluntaryCommitmentBoost(id, 1 ether);
    }

    // ---- household basics ----

    function test_initializeCovenant() public {
        uint256 id = _household(alice, bob);
        assertEq(id, 1);
        (address a, address b, bool active, uint256 tenure,,,, uint256 kids, uint256 bal) = vault.households(id);
        assertEq(a, alice);
        assertEq(b, bob);
        assertTrue(active);
        assertEq(tenure, 1);
        assertEq(kids, 0);
        assertEq(bal, 0);
    }

    function test_selfLinkRejected() public {
        vm.prank(alice);
        vm.expectRevert("Self-linking configuration is programmatically restricted");
        vault.initializeCovenant(alice);
    }

    function test_onlySpouseCanDeposit() public {
        uint256 id = _household(alice, bob);
        vm.prank(attacker);
        vm.expectRevert("Caller is not a registered cryptographic spouse in this household vault");
        vault.depositStablecoin(id, 1e6);
    }

    // ---- tokenomics ----

    function test_boostBurnsAndScalesMultiplier() public {
        uint256 id = _household(alice, bob);
        vm.prank(alice);
        vault.voluntaryCommitmentBoost(id, 300 ether);

        (,,, uint256 tenure,,,,,) = vault.households(id);
        assertEq(tenure, 1 + 3);
        assertEq(cov.totalSupply(), SUPPLY - 300 ether);
        assertEq(cov.balanceOf(address(vault)), 0);
    }

    function test_generationalTrust_fullBurnAboveThreshold() public {
        uint256 id = _household(alice, bob);
        vm.prank(alice);
        vault.initializeGenerationalTrust(id, 1_000 ether);

        assertEq(cov.totalSupply(), SUPPLY - 1_000 ether);
        assertEq(cov.balanceOf(stabilization), 0);
        assertEq(vault.childTrusts(id, 1), block.timestamp + 18 * 365 days);
    }

    function test_generationalTrust_decayBelowThreshold() public {
        // Push supply under 5M by burning from the owner's remaining balance
        cov.burn(cov.balanceOf(owner) - 100 ether);
        assertLt(cov.totalSupply(), 5_000_000 ether);

        uint256 id = _household(alice, bob);
        uint256 supplyBefore = cov.totalSupply();
        vm.prank(alice);
        vault.initializeGenerationalTrust(id, 1_000 ether);

        assertEq(cov.totalSupply(), supplyBefore - 200 ether); // 20% burned
        assertEq(cov.balanceOf(stabilization), 800 ether);     // 80% recycled
        assertEq(cov.balanceOf(address(vault)), 0);            // nothing stuck
    }

    // ---- dissolution ----

    function test_cancelDissolution_initiatorCannotCancel() public {
        uint256 id = _household(alice, bob);
        vm.prank(alice);
        vault.initiateDissolution(id);

        vm.prank(alice);
        vm.expectRevert("Mutual verification constraint check failed");
        vault.cancelDissolution(id);

        vm.prank(bob);
        vault.cancelDissolution(id);
        (,,,,,, bool dissolving,,) = vault.households(id);
        assertFalse(dissolving);
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
        vault.executeAlgorithmicDivorceSplit(id, 100 ether);
    }

    function test_split_halvesBalanceAndSettlesFee() public {
        uint256 id = _household(alice, bob);
        vm.prank(alice);
        vault.depositStablecoin(id, 1_001e6 + 1); // odd amount
        vm.prank(alice);
        vault.initiateDissolution(id);
        vm.warp(block.timestamp + 90 days);

        uint256 aBefore = usdc.balanceOf(alice);
        uint256 bBefore = usdc.balanceOf(bob);
        uint256 supplyBefore = cov.totalSupply();

        vm.prank(bob);
        vault.executeAlgorithmicDivorceSplit(id, 1_000 ether);

        uint256 total = 1_001e6 + 1;
        assertEq(usdc.balanceOf(alice) - aBefore, total / 2);
        assertEq(usdc.balanceOf(bob) - bBefore, total - total / 2);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(cov.totalSupply(), supplyBefore - 700 ether);
        assertEq(cov.balanceOf(stabilization), 300 ether);

        (,, bool active,,,, bool dissolving,, uint256 bal) = vault.households(id);
        assertFalse(active);
        assertFalse(dissolving);
        assertEq(bal, 0);
    }

    function test_split_onlyPaysOutOwnHouseholdFunds() public {
        uint256 idAB = _household(alice, bob);
        uint256 idCD = _household(carol, dave);

        vm.prank(alice);
        vault.depositStablecoin(idAB, 1_000e6);
        vm.prank(carol);
        vault.depositStablecoin(idCD, 5_000e6);

        vm.prank(alice);
        vault.initiateDissolution(idAB);
        vm.warp(block.timestamp + 90 days);
        vm.prank(bob);
        vault.executeAlgorithmicDivorceSplit(idAB, 0);

        // Household C+D's funds are untouched
        assertEq(usdc.balanceOf(address(vault)), 5_000e6);
        (,,,,,,,, uint256 balCD) = vault.households(idCD);
        assertEq(balCD, 5_000e6);
    }

    function test_split_cannotRunTwice() public {
        uint256 id = _household(alice, bob);
        vm.prank(alice);
        vault.depositStablecoin(id, 1_000e6);
        vm.prank(alice);
        vault.initiateDissolution(id);
        vm.warp(block.timestamp + 90 days);
        vm.prank(bob);
        vault.executeAlgorithmicDivorceSplit(id, 0);

        vm.prank(bob);
        vm.expectRevert("Escrow barrier is not initialized");
        vault.executeAlgorithmicDivorceSplit(id, 0);
    }
}
