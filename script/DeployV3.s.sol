// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CovToken} from "../src/CovToken.sol";
import {CovenantVaultV3} from "../src/CovenantVaultV3.sol";
import {MockPriceSource, MockBuybackRouter} from "../src/mocks/MockBuyback.sol";

/**
 * TESTNET deploy for v3. Deploys $COV, the vault, and the mock price source and buyback
 * router, wires them together, and funds the mock router with a $COV reserve.
 *
 * Required env vars:
 *   USDC_ADDRESS          testnet USDC for the target network (verify against Circle's docs)
 *   TREASURY              receives the non-buyback share of USDC fees
 *   STABILIZATION_VAULT   receives the recycled share of $COV fees
 * Optional:
 *   COV_INITIAL_SUPPLY    in wei (default 10,000,000 * 1e18)
 *   COV_PER_USDC          mock price, $COV (18 dec) per 1 USDC (default 10e18, i.e. $0.10 per COV)
 *   ROUTER_RESERVE_COV    $COV sent to the mock router (default 1,000,000 * 1e18)
 *
 * Mainnet must NOT use the mocks. Replace them with a TWAP/oracle price source and a real
 * DEX adapter, and make the owner a multisig with a timelock.
 */
contract DeployV3 is Script {
    function run()
        external
        returns (CovToken cov, CovenantVaultV3 vault, MockPriceSource price, MockBuybackRouter router)
    {
        address usdc = vm.envAddress("USDC_ADDRESS");
        address treasury = vm.envAddress("TREASURY");
        address stabilization = vm.envAddress("STABILIZATION_VAULT");
        uint256 supply = vm.envOr("COV_INITIAL_SUPPLY", uint256(10_000_000 ether));
        uint256 covPerUsdc = vm.envOr("COV_PER_USDC", uint256(10 ether));
        uint256 reserve = vm.envOr("ROUTER_RESERVE_COV", uint256(1_000_000 ether));

        vm.startBroadcast();

        // The deployer receives the full supply so it can fund the router reserve.
        cov = new CovToken(msg.sender, supply);
        vault = new CovenantVaultV3(usdc, treasury, stabilization);
        vault.setCovUtilityToken(address(cov));

        price = new MockPriceSource(covPerUsdc);
        router = new MockBuybackRouter(usdc, address(cov), address(price));
        vault.setPriceSource(address(price));
        vault.setBuybackRouter(address(router));

        cov.transfer(address(router), reserve);

        vm.stopBroadcast();

        console2.log("COV token:         ", address(cov));
        console2.log("CovenantVaultV3:   ", address(vault));
        console2.log("MockPriceSource:   ", address(price));
        console2.log("MockBuybackRouter: ", address(router));
        console2.log("Owner:             ", vault.owner());
    }
}
