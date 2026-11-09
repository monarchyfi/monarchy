import { useMemo, useState } from "react";
import { useConnection, useReadContract, useReadContracts } from "wagmi";
import { erc721Abi, isAddress, parseUnits, type Address } from "viem";
import { exileAbi, lodestarAbi, mockERC20Abi } from "../abi";
import { tagline, TierBadge } from "../components/Tiers";
import { TxButton, WithApproval } from "../components/Tx";
import { ConnectPrompt, NoDeployment } from "../components/States";
import { Addr, Amt, Badge, Card, Empty, Row, Skel, Stat, Sym, TokenAddr } from "../components/Ui";
import { Slider } from "../components/Slider";
import { PageMark } from "../components/NavGlyphs";
import { isSet, useDeployment, ZERO } from "../lib/deployments";
import { date, duration, fmt, label, mult } from "../lib/format";
import { POLL, useNow, usePageTitle, useTicking } from "../lib/hooks";
import { DISTRIBUTE_NOTE } from "../lib/constants";
import { dayLabel, useDripDays, useLockedTotal, useLodestarCore, useRouterOf, useTokenMeta, NATIVE_META, type TokenMeta } from "../lib/monarchy";
import { days } from "./Home";

type Tier = { minDuration: number; multiplierBps: number; label: `0x${string}` };
type Rates = { totalPoints: bigint; rewardRate: bigint; periodFinish: bigint | number; stakeRewardRate: bigint; stakePeriodFinish: bigint | number };
// a tx can sit in the mempool for a bit; pad so the chosen tier still qualifies when it lands
const BUFFER = 10 * 60;

export function ExilePage() {
  usePageTitle("Exile");
  const d = useDeployment();
  const core = useLodestarCore();
  // a chain with no featured token (Elysium mainnet, where the coins are on Ascend, Volta, Montra, ElysPump, Boxa and Kleos) opens on "Lock a coin"
  const featured = isSet(d?.lodestar);
  const [mode, setMode] = useState<"main" | "else">(featured ? "main" : "else");
  const poolId = core.exilePoolId;
  const pool = useReadContract({
    address: d?.exile,
    abi: exileAbi,
    functionName: "poolInfo",
    args: [poolId ?? 0n],
    query: { enabled: !!d && poolId !== undefined, ...POLL.query },
  });
  const tiers = (pool.data?.tiers ?? []) as readonly Tier[];
  // Until the pool is read, say "loading" rather than guessing which tier a lock lands in.
  const tiersLoading = !pool.data && (core.isLoading || poolId !== undefined || !!core.lodestar);
  const now = useNow();
  const rewardMeta = core.quoteMeta;
  const dripPerDay = pool.data ? (Number(pool.data.periodFinish) > now ? (pool.data.rewardRate * 86400n) / 10n ** 18n : 0n) : undefined;
  const rd = rewardMeta?.decimals ?? 6;
  const drip = useDripDays();
  const locked = useLockedTotal(core.token);
  // token-side fees paid in the token itself, when the creator chose to send them to lockers
  const stakeMeta = core.tokenMeta;
  const sd = stakeMeta?.decimals ?? 18;
  const stakeDripPerDay = pool.data ? (Number(pool.data.stakePeriodFinish) > now ? (pool.data.stakeRewardRate * 86400n) / 10n ** 18n : 0n) : undefined;
  const hasStakeRewards = !!pool.data && (pool.data.stakeTotalDistributed > 0n || pool.data.stakeCarry > 0n);

  if (!d) return <NoDeployment />;
  const sym = core.tokenMeta?.symbol;
  return (
    <div className="page">
      <header className="page-head">
        <h1>
          <PageMark page="exile" />
          Exile
        </h1>
        <p className="muted">
          Lock to earn. Holding a coin earns nothing; locking it earns a share of its creator fees, and the longer the lock, the
          bigger the share. Any coin can be locked, and every coin with a Lodestar pays its lockers. A lock can be extended but
          never shortened, cancelled or transferred. LP tokens and NFTs can be locked too.
        </p>
      </header>

      <Card
        title={mode === "main" ? <>Lock <Sym s={sym} /></> : featured ? "Lock something else" : "Lock a coin"}
        right={
          featured && <Switch
            options={[
              { key: "main", label: sym ?? "Token" },
              { key: "else", label: "Something else" },
            ]}
            value={mode}
            onChange={(k) => setMode(k as "main" | "else")}
          />
        }
      >
        <div key={mode} className="swap-in">
          {mode === "main" ? (
            <LockForm exile={d.exile} token={core.token} tokenMeta={core.tokenMeta} poolId={poolId} tiers={tiers} tiersLoading={tiersLoading} rates={pool.data} rewardMeta={rewardMeta} canOptOut />
          ) : (
            <SomethingElse exile={d.exile} />
          )}
        </div>
      </Card>

      {featured && <Card
        title={
          <>
            <Sym s={core.tokenMeta?.symbol} /> holder rewards
          </>
        }
        right={<span className="muted small">Paid as a {dayLabel(drip)} drip</span>}
      >
        <div className="stats stats-4">
          <Stat label="Dripping now" value={<><Amt value={dripPerDay} decimals={rd} symbol={rewardMeta?.symbol} /><span className="amt-sym"> a day</span></>} hint={`Each deposit drips out over ${drip} days`} />
          <Stat label="Paid in so far" value={<Amt value={pool.data?.totalDistributed} decimals={rd} symbol={rewardMeta?.symbol} />} hint="Sent here by Lodestar" />
          <Stat
            label={core.tokenMeta ? `Locked ${core.tokenMeta.symbol}` : "Locked"}
            value={<Amt value={locked?.amount} decimals={core.tokenMeta?.decimals ?? 18} digits={0} symbol={core.tokenMeta?.symbol} />}
            hint={locked ? `${locked.locks} ${locked.locks === 1 ? "lock" : "locks"} by ${locked.lockers} ${locked.lockers === 1 ? "holder" : "holders"}` : <Skel w="9em" />}
          />
          <Stat label="Drip ends" value={pool.data ? (Number(pool.data.periodFinish) > now ? duration(Number(pool.data.periodFinish) - now) : "Idle") : <Skel w="5em" />} hint="Refills on every distribute" />
        </div>
        {hasStakeRewards && (
          <div className="stats stats-4">
            <Stat label="Token rewards dripping" value={<><Amt value={stakeDripPerDay} decimals={sd} digits={0} symbol={stakeMeta?.symbol} /><span className="amt-sym"> a day</span></>} hint="Token-side fees, paid to lockers" />
            <Stat label="Token rewards paid in" value={<Amt value={pool.data?.stakeTotalDistributed} decimals={sd} digits={0} symbol={stakeMeta?.symbol} />} hint="Sent here by Lodestar" />
          </div>
        )}
        <p className="small cadence">{DISTRIBUTE_NOTE}</p>
      </Card>}

      {/* without a featured token the rewards are the launchpads' quote, native HYPE */}
      <MyLocks exile={d.exile} tiers={tiers} rewardMeta={featured ? rewardMeta : NATIVE_META} stakeMeta={stakeMeta} />
    </div>
  );
}

/** A lock form for one token. With a reward pool (poolId > 0) it shows the pool's tiers along the slider. */
function LockForm({
  exile,
  token,
  tokenMeta,
  poolId,
  tiers,
  tiersLoading,
  rates,
  rewardMeta,
  canOptOut,
}: {
  exile: Address;
  token?: Address;
  tokenMeta?: TokenMeta;
  poolId?: bigint;
  tiers: readonly Tier[];
  tiersLoading: boolean;
  /** The pool's live points and drip rates, for the earnings estimate. */
  rates?: Rates;
  rewardMeta?: TokenMeta;
  /** The token has a reward pool and no dividend harvest, so a lock may stay out of the pool (a plain lock). */
  canOptOut?: boolean;
}) {
  const { address } = useConnection();
  const [amount, setAmount] = useState("");
  // a holder who doesn't want rewards (a team's own supply, say) locks outside the pool, so lockers get it all
  const [optOut, setOptOut] = useState(false);
  const [seconds, setSeconds] = useState(30 * 86400);
  const drip = useDripDays();
  // While the pool is loading (or its read failed) the lock still belongs in it: wait rather than fall back
  // to poolId 0, which would make a permanent lock that never earns.
  const rewards = (!!poolId || tiersLoading) && !(canOptOut && optOut);
  const meta = useReadContracts({
    allowFailure: false,
    contracts: [
      { address: token, abi: mockERC20Abi, functionName: "decimals" },
      { address: token, abi: mockERC20Abi, functionName: "symbol" },
      { address: token, abi: mockERC20Abi, functionName: "balanceOf", args: [address ?? ZERO] },
    ],
    query: { enabled: !!token, ...POLL.query },
  });
  const [decimals, symbol, balance] = meta.data ?? [tokenMeta?.decimals ?? 18, tokenMeta?.symbol ?? "", undefined];
  const value = safeParse(amount, Number(decimals));
  const tier = rewards ? pickTier(tiers, seconds) : undefined;
  // Exile rounds every unlock time up to the next hour, so the preview does too
  const unlockAt = ceilHour(Math.floor(Date.now() / 1000) + seconds + BUFFER);
  const overBalance = balance !== undefined && value > (balance as bigint);
  const points = tier ? (value * BigInt(tier.multiplierBps)) / 10_000n : 0n;
  const earns = rates && rewards ? estimate(rates, points, unlockAt - Math.floor(Date.now() / 1000)) : undefined;
  const reason = !token ? "Enter the token or LP address" : tiersLoading && rewards ? "Loading reward tiers" : value === 0n ? "Enter an amount" : overBalance ? "More than your balance" : undefined;

  return (
    <>
      {canOptOut && (
        <label className="check opt-out">
          <input type="checkbox" checked={optOut} onChange={(e) => setOptOut(e.target.checked)} />
          <span>
            <b className="text">Lock without rewards.</b> The coins stay locked until the unlock date and show in the Garden like any lock, but
            they earn nothing, so every reward goes to the other lockers. A lock can't join the reward pool later.
          </span>
        </label>
      )}
      {rewards && tiersLoading && (
        <div className="tiers pick" aria-busy="true">
          {[0, 1, 2, 3].map((i) => (
            <Skel key={i} block h="118px" w="auto" />
          ))}
        </div>
      )}
      {rewards && !tiersLoading && (
        <div className="tiers pick">
          {tiers.map((t) => {
            const name = label(t.label);
            const active = tier?.label === t.label;
            return (
              <button key={name} type="button" aria-pressed={active} className={`tier tier-${name.toLowerCase()} ${active ? "active" : ""}`} onClick={() => setSeconds(t.minDuration)}>
                <TierBadge name={name} />
                <div className="tier-mult">{mult(t.multiplierBps)}</div>
                <div className="tier-len">{days(t.minDuration)}</div>
                <div className="tier-tag">{tagline(name) ?? ""}</div>
              </button>
            );
          })}
        </div>
      )}
      <div className="lock-split">
        <div className="lock-main">
          <DurationSlider seconds={seconds} onChange={setSeconds} tiers={rewards ? tiers : []} tierName={tier ? label(tier.label) : undefined} />
          <label className="field" style={{ marginTop: 14 }}>
            <span className="field-label">Amount {symbol && <span className="faint">({symbol})</span>}</span>
            <div className="input-row">
              <input className="input" inputMode="decimal" placeholder="0.0" value={amount} onChange={(e) => setAmount(e.target.value)} />
              {balance !== undefined && (
                <button className="btn btn-ghost btn-sm" onClick={() => setAmount(fmtPlain(balance as bigint, Number(decimals)))}>
                  Max {fmt(balance as bigint, Number(decimals))}
                </button>
              )}
            </div>
          </label>
        </div>
        <div className="lock-side">
          <div className="summary">
            <Row k="Unlocks" v={date(unlockAt)} />
            <Row
              k="Tier"
              v={
                !rewards ? (
                  <Badge tone="grey">{canOptOut && optOut ? "No rewards, by choice" : "No rewards for this token"}</Badge>
                ) : tiersLoading ? (
                  <Skel w="8em" />
                ) : tier ? (
                  <>
                    <TierBadge name={label(tier.label)} /> {mult(tier.multiplierBps)}
                  </>
                ) : (
                  <Badge tone="red">No rewards</Badge>
                )
              }
            />
            {rewards && value > 0n && tier && <Row k="Points" v={fmt(points, Number(decimals))} />}
            <Row k="Cancellable" v={<Badge tone="green">Not cancellable</Badge>} />
          </div>
          {earns && (
            <div className="lock-est">
              <div className="lock-est-k">Estimated earnings</div>
              <div className="lock-est-v">
                {earns.quote > 0n || earns.stake > 0n ? (
                  <>
                    {earns.quote > 0n && <Amt value={earns.quote} decimals={rewardMeta?.decimals ?? 6} symbol={rewardMeta?.symbol} />}
                    {earns.quote > 0n && earns.stake > 0n && <span className="faint"> + </span>}
                    {earns.stake > 0n && <Amt value={earns.stake} decimals={Number(decimals)} digits={0} symbol={symbol} />}
                  </>
                ) : (
                  "Nothing dripping right now"
                )}
              </div>
              <div className="muted small">Over the {seconds >= 86400 ? `${Math.round(seconds / 86400)} day` : duration(seconds)} lock, at today's drip rate.</div>
              <p className="lock-est-note small">
                <b>A rough estimate, not a promise.</b> Real earnings will differ: they rise and fall with the drip rate, trading volume and how
                much everyone has locked.
              </p>
            </div>
          )}
          {/* Approve is only offered once the lock itself could go through */}
          <WithApproval token={token} spender={exile} amount={reason ? 0n : value}>
            <TxButton headroom
              disabledReason={reason}
              request={() =>
                token && {
                  address: exile,
                  abi: exileAbi,
                  functionName: "lockERC20",
                  args: [token, value, BigInt(unlockAt), rewards ? (poolId ?? 0n) : 0n],
                }
              }
              onDone={() => setAmount("")}
            >
              {symbol ? `Lock ${symbol}` : "Lock"}
            </TxButton>
          </WithApproval>
          <p className="muted small">
            Unlock times round up to the next hour.{rewards ? ` Rewards drip in over ${drip} days and stop the second a lock ends.` : ""}
          </p>
        </div>
      </div>
    </>
  );
}

/** What a lock with these points would earn over `seconds` if both streams kept dripping at today's rate:
 * its share of all points, after it joins, times each stream's rate. A stream that has run dry counts as zero. */
function estimate(r: Rates, points: bigint, seconds: number): { quote: bigint; stake: bigint } | undefined {
  if (points === 0n || seconds <= 0) return undefined;
  const now = Math.floor(Date.now() / 1000);
  const total = r.totalPoints + points;
  // rates are scaled by 1e18 (Exile's RATE_PREC)
  const over = (rate: bigint, finish: bigint | number) => (Number(finish) > now ? (rate * BigInt(seconds) * points) / total / 10n ** 18n : 0n);
  return { quote: over(r.rewardRate, r.periodFinish), stake: over(r.stakeRewardRate, r.stakePeriodFinish) };
}

/** "Something else": any token or LP (with rewards when it has a Lodestar), or an NFT. */
function SomethingElse({ exile }: { exile: Address }) {
  const [kind, setKind] = useState<"token" | "nft">("token");
  const [input, setInput] = useState("");
  const token = isAddress(input) ? input : undefined;
  const bad = input !== "" && !token;
  // a token with its own Lodestar has its own Exile reward pool and tiers
  const lodestar = useRouterOf(token);
  // A coin that pays holders dividends (ElysPump, Boxa, Kleos) has a harvest, and Exile only takes its locks in the
  // harvest's pool (anything else reverts HarvestPoolOnly), so that pool wins over whatever router the lookup found.
  const harvest = useReadContract({ address: exile, abi: exileAbi, functionName: "harvestOf", args: [token ?? ZERO], query: { enabled: !!token } });
  const harvestPool = harvest.data && harvest.data[0] !== 0n ? harvest.data[0] : undefined;
  const router = harvestPool ? undefined : lodestar.router;
  const pid = useReadContract({ address: router, abi: lodestarAbi, functionName: "exilePoolId", query: { enabled: !!router } });
  const poolId = harvestPool ?? pid.data;
  const pool = useReadContract({ address: exile, abi: exileAbi, functionName: "poolInfo", args: [poolId ?? 0n], query: { enabled: poolId !== undefined } });
  const tiers = (pool.data?.tiers ?? []) as readonly Tier[];
  const rewarded = !!harvestPool || !!router;
  const checking = !!token && (lodestar.isLoading || harvest.isLoading || (!!router && pid.isLoading) || (rewarded && pool.isLoading));
  return (
    <>
      <div className="note-box">
        <b>Tokens that use Lodestar earn rewards here too.</b> Every Lodestar token gets its own Exile reward pool and tiers. Anything
        else can still be locked, it just earns nothing.
      </div>
      <div className="tabs" role="tablist" style={{ marginBottom: 16 }}>
        <button role="tab" aria-selected={kind === "token"} className={kind === "token" ? "tab active" : "tab"} onClick={() => setKind("token")}>
          Token or LP
        </button>
        <button role="tab" aria-selected={kind === "nft"} className={kind === "nft" ? "tab active" : "tab"} onClick={() => setKind("nft")}>
          NFT
        </button>
      </div>
      {kind === "nft" ? (
        <LockNfts exile={exile} />
      ) : (
        <>
          <label className="field">
            <span className="field-label">Token or LP address</span>
            <input className="input mono-input" placeholder="0x…" value={input} onChange={(e) => setInput(e.target.value.trim())} spellCheck={false} autoComplete="off" />
          </label>
          <p className={bad ? "warn small" : "muted small"}>
            {bad
              ? "That isn't a valid address yet."
              : !token
                ? "Paste the address of the token or LP to lock."
                : checking
                  ? "Checking for a Lodestar…"
                  : harvestPool
                    ? "This coin pays its holders dividends, so Exile only locks it in its Lodestar's reward pool, where the dividends Exile earns on it go to lockers. It earns rewards by tier."
                    : router
                    ? "This token uses Lodestar, so this lock earns rewards by tier."
                    : "No Lodestar for this token: a plain lock, held until the unlock date, with no rewards."}
          </p>
          {token && !checking && (
            <div style={{ marginTop: 16 }}>
              <LockForm key={token} exile={exile} token={token} poolId={rewarded ? poolId : 0n} tiers={rewarded ? tiers : []} tiersLoading={rewarded && (!poolId || !pool.data)} canOptOut={!!router} />
            </div>
          )}
        </>
      )}
    </>
  );
}

/** A sliding knob between options. */
/** A row of options with a sliding knob. `grid` lays many options out as a grid that wraps to rows of three on a
 * phone (the launchpad picker), with the picked one filled in instead of the knob. */
export function Switch({
  options,
  value,
  onChange,
  grid,
}: {
  options: { key: string; label: string }[];
  value: string;
  onChange: (k: string) => void;
  grid?: boolean;
}) {
  const i = Math.max(0, options.findIndex((o) => o.key === value));
  return (
    <div className={grid ? "switch switch-grid" : "switch"} role="tablist" style={grid ? ({ "--cols": options.length } as React.CSSProperties) : undefined}>
      {!grid && <span className="switch-knob" style={{ width: `calc((100% - 6px) / ${options.length})`, transform: `translateX(${i * 100}%)` }} aria-hidden="true" />}
      {options.map((o) => (
        <button key={o.key} role="tab" aria-selected={o.key === value} className={o.key === value ? "on" : ""} onClick={() => onChange(o.key)}>
          {o.label}
        </button>
      ))}
    </div>
  );
}

// The duration slider runs from an hour to a year on a log scale, so short and long locks both get room.
const MIN_S = 3600;
const MAX_S = 365 * 86400;
const toPos = (sec: number) => (Math.log(Math.max(MIN_S, Math.min(MAX_S, sec)) / MIN_S) / Math.log(MAX_S / MIN_S)) * 1000;
function fromPos(pos: number): number {
  const raw = MIN_S * Math.pow(MAX_S / MIN_S, pos / 1000);
  // whole hours below two days, whole days above
  return raw < 2 * 86400 ? Math.round(raw / 3600) * 3600 : Math.round(raw / 86400) * 86400;
}
/** One key press on the duration slider: an hour (a day with Page keys) below two days, a day (a week) above. */
function nudge(sec: number, dir: -1 | 1, big: boolean): number {
  const unit = sec + dir * 3600 < 2 * 86400 ? 3600 : 86400;
  const next = sec + dir * unit * (big ? (unit === 3600 ? 24 : 7) : 1);
  return Math.min(MAX_S, Math.max(MIN_S, next < 2 * 86400 ? Math.round(next / 3600) * 3600 : Math.round(next / 86400) * 86400));
}
function lockLength(sec: number): string {
  if (sec < 86400) return `${Math.round(sec / 3600)} hour${sec === 3600 ? "" : "s"}`;
  const dd = Math.round(sec / 86400);
  if (dd === 365) return "1 year";
  return `${dd} day${dd === 1 ? "" : "s"}`;
}

/** Tick labels under the slider: 1h, 3d, 1y. Short enough that close tiers don't collide on a phone. */
function shortLength(sec: number) {
  if (sec >= 365 * 86400) return `${Math.round(sec / (365 * 86400))}y`;
  if (sec >= 86400) return `${Math.round(sec / 86400)}d`;
  return `${Math.max(1, Math.round(sec / 3600))}h`;
}

function DurationSlider({ seconds, onChange, tiers, tierName }: { seconds: number; onChange: (s: number) => void; tiers: readonly Tier[]; tierName?: string }) {
  return (
    <div className="dur">
      <div className="dur-top">
        <span className="field-label muted">Lock for</span>
        <span className="dur-value">
          {lockLength(seconds)}
          {tierName && <span className="amt-sym"> · {tierName}</span>}
        </span>
      </div>
      <Slider max={1000} values={[toPos(seconds)]} onChange={(_, p) => onChange(fromPos(p))} keyStep={(_, dir, big) => onChange(nudge(seconds, dir, big))} labels={["Lock length"]} valueTexts={[lockLength(seconds)]} />
      <div className="dur-marks">
        {tiers.length > 0
          ? tiers.map((t) => (
              <button key={t.label} type="button" className={`dur-mark ${seconds >= t.minDuration ? "on" : ""}`} style={{ left: `${toPos(t.minDuration) / 10}%` }} onClick={() => onChange(t.minDuration)} title={label(t.label)}>
                {shortLength(t.minDuration)}
              </button>
            ))
          : [3600, 86400, 7 * 86400, 30 * 86400, MAX_S].map((sec) => (
              <button key={sec} type="button" className={`dur-mark ${seconds >= sec ? "on" : ""}`} style={{ left: `${toPos(sec) / 10}%` }} onClick={() => onChange(sec)}>
                {shortLength(sec)}
              </button>
            ))}
      </div>
    </div>
  );
}

function LockNfts({ exile }: { exile: Address }) {
  const { address } = useConnection();
  const [kind, setKind] = useState<"721" | "1155">("721");
  const [collection, setCollection] = useState("");
  const [id, setId] = useState("");
  const [amount, setAmount] = useState("1");
  const [seconds, setSeconds] = useState(30 * 86400);
  const ok = isAddress(collection);
  const approved = useReadContract({
    address: ok ? collection : undefined,
    abi: erc721Abi,
    functionName: "isApprovedForAll",
    args: [address ?? "0x0000000000000000000000000000000000000000", exile],
    query: { enabled: ok && !!address, ...POLL.query },
  });
  const unlockAt = BigInt(Math.floor(Date.now() / 1000) + seconds + BUFFER);
  const tokenId = /^\d+$/.test(id) ? BigInt(id) : undefined;
  const count = /^\d+$/.test(amount) ? BigInt(amount) : 0n;
  return (
    <>
      <p className="muted small">ERC-721 or ERC-1155. NFT locks hold the item until the unlock date and don't earn rewards.</p>
      <div className="form">
        <label>
          Standard
          <select className="input" value={kind} onChange={(e) => setKind(e.target.value as "721" | "1155")}>
            <option value="721">ERC-721</option>
            <option value="1155">ERC-1155</option>
          </select>
        </label>
        <label>
          Collection
          <input className="input" placeholder="0x…" value={collection} onChange={(e) => setCollection(e.target.value.trim())} />
        </label>
        <label>
          Token id
          <input className="input" value={id} onChange={(e) => setId(e.target.value.trim())} />
        </label>
        {kind === "1155" && (
          <label>
            Amount
            <input className="input" value={amount} onChange={(e) => setAmount(e.target.value)} />
          </label>
        )}
      </div>
      <DurationSlider seconds={seconds} onChange={setSeconds} tiers={[]} />
      {ok && approved.data === false ? (
        // keyed apart from the lock button, so it doesn't inherit the approval's "Confirmed"
        <TxButton key="approve" request={() => ({ address: collection as Address, abi: erc721Abi, functionName: "setApprovalForAll", args: [exile, true] })}>
          Approve collection
        </TxButton>
      ) : (
        <TxButton headroom
          key="lock"
          disabledReason={!ok ? "Enter a collection" : tokenId === undefined ? "Enter a token id" : kind === "1155" && count === 0n ? "Enter a whole amount" : undefined}
          request={() =>
            kind === "721"
              ? { address: exile, abi: exileAbi, functionName: "lockERC721", args: [collection as Address, tokenId!, unlockAt] }
              : { address: exile, abi: exileAbi, functionName: "lockERC1155", args: [collection as Address, tokenId!, count, unlockAt] }
          }
        >
          Lock NFT
        </TxButton>
      )}
    </>
  );
}

function MyLocks({ exile, tiers, rewardMeta, stakeMeta }: { exile: Address; tiers: readonly Tier[]; rewardMeta?: TokenMeta; stakeMeta?: TokenMeta }) {
  const { address } = useConnection();
  const ids = useReadContract({
    address: exile,
    abi: exileAbi,
    functionName: "lockIdsOf",
    args: [address ?? "0x0000000000000000000000000000000000000000"],
    query: { enabled: !!address, ...POLL.query },
  });
  const list = useMemo(() => [...(ids.data ?? [])].reverse(), [ids.data]);
  return (
    <Card title="My locks" right={address && ids.data ? <span className="muted small">{list.length} {list.length === 1 ? "lock" : "locks"}</span> : undefined}>
      {!address && <ConnectPrompt>Your locks and rewards show up here once a wallet is connected.</ConnectPrompt>}
      {address && !ids.data && (
        <div className="locks">
          <div className="lock skeleton" />
        </div>
      )}
      {address && ids.data && list.length === 0 && <Empty title="No locks yet">Everyone starts somewhere. Pick a tier above to make your first lock.</Empty>}
      <div className="locks">
        {list.map((id) => (
          <LockCard key={id.toString()} exile={exile} id={id} tiers={tiers} rewardMeta={rewardMeta} stakeMeta={stakeMeta} />
        ))}
      </div>
    </Card>
  );
}

function LockCard({ exile, id, tiers: mainTiers, rewardMeta: mainReward, stakeMeta: mainStake }: { exile: Address; id: bigint; tiers: readonly Tier[]; rewardMeta?: TokenMeta; stakeMeta?: TokenMeta }) {
  const base = { address: exile, abi: exileAbi } as const;
  const r = useReadContracts({
    allowFailure: false,
    contracts: [
      { ...base, functionName: "lockInfo", args: [id] },
      { ...base, functionName: "pendingRewards", args: [id] },
      { ...base, functionName: "earningRatePerSecond", args: [id] },
      { ...base, functionName: "pendingStakeRewards", args: [id] },
      { ...base, functionName: "stakeEarningRatePerSecond", args: [id] },
    ],
    query: POLL.query,
  });
  const [lock, pending, rate, pendingStake, stakeRate] = r.data ?? [];
  const live = useTicking(pending, rate);
  const liveStake = useTicking(pendingStake, stakeRate);
  const now = useNow();
  const [extendDays, setExtendDays] = useState(30);
  const dec = useReadContract({
    address: lock?.asset,
    abi: mockERC20Abi,
    functionName: "decimals",
    query: { enabled: !!lock && lock.kind === 0, staleTime: Infinity },
  });
  // a lock made under "Something else" sits in that token's pool, with its own tiers and reward tokens
  const own = useReadContract({ ...base, functionName: "poolInfo", args: [lock?.poolId ?? 0n], query: { enabled: !!lock && lock.poolId !== 0n, ...POLL.query } });
  const [ownReward, ownStake] = useTokenMeta([own.data?.rewardToken, own.data?.stakeToken]);
  if (!lock) return <div className="lock skeleton" />;
  const tiers = (own.data?.tiers ?? mainTiers) as readonly Tier[];
  const rewardMeta = own.data ? ownReward : mainReward;
  const stakeMeta = own.data ? ownStake : mainStake;

  const unlockAt = Number(lock.unlockAt);
  const ended = now >= unlockAt;
  const kind = ["Token", "ERC-721", "ERC-1155"][lock.kind];
  const tier = tiers.find((t) => t.multiplierBps === lock.multiplierBps);
  // after a tier change no tier may match the multiplier a lock was made with; show the multiplier then
  const name = lock.poolId === 0n || !lock.multiplierBps ? "" : tier ? label(tier.label) : mult(lock.multiplierBps);
  const newUnlock = Math.max(unlockAt, now) + extendDays * 86400;
  const newTier = pickTier(tiers, newUnlock - now);
  const rd = rewardMeta?.decimals ?? 6;
  const sd = stakeMeta?.decimals ?? 18;
  const showStake = !!pendingStake || (!!stakeRate && stakeRate > 0n);
  const amountDec = lock.kind === 0 ? Number(dec.data ?? 18) : 0;

  return (
    <div className={`lock ${ended ? "lock-ended" : ""}`}>
      <div className="lock-top">
        <div className="lock-badges">
          {lock.poolId !== 0n ? <TierBadge name={name} /> : <Badge tone="grey">{kind} lock</Badge>}
          <Badge tone="green">Not cancellable</Badge>
          {lock.withdrawn ? <Badge tone="grey">Withdrawn</Badge> : ended ? <Badge tone="amber">Unlocked</Badge> : <Badge tone="silver">Locked</Badge>}
        </div>
        <span className="muted mono">#{id.toString()}</span>
      </div>
      <div className="lock-body">
        <Row k="Asset" v={lock.kind === 0 ? <TokenAddr address={lock.asset} /> : <Addr address={lock.asset} />} />
        {lock.kind !== 0 && <Row k="Token id" v={lock.tokenId.toString()} />}
        <Row k="Amount" v={lock.kind === 1 ? "1" : fmt(lock.amount, amountDec)} />
        <Row k={ended ? "Unlocked" : "Unlocks in"} v={ended ? date(unlockAt) : `${duration(unlockAt - now)} (${date(unlockAt)})`} />
        {lock.poolId !== 0n && (
          <>
            <Row k="Multiplier" v={mult(lock.multiplierBps)} />
            <Row
              k="Rewards"
              v={
                <span className={rate && rate > 0n ? "ticking gold" : ""}>
                  {fmt(live, rd, 6)} {rewardMeta?.symbol}
                </span>
              }
            />
            <Row k="Earning" v={rate && rate > 0n ? `${fmt((rate * 86400n) / 10n ** 18n, rd, 4)} ${rewardMeta?.symbol}/day` : ended ? "stopped at unlock" : "waiting for the next drip"} />
            {showStake && (
              <>
                <Row
                  k="Token rewards"
                  v={
                    <span className={stakeRate && stakeRate > 0n ? "ticking gold" : ""}>
                      {fmt(liveStake, sd, 4)} {stakeMeta?.symbol}
                    </span>
                  }
                />
                <Row k="Earning" v={stakeRate && stakeRate > 0n ? `${fmt((stakeRate * 86400n) / 10n ** 18n, sd, 2)} ${stakeMeta?.symbol}/day` : ended ? "stopped at unlock" : "waiting for the next drip"} />
              </>
            )}
          </>
        )}
      </div>
      <div className="lock-actions">
        {lock.poolId !== 0n && (
          <TxButton headroom className="btn btn-sm" disabledReason={!pending && !pendingStake ? "Nothing to claim" : undefined} request={() => ({ ...base, functionName: "claimRewards", args: [id] })}>
            Claim
          </TxButton>
        )}
        {!lock.withdrawn && (
          <div className="extend">
            <input className="input input-sm" type="number" min={1} step={1} aria-label="Extend by this many days" value={extendDays} onChange={(e) => setExtendDays(Number(e.target.value))} />
            <span className="muted small">days</span>
            <TxButton headroom className="btn btn-sm btn-ghost" disabledReason={!(Number.isInteger(extendDays) && extendDays >= 1) ? "Whole days, at least 1" : undefined} request={() => ({ ...base, functionName: "extend", args: [id, BigInt(newUnlock + BUFFER)] })}>
              Extend
              {lock.poolId !== 0n && (newTier?.multiplierBps ?? 0) !== lock.multiplierBps
                ? newTier
                  ? ` (${newTier.multiplierBps > lock.multiplierBps ? "up" : "down"} to ${label(newTier.label)})`
                  : " (no rewards)"
                : ""}
            </TxButton>
          </div>
        )}
        {!lock.withdrawn && (
          <TxButton headroom className="btn btn-sm btn-ghost" disabledReason={!ended ? "Still locked" : undefined} request={() => ({ ...base, functionName: "withdraw", args: [id] })}>
            Withdraw
          </TxButton>
        )}
      </div>
    </div>
  );
}

function ceilHour(t: number): number {
  return Math.ceil(t / 3600) * 3600;
}

function pickTier(tiers: readonly Tier[], seconds: number): Tier | undefined {
  let best: Tier | undefined;
  for (const t of tiers) if (seconds >= t.minDuration) best = t;
  return best;
}

function safeParse(v: string, decimals: number): bigint {
  try {
    return v ? parseUnits(v as `${number}`, decimals) : 0n;
  } catch {
    return 0n;
  }
}

function fmtPlain(v: bigint, decimals: number): string {
  const s = v.toString().padStart(decimals + 1, "0");
  const whole = s.slice(0, s.length - decimals);
  const frac = s.slice(s.length - decimals).replace(/0+$/, "");
  return frac ? `${whole}.${frac}` : whole;
}

export { safeParse, fmtPlain };
