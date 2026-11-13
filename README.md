# 🏛️ Covenant ($COV)

**A programmable savings vault for couples, with a built-in cooling-off period and a revenue-backed utility token. Built for Base.**

> ⚠️ **Testnet only. Unaudited.** The contracts are deployed on Base Sepolia for testing. Do not use real funds. Testnet tokens have no value. Nothing here is investment, legal or financial advice.

Two partners bind their wallets into a 2-of-2 household vault. Each household holds its own USDC, accrues a Tenure Multiplier, can create 18-year child-trust records, and, if the relationship ends, goes through a mandatory **90-day freeze** that only the *other* partner can cancel. If the freeze expires, the household's USDC is split 50/50 on-chain.

📄 Full details: [`docs/WHITEPAPER.md`](docs/WHITEPAPER.md)

---

## How it works

| Stage | What happens |
|---|---|
| **Foundation** | `initializeCovenant` binds two wallets. Each household has an isolated USDC balance (`depositStablecoin`). |
| **Generational** | `initializeGenerationalTrust` creates a child-trust record locked for 18 years and raises the Tenure Multiplier. |
| **Stabilizer** | `initiateDissolution` starts a 90-day freeze. The non-initiating partner can `cancelDissolution`. After 90 days, `executeAlgorithmicDivorceSplit` splits the household's USDC 50/50. |

### The $COV token model (v3.1)

$COV is a fixed-supply utility token, modeled on exchange platform tokens: the protocol earns USDC revenue, and a share of it buys and burns $COV.

- **Fixed, contract-set fees:** 20 USDC per trust, 50 USDC per divorce split (bounded, owner-adjustable between 1 and 1,000 USDC). Callers cannot choose the amount.
- **Pay in USDC:** 60% to the treasury, 40% queued for buyback-and-burn.
- **Pay in $COV:** 25% discount. 70% burned, 30% to the Stabilization Vault.
- **`executeBuyback`** (callable by anyone): spends only queued fee USDC, enforces a slippage floor, burns the $COV received.
- **Decay threshold:** once supply falls below **50% of the initial supply** (recorded on-chain at link time), burns slow to 20% and 80% is recycled. Voluntary boosts are exempt.
- **Token-free mode:** USDC fees work without $COV configured.

---

## Deployed contracts (Base Sepolia, chain ID 84532)

**v3.1 (current)**

| Contract | Address |
|---|---|
| CovenantVaultV31 | [`0x27B5F5cEE8CB63312f11cb1AC7F54A06A0cE43c1`](https://base-sepolia.blockscout.com/address/0x27B5F5cEE8CB63312f11cb1AC7F54A06A0cE43c1) |
| $COV token | [`0x6ad9DCeA78Bf4eE9768445a9d46ae034BEbd346f`](https://base-sepolia.blockscout.com/address/0x6ad9DCeA78Bf4eE9768445a9d46ae034BEbd346f) |
| MockPriceSource (testnet only) | [`0xea4b30ac2227E0a8abD3677C574DF42EE203Ec04`](https://base-sepolia.blockscout.com/address/0xea4b30ac2227E0a8abD3677C574DF42EE203Ec04) |
| MockBuybackRouter (testnet only) | [`0x922a2Fd83eE91472Aa3Ca7A22F541813D2988bb1`](https://base-sepolia.blockscout.com/address/0x922a2Fd83eE91472Aa3Ca7A22F541813D2988bb1) |

All four are verified on Blockscout. Earlier versions (v1, v2, v3) are listed in the whitepaper.

### Check it yourself on-chain

- v3.1 vault creation: [`0xebf5efbf…3a49`](https://base-sepolia.blockscout.com/tx/0xebf5efbfb1b29bf73c2db7709ec9c843097a451494cbb5082545a579f2533a49)
- v3 proof, trust fee paid in USDC (20 USDC in, 12 to treasury, 8 queued): [`0x29a464e5…5790`](https://base-sepolia.blockscout.com/tx/0x29a464e569e4369ae25fd6ceae28e8093d215ce2be668d1dff43972accec5790)
- v3 proof, trust fee paid in $COV (150 paid, 105 burned, 45 recycled): [`0x459ba39a…421c`](https://base-sepolia.blockscout.com/tx/0x459ba39a2658f98c69c932b802167b7d30886b81d0602a6bbf5593b28d31421c)
- v3.1 decay test (done by calling the contracts from the command line): with supply above the threshold, a 0.8 USDC buyback burned all 8 $COV bought; after crossing the threshold, the same buyback burned 1.6 and recycled 6.4.

---

## Quickstart

Requires [Foundry](https://getfoundry.sh).

```bash
git clone --recurse-submodules https://github.com/christianlloydcasicas-lab/covenant-protocol.git
cd covenant-protocol          # or the folder name you cloned into
forge install                 # if the lib/ folder is empty
forge test                    # 74 tests
```

Deploy to Base Sepolia (copy `.env.example` to `.env` and fill it in first):

```bash
source .env
forge script script/DeployV31.s.sol --rpc-url https://sepolia.base.org --broadcast --account <your-keystore>
```

Never put a private key in `.env`. Use Foundry's encrypted keystore (`cast wallet new ~/.foundry/keystores <name>`).

## Repository layout

```
src/
  CovToken.sol                 $COV (fixed supply, burnable ERC-20)
  CovenantVaultV31.sol         Current vault (v3.1)
  CovenantVaultV3.sol          Previous vault (v3). Also holds shared interfaces
  CovenantVault.sol            v2 vault
  mocks/MockBuyback.sol        Testnet price source and buyback router
test/                          Foundry tests (fuzz tests included)
script/                        Deploy scripts
docs/WHITEPAPER.md             Whitepaper
V3_NOTES.md, V31_NOTES.md      Behavior notes and mainnet blockers
```

---

## Known limitations (read before reviewing)

- **Unaudited.** An audit is required before any mainnet plan.
- **Testnet uses mocks:** an owner-set price source and a stand-in DEX router. Mainnet needs a TWAP or oracle and a real pool.
- **Single-key owner** on testnet. Mainnet needs a multisig plus timelock.
- **Funds leave a household only through the divorce split.** Mutual withdrawal, personal pockets and a recovery path (lost key, death) are not built yet.
- **The 90-day freeze can hold shared funds**, which is a risk for a partner who needs to leave a controlling relationship. Protections are on the roadmap.
- **Generational trusts are records**, not funded sub-vaults. Birth verification is not implemented.
- The on-chain split does not override family law in any jurisdiction.

## Roadmap

1. Mutual withdrawals, personal pockets, recovery path
2. Real child-trust sub-vault, with attester or ZK birth verification
3. Attester and mediator staking with slashing
4. Real price oracle and DEX adapter, multisig and timelock ownership
5. Testnet web app, pilot with real test users
6. Legal review and third-party audit

## License

MIT. See [`LICENSE`](LICENSE).
