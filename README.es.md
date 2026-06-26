# 🔁 MiniSwap

**🌐 Idioma:** [English](README.md) · Español

Un **AMM de producto constante** (estilo Uniswap-V2) hecho desde cero para un único par de ERC-20. Proveés liquidez para ganar LP tokens y una parte del **fee de swap del 0.3%**, o swappeás un token por el otro a lo largo de la curva **x · y = k**.

> Proyecto de portfolio fullstack: contrato Solidity (Foundry) + frontend Next.js (wagmi/viem). Esto construye el *motor* de un DEX — el invariante, las LP shares y la matemática del fee — no solo una integración con uno ya existente.

---

## Demo en vivo

- 🌐 **App:** https://miniswap-project.vercel.app
- 📜 **MiniSwap (verificado):** [`0x34c2…1CfC`](https://sepolia.etherscan.io/address/0x34c2b149bf5a7783bac817db8ad7b880c5531cfc#code)
- 🪙 **Tokens de prueba (verificados):** [TKA `0x5fAd…a579`](https://sepolia.etherscan.io/address/0x5fadd5c1f2b79dad290ca47a9284046ec8ffa579#code) · [TKB `0x126C…1e43`](https://sepolia.etherscan.io/address/0x126ce9b37c5ca1f7c102d962be2d47be48a31e43#code)

En **Ethereum Sepolia**, con liquidez sembrada. La app tiene una faucet integrada — conectá, conseguí tokens de prueba, y swappeá o agregá liquidez.

---

## Qué lo hace interesante

- **Un AMM desde los primeros principios.** Sin router, sin factory — solo el pool núcleo: el invariante `x·y=k`, el minteo/quema de LP shares, y la fórmula de swap de producto constante con fee.
- **El fee gana para los LP.** Cada swap deja 0.3% en el pool, así que `k` crece y las shares de los proveedores de liquidez valen un poco más con el tiempo.
- **Robusto por diseño.** Maneja el ataque de inflación del primer depositante, tokens fee-on-transfer, redondeo y reentrancy (ver Seguridad).

---

## Cómo funciona

```solidity
addLiquidity(amount0Desired, amount1Desired, minShares); // deposita ambos tokens, mintea LP shares
removeLiquidity(shares, minAmount0, minAmount1);         // quema LP, retira pro-rata
swap(tokenIn, amountIn, minAmountOut);                   // opera sobre x·y=k, menos el fee del 0.3%
getAmountOut(amountIn, reserveIn, reserveOut);           // helper pure para cotizar
```

El output de un swap es `(amountIn · 997 · reserveOut) / (reserveIn · 1000 + amountIn · 997)` — la clásica fórmula de producto constante con el fee tomado sobre el input.

---

## Arquitectura

```
src/MiniSwap.sol          El AMM: ES el LP token (ERC-20) y guarda las reservas
src/MockToken.sol         ERC-20 tipo faucet para el par de la demo
script/Deploy.s.sol       Deploya los dos tokens + el pool y siembra liquidez inicial
test/MiniSwap.t.sol       Suite Foundry (unit + fuzz + fee-on-transfer + invariante k), 100% coverage
web/                      Frontend Next.js (App Router): stats del pool, swap, add/remove liquidity
```

---

## Decisiones de diseño

**Producto constante con fee del 0.3%.** `getAmountOut` redondea hacia abajo, así que el trader siempre recibe un poco *menos* que la curva exacta — lo que significa que `k = reserve0 · reserve1` **nunca puede bajar** en un swap. El fuzz test `testFuzzKNeverDecreasesOnSwap` lo prueba.

**Ataque de inflación del primer depositante, neutralizado.** El primer `MINIMUM_LIQUIDITY` (1000) de LP se mintea a una dead address y queda lockeado para siempre, y un primer depósito demasiado chico revierte limpio. Esto neutraliza la clásica manipulación del precio de la share que si no dejaría a un atacante robarle al siguiente LP.

**Fee-on-transfer safe.** Los depósitos y los inputs de swap se miden por **diferencia de balance** (lo que realmente llegó), y las reservas se sincronizan a los balances reales después de cada operación — así un token que cobra fee en transfer no puede corromper la contabilidad del pool.

**Precisión y overflow.** `Math.mulDiv` (intermedio de 512 bits) y `Math.sqrt` mantienen la matemática de swap/cotización/shares exacta y sin overflow, con cada dirección de redondeo favoreciendo al pool.

---

## Seguridad

- **`SafeERC20` + `ReentrancyGuard` + CEI estricto** en `addLiquidity`, `removeLiquidity` y `swap`.
- **Guards de slippage** en las tres (`minShares` / `minAmount0,1` / `minAmountOut`).
- **Sin roles privilegiados** — totalmente permissionless, como debe ser un AMM.
- **Revisado adversarialmente** (reentrancy, invariante k, ataque del primer depositante, redondeo, donación/`_sync`, fee-on-transfer, div-by-zero, overflow): **sin issues críticos/altos/medios.** Verificado que ningún camino drena el pool, roba valor de LP, ni baja `k`.

**Característica conocida (por diseño):** como todo AMM de producto constante, el precio se mueve por trades y donaciones (sandwich/MEV es inherente); los LP se protegen con los guards de slippage. Los tokens rebasing (cambios de balance fuera de banda) no están soportados.

---

## Tests

```
src/MiniSwap.sol   100% líneas · 100% statements · 100% branches · 100% funcs   (31 tests)
```

Happy paths, todos los reverts, matemática de ratios, contabilidad fee-on-transfer, el lock del primer depositante, más fuzz tests para el invariante `k` y los roundtrips de add/remove.

---

## Gas

| Operación | Gas |
|-----------|-----|
| `addLiquidity` | ~180.000 |
| `swap` | ~73.000 |
| `removeLiquidity` | ~77.000 |
| `getAmountOut` / `getReserves` | lecturas — 0 |

---

## Stack

Solidity 0.8.24 · Foundry · OpenZeppelin (ERC-20, SafeERC20, ReentrancyGuard, Math) · Next.js · wagmi · viem · TypeScript · Tailwind CSS
