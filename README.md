# 🏛️ COVENANT ($COV)

A decentralized, programmable relational lifecycle engine designed to establish economic stability for modern marriages, protect child trust assets, and mathematically mitigate adversarial divorce costs. Built on secure 2-of-2 state-gated multi-signature infrastructure and powered by the hard-capped **$COV** utility token.

> **Status:** Testnet. Contracts are unaudited and must not be used with real funds. Features marked **(Roadmap)** are designed but not yet implemented on-chain.

---

## 🗺️ Protocol Architecture Overview

Covenant functions as an automated family sovereign fund split into three sequential lifecycles:

1. **The Foundation Tier (Marriage):** Couples bind their wallets into a strict 2-of-2 state layout. Each household holds its own USDC balance, isolated from every other household, and accrues a **Tenure Multiplier** that grows through generational milestones and voluntary $COV commitment. *(Roadmap: routing pooled USDC into low-risk lending registries, and using the multiplier to scale yield.)*
2. **The Generational Tier (Birth):** A birth event initializes a **Generational Trust** record for the child, time-locked for exactly 18 years, and raises the household's Tenure Multiplier. *(Roadmap: Zero-Knowledge Proof verification of birth registry events via decentralized validation layers, so no sensitive civil data touches the chain. Today the trigger is gated to the household's spouses only.)*
3. **The Stabilizer Tier (Divorce Prevention):** Any dissolution trigger starts a mandatory **90-day isolation freeze**. During the freeze, the non-initiating partner can cancel the dissolution and restore the household. If the freeze expires uncancelled, the engine executes an absolute 50/50 partition of the household's USDC, bypassing courtroom fees.

---

## 🪙 $COV Tokenomics

$COV is the protocol's utility and commitment asset. USDC holds the family's money; $COV is what couples spend to use the protocol's lifecycle features, and almost all of it is permanently destroyed when they do.

### Supply

| Parameter | Value |
|---|---|
| Standard | ERC-20 with burn |
| Supply model | Fixed. Entire supply minted once at deployment; no mint function exists |
| Testnet supply | 10,000,000 $COV (configurable at deploy) |
| Supply direction | Only decreases, through burns |
| Allocation / distribution | `[TBD before mainnet]` |

### The 4-Tier Burn Model

| Tier | Trigger | Who pays | Mechanism |
|---|---|---|---|
| **1 & 2: Divorce Settlement** | Executing the 50/50 split after the 90-day freeze | Spouse executing the split | Fee is split **70% burned / 30% to the Stabilization Vault** |
| **3: Generational Trust** | Initializing a child trust | Either spouse | Cost is **100% burned** while supply ≥ 5,000,000 $COV; under that floor, **20% burned / 80% to the Stabilization Vault** |
| **4: Commitment Boost** | Voluntary | Either spouse | **100% burned.** Every 100 $COV burned adds +1 to the household's Tenure Multiplier |

### Dynamic Burn Decay

Deflation slows itself down. Once circulating supply falls below **5,000,000 $COV**, Tier 3 shifts from a full burn to a 20% burn, with the remainder recycled into the Stabilization Vault. This protects the token from burning toward zero and keeps $COV available for future households.

### Stabilization Vault

A protocol-level address that receives the non-burned share of fees. It exists to recycle liquidity back into the network rather than lock it away. Its governance and spending rules are `[TBD]`.

### Stablecoin Isolation

All household funds are denominated in USDC and accounted **per household**. A split only ever pays out the dissolving household's own balance. $COV never touches the family's savings; it only pays fees.

---

## 🔐 Security Model

* Token configuration is owner-only and can be set exactly once.
* All token movements use SafeERC20 and reentrancy guards; state is updated before external calls.
* The contract is **unaudited**. A professional audit is required before any mainnet launch.

---

## 🛠️ Public Smart Contract Deployments

**v1 (core multi-sig vault, no tokenomics):** open source and live on test networks.

* **Ethereum Sepolia (Chain ID: 11155111):** `0x8D25a7396b2e7888bD2Aca0f57BfA139C464A3BA`
* **Base Sepolia (Chain ID: 84532):** `0x1565403F107CC08e5cf59235347D1C2fEcbEeFe9`

**v2 (tokenomics, per-household balances, hardened):** not yet deployed.

* **Ethereum Sepolia:** `[pending]` (vault) / `[pending]` ($COV)
* **Base Sepolia:** `[pending]` (vault) / `[pending]` ($COV)

v1 and v2 are separate deployments; households created on v1 do not carry over.

---

## 🚀 Dev Setup & Testing

**Foundry (recommended)**

```bash
forge install OpenZeppelin/openzeppelin-contracts foundry-rs/forge-std
forge test
forge script script/Deploy.s.sol --rpc-url sepolia --broadcast --verify
```

**Remix IDE sandbox**

1. Open [Remix IDE](https://remix.ethereum.org) and add `CovToken.sol` and `CovenantVault.sol`.
2. Set the Solidity compiler to `0.8.24` or higher (OpenZeppelin 5.x imports resolve automatically from npm).
3. Deploy `CovToken(initialHolder, initialSupply)`, then `CovenantVault(mockUSDC, stabilizationVault)` on the **Remix VM**.
4. As the deployer, call `setCovUtilityToken(<CovToken address>)`.
5. Approve the vault for USDC and $COV from each spouse wallet, then simulate the full lifecycle at zero cost.

---

## 🧭 Roadmap

* ZK birth-registry verification for generational trusts
* Yield routing and Tenure Multiplier–based yield scaling
* Mutual-consent withdrawals from the household vault
* Stabilization Vault governance
* Third-party security audit
* Token allocation and distribution plan
