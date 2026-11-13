# CovenantVaultV31 notes (v3.1)

Everything in V3_NOTES.md still applies. Changes in v3.1:

## Proportional decay threshold
- The vault records `initialCovSupply` (the $COV total supply) when `setCovUtilityToken` is called.
- Decay starts when supply falls below 50% of that (`DECAY_THRESHOLD_BPS = 5000`). With 20M initial supply, that is 10M.
- Views: `decayThreshold()` and `isDecayActive()`.
- Link the token right after deploying it. If tokens are burned before linking, the recorded supply is lower.

## Decay now covers both burn paths
- $COV-paid fees: 70% burned normally, 20% under the threshold (rest to the stabilization vault).
- Buyback: 100% of the bought $COV is burned normally; under the threshold only 20% is burned and 80% goes to the stabilization vault.
- Voluntary commitment boosts are exempt: the user chooses to burn.
- `BuybackExecuted(usdcSpent, covReceived, covBurned, covToStabilization)` has a new signature.

## Same mainnet blockers as v3
Mock price source and router, single-key owner, no audit, and the missing safety features
(mutual withdrawal, personal pockets, recovery, real child trust vault).

## Tests
74 tests pass (v2 suite, v3 suite, v3.1 suite including fuzz tests for fee and burn conservation).

## Run
    forge test
    forge script script/DeployV31.s.sol --rpc-url https://sepolia.base.org --broadcast --account deployer
