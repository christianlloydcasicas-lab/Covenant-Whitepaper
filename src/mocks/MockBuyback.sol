// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceSource, IBuybackRouter} from "../CovenantVaultV3.sol";

/**
 * @title MockPriceSource
 * @notice TESTNET ONLY. Owner-set price. On mainnet replace with a TWAP or oracle.
 * @dev covPerUsdc is the amount of $COV (18 decimals) worth 1 USDC (1e6 units).
 *      Example: $COV = $0.10 -> 10 $COV per USDC -> covPerUsdc = 10e18.
 */
contract MockPriceSource is IPriceSource, Ownable {
    uint256 public covPerUsdc;

    constructor(uint256 _covPerUsdc) Ownable(msg.sender) {
        covPerUsdc = _covPerUsdc;
    }

    function setCovPerUsdc(uint256 _covPerUsdc) external onlyOwner {
        covPerUsdc = _covPerUsdc;
    }

    function usdcToCov(uint256 usdcAmount) external view returns (uint256) {
        return (usdcAmount * covPerUsdc) / 1e6;
    }
}

/**
 * @title MockBuybackRouter
 * @notice TESTNET ONLY. Stands in for a DEX: swaps USDC for $COV at the price
 * source's rate out of a pre-funded $COV reserve. `deliveryBps` lets tests
 * simulate a bad price (slippage or manipulation).
 */
contract MockBuybackRouter is IBuybackRouter {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    IERC20 public immutable cov;
    IPriceSource public immutable priceSource;
    uint256 public deliveryBps = 10_000;

    constructor(address _usdc, address _cov, address _priceSource) {
        usdc = IERC20(_usdc);
        cov = IERC20(_cov);
        priceSource = IPriceSource(_priceSource);
    }

    /// @dev Open on purpose: this is a mock for tests and testnet demos.
    function setDeliveryBps(uint256 bps) external {
        deliveryBps = bps;
    }

    function swapUsdcForCov(uint256 usdcIn, uint256 minCovOut) external returns (uint256 covOut) {
        usdc.safeTransferFrom(msg.sender, address(this), usdcIn);
        covOut = (priceSource.usdcToCov(usdcIn) * deliveryBps) / 10_000;
        require(covOut >= minCovOut, "Router: slippage");
        cov.safeTransfer(msg.sender, covOut);
    }
}
