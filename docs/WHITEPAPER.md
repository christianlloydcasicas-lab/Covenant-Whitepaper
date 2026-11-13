# 🏛️ COVENANT ($COV)

A decentralized, programmable relational lifecycle engine designed to establish economic stability for modern marriages, protect child trust assets, and mathematically mitigate adversarial divorce costs. Built on secure 2-of-2 state-gated multi-signature infrastructure, with a revenue-backed utility token, **$COV**.

> **Built for Base.** Current testnet deployments are on Base Sepolia.
>
> **Status: Testnet.** Contracts are unaudited and must not be used with real funds. Testnet tokens have no value. Features marked **(Roadmap)** are designed but not yet implemented. Nothing here is investment, legal or financial advice.

---

## 🗺️ Protocol Architecture Overview

Covenant functions as an automated family sovereign fund split into three sequential lifecycles:

1. **The Foundation Tier (Marriage):** Couples bind their wallets into a strict 2-of-2 state layout. Each household holds its own USDC balance, isolated from every other household, and accrues a **Tenure Multiplier** through generational milestones and voluntary $COV commitment. *(Roadmap: lending/yield routing for pooled USDC, and using the multiplier to scale benefits.)*
2. **The Generational Tier (Birth):** A birth event creates a **Generational Trust** record for the child, time-locked for exactly 18 years, and raises the household's Tenure Multiplier. *(Roadmap: Zero-Knowledge or attester-based birth verification, and a real child trust sub-vault that holds funds. Today the trigger is limited to the household's spouses.)*
3. **The Stabilizer Tier (Divorce Prevention):** Any dissolution trigger starts a mandatory **90-day isolation freeze**. During the freeze, the non-initiating partner can cancel and restore the household. If the freeze expires uncancelled, the engine executes a 50/50 split of that household's USDC, bypassing courtroom fees.

---

## 🪙 $COV Tokenomics (v3.1)

$COV is a utility and commitment token modeled on exchange platform tokens: the protocol earns **USDC revenue**, and a share of that revenue buys and burns $COV. Users can also pay fees in $COV at a discount. Nobody is required to hold $COV to use the protocol's core functions.

### Supply

| Parameter | Value |
|---|---|
| Standard | ERC-20 with burn |
| Supply model | Fixed. The entire supply is minted once at deployment; no mint function exists |
| Testnet supply | 10,000,000 $COV |
| Mainnet supply | `[TBD]` (currently planned: 20,000,000 $COV) |
| Supply direction | Only decreases, through burns |
| Allocation / distribution | `[TBD before mainnet]` |

### Fixed, contract-set fees

Fees are set by the contract, never chosen by the caller, and the owner can only adjust them within hard bounds (1 to 1,000 USDC).

| Action | Fee (testnet default) | Paid by |
|---|---|---|
| Create a generational trust | 20 USDC | The spouse who calls it |
| Execute the divorce split (after the 90-day freeze) | 50 USDC | The spouse who calls it |

### Two ways to pay

- **USDC:** the full fee. 60% goes to the treasury and **40% is queued for buyback-and-burn** of $COV.
- **$COV:** a **25% discount** (adjustable up to 50%), priced by a price source. Of the $COV paid, **70% is burned and 30% goes to the Stabilization Vault**. Once supply falls below the **decay threshold** (see below), the burn share drops to 20% and 80% is recycled, so deflation slows as supply thins.

### Buyback-and-burn

`executeBuyback` can be called by anyone. It spends only queued fee USDC (never household funds), enforces a slippage floor against the price source, measures the $COV actually received, and burns it. Under the decay threshold, only 20% of the bought $COV is burned and 80% goes to the Stabilization Vault. Revenue therefore drives scarcity, rather than users being forced to buy a token.

### Decay threshold

The burn slows once supply has fallen far enough, so burning does not run to zero. The threshold is **50% of the initial supply**, recorded on-chain when $COV is linked to the vault (for a 20,000,000 supply, that is 10,000,000). Because it is a percentage, it scales with whatever supply is launched.

| | Above the threshold | Below the threshold |
|---|---|---|
| $COV-paid fees | 70% burned, 30% recycled | 20% burned, 80% recycled |
| Buyback | 100% burned | 20% burned, 80% recycled |
| Voluntary Commitment Boost | 100% burned | 100% burned (the burn is the user's own choice) |

### Voluntary Commitment Boost

Spouses can burn $COV to raise their household's Tenure Multiplier: every 100 $COV burned adds +1. A trust adds +1 as well. *(Roadmap: tie the multiplier to fee discounts or other benefits.)*

### Token-free mode

If $COV is not configured, USDC fees still work. The token adds discounts and burns on top of a working protocol and is not a requirement to use it.

### Stabilization Vault

A protocol address that receives the recycled share of $COV fees. Its governance and spending rules are `[TBD]`.

---

## ✅ Testnet Proof (Base Sepolia, v3 fee flow)

The fee flow was executed on-chain:

- A trust fee paid in **USDC**: 20 USDC in, **12 USDC to the treasury, 8 USDC queued**.
- `executeBuyback(8 USDC)`: the queue returned to 0 and **80 $COV were bought and burned**.
- A trust fee paid in **$COV**: **150 $COV** paid (20 USDC less 25%, at a mock price of 10 $COV per USDC), **105 burned and 45 sent** to the Stabilization Vault, with nothing left in the vault.
- Supply after these tests: 9,999,815 $COV (from 10,000,000).

**v3.1 decay threshold, on-chain (Base Sepolia).** After deployment, the vault recorded the initial supply (10,000,000 $COV) and a decay threshold of 5,000,000. With the trust fee set to 2 USDC for testing:

- Above the threshold, a buyback of 0.8 USDC bought 8 $COV and **burned all 8** (supply 9,999,992).
- After burning 5,000,000 test $COV to cross the threshold, the same buyback bought 8 $COV and **burned 1.6 and recycled 6.4** to the Stabilization Vault (supply 4,999,990.4).

The decay logic is also covered by automated tests, including fuzz tests showing every bought $COV is either burned or recycled. The 90-day freeze and the divorce split are covered by an automated test suite (Foundry) that simulates the passage of time. They can't be waited out on a live testnet.

---

## 🔐 Security & Known Limitations

* **Unaudited.** A professional audit is required before any mainnet launch.
* **Testnet uses mocks.** The price source is an owner-set mock and the buyback router is a stand-in for a DEX. Mainnet requires a manipulation-resistant price source (TWAP or oracle) and a real, liquid pool.
* **Single-key owner on testnet.** Mainnet requires a multisig with a timelock for fee, price-source and router changes.
* Token configuration is owner-only and can be set once. Token movements use SafeERC20 and reentrancy guards, and state changes happen before external calls.
* Funds can currently leave a household only through the divorce split. Mutual withdrawal, personal pockets and a recovery path are on the roadmap, and are needed before the protocol can responsibly hold real value.
* The freeze protects against impulsive separation, but it can also hold shared funds for 90 days. Protections for a partner who needs to leave a controlling relationship are on the roadmap.
* The 50/50 rule and on-chain splits do not override family-law requirements in any jurisdiction.

---

## 🛠️ Public Smart Contract Deployments

Covenant is built for **Base**. The current deployments are on **Base Sepolia (Chain ID: 84532)**.

**v3.1 (current): fixed fees, $COV discount, revenue-backed buyback-and-burn, proportional decay threshold**

* CovenantVaultV31: `0x27B5F5cEE8CB63312f11cb1AC7F54A06A0cE43c1`
* $COV token: `0x6ad9DCeA78Bf4eE9768445a9d46ae034BEbd346f`
* MockPriceSource (testnet only): `0xea4b30ac2227E0a8abD3677C574DF42EE203Ec04`
* MockBuybackRouter (testnet only): `0x922a2Fd83eE91472Aa3Ca7A22F541813D2988bb1`

Source code is verified on Blockscout.

**Earlier versions on Base Sepolia**

* v3 (fixed fees, $COV discount, buyback-and-burn; fixed 5M decay threshold): vault `0x8a47D79d2dA9268edF320eF2Ed4079349d1377BE`, $COV `0x3688d493591730dD0A7BEa9FD9E07a25a91350a7`, MockPriceSource `0xd6e9f65BDa639DDA6B7899f00766eF20c4b4d938`, MockBuybackRouter `0x796239f6BC033a67a0A4eC986F9AB41dc5Ec700d`
* v2 (per-household balances, hardened, caller-set $COV amounts): vault `0x9A4e347951F946dBCE69Ecf5276468c8BD516f90`, $COV `0xFb1C4e2b60ac469904F91981D8df23162EdCafDC`
* v1 (core multi-sig vault): `0x1565403F107CC08e5cf59235347D1C2fEcbEeFe9`

**Legacy: Ethereum Sepolia (Chain ID: 11155111)**, kept for reference only. These are earlier versions and are not being developed further.

* v2: vault `0xe1Ee6eBB26354D9132b9DC68fBa1d890343b0041`, $COV `0xD2B743D2c0FCb920Cf2c3d859D7E14F04c6a07ed`
* v1: `0x8D25a7396b2e7888bD2Aca0f57BfA139C464A3BA`

Each version is a separate deployment. Households and tokens do not carry over between versions.

---

## 🚀 Dev Setup & Testing

```bash
forge install OpenZeppelin/openzeppelin-contracts foundry-rs/forge-std
forge test
forge script script/DeployV31.s.sol --rpc-url <your-rpc> --broadcast --account <your-keystore>
```

Set `USDC_ADDRESS`, `TREASURY` and `STABILIZATION_VAULT` in `.env` first (see `.env.example`). The `V3_NOTES.md` file lists the behaviors and mainnet blockers in detail.

---

## 🧭 Roadmap

* Mutual withdrawals, personal pockets, and a recovery path for lost keys
* A real child trust sub-vault, with attester or ZK birth verification
* Attester and mediator staking, with slashing
* Real price oracle (TWAP) and a DEX adapter for the buyback
* Multisig and timelock ownership, and Stabilization Vault governance
* Yield routing, and Tenure Multiplier benefits
* Legal review and a third-party security audit
* Token allocation and distribution plan
