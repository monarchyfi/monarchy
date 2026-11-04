import { useMemo } from "react";
import { useReadContract, useReadContracts } from "wagmi";
import type { Address } from "viem";
import { exileAbi, lodestarAbi, lodestarFactoryAbi, mockERC20Abi } from "../abi";
import { DEFAULT_DRIP_DAYS } from "./constants";
import { padsOf } from "./launchpads";
import { isSet, useDeployment, ZERO } from "./deployments";

/** The router and assets for the deployment's token, or any Lodestar passed in. */
export function useLodestarCore(lodestar?: Address) {
  const d = useDeployment();
  const address = lodestar ?? (isSet(d?.lodestar) ? d!.lodestar : undefined);
  const base = { address, abi: lodestarAbi } as const;
  const r = useReadContracts({
    allowFailure: false,
    contracts: [
      { ...base, functionName: "token" },
      { ...base, functionName: "quote" },
      { ...base, functionName: "exilePoolId" },
      { ...base, functionName: "treasuryStreamId" },
      { ...base, functionName: "poolId" },
      { ...base, functionName: "steward" },
    ],
    query: { enabled: !!address },
  });
  const [token, quote, exilePoolId, treasuryStreamId, poolId, steward] = r.data ?? [];
  const meta = useTokenMeta([token, quote]);
  return {
    lodestar: address,
    token,
    quote,
    exilePoolId,
    treasuryStreamId,
    poolId,
    steward,
    tokenMeta: meta[0],
    quoteMeta: meta[1],
    isLoading: r.isLoading,
  };
}

export type TokenMeta = { symbol: string; decimals: number };

/** What address(0) stands for as a quote asset: the chain's native coin (HYPE on Elysium). */
export const NATIVE_META: TokenMeta = { symbol: "HYPE", decimals: 18 };

export function useTokenMeta(tokens: (Address | undefined)[]): (TokenMeta | undefined)[] {
  const r = useReadContracts({
    allowFailure: true,
    contracts: tokens.flatMap((t) => [
      { address: t, abi: mockERC20Abi, functionName: "symbol" } as const,
      { address: t, abi: mockERC20Abi, functionName: "decimals" } as const,
    ]),
    query: { enabled: tokens.every((t) => !!t), staleTime: Infinity },
  });
  return tokens.map((t, i) => {
    if (t === ZERO) return NATIVE_META;
    const s = r.data?.[2 * i];
    const dec = r.data?.[2 * i + 1];
    if (!s || !dec || s.status !== "success" || dec.status !== "success") return undefined;
    return { symbol: s.result as string, decimals: Number(dec.result) };
  });
}

/** Exile's reward drip length in days, read from the contract (falls back to the default while loading). */
export function useDripDays(): number {
  const d = useDeployment();
  const r = useReadContract({ address: d?.exile, abi: exileAbi, functionName: "DRIP", query: { enabled: !!d, staleTime: Infinity } });
  return r.data !== undefined ? Number(r.data) / 86400 : DEFAULT_DRIP_DAYS;
}

/** "7 day" style label for a number of days. */
export function dayLabel(days: number): string {
  return `${Number.isInteger(days) ? days : days.toFixed(1)} day`;
}

/** How much of `token` sits in Exile locks that are still running, from the newest 2,000 locks (the Garden reads the same
 * ones). Exile keeps no per-token total, so it is summed here. */
export function useLockedTotal(token?: Address) {
  const d = useDeployment();
  const count = useReadContract({ address: d?.exile, abi: exileAbi, functionName: "lockCount", query: { enabled: !!d, refetchInterval: 30_000 } });
  const ids = useMemo(() => {
    const out: bigint[] = [];
    for (let i = count.data ?? 0n; i >= 1n && out.length < 2000; i--) out.push(i);
    return out;
  }, [count.data]);
  const reads = useReadContracts({
    allowFailure: false,
    contracts: ids.map((id) => ({ address: d?.exile, abi: exileAbi, functionName: "lockInfo", args: [id] }) as const),
    query: { enabled: !!d && ids.length > 0, refetchInterval: 30_000 },
  });
  if (!token || count.data === undefined || (ids.length > 0 && !reads.data)) return undefined;
  const now = Math.floor(Date.now() / 1000);
  let amount = 0n;
  let locks = 0;
  const owners = new Set<string>();
  // a dynamic list of reads loses its row type, the same as on the Garden
  const rows = (reads.data ?? []) as unknown as { kind: number; withdrawn: boolean; unlockAt: bigint; asset: Address; amount: bigint; owner: Address }[];
  for (const l of rows) {
    if (l.kind !== 0 || l.withdrawn || Number(l.unlockAt) <= now || l.asset.toLowerCase() !== token.toLowerCase()) continue;
    amount += l.amount;
    locks++;
    owners.add(l.owner.toLowerCase());
  }
  return { amount, locks, lockers: owners.size };
}

/** The factories this chain's routers come from: Ascend's, then one per launchpad on Elysium mainnet. */
export function useFactories(): Address[] {
  const d = useDeployment();
  if (!d) return [];
  return [...(isSet(d.factory) ? [d.factory] : []), ...padsOf(d.pads).map((p) => p.pad.factory)];
}

/** The Lodestar any of this chain's factories made for `token`, or undefined when none did. */
export function useRouterOf(token?: Address) {
  const factories = useFactories();
  const r = useReadContracts({
    allowFailure: true,
    contracts: factories.map((f) => ({ address: f, abi: lodestarFactoryAbi, functionName: "lodestarOf", args: [token ?? ZERO] }) as const),
    query: { enabled: !!token && factories.length > 0 },
  });
  const router = r.data?.map((x) => (x.status === "success" ? x.result : undefined)).find((a) => isSet(a));
  return { router, isLoading: r.isLoading };
}
