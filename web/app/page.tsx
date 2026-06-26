"use client";

import { useCallback, useEffect, useState } from "react";
import {
  useAccount,
  useConnect,
  useDisconnect,
  useSwitchChain,
  usePublicClient,
  useWriteContract,
} from "wagmi";
import { sepolia } from "wagmi/chains";
import { formatUnits, parseUnits, BaseError, UserRejectedRequestError } from "viem";
import {
  MINISWAP_ADDRESS,
  TOKEN0_ADDRESS,
  TOKEN1_ADDRESS,
  TOKEN0_SYMBOL,
  TOKEN1_SYMBOL,
  DECIMALS,
  miniSwapAbi,
  tokenAbi,
} from "@/lib/contract";

const EXPECTED_CHAIN = sepolia;
const ZERO = BigInt(0);
const FAUCET_AMOUNT = parseUnits("1000", DECIMALS);

function fmt(wei: bigint, dp = 4): string {
  return Number(formatUnits(wei, DECIMALS)).toLocaleString("en-US", { maximumFractionDigits: dp });
}

function safeParse(v: string): bigint | null {
  try {
    return v.trim() ? parseUnits(v, DECIMALS) : null;
  } catch {
    return null;
  }
}

function onlyNumber(v: string): boolean {
  return v === "" || /^\d*\.?\d*$/.test(v);
}

function shortAddr(a: string): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

// Constant-product output after the 0.3% fee — mirrors the contract's getAmountOut.
function computeOut(amountIn: bigint, reserveIn: bigint, reserveOut: bigint): bigint {
  if (amountIn <= ZERO || reserveIn === ZERO || reserveOut === ZERO) return ZERO;
  const withFee = amountIn * BigInt(9970);
  return (withFee * reserveOut) / (reserveIn * BigInt(10000) + withFee);
}

export default function Home() {
  const { address, isConnected, chainId } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();
  const publicClient = usePublicClient();
  const { writeContractAsync } = useWriteContract();

  const [reserve0, setReserve0] = useState<bigint>(ZERO);
  const [reserve1, setReserve1] = useState<bigint>(ZERO);
  const [bal0, setBal0] = useState<bigint>(ZERO);
  const [bal1, setBal1] = useState<bigint>(ZERO);
  const [lp, setLp] = useState<bigint>(ZERO);
  const [totalLp, setTotalLp] = useState<bigint>(ZERO);
  const [busy, setBusy] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);

  // forms
  const [swapZeroForOne, setSwapZeroForOne] = useState(true);
  const [swapAmount, setSwapAmount] = useState("");
  const [add0, setAdd0] = useState("");
  const [add1, setAdd1] = useState("");
  const [removeAmount, setRemoveAmount] = useState("");

  const wrongNetwork = isConnected && chainId !== EXPECTED_CHAIN.id;

  const refresh = useCallback(async () => {
    if (!publicClient) return;
    setFailed(false);
    // Retry with backoff so a cold/flaky RPC doesn't render the pool/balances as empty.
    for (let attempt = 0; ; attempt++) {
      try {
        const [r0, r1] = (await publicClient.readContract({
          address: MINISWAP_ADDRESS,
          abi: miniSwapAbi,
          functionName: "getReserves",
        })) as [bigint, bigint];
        const supply = (await publicClient.readContract({
          address: MINISWAP_ADDRESS,
          abi: miniSwapAbi,
          functionName: "totalSupply",
        })) as bigint;

        let nextBal0 = ZERO;
        let nextBal1 = ZERO;
        let nextLp = ZERO;
        if (address) {
          const read = (token: `0x${string}`) =>
            publicClient.readContract({ address: token, abi: tokenAbi, functionName: "balanceOf", args: [address] }) as Promise<bigint>;
          nextBal0 = await read(TOKEN0_ADDRESS);
          nextBal1 = await read(TOKEN1_ADDRESS);
          nextLp = (await publicClient.readContract({
            address: MINISWAP_ADDRESS,
            abi: miniSwapAbi,
            functionName: "balanceOf",
            args: [address],
          })) as bigint;
        }

        setReserve0(r0);
        setReserve1(r1);
        setTotalLp(supply);
        setBal0(nextBal0);
        setBal1(nextBal1);
        setLp(nextLp);
        return;
      } catch {
        if (attempt >= 4) {
          setFailed(true);
          return;
        }
        await new Promise((r) => setTimeout(r, 800 * (attempt + 1)));
      }
    }
  }, [publicClient, address]);

  // Load pool + balances on connect / account / network change.
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    refresh();
  }, [refresh]);

  async function run(label: string, fn: () => Promise<void>) {
    setBusy(label);
    try {
      await fn();
      await refresh();
    } catch (err) {
      if (!(err instanceof BaseError && err.walk((e) => e instanceof UserRejectedRequestError))) {
        console.error(err);
      }
    } finally {
      setBusy(null);
    }
  }

  function getTestTokens() {
    run("faucet", async () => {
      for (const token of [TOKEN0_ADDRESS, TOKEN1_ADDRESS]) {
        const hash = await writeContractAsync({
          address: token,
          abi: tokenAbi,
          functionName: "mint",
          args: [address!, FAUCET_AMOUNT],
        });
        await publicClient!.waitForTransactionReceipt({ hash });
      }
    });
  }

  // --- swap ---
  const swapIn = safeParse(swapAmount);
  const reserveIn = swapZeroForOne ? reserve0 : reserve1;
  const reserveOut = swapZeroForOne ? reserve1 : reserve0;
  const tokenInAddr = swapZeroForOne ? TOKEN0_ADDRESS : TOKEN1_ADDRESS;
  const symbolIn = swapZeroForOne ? TOKEN0_SYMBOL : TOKEN1_SYMBOL;
  const symbolOut = swapZeroForOne ? TOKEN1_SYMBOL : TOKEN0_SYMBOL;
  const balIn = swapZeroForOne ? bal0 : bal1;
  const expectedOut = swapIn ? computeOut(swapIn, reserveIn, reserveOut) : ZERO;
  const minOut = (expectedOut * BigInt(995)) / BigInt(1000); // 0.5% slippage tolerance
  const swapOk = swapIn !== null && swapIn > ZERO && swapIn <= balIn && expectedOut > ZERO;

  function doSwap() {
    if (!swapOk || swapIn === null) return;
    run("swap", async () => {
      const approveHash = await writeContractAsync({
        address: tokenInAddr,
        abi: tokenAbi,
        functionName: "approve",
        args: [MINISWAP_ADDRESS, swapIn],
      });
      await publicClient!.waitForTransactionReceipt({ hash: approveHash });
      const swapHash = await writeContractAsync({
        address: MINISWAP_ADDRESS,
        abi: miniSwapAbi,
        functionName: "swap",
        args: [tokenInAddr, swapIn, minOut],
      });
      await publicClient!.waitForTransactionReceipt({ hash: swapHash });
      setSwapAmount("");
    });
  }

  // --- add liquidity ---
  const a0 = safeParse(add0);
  const a1 = safeParse(add1);
  const addOk = a0 !== null && a1 !== null && a0 > ZERO && a1 > ZERO && a0 <= bal0 && a1 <= bal1;

  function doAdd() {
    if (!addOk || a0 === null || a1 === null) return;
    run("add", async () => {
      const h0 = await writeContractAsync({ address: TOKEN0_ADDRESS, abi: tokenAbi, functionName: "approve", args: [MINISWAP_ADDRESS, a0] });
      await publicClient!.waitForTransactionReceipt({ hash: h0 });
      const h1 = await writeContractAsync({ address: TOKEN1_ADDRESS, abi: tokenAbi, functionName: "approve", args: [MINISWAP_ADDRESS, a1] });
      await publicClient!.waitForTransactionReceipt({ hash: h1 });
      const hAdd = await writeContractAsync({
        address: MINISWAP_ADDRESS,
        abi: miniSwapAbi,
        functionName: "addLiquidity",
        args: [a0, a1, ZERO],
      });
      await publicClient!.waitForTransactionReceipt({ hash: hAdd });
      setAdd0("");
      setAdd1("");
    });
  }

  // --- remove liquidity ---
  const rem = safeParse(removeAmount);
  const removeOk = rem !== null && rem > ZERO && rem <= lp;

  function doRemove() {
    if (!removeOk || rem === null) return;
    run("remove", async () => {
      const hash = await writeContractAsync({
        address: MINISWAP_ADDRESS,
        abi: miniSwapAbi,
        functionName: "removeLiquidity",
        args: [rem, ZERO, ZERO],
      });
      await publicClient!.waitForTransactionReceipt({ hash });
      setRemoveAmount("");
    });
  }

  const price =
    reserve0 > ZERO
      ? (Number(formatUnits(reserve1, DECIMALS)) / Number(formatUnits(reserve0, DECIMALS))).toLocaleString("en-US", {
          maximumFractionDigits: 4,
        })
      : "—";
  const sharePct =
    totalLp > ZERO ? ((Number(lp) / Number(totalLp)) * 100).toLocaleString("en-US", { maximumFractionDigits: 2 }) : "0";

  const card = "rounded-2xl border border-white/10 bg-white/[0.04] p-5 shadow-2xl backdrop-blur";
  const input =
    "rounded-xl border border-white/10 bg-white/5 px-3 py-2.5 text-sm text-slate-100 placeholder-slate-500 outline-none focus:border-violet-400";

  return (
    <div className="flex flex-1 flex-col bg-gradient-to-br from-[#0d0918] via-[#150d2b] to-[#241043] text-slate-100">
      <header className="flex flex-wrap items-center justify-between gap-3 px-4 py-4 sm:px-6">
        <span className="text-xl font-bold">
          🔁 <span className="bg-gradient-to-r from-violet-300 to-fuchsia-300 bg-clip-text text-transparent">MiniSwap</span>
        </span>
        {isConnected ? (
          <button
            onClick={() => disconnect()}
            className="rounded-full border border-white/15 bg-white/10 px-4 py-2 text-sm font-medium text-white hover:bg-white/20"
          >
            {shortAddr(address!)} · Disconnect
          </button>
        ) : (
          <button
            onClick={() => connect({ connector: connectors[0] })}
            className="rounded-full bg-gradient-to-r from-violet-500 to-fuchsia-500 px-4 py-2 text-sm font-semibold text-white hover:from-violet-400 hover:to-fuchsia-400"
          >
            Connect wallet
          </button>
        )}
      </header>

      <main className="mx-auto w-full max-w-xl flex-1 px-4 py-8 sm:px-6">
        <div className="mb-8 text-center">
          <h1 className="text-3xl font-extrabold tracking-tight sm:text-4xl">
            <span className="bg-gradient-to-r from-violet-200 via-fuchsia-200 to-violet-200 bg-clip-text text-transparent">
              A tiny on-chain exchange
            </span>
          </h1>
          <p className="mx-auto mt-3 max-w-md text-slate-400">
            Swap two tokens or provide liquidity to earn fees — a constant-product (x·y=k) AMM built from scratch.
          </p>
        </div>

        {/* pool stats — always visible */}
        <section className={`mb-6 ${card}`}>
          <h2 className="mb-3 text-xs font-semibold uppercase tracking-widest text-violet-300/80">Pool</h2>
          <div className="grid grid-cols-2 gap-4 text-sm">
            <Stat label={`${TOKEN0_SYMBOL} reserve`} value={fmt(reserve0)} />
            <Stat label={`${TOKEN1_SYMBOL} reserve`} value={fmt(reserve1)} />
            <Stat label="Price" value={`1 ${TOKEN0_SYMBOL} ≈ ${price} ${TOKEN1_SYMBOL}`} />
            <Stat label="Your LP share" value={`${sharePct}%`} />
          </div>
        </section>

        {!isConnected && <p className="text-center text-slate-400">Connect your wallet to swap or add liquidity.</p>}

        {wrongNetwork && (
          <Banner>
            Wrong network.{" "}
            <button onClick={() => switchChain({ chainId: EXPECTED_CHAIN.id })} className="font-semibold underline">
              Switch to {EXPECTED_CHAIN.name}
            </button>
          </Banner>
        )}

        {failed && (
          <Banner>
            Couldn&apos;t load pool data — the network may be busy.{" "}
            <button onClick={refresh} className="font-semibold underline">
              Retry
            </button>
          </Banner>
        )}

        {isConnected && !wrongNetwork && (
          <div className="space-y-6">
            <div className={`flex items-center justify-between gap-3 text-sm ${card} !p-4`}>
              <span className="text-slate-400">
                <strong className="text-slate-100">{fmt(bal0)} {TOKEN0_SYMBOL}</strong> ·{" "}
                <strong className="text-slate-100">{fmt(bal1)} {TOKEN1_SYMBOL}</strong>
              </span>
              <button
                onClick={getTestTokens}
                disabled={busy === "faucet"}
                className="rounded-lg bg-emerald-500/90 px-3 py-1.5 text-sm font-semibold text-white hover:bg-emerald-400 disabled:opacity-40"
              >
                {busy === "faucet" ? "Minting…" : "Get test tokens"}
              </button>
            </div>

            {/* swap */}
            <section className={card}>
              <h2 className="mb-3 font-semibold">Swap</h2>
              <div className="flex items-center gap-2">
                <input
                  value={swapAmount}
                  onChange={(e) => onlyNumber(e.target.value) && setSwapAmount(e.target.value)}
                  placeholder={`Amount (${symbolIn})`}
                  inputMode="decimal"
                  className={`flex-1 ${input}`}
                />
                <span className="w-12 text-center text-sm font-semibold text-slate-200">{symbolIn}</span>
                <button
                  onClick={() => setSwapZeroForOne((v) => !v)}
                  className="rounded-xl border border-white/10 bg-white/10 px-3 py-2.5 text-sm font-semibold text-slate-200 hover:bg-white/20"
                  title="Flip direction"
                >
                  ⇅
                </button>
                <span className="w-12 text-center text-sm font-semibold text-slate-400">{symbolOut}</span>
              </div>
              <p className="mt-2 text-sm text-slate-400">
                You receive ≈ <strong className="text-slate-100">{fmt(expectedOut, 6)} {symbolOut}</strong>
                {expectedOut > ZERO && <span className="text-slate-500"> · min {fmt(minOut, 6)} (0.5% slippage)</span>}
              </p>
              <button
                onClick={doSwap}
                disabled={busy === "swap" || !swapOk}
                className="mt-3 w-full rounded-xl bg-gradient-to-r from-violet-500 to-fuchsia-500 py-2.5 text-sm font-semibold text-white hover:from-violet-400 hover:to-fuchsia-400 disabled:opacity-40"
              >
                {busy === "swap" ? "Swapping…" : swapIn !== null && swapIn > balIn ? `Not enough ${symbolIn}` : "Swap"}
              </button>
            </section>

            {/* liquidity */}
            <section className={card}>
              <h2 className="mb-1 font-semibold">Liquidity</h2>
              <p className="mb-3 text-xs text-slate-500">Your LP: {fmt(lp)} of {fmt(totalLp)} total</p>

              <div className="grid gap-2 sm:grid-cols-2">
                <input
                  value={add0}
                  onChange={(e) => onlyNumber(e.target.value) && setAdd0(e.target.value)}
                  placeholder={`Add ${TOKEN0_SYMBOL}`}
                  inputMode="decimal"
                  className={input}
                />
                <input
                  value={add1}
                  onChange={(e) => onlyNumber(e.target.value) && setAdd1(e.target.value)}
                  placeholder={`Add ${TOKEN1_SYMBOL}`}
                  inputMode="decimal"
                  className={input}
                />
              </div>
              <button
                onClick={doAdd}
                disabled={busy === "add" || !addOk}
                className="mt-2 w-full rounded-xl bg-fuchsia-500/90 py-2.5 text-sm font-semibold text-white hover:bg-fuchsia-400 disabled:opacity-40"
              >
                {busy === "add" ? "Adding…" : "Add liquidity"}
              </button>

              <div className="mt-4 flex items-center gap-2">
                <input
                  value={removeAmount}
                  onChange={(e) => onlyNumber(e.target.value) && setRemoveAmount(e.target.value)}
                  placeholder="LP to remove"
                  inputMode="decimal"
                  className={`flex-1 ${input}`}
                />
                <button
                  onClick={doRemove}
                  disabled={busy === "remove" || !removeOk}
                  className="rounded-xl border border-white/10 bg-white/10 px-4 py-2.5 text-sm font-semibold text-white hover:bg-white/20 disabled:opacity-40"
                >
                  {busy === "remove" ? "Removing…" : "Remove"}
                </button>
              </div>
            </section>
          </div>
        )}
      </main>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="text-slate-500">{label}</div>
      <div className="font-semibold text-slate-100">{value}</div>
    </div>
  );
}

function Banner({ children }: { children: React.ReactNode }) {
  return (
    <div className="mx-auto mb-6 max-w-xl rounded-lg border border-amber-400/20 bg-amber-400/10 px-4 py-3 text-center text-sm text-amber-200">
      {children}
    </div>
  );
}
