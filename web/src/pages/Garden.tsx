import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { useReadContracts } from "wagmi";
import { formatUnits, type Address } from "viem";
import { exileAbi, lodestarAbi, lodestarFactoryAbi, sandfallAbi } from "../abi";
import { HeldChart, type HeldPoint } from "../components/HeldChart";
import { PageMark } from "../components/NavGlyphs";
import { NoDeployment } from "../components/States";
import { unlockedAt } from "../components/UnlockChart";
import { Addr, Badge, Card, Empty, Skel, Stat, TokenAddr } from "../components/Ui";
import { useDeployment, ZERO } from "../lib/deployments";
import { compact, duration, fmt, label, mult, short } from "../lib/format";
import { useNow, usePageTitle } from "../lib/hooks";
import { useFactories, useLodestarCore, useTokenMeta, type TokenMeta } from "../lib/monarchy";

/** Reads stop here, newest first; past it the page says how many it left out. */
const CAP = 2000;
/** Every list here is read whole, so it refreshes slower than the tool pages. */
const SLOW = { query: { refetchInterval: 30_000 } } as const;
const PAGE = 20;
/** The unlock chart looks this far ahead; anything unlocking later is counted in a note under it. */
const HORIZON = 2 * 365 * 86400;
/** A timelocked change can be carried out for this long once its wait ends (Lodestar and Exile EXECUTION_WINDOW). */
const EXECUTION_WINDOW = 7 * 86400;
const STEPS = 240;

type Lock = { id: bigint; owner: Address; kind: number; withdrawn: boolean; multiplierBps: number; unlockAt: bigint; asset: Address; tokenId: bigint; amount: bigint; poolId: bigint };
type Stream = { id: bigint; creator: Address; recipient: Address; asset: Address; kind: number; cancellable: boolean; cancelled: boolean; start: bigint; cliff: bigint; end: bigint; stepSeconds: number; total: bigint; periodFinish: bigint; vested: bigint };
type Tier = { minDuration: number; multiplierBps: number; label: `0x${string}` };
type Router = { address: Address; token: Address; quote: Address; feeBurned: bigint; buybackBurned: bigint; buybackQuote: bigint; holders: bigint; treasury: bigint; tokenToHolders: bigint; lockedUntil: bigint };

/** ids n, n-1, … down to 1 (or `from`), at most CAP of them */
function newest(n: bigint | undefined, from = 1n): bigint[] {
  if (n === undefined) return [];
  const out: bigint[] = [];
  for (let i = n; i >= from && out.length < CAP; i--) out.push(i);
  return out;
}

const day = (ts: bigint | number) => {
  const n = Number(ts);
  if (n >= 2 ** 63 || n > 1e12) return "never";
  return new Date(n * 1000).toLocaleDateString(undefined, { dateStyle: "medium" });
};

/** The Garden, Monarchy's analytics: every lock, stream and fee router, read from the contracts, with totals and an
 * unlock outlook per token. */
export function GardenPage() {
  usePageTitle("Garden");
  const d = useDeployment();
  const core = useLodestarCore();
  const now = useNow(30_000);
  // ?token= opens the lists on that token's tab, so another page can link straight to one token's locks and streams
  const [params] = useSearchParams();
  const token0 = params.get("token")?.toLowerCase() ?? undefined;
  const [tokenQ, setTokenQ] = useState("");
  const [tokenShown, setTokenShown] = useState(PAGE);
  const [routerQ, setRouterQ] = useState("");
  const [routerShown, setRouterShown] = useState(PAGE);

  const counts = useReadContracts({
    allowFailure: false,
    contracts: [
      { address: d?.exile, abi: exileAbi, functionName: "lockCount" },
      { address: d?.exile, abi: exileAbi, functionName: "poolCount" },
      { address: d?.sandfall, abi: sandfallAbi, functionName: "streamCount" },
    ],
    query: { enabled: !!d, ...SLOW.query },
  });
  const [lockCount, poolCount, streamCount] = counts.data ?? [];
  // every factory on this chain: Ascend's on the testnet, one per launchpad on Elysium mainnet
  const factories = useFactories();
  const factoryCounts = useReadContracts({
    allowFailure: false,
    contracts: factories.map((f) => ({ address: f, abi: lodestarFactoryAbi, functionName: "allLodestarsLength" }) as const),
    query: { enabled: factories.length > 0, ...SLOW.query },
  });
  const routerCount = factories.length === 0 ? 0n : factoryCounts.data?.reduce((a, n) => a + n, 0n);

  const lockIds = useMemo(() => newest(lockCount), [lockCount]);
  const lockReads = useReadContracts({
    allowFailure: false,
    contracts: lockIds.map((id) => ({ address: d?.exile, abi: exileAbi, functionName: "lockInfo", args: [id] }) as const),
    query: { enabled: !!d && lockIds.length > 0, ...SLOW.query },
  });
  const poolIds = useMemo(() => newest(poolCount), [poolCount]);
  const poolReads = useReadContracts({
    allowFailure: false,
    contracts: poolIds.map((id) => ({ address: d?.exile, abi: exileAbi, functionName: "poolInfo", args: [id] }) as const),
    query: { enabled: !!d && poolIds.length > 0, staleTime: 60_000 },
  });
  const streamIds = useMemo(() => newest(streamCount), [streamCount]);
  const streamReads = useReadContracts({
    allowFailure: false,
    contracts: streamIds.flatMap(
      (id) =>
        [
          { address: d?.sandfall, abi: sandfallAbi, functionName: "stream", args: [id] },
          { address: d?.sandfall, abi: sandfallAbi, functionName: "vestedAmount", args: [id] },
        ] as const,
    ),
    query: { enabled: !!d && streamIds.length > 0, ...SLOW.query },
  });
  // allLodestars is 0-indexed; newest first in each factory, at most CAP in all
  const routerIdx = useMemo(() => {
    const out: { factory: Address; i: bigint }[] = [];
    (factoryCounts.data ?? []).forEach((n, k) => {
      for (const i of newest(n, 1n)) if (out.length < CAP) out.push({ factory: factories[k], i: i - 1n });
    });
    return out;
  }, [factoryCounts.data, factories]);
  const routerAddrs = useReadContracts({
    allowFailure: false,
    contracts: routerIdx.map(({ factory, i }) => ({ address: factory, abi: lodestarFactoryAbi, functionName: "allLodestars", args: [i] }) as const),
    query: { enabled: !!d && routerIdx.length > 0, staleTime: 60_000 },
  });
  const routerList = (routerAddrs.data ?? []) as Address[];
  const RF = ["token", "quote", "totalTokenBurned", "totalBuybackTokensBurned", "totalBuybackQuote", "totalHoldersQuote", "totalTreasuryQuote", "totalTokenToHolders", "creatorLockedUntil"] as const;
  const routerReads = useReadContracts({
    allowFailure: false,
    contracts: routerList.flatMap((a) => RF.map((functionName) => ({ address: a, abi: lodestarAbi, functionName }) as const)),
    query: { enabled: routerList.length > 0, ...SLOW.query },
  });
  // what each router has waiting behind its timelocks; routers from before the upgrade path lack upgradeEta, so a failed read means none
  const PF = ["pendingConfig", "upgradeEta", "exilePoolId"] as const;
  const pendingReads = useReadContracts({
    contracts: routerList.flatMap((a) => PF.map((functionName) => ({ address: a, abi: lodestarAbi, functionName }) as const)),
    query: { enabled: routerList.length > 0, ...SLOW.query },
  });

  const locks: Lock[] = useMemo(() => {
    const raw = (lockReads.data ?? []) as unknown as Omit<Lock, "id">[];
    return raw.map((l, i) => ({ ...l, id: lockIds[i] }));
  }, [lockReads.data, lockIds]);
  const streams: Stream[] = useMemo(() => {
    const raw = (streamReads.data ?? []) as unknown[];
    const out: Stream[] = [];
    for (let i = 0; i + 1 < raw.length; i += 2) out.push({ ...(raw[i] as Omit<Stream, "id" | "vested">), id: streamIds[i / 2], vested: raw[i + 1] as bigint });
    return out;
  }, [streamReads.data, streamIds]);
  const tiersByPool = useMemo(() => {
    const m = new Map<bigint, readonly Tier[]>();
    ((poolReads.data ?? []) as unknown as { tiers: readonly Tier[] }[]).forEach((p, i) => m.set(poolIds[i], p.tiers));
    return m;
  }, [poolReads.data, poolIds]);
  const tiersEtaByPool = useMemo(() => {
    const m = new Map<bigint, number>();
    ((poolReads.data ?? []) as unknown as { tiersEta: bigint }[]).forEach((p, i) => m.set(poolIds[i], Number(p.tiersEta)));
    return m;
  }, [poolReads.data, poolIds]);
  const pendingOf = (i: number): Change[] => {
    const v = pendingReads.data?.slice(i * PF.length, (i + 1) * PF.length);
    if (!v) return [];
    const cfg = v[0]?.result as readonly [unknown, bigint] | undefined;
    const pool = v[2]?.result as bigint | undefined;
    return [
      { what: "Split change", eta: Number(cfg?.[1] ?? 0n) },
      { what: "Tier change", eta: pool === undefined ? 0 : (tiersEtaByPool.get(pool) ?? 0) },
      { what: "Upgrade", eta: Number((v[1]?.result as bigint | undefined) ?? 0n) },
    ];
  };
  const routers: Router[] = useMemo(() => {
    const raw = (routerReads.data ?? []) as unknown[];
    return routerList.map((address, i) => {
      const v = raw.slice(i * RF.length, (i + 1) * RF.length);
      return {
        address,
        token: v[0] as Address,
        quote: v[1] as Address,
        feeBurned: v[2] as bigint,
        buybackBurned: v[3] as bigint,
        buybackQuote: v[4] as bigint,
        holders: v[5] as bigint,
        treasury: v[6] as bigint,
        tokenToHolders: v[7] as bigint,
        lockedUntil: v[8] as bigint,
      };
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [routerReads.data, routerList]);

  // every ERC-20 the page names, so amounts get their own decimals and symbol (HYPE, the native coin, is address 0)
  const tokens = useMemo(() => {
    const s = new Set<string>();
    locks.forEach((l) => l.kind === 0 && s.add(l.asset));
    streams.forEach((x) => x.asset !== ZERO && s.add(x.asset));
    if (routerReads.data) routers.forEach((r) => (s.add(r.token), s.add(r.quote)));
    return [...s].sort() as Address[];
  }, [locks, streams, routers, routerReads.data]);
  const metas = useTokenMeta(tokens);
  const metaOf = useMemo(() => {
    const m = new Map<string, TokenMeta>();
    tokens.forEach((t, i) => metas[i] && m.set(t.toLowerCase(), metas[i]!));
    return (a: Address): TokenMeta | undefined => (a === ZERO ? { symbol: "HYPE", decimals: 18 } : m.get(a.toLowerCase()));
  }, [tokens, metas]);

  const byToken = useMemo(() => summarize(locks, streams, now), [locks, streams, now]);
  // the unlock chart follows the kingdom's own token only, so it stays one chart however many tokens Ascend lists
  const mainToken = core.token;
  const mainMeta = (mainToken && metaOf(mainToken)) || core.tokenMeta;
  const mainSummary = mainToken && byToken.find((b) => b.asset.toLowerCase() === mainToken.toLowerCase());

  if (!d) return <NoDeployment />;

  const loading = counts.isLoading || (lockIds.length > 0 && !lockReads.data) || (streamIds.length > 0 && !streamReads.data);
  const failed = counts.isError || lockReads.isError || streamReads.isError;
  const activeLocks = locks.filter((l) => !l.withdrawn && Number(l.unlockAt) > now);
  const lockers = new Set(activeLocks.map((l) => l.owner.toLowerCase())).size;
  const activeStreams = streams.filter((s) => !s.cancelled && s.vested < s.total);
  const recipients = new Set(activeStreams.map((s) => s.recipient.toLowerCase())).size;
  const forever = routers.filter((r) => r.lockedUntil >= 2n ** 63n).length;
  const capped = (lockCount ?? 0n) > BigInt(CAP) || (streamCount ?? 0n) > BigInt(CAP);
  const tokenRows = filter(mainFirst(byToken, mainToken), tokenQ, (b) => [b.asset, metaOf(b.asset)?.symbol]);
  const routerRows = filter(
    routers.map((r, i) => ({ r, i })),
    routerQ,
    ({ r }) => [r.token, r.address, metaOf(r.token)?.symbol],
  );

  return (
    <div className="page">
      <header className="page-head">
        <h1>
          <PageMark page="garden" />
          Garden
        </h1>
        <p>
          Everything planted in the kingdom grows here in the open. The Garden is Monarchy's analytics: every lock, vesting
          stream and fee router, read straight from the contracts each time the page loads. Monarchy stores and reports none
          of it, so anyone can check it for themselves: tokens open on Ascend, and every other address in the explorer.
        </p>
      </header>

      {failed && (
        <Card>
          <Empty title="Couldn't read the contracts">The network didn't answer. The page tries again on its own every 30 seconds.</Empty>
        </Card>
      )}

      <Card title="The Harvest" right={mainToken && <span className="muted small">When locked and vesting {mainMeta?.symbol ?? <Skel w="3em" />} comes due</span>}>
        {loading || core.isLoading ? (
          <Skel block h="220px" w="100%" />
        ) : !mainToken || !mainSummary || (mainSummary.locked === 0n && mainSummary.unvested === 0n) ? (
          <Empty title="Nothing to chart yet">Once the kingdom's token is locked or vesting, this shows how much stays put and for how long.</Empty>
        ) : (
          <Outlook asset={mainToken} meta={mainMeta} locks={activeLocks} streams={activeStreams} now={now} />
        )}
      </Card>

      <div className="stats stats-4">
        <Stat label="Active locks" value={loading ? <Skel w="3em" /> : activeLocks.length.toLocaleString()} hint={loading ? <Skel w="7em" /> : `${(lockCount ?? 0n).toLocaleString()} made in total`} />
        <Stat label="Lockers" value={loading ? <Skel w="3em" /> : lockers.toLocaleString()} hint="Wallets with a lock still running" />
        <Stat label="Vesting streams" value={loading ? <Skel w="3em" /> : activeStreams.length.toLocaleString()} hint={loading ? <Skel w="7em" /> : `${recipients} ${recipients === 1 ? "recipient" : "recipients"}, ${(streamCount ?? 0n).toLocaleString()} made in total`} />
        <Stat label="Fee routers" value={routerCount === undefined ? <Skel w="3em" /> : routerCount.toLocaleString()} hint={routerReads.data ? `${forever} with the creator role locked forever` : <Skel w="9em" />} />
      </div>

      <Card title="Locked and vesting, by token" right={<span className="muted small">Tokens only; NFT locks are in the lists below</span>}>
        {loading ? (
          <Skel block h="120px" w="100%" />
        ) : byToken.length === 0 ? (
          <Empty title="Nothing locked or vesting yet" />
        ) : (
          <>
            <div className="rolls-bar">
              <Search value={tokenQ} onChange={(v) => (setTokenQ(v), setTokenShown(PAGE))} placeholder="Filter by token address or symbol" label="Filter tokens" />
              <span className="muted small">
                {tokenRows.length.toLocaleString()} of {byToken.length.toLocaleString()} {byToken.length === 1 ? "token" : "tokens"}
              </span>
            </div>
            {tokenRows.length === 0 ? (
              <Empty title="No tokens match" />
            ) : (
              <Table label="Locked and vesting by token" head={["Token", "Locked now", "Active locks", "Unlocks in 30 days", "Still vesting", "Active streams"]} num={[1, 2, 3, 4, 5]}>
                {tokenRows.slice(0, tokenShown).map((b) => {
                  const m = metaOf(b.asset);
                  const dec = m?.decimals ?? 18;
                  return (
                    <tr key={b.asset}>
                      <td>
                        <TokenName asset={b.asset} meta={m} />
                      </td>
                      <td>{compact(b.locked, dec)}</td>
                      <td>{b.locks}</td>
                      <td>{compact(b.unlocking30, dec)}</td>
                      <td>{compact(b.unvested, dec)}</td>
                      <td>{b.streams}</td>
                    </tr>
                  );
                })}
              </Table>
            )}
            <More shown={tokenShown} total={tokenRows.length} onMore={() => setTokenShown(tokenShown + PAGE)} />
          </>
        )}
      </Card>

      <Rolls locks={locks} streams={streams} loading={loading} now={now} metaOf={metaOf} tiersByPool={tiersByPool} lockTotal={lockCount} streamTotal={streamCount} mainToken={mainToken} initialToken={token0} />

      <Card title="Fee routers" right={<span className="muted small">One Lodestar per token</span>}>
        {routerCount === undefined || (routerList.length > 0 && !routerReads.data) ? (
          <Skel block h="80px" w="100%" />
        ) : routers.length === 0 ? (
          <Empty title="No routers yet" />
        ) : (
          <>
            <div className="rolls-bar">
              <Search value={routerQ} onChange={(v) => (setRouterQ(v), setRouterShown(PAGE))} placeholder="Filter by token address, symbol or router" label="Filter fee routers" />
              <span className="muted small">
                {routerRows.length.toLocaleString()} of {routers.length.toLocaleString()} {routers.length === 1 ? "router" : "routers"}
              </span>
            </div>
            {routerRows.length === 0 ? (
              <Empty title="No routers match" />
            ) : (
              <Table label="Fee routers" head={["Token", "Router", "Burned from fees", "Bought back and burned", "To holders", "To treasury", "Creator role", "Waiting to take effect"]} num={[2, 3, 4, 5]}>
                {routerRows.slice(0, routerShown).map(({ r, i }) => {
                  const tm = metaOf(r.token);
                  const qm = metaOf(r.quote);
                  const to = `/lodestar?token=${r.token}${r.quote.toLowerCase() === d.quote.toLowerCase() ? "" : `&quote=${r.quote}`}`;
                  return (
                    <tr key={r.address}>
                      <td>
                        <TokenName asset={r.token} meta={tm} />
                      </td>
                      <td>
                        <Addr address={r.address} />
                      </td>
                      <td>{compact(r.feeBurned, tm?.decimals ?? 18)}</td>
                      <td>{compact(r.buybackBurned, tm?.decimals ?? 18)}</td>
                      <td>
                        {fmt(r.holders, qm?.decimals ?? 18)} {qm?.symbol}
                        {r.tokenToHolders > 0n && <span className="muted"> + {compact(r.tokenToHolders, tm?.decimals ?? 18)} {tm?.symbol}</span>}
                      </td>
                      <td>
                        {fmt(r.treasury, qm?.decimals ?? 18)} {qm?.symbol}
                      </td>
                      <td>{r.lockedUntil >= 2n ** 63n ? <Badge tone="gold">Locked forever</Badge> : Number(r.lockedUntil) > now ? <Badge tone="silver">Until {day(r.lockedUntil)}</Badge> : <Badge tone="amber">Not locked</Badge>}</td>
                      <td>
                        <Pending changes={pendingOf(i)} now={now} loading={!pendingReads.data} to={to} />
                      </td>
                    </tr>
                  );
                })}
              </Table>
            )}
            <More shown={routerShown} total={routerRows.length} onMore={() => setRouterShown(routerShown + PAGE)} />
          </>
        )}
      </Card>

      {capped && <p className="muted small">Showing the newest {CAP.toLocaleString()} locks and streams; the totals above count those.</p>}
    </div>
  );
}

type Change = { what: string; eta: number };

/** The timelocked changes a router has waiting, each with its countdown, linking to the router's page where anyone can
 * carry it out once the wait ends. A change past its 7 day window has lapsed and isn't shown. */
function Pending({ changes, now, loading, to }: { changes: Change[]; now: number; loading: boolean; to: string }) {
  if (loading) return <Skel w="5em" />;
  const live = changes.filter((c) => c.eta > 0 && now <= c.eta + EXECUTION_WINDOW);
  if (live.length === 0) return <span className="muted">Nothing</span>;
  return (
    <Link to={to} className="pending-list">
      {live.map((c) => (
        <Badge key={c.what} tone="amber">
          {c.what} {c.eta > now ? `in ${duration(c.eta - now)}` : "ready"}
        </Badge>
      ))}
    </Link>
  );
}

type Summary = { asset: Address; locked: bigint; locks: number; unlocking30: bigint; unvested: bigint; streams: number };

/** Per token: what is locked now and how much of it frees up within 30 days, and what is still vesting. */
function summarize(locks: Lock[], streams: Stream[], now: number): Summary[] {
  const m = new Map<string, Summary>();
  const get = (a: Address) => {
    const k = a.toLowerCase();
    if (!m.has(k)) m.set(k, { asset: a, locked: 0n, locks: 0, unlocking30: 0n, unvested: 0n, streams: 0 });
    return m.get(k)!;
  };
  for (const l of locks) {
    if (l.kind !== 0 || l.withdrawn || Number(l.unlockAt) <= now) continue;
    const s = get(l.asset);
    s.locked += l.amount;
    s.locks++;
    if (Number(l.unlockAt) <= now + 30 * 86400) s.unlocking30 += l.amount;
  }
  for (const x of streams) {
    if (x.cancelled || x.vested >= x.total) continue;
    const s = get(x.asset);
    s.unvested += x.total - x.vested;
    s.streams++;
  }
  return [...m.values()].sort((a, b) => b.locks + b.streams - (a.locks + a.streams));
}

/** The kingdom's own token first, the rest in their order. */
function mainFirst(rows: Summary[], main?: Address): Summary[] {
  const k = main?.toLowerCase();
  return [...rows].sort((a, b) => Number(b.asset.toLowerCase() === k) - Number(a.asset.toLowerCase() === k));
}

/** The unlock chart for one token, with what falls beyond the chart's horizon noted underneath. */
function Outlook({ asset, meta, locks, streams, now }: { asset: Address; meta?: TokenMeta; locks: Lock[]; streams: Stream[]; now: number }) {
  const dec = meta?.decimals ?? 18;
  const a = asset.toLowerCase();
  const mine = locks.filter((l) => l.kind === 0 && l.asset.toLowerCase() === a);
  const flows = streams.filter((s) => s.asset.toLowerCase() === a);
  const f = (v: bigint) => Number(formatUnits(v, dec));
  const lastLock = Math.max(0, ...mine.map((l) => Number(l.unlockAt)));
  const lastFlow = Math.max(0, ...flows.map((s) => Number(s.kind === 2 ? s.periodFinish : s.end)));
  const end = Math.min(Math.max(lastLock, lastFlow, now + 86400) + 86400, now + HORIZON);
  const later = mine.filter((l) => Number(l.unlockAt) > end);

  const points: HeldPoint[] = [];
  for (let i = 0; i <= STEPS; i++) {
    const t = now + ((end - now) * i) / STEPS;
    let locked = 0;
    for (const l of mine) if (Number(l.unlockAt) > t) locked += f(l.amount);
    let vesting = 0;
    for (const s of flows) {
      const left = f(s.total - s.vested);
      if (s.kind === 2) {
        // a rolling stream pays out its balance evenly until periodFinish
        const fin = Number(s.periodFinish);
        vesting += fin > now ? left * Math.max(0, (fin - t) / (fin - now)) : 0;
      } else {
        const sch = { start: Number(s.start), cliff: Number(s.cliff), end: Number(s.end), step: s.stepSeconds };
        const total = f(s.total);
        vesting += Math.min(left, total * (1 - unlockedAt(sch, t)));
      }
    }
    points.push({ t, locked, vesting });
  }
  const sym = meta?.symbol ?? short(asset);
  return (
    <>
      <div className="held-legend" aria-hidden="true">
        <span>
          <i className="held-key held-key-locked" /> Locked in Exile
        </span>
        <span>
          <i className="held-key held-key-vesting" /> Still vesting in Sandfall
        </span>
      </div>
      <HeldChart points={points} symbol={sym} />
      <p className="muted small">
        How much {sym} stays put from today, falling as locks end and streams pay out.
        {later.length > 0 && ` ${later.length} ${later.length === 1 ? "lock unlocks" : "locks unlock"} after ${day(end)}, holding ${compact(later.reduce((s, l) => s + l.amount, 0n), dec)} ${sym} past the chart.`}
      </p>
    </>
  );
}

const MAIN = "main";
const OTHERS = "others";
type Kind = "locks" | "streams";

/** Every lock and every vesting stream in two tabs, the kingdom's own token and everything else, so the tabs stay two
 * however many tokens use Monarchy. A switch picks Exile locks or Sandfall streams, and a search narrows by wallet (and,
 * under Others, by token address or symbol). */
function Rolls({ locks, streams, loading, now, metaOf, tiersByPool, lockTotal, streamTotal, mainToken, initialToken }: { locks: Lock[]; streams: Stream[]; loading: boolean; now: number; metaOf: (a: Address) => TokenMeta | undefined; tiersByPool: Map<bigint, readonly Tier[]>; lockTotal?: bigint; streamTotal?: bigint; mainToken?: Address; initialToken?: string }) {
  const main = mainToken?.toLowerCase();
  // ?token= with another token's address opens Others, already filtered to that token
  const linkedOther = !!initialToken && !!main && initialToken !== main;
  const [picked, setPicked] = useState<string>(linkedOther ? OTHERS : MAIN);
  const [kind, setKind] = useState<Kind>();
  const [q, setQ] = useState(linkedOther ? initialToken : "");
  const [shown, setShown] = useState(PAGE);
  const ref = useRef<HTMLElement>(null);

  const isMain = (asset: Address, nft = false) => !nft && !!main && asset.toLowerCase() === main;
  const ours = { locks: locks.filter((l) => isMain(l.asset, l.kind !== 0)), streams: streams.filter((x) => isMain(x.asset)) };
  const rest = { locks: locks.filter((l) => !isMain(l.asset, l.kind !== 0)), streams: streams.filter((x) => !isMain(x.asset)) };
  // with no kingdom token known, everything sits under one tab
  const key = main ? picked : OTHERS;
  const set = key === MAIN ? ours : rest;
  // a side with nothing to show opens on the side that has something
  const view: Kind = kind ?? (set.locks.length === 0 && set.streams.length > 0 ? "streams" : "locks");

  // a link from another page lands on this card once the lists have loaded
  useEffect(() => {
    if (initialToken && !loading) ref.current?.scrollIntoView({ behavior: "smooth", block: "start" });
  }, [initialToken, loading]);

  const choose = (k: string) => {
    setPicked(k);
    setShown(PAGE);
    setQ("");
  };
  const mainName = (mainToken && metaOf(mainToken)?.symbol) ?? "Our token";
  const tabs = main ? [{ key: MAIN, name: mainName, n: ours }, { key: OTHERS, name: "Others", n: rest }] : [];

  const lockRows = filter(set.locks, q, (l) => [l.owner, ...(key === OTHERS ? [l.asset, metaOf(l.asset)?.symbol] : [])]);
  const streamRows = filter(set.streams, q, (x) => [x.creator, x.recipient, ...(key === OTHERS ? [x.asset, metaOf(x.asset)?.symbol] : [])]);
  const rows = view === "locks" ? lockRows : streamRows;
  const total = view === "locks" ? lockTotal : streamTotal;

  return (
    <section ref={ref} className="card rolls">
      <header className="card-head">
        <h3>Every lock and vesting stream</h3>
        <div className="tabs" role="tablist" aria-label="Show">
          {(["locks", "streams"] as const).map((k) => (
            <button key={k} role="tab" aria-selected={view === k} className={view === k ? "tab active" : "tab"} onClick={() => (setKind(k), setShown(PAGE))}>
              {k === "locks" ? "Exile locks" : "Sandfall streams"}
            </button>
          ))}
        </div>
      </header>
      {loading ? (
        <Skel block h="200px" w="100%" />
      ) : (
        <>
          {tabs.length > 0 && (
            <div className="token-tabs" role="tablist" aria-label="Token">
              {tabs.map((t) => (
                <button key={t.key} role="tab" aria-selected={t.key === key} className={t.key === key ? "token-tab active" : "token-tab"} onClick={() => choose(t.key)}>
                  {t.name}
                  <span className="token-tab-n">{t.n[view].length}</span>
                </button>
              ))}
            </div>
          )}
          <div className="rolls-bar">
            <Search value={q} onChange={(v) => (setQ(v), setShown(PAGE))} placeholder={key === OTHERS ? "Filter by token address, symbol or wallet" : "Filter by wallet"} label={`Filter ${view}`} />
            {total !== undefined && <span className="muted small">{`${rows.length.toLocaleString()} of ${total.toLocaleString()}`}, newest first</span>}
          </div>
          {rows.length === 0 ? (
            <Empty title={q ? `No ${view} match` : `No ${view === "locks" ? "Exile locks" : "Sandfall streams"}${key === MAIN ? ` for ${mainName}` : " for other tokens"} yet`} />
          ) : (
            <>
              {view === "locks" ? <LockTable locks={lockRows.slice(0, shown)} now={now} metaOf={metaOf} tiersByPool={tiersByPool} /> : <StreamTable streams={streamRows.slice(0, shown)} now={now} metaOf={metaOf} />}
              <More shown={shown} total={rows.length} onMore={() => setShown(shown + PAGE)} />
            </>
          )}
        </>
      )}
    </section>
  );
}

function LockTable({ locks, now, metaOf, tiersByPool }: { locks: Lock[]; now: number; metaOf: (a: Address) => TokenMeta | undefined; tiersByPool: Map<bigint, readonly Tier[]> }) {
  return (
    <Table label="Exile locks" head={["#", "Owner", "Token", "Amount", "Tier", "Unlocks", "Status"]} num={[3]}>
      {locks.map((l) => {
        const m = metaOf(l.asset);
        const tier = (tiersByPool.get(l.poolId) ?? []).find((t) => t.multiplierBps === l.multiplierBps);
        const ended = Number(l.unlockAt) <= now;
        return (
          <tr key={l.id.toString()}>
            <td className="muted">{l.id.toString()}</td>
            <td>
              <Addr address={l.owner} />
            </td>
            <td>{l.kind === 0 ? <TokenName asset={l.asset} meta={m} /> : <span>{l.kind === 1 ? "ERC-721" : "ERC-1155"} <Addr address={l.asset} /> #{l.tokenId.toString()}</span>}</td>
            <td>{l.kind === 1 ? "1" : l.kind === 2 ? l.amount.toString() : fmt(l.amount, m?.decimals ?? 18)}</td>
            <td>{l.poolId === 0n ? <span className="muted">No rewards</span> : !l.multiplierBps ? <span className="muted">Below the first tier</span> : tier ? `${label(tier.label)} ${mult(tier.multiplierBps)}` : mult(l.multiplierBps)}</td>
            <td>{day(l.unlockAt)}</td>
            <td>{l.withdrawn ? <Badge tone="grey">Withdrawn</Badge> : ended ? <Badge tone="amber">Unlocked</Badge> : <Badge tone="silver">Locked</Badge>}</td>
          </tr>
        );
      })}
    </Table>
  );
}

function StreamTable({ streams, now, metaOf }: { streams: Stream[]; now: number; metaOf: (a: Address) => TokenMeta | undefined }) {
  return (
    <Table label="Sandfall streams" head={["#", "From", "To", "Token", "Total", "Vested", "Ends", "Cancellable", "Status"]} num={[4, 5]}>
      {streams.map((s) => {
        const m = metaOf(s.asset);
        const dec = m?.decimals ?? 18;
        const rolling = s.kind === 2;
        const finish = rolling ? s.periodFinish : s.end;
        return (
          <tr key={s.id.toString()}>
            <td className="muted">{s.id.toString()}</td>
            <td>
              <Addr address={s.creator} />
            </td>
            <td>
              <Addr address={s.recipient} />
            </td>
            <td>
              <TokenName asset={s.asset} meta={m} />
            </td>
            <td>{fmt(s.total, dec)}</td>
            <td>{fmt(s.vested, dec)}</td>
            <td>{rolling ? <span className="muted">Rolling{Number(finish) > now ? `, to ${day(finish)}` : ""}</span> : day(finish)}</td>
            <td>{s.cancellable ? <Badge tone="amber">Yes</Badge> : <Badge tone="green">No</Badge>}</td>
            <td>{s.cancelled ? <Badge tone="red">Cancelled</Badge> : s.vested >= s.total && !rolling ? <Badge tone="grey">Done</Badge> : <Badge tone="silver">Vesting</Badge>}</td>
          </tr>
        );
      })}
    </Table>
  );
}

function filter<T>(rows: T[], q: string, fields: (r: T) => (string | undefined)[]): T[] {
  const needle = q.trim().toLowerCase();
  if (!needle) return rows;
  return rows.filter((r) => fields(r).some((f) => f?.toLowerCase().includes(needle)));
}

function Search({ value, onChange, placeholder, label }: { value: string; onChange: (v: string) => void; placeholder: string; label: string }) {
  return <input className="input mono-input table-search" value={value} onChange={(e) => onChange(e.target.value)} placeholder={placeholder} aria-label={label} spellCheck={false} autoComplete="off" />;
}

function More({ shown, total, onMore }: { shown: number; total: number; onMore: () => void }) {
  if (shown >= total) return null;
  return (
    <button type="button" className="btn btn-ghost btn-sm table-more" onClick={onMore}>
      Show {Math.min(PAGE, total - shown)} more of {total - shown}
    </button>
  );
}

function TokenName({ asset, meta }: { asset: Address; meta?: TokenMeta }) {
  if (asset === ZERO) return <span>HYPE</span>;
  return (
    <span className="token-name">
      {meta ? <b>{meta.symbol}</b> : null} <TokenAddr address={asset} />
    </span>
  );
}

/** A plain table that scrolls sideways on a phone; `num` marks the columns that hold numbers. */
function Table({ head, num = [], label, children }: { head: string[]; num?: number[]; label: string; children: ReactNode }) {
  return (
    <div className="table-wrap">
      <table className="table" aria-label={label}>
        <thead>
          <tr>
            {head.map((h, i) => (
              <th key={h} className={num.includes(i) ? "n" : undefined} scope="col">
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className={num.map((i) => `n${i}`).join(" ")}>{children}</tbody>
      </table>
    </div>
  );
}
