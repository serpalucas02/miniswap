# 🔁 MiniSwap

**🌐 Language:** English · [Español](README.es.md)

A minimal **constant-product AMM** (Uniswap-V2 style) built from scratch for a single ERC-20 pair. Provide liquidity to earn LP tokens and a share of the **0.3% swap fee**, or swap one token for the other along the **x · y = k** curve.

> Full-stack portfolio project: Solidity contract (Foundry) + Next.js frontend (wagmi/viem). This builds the *engine* of a DEX — the invariant, LP shares and fee math — not just an integration with an existing one.

---

## Live demo

- 🌐 **App:** https://miniswap-delta.vercel.app
- 📜 **MiniSwap (verified):** [`0x34c2…1CfC`](https://sepolia.etherscan.io/address/0x34c2b149bf5a7783bac817db8ad7b880c5531cfc#code)
- 🪙 **Test tokens (verified):** [TKA `0x5fAd…a579`](https://sepolia.etherscan.io/address/0x5fadd5c1f2b79dad290ca47a9284046ec8ffa579#code) · [TKB `0x126C…1e43`](https://sepolia.etherscan.io/address/0x126ce9b37c5ca1f7c102d962be2d47be48a31e43#code)

On **Ethereum Sepolia**, seeded with liquidity. The app has a built-in faucet — connect, grab test tokens, then swap or add liquidity.

---

## What makes it interesting

- **An AMM from first principles.** No router, no factory — just the core pool: the `x·y=k` invariant, LP-share minting/burning, and the constant-product swap formula with a fee.
- **The fee earns for LPs.** Every swap keeps 0.3% in the pool, so `k` grows and liquidity providers' shares are worth a bit more over time.
- **Robust by design.** Handles the first-depositor inflation attack, fee-on-transfer tokens, rounding, and reentrancy (see Security).

---

## How it works

```solidity
addLiquidity(amount0Desired, amount1Desired, minShares); // deposit both tokens, mint LP shares
removeLiquidity(shares, minAmount0, minAmount1);         // burn LP, withdraw pro-rata
swap(tokenIn, amountIn, minAmountOut);                   // trade along x·y=k, minus the 0.3% fee
getAmountOut(amountIn, reserveIn, reserveOut);           // pure quote helper
```

The output of a swap is `(amountIn · 997 · reserveOut) / (reserveIn · 1000 + amountIn · 997)` — the classic constant-product formula with the fee taken on the input.

---

## Architecture

```
src/MiniSwap.sol          The AMM: it IS the LP token (ERC-20) and holds the reserves
src/MockToken.sol         Faucet-style ERC-20s for the demo pair
script/Deploy.s.sol       Deploys the two tokens + the pool and seeds initial liquidity
test/MiniSwap.t.sol       Foundry suite (unit + fuzz + fee-on-transfer + k-invariant), 100% coverage
web/                      Next.js frontend (App Router): pool stats, swap, add/remove liquidity
```

---

## Design decisions

**Constant product with a 0.3% fee.** `getAmountOut` floors the result, so the trader always receives slightly *less* than the exact curve — which means `k = reserve0 · reserve1` can **never decrease** on a swap. The fuzz test `testFuzzKNeverDecreasesOnSwap` proves it.

**First-depositor inflation attack, defeated.** The very first `MINIMUM_LIQUIDITY` (1000) of LP is minted to a dead address and locked forever, and a too-small first deposit reverts cleanly. This neutralizes the classic share-price manipulation that would otherwise let an attacker steal from the next LP.

**Fee-on-transfer safe.** Deposits and swap inputs are measured by **balance diff** (what actually arrived), and reserves are synced to real balances after every op — so a token that charges a transfer fee can't corrupt the pool's accounting.

**Precision & overflow.** `Math.mulDiv` (512-bit intermediate) and `Math.sqrt` keep the swap/quote/share math exact and overflow-free, with every rounding direction favoring the pool.

---

## Security

- **`SafeERC20` + `ReentrancyGuard` + strict CEI** on `addLiquidity`, `removeLiquidity`, and `swap`.
- **Slippage guards** on all three (`minShares` / `minAmount0,1` / `minAmountOut`).
- **No privileged roles** — fully permissionless, as an AMM should be.
- **Reviewed adversarially** (reentrancy, k-invariant, first-depositor attack, rounding, donation/`_sync`, fee-on-transfer, div-by-zero, overflow): **no critical/high/medium issues.** Verified that no path drains the pool, steals LP value, or decreases `k`.

**Known characteristic (by design):** like every constant-product AMM, price is moved by trades and donations (sandwich/MEV is inherent); LPs protect themselves with the slippage guards. Rebasing tokens (out-of-band balance changes) are not supported.

---

## Run it locally

Needs [Foundry](https://book.getfoundry.sh/) and Node.js.

```bash
forge test            # run the suite
forge coverage        # coverage report

cd web && npm install && npm run dev   # http://localhost:3000
```

---

## Tests

```
src/MiniSwap.sol   100% lines · 100% statements · 100% branches · 100% funcs   (31 tests)
```

Happy paths, every revert, ratio math, fee-on-transfer accounting, the first-depositor lock, plus fuzz tests for the `k` invariant and add/remove roundtrips.

---

## Gas

| Operation | Gas |
|-----------|-----|
| `addLiquidity` | ~180,000 |
| `swap` | ~73,000 |
| `removeLiquidity` | ~77,000 |
| `getAmountOut` / `getReserves` | reads — 0 |

---

## Tech stack

Solidity 0.8.24 · Foundry · OpenZeppelin (ERC-20, SafeERC20, ReentrancyGuard, Math) · Next.js · wagmi · viem · TypeScript · Tailwind CSS
