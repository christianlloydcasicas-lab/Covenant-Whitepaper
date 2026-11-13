# CovenantVaultV3 notes

## What changed from v2
- Fees are fixed by the contract (bounded, owner-adjustable). Callers no longer pass a COV amount.
- Pay in USDC, or in COV with a discount (default 25%).
- USDC fees: 40% queued for buyback-and-burn of COV, 60% to the treasury (both adjustable within bounds).
- COV fees: 70% burned (20% when supply is under 5M), the rest to the stabilization vault.
- `executeBuyback(usdcAmount)` is callable by anyone. It spends only queued fee USDC, enforces a
  slippage floor against the price source, and burns the COV actually received.
- Token-free mode: USDC fees work even if COV is not configured.

## Behavior changes to be aware of
- The low-supply decay now applies to all COV fees (v2 applied it only to the trust fee).
- Divorce fee is paid by whoever calls the split, in addition to the 50/50 split of household USDC.

## Mainnet blockers (testnet uses mocks)
- MockPriceSource is owner-set. Replace with a TWAP or oracle; discounts and slippage floors read from it.
- MockBuybackRouter is a stand-in DEX. Replace with a real adapter and a liquid pool.
- Owner is a single key. Use a multisig plus timelock for fees, price source and router.
- Still unaudited. Still missing: birth verification, mutual withdrawal, recovery path,
  personal pockets, real child trust vault, attester/mediator staking, governance.

## Run
    forge install OpenZeppelin/openzeppelin-contracts foundry-rs/forge-std
    forge test
    forge script script/DeployV3.s.sol --rpc-url base_sepolia --broadcast --account deployer
