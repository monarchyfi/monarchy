import { useState } from "react";
import { useSearchParams } from "react-router-dom";
import { useConnection, useEstimateGas, useReadContract, useReadContracts } from "wagmi";
import { encodeFunctionData, isAddress, stringToHex, type Address } from "viem";
import { exileAbi, iAscendLaunchpadAbi, lodestarAbi, lodestarFactoryAbi } from "../abi";
import { TierBadge, tagline } from "../components/Tiers";
import { TxButton } from "../components/Tx";
import { Addr, Amt, Badge, Card, Empty, Row, Skel, Stat, Sym } from "../components/Ui";
import { CATCH_UP_ALONE_ABOVE_GAS, DEFAULT_TREASURY_WINDOW_DAYS, DISTRIBUTE_NOTE, EXILE_CATCH_UP_HOURS } from "../lib/constants";
import { isSet, useDeployment, ZERO, type Deployment } from "../lib/deployments";
import { date, duration, fmt, label, mult, pct } from "../lib/format";
import { POLL, useNow, usePageTitle } from "../lib/hooks";
import { useLodestarCore, useTokenMeta } from "../lib/monarchy";
import { NoDeployment } from "../components/States";
import { Slider } from "../components/Slider";
import { PageMark } from "../components/NavGlyphs";
import { PadsLodestar } from "./LodestarPads";

/** Lodestar.EXECUTION_WINDOW: how long a ready proposal can still be executed. */
const EXECUTION_WINDOW = 7 * 86400;

export function LodestarPage() {
  usePageTitle("Lodestar");
  const d = useDeployment();
  // ?token= (and ?quote=) open a given router, so the Garden can link straight to one
  const [params] = useSearchParams();
  const [input, setInput] = useState(() => params.get("token") ?? "");
  const [quoteInput, setQuoteInput] = useState(() => params.get("quote") ?? "");
  const defaultToken = d && isSet(d.token) ? d.token : undefined;
  const [defaultMeta, defaultQuoteMeta] = useTokenMeta([defaultToken, d?.quote]);
  if (!d) return <NoDeployment />;
  // Elysium mainnet before Ascend is there: the coins to activate are on Eleos, Kleos and Boxa
  if (d.pads && d.mode === "launchpads") return <PadsLodestar pads={d.pads} />;
  const token = isAddress(input) ? input : defaultToken;
  const badInput = input !== "" && !isAddress(input);
  // Ascend pools can pair with any quote asset (USDC, WHYPE, a tokenized stock...), and the router address
  // depends on the pair, so the quote can be changed here. Empty means the deployment's default.
  const quote = isAddress(quoteInput) ? quoteInput : d.quote;
  const badQuote = quoteInput !== "" && !isAddress(quoteInput);
  return (
    <div className="page">
      <header className="page-head">
        <h1>
          <PageMark page="lodestar" />
          Lodestar
        </h1>
        <p className="muted">
          Your token, your rules. A Lodestar holds your token's creator role and routes every fee the way you set it: to
          Exile lockers, into buyback and burn, or to a Team Treasury streamed through Sandfall. You pick the split, where
          token-side fees go and the lock tiers, and anyone can trigger a distribute. Later changes wait 12 hours, in public.
          No fees.
        </p>
      </header>
      <Card title="Token">
        <label className="field">
          <span className="field-label">Ascend token address</span>
          <input
            className="input mono-input"
            placeholder={defaultToken ? `${defaultToken}${defaultMeta ? ` (${defaultMeta.symbol})` : ""}` : "0x…"}
            value={input}
            onChange={(e) => setInput(e.target.value.trim())}
            spellCheck={false}
            autoComplete="off"
          />
        </label>
        <p className="muted small field-help">
          {badInput
            ? "That isn't a valid address yet."
            : input
              ? "Showing the token you pasted."
              : defaultToken
                ? <>Showing <b className="text">{defaultMeta?.symbol ?? "the demo token"}</b>. Paste another Ascend token to view or activate its Lodestar.</>
                : "Paste an Ascend token to view or activate its Lodestar."}
        </p>
        <label className="field">
          <span className="field-label">Quote asset (what the pool pairs with)</span>
          <input
            className="input mono-input"
            placeholder={`${d.quote}${defaultQuoteMeta ? ` (${defaultQuoteMeta.symbol})` : ""}`}
            value={quoteInput}
            onChange={(e) => setQuoteInput(e.target.value.trim())}
            spellCheck={false}
            autoComplete="off"
          />
        </label>
        <p className="muted small field-help">
          {badQuote
            ? "That isn't a valid address yet."
            : quoteInput
              ? "Looking for the pool against the quote asset you pasted."
              : <>Pools paired with {defaultQuoteMeta?.symbol ?? "the default quote asset"}. Paste another quote asset if the pool pairs with something else.</>}
        </p>
      </Card>
      {token && <ForToken d={d} token={token} quote={quote} />}
    </div>
  );
}

function ForToken({ d, token, quote }: { d: Deployment; token: Address; quote: Address }) {
  const r = useReadContracts({
    allowFailure: false,
    contracts: [
      { address: d.factory, abi: lodestarFactoryAbi, functionName: "lodestarOf", args: [token] },
      { address: d.factory, abi: lodestarFactoryAbi, functionName: "predict", args: [token, quote] },
    ],
    query: POLL.query,
  });
  if (!r.data) return <LoadingCard />;
  const [deployed, [predicted, poolId]] = r.data;
  return deployed !== ZERO ? (
    <Router env={ascendEnv(d)} lodestar={deployed} />
  ) : (
    <Activate d={d} token={token} quote={quote} predicted={predicted} poolId={poolId} />
  );
}

/** Where a router lives: the Exile and factory it was made with, and the launchpad that holds its coin's creator
 * role. `launchpad` is Ascend's, for its listing set-aside; routers on Eleos, Kleos and Boxa have none. */
export type RouterEnv = { exile: Address; factory: Address; launchpad?: Address; venue: string; priceRef: string };

const ascendEnv = (d: Deployment): RouterEnv => ({ exile: d.exile, factory: d.factory, launchpad: d.launchpad, venue: "Ascend", priceRef: "Ascend's EMA" });

/** Distribute, after catching Exile's reward pool up when a long pause left it far behind. distribute catches it up
 * itself, but then it needs more gas than a wallet estimates (and older routers park the payouts without moving
 * the pool), so like the keeper the card pokes the pool forward first, EXILE_CATCH_UP_HOURS per transaction. */
function DistributeButton({ exile, lodestar, exilePoolId }: { exile: Address; lodestar: Address; exilePoolId?: bigint }) {
  const poke = exilePoolId === undefined ? undefined : ({ address: exile, abi: exileAbi, functionName: "poke", args: [exilePoolId, BigInt(EXILE_CATCH_UP_HOURS)] } as const);
  // what one catch-up costs right now: a few idle hours cost little, weeks of expiring locks cost millions
  const catchUp = useEstimateGas({ to: exile, data: poke && encodeFunctionData(poke), query: { enabled: !!poke, ...POLL.query } });
  const heavy = (catchUp.data ?? 0n) > CATCH_UP_ALONE_ABOVE_GAS;
  return (
    <>
      {heavy && (
        <>
          <p className="muted small">Lockers' rewards have fallen behind after a long pause. Catch them up first; it can take a few transactions.</p>
          <TxButton request={() => poke}>Catch up rewards</TxButton>
        </>
      )}
      <TxButton headroom disabledReason={heavy ? "Catch up rewards first" : undefined} request={() => ({ address: lodestar, abi: lodestarAbi, functionName: "distribute" })}>
        Distribute
      </TxButton>
    </>
  );
}

// ==================================================================== router dashboard

export function Router({ env, lodestar }: { env: RouterEnv; lodestar: Address }) {
  const { address } = useConnection();
  const core = useLodestarCore(lodestar);
  const now = useNow();
  const l = { address: lodestar, abi: lodestarAbi } as const;
  const r = useReadContracts({
    allowFailure: false,
    contracts: [
      { ...l, functionName: "config" },
      { ...l, functionName: "pendingConfig" },
      { ...l, functionName: "previewDistribute" },
      { ...l, functionName: "totalTokenBurned" },
      { ...l, functionName: "totalBuybackQuote" },
      { ...l, functionName: "totalBuybackTokensBurned" },
      { ...l, functionName: "totalHoldersQuote" },
      { ...l, functionName: "totalTreasuryQuote" },
      { ...l, functionName: "buybackReserve" },
      { ...l, functionName: "creatorLockedUntil" },
      { ...l, functionName: "isCreator" },
      { ...l, functionName: "lastDistributeAt" },
      { ...l, functionName: "totalTokenToHolders" },
    ],
    query: POLL.query,
  });
  const listing = useReadContracts({
    allowFailure: false,
    contracts: [
      { address: env.launchpad, abi: iAscendLaunchpadAbi, functionName: "listingElection", args: [core.poolId ?? "0x"] },
      { address: env.launchpad, abi: iAscendLaunchpadAbi, functionName: "listingOwed", args: [core.poolId ?? "0x"] },
    ],
    query: { enabled: !!core.poolId && isSet(env.launchpad), ...POLL.query },
  });
  // routers and factories from before the upgrade path don't have these, so a failed read means none
  const up = useReadContracts({
    contracts: [
      { ...l, functionName: "upgradeTarget" },
      { ...l, functionName: "upgradeEta" },
      { address: env.factory, abi: lodestarFactoryAbi, functionName: "successor" },
      { ...l, functionName: "upgradeFactory" },
    ],
    query: POLL.query,
  });
  if (!r.data) return <LoadingCard />;
  const upTarget = up.data?.[0]?.result;
  const upEta = up.data?.[1]?.result ?? 0n;
  const successor = up.data?.[2]?.result;
  const upFactory = up.data?.[3]?.result;
  const [cfg, [pending, eta], preview, tokenBurned, buyQ, buyBurned, holdQ, treasQ, reserve, lockedUntil, isCreator, lastAt, tokenToHolders] = r.data;
  const [election, owed] = listing.data ?? [0n, 0n];
  const qd = core.quoteMeta?.decimals ?? 6;
  const qs = core.quoteMeta?.symbol;
  const ts = core.tokenMeta?.symbol;
  // a ready proposal has to be carried out within 7 days (Lodestar.EXECUTION_WINDOW), or it reverts ProposalExpired
  const cfgExpired = eta > 0n && now > Number(eta) + EXECUTION_WINDOW;
  const upExpired = upEta > 0n && now > Number(upEta) + EXECUTION_WINDOW;
  // the move only goes through to the successor it was proposed for
  const successorMoved = !!upFactory && successor !== undefined && successor.toLowerCase() !== upFactory.toLowerCase();
  const listingLive = election !== 0n && (election & ((1n << 160n) - 1n)) === BigInt(lodestar);
  const isSteward = !!address && address.toLowerCase() === core.steward?.toLowerCase();
  const lockForever = lockedUntil >= 2n ** 63n;

  return (
    <>
      <Card
        title={
          <>
            <Sym s={ts} /> Lodestar
          </>
        }
        right={
          <div className="lock-badges">
            {isCreator ? <Badge tone="green">Holds the creator role</Badge> : <Badge tone="red">Not the creator</Badge>}
            {Number(lockedUntil) > now ? <Badge tone="gold">Role locked {lockForever ? "forever" : `until ${date(lockedUntil)}`}</Badge> : <Badge tone="amber">Role not locked</Badge>}
            {upEta > 0n && <Badge tone="amber">Upgrade proposed</Badge>}
            <Badge tone="grey">No fees</Badge>
          </div>
        }
      >
        <SplitBar burn={cfg.burnBps} holders={cfg.holdersBps} treasury={cfg.treasuryBps} />
        <div className="stats stats-4">
          {cfg.tokenToHolders ? (
            <Stat label="Token fees to lockers" value={<Amt value={tokenToHolders} digits={0} symbol={ts} />} hint={tokenBurned > 0n ? `${fmt(tokenBurned, 18, 0)} burned before` : "Dripped to Exile lockers"} />
          ) : (
            <Stat label="Token fees burned" value={<Amt value={tokenBurned} digits={0} symbol={ts} />} hint={tokenToHolders > 0n ? `${fmt(tokenToHolders, 18, 0)} paid to lockers before` : "Sent to the burn address"} />
          )}
          <Stat label="Bought back and burned" value={<Amt value={buyBurned} digits={0} symbol={ts} />} hint={`${fmt(buyQ, qd)} ${qs ?? ""} spent`} />
          <Stat label="To holders (Exile)" value={<Amt value={holdQ} decimals={qd} symbol={qs} />} hint="Dripped to lockers" />
          <Stat label="To Team Treasury" value={<Amt value={treasQ} decimals={qd} symbol={qs} />} hint="Streamed through Sandfall" />
        </div>
        <div className="summary">
          <Row k="Router" v={<Addr address={lodestar} />} />
          <Row k="Steward" v={<Addr address={core.steward} />} />
          {Number(lockedUntil) > now && <Row k="Creator role" v={`Locked ${lockForever ? "forever" : `until ${date(lockedUntil)}`}*`} />}
          {/* Eleos, Kleos and Boxa take no tax in the coin, so only Ascend routers have token-side fees to route */}
          {env.launchpad && <Row k="Token-side fees" v={cfg.tokenToHolders ? <Badge tone="gold">All paid to Exile lockers</Badge> : <Badge tone="grey">All burned</Badge>} />}
          <Row k="Buyback route" v={cfg.swapper === ZERO ? <Badge tone="amber">None: buybacks wait in reserve</Badge> : <Addr address={cfg.swapper} />} />
          <Row k="Max slippage" v={`${pct(cfg.maxSlippageBps)} vs ${env.priceRef}`} />
          {listingLive && <Row k="Listing set-aside" v={<><Badge tone="green">Enrolled</Badge> {fmt(owed, qd)} of {fmt(owed + (election >> 168n), qd)} {qs} saved</>} />}
          <Row k="Last distribute" v={Number(lastAt) ? `${duration(now - Number(lastAt))} ago` : "never"} />
        </div>
        {Number(lockedUntil) > now && (
          <p className="footnote">
            * The one way out is a move to this token's router on a newer Monarchy factory, approved by Monarchy and the steward and announced here 7 days ahead.{" "}
            <a href="https://github.com/monarchy-fi/monarchy#security-model" target="_blank" rel="noreferrer">
              How upgrades work
            </a>
          </p>
        )}
      </Card>

      <Card title="Distribute" right={<span className="muted small">Anyone can call this</span>}>
        <p className="muted small">Collects and claims this token's creator fees from {env.venue}, then routes everything the router holds.</p>
        <div className="stats stats-4">
          <Stat label={cfg.tokenToHolders ? "Token fees to lockers" : "Token fees to burn"} value={<Amt value={preview[0]} digits={0} symbol={ts} />} />
          <Stat label="Buyback" value={<Amt value={preview[2] + reserve} decimals={qd} symbol={qs} />} hint={reserve > 0n ? `Includes ${fmt(reserve, qd)} waiting in reserve` : undefined} />
          <Stat label="Holders" value={<Amt value={preview[3]} decimals={qd} symbol={qs} />} />
          <Stat label="Treasury" value={<Amt value={preview[4]} decimals={qd} symbol={qs} />} />
        </div>
        <p className="muted small">Plus any fees still sitting in the pool, which distribute collects first.</p>
        <p className="small cadence">{DISTRIBUTE_NOTE}</p>
        <DistributeButton exile={env.exile} lodestar={lodestar} exilePoolId={core.exilePoolId} />
      </Card>

      {eta > 0n && (
        <Card title="Pending split change" right={<Badge tone="amber">12 hour timelock</Badge>}>
          <SplitBar burn={pending.burnBps} holders={pending.holdersBps} treasury={pending.treasuryBps} />
          <Row k="Token-side fees" v={pending.tokenToHolders ? "All paid to Exile lockers" : "All burned"} />
          <Row k="Executable" v={Number(eta) > now ? `in ${duration(Number(eta) - now)} (${date(eta)})` : cfgExpired ? `expired ${date(Number(eta) + EXECUTION_WINDOW)}` : `now, until ${date(Number(eta) + EXECUTION_WINDOW)}`} />
          <div className="lock-actions">
            <TxButton disabledReason={Number(eta) > now ? "Timelock still running" : cfgExpired ? "Expired, the steward can propose it again" : undefined} request={() => ({ ...l, functionName: "executeConfig" })}>
              Execute
            </TxButton>
            {isSteward && (
              <TxButton className="btn btn-ghost" request={() => ({ ...l, functionName: "cancelConfig" })}>
                Cancel change
              </TxButton>
            )}
          </div>
        </Card>
      )}

      {core.exilePoolId !== undefined && <PendingTiers exile={env.exile} lodestar={lodestar} poolId={core.exilePoolId} isSteward={isSteward} now={now} />}

      {upEta > 0n && upTarget && (
        <Card title="Pending upgrade" right={<Badge tone="amber">7 day notice</Badge>}>
          <p className="muted small">
            The steward has proposed moving this token's creator role, and with it every future fee, to its router on a newer Monarchy factory. Anyone can carry it out once the
            notice ends. Locked tokens and vesting streams stay where they are.
          </p>
          <Row k="New router" v={<Addr address={upTarget} />} />
          <Row k="Executable" v={Number(upEta) > now ? `in ${duration(Number(upEta) - now)} (${date(upEta)})` : upExpired ? `expired ${date(Number(upEta) + EXECUTION_WINDOW)}` : `now, until ${date(Number(upEta) + EXECUTION_WINDOW)}`} />
          <div className="lock-actions">
            <TxButton
              disabledReason={
                Number(upEta) > now ? "The 7 day notice is still running" : upExpired ? "Expired, the steward can propose it again" : successorMoved ? "Monarchy named a different newer factory since" : undefined
              }
              request={() => ({ ...l, functionName: "executeUpgrade" })}
            >
              Execute upgrade
            </TxButton>
            {isSteward && (
              <TxButton className="btn btn-ghost" request={() => ({ ...l, functionName: "cancelUpgrade" })}>
                Cancel upgrade
              </TxButton>
            )}
          </div>
        </Card>
      )}

      {isSteward && <Steward lodestar={lodestar} cfg={cfg} lockedUntil={lockedUntil} listingLive={listingLive} successor={successor} upgradePending={upEta > 0n} />}
    </>
  );
}

/** A tier change the steward proposed, shown to everyone for its 12 hours, next to the tiers it replaces. Exile carries it
 * out for anyone once the wait is over, and the steward can cancel it through the router until then. */
function PendingTiers({ exile, lodestar, poolId, isSteward, now }: { exile: Address; lodestar: Address; poolId: bigint; isSteward: boolean; now: number }) {
  const pool = useReadContract({ address: exile, abi: exileAbi, functionName: "poolInfo", args: [poolId], query: POLL.query });
  const eta = Number(pool.data?.tiersEta ?? 0n);
  if (!pool.data || eta === 0) return null;
  const expired = now > eta + EXECUTION_WINDOW;
  const before = new Map(pool.data.tiers.map((t) => [label(t.label), t]));
  return (
    <Card title="Pending tier change" right={<Badge tone="amber">12 hour timelock</Badge>}>
      <p className="muted small">
        The steward has proposed new Exile reward tiers. They apply to new locks and extensions only: locks already running keep the tier they have.
      </p>
      <div className="table-wrap tier-diff">
        <table className="table" aria-label="Proposed tiers">
          <thead>
            <tr>
              <th scope="col">Tier</th>
              <th scope="col">Lock at least</th>
              <th scope="col">Multiplier</th>
            </tr>
          </thead>
          <tbody>
            {pool.data.pendingTiers.map((t) => {
              const name = label(t.label);
              const was = before.get(name);
              const lenChanged = !was || was.minDuration !== t.minDuration;
              const multChanged = !was || was.multiplierBps !== t.multiplierBps;
              return (
                <tr key={name}>
                  <td>
                    <TierBadge name={name} />
                  </td>
                  <td>
                    {lockLen(t.minDuration)} {was && lenChanged && <span className="faint tier-was">(was {lockLen(was.minDuration)})</span>}
                  </td>
                  <td>
                    {mult(t.multiplierBps)} {was && multChanged && <span className="faint tier-was">(was {mult(was.multiplierBps)})</span>}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <Row k="Executable" v={eta > now ? `in ${duration(eta - now)} (${date(eta)})` : expired ? `expired ${date(eta + EXECUTION_WINDOW)}` : `now, until ${date(eta + EXECUTION_WINDOW)}`} />
      <div className="lock-actions">
        <TxButton
          disabledReason={eta > now ? "Timelock still running" : expired ? "Expired, the steward can propose it again" : undefined}
          request={() => ({ address: exile, abi: exileAbi, functionName: "executeTiers", args: [poolId] })}
        >
          Execute
        </TxButton>
        {isSteward && (
          <TxButton className="btn btn-ghost" request={() => ({ address: lodestar, abi: lodestarAbi, functionName: "cancelTiers" })}>
            Cancel change
          </TxButton>
        )}
      </div>
    </Card>
  );
}

/** A tier's minimum lock: whole days as days, anything shorter in hours (Exile allows tiers from one hour). */
function lockLen(seconds: number): string {
  return seconds % 86400 === 0 ? dayCount(seconds / 86400) : `${+(seconds / 3600).toFixed(2)} hour${seconds === 3600 ? "" : "s"}`;
}

type Cfg = { burnBps: number; holdersBps: number; treasuryBps: number; swapper: Address; maxSlippageBps: number; tokenToHolders: boolean };

/** Pay all the token-side fees to Exile lockers, or burn them. One choice per token, behind the timelock. */
function TokenRoute({ value, onChange, name }: { value: boolean; onChange: (v: boolean) => void; name: string }) {
  return (
    <div className="check-list">
      <label className="check">
        <input type="radio" name={name} checked={value} onChange={() => onChange(true)} />
        Pay all token-side fees to Exile lockers (dripped over 3 days, in the token itself)
      </label>
      <label className="check">
        <input type="radio" name={name} checked={!value} onChange={() => onChange(false)} />
        Burn all token-side fees
      </label>
    </div>
  );
}

function Steward({
  lodestar,
  cfg,
  lockedUntil,
  listingLive,
  successor,
  upgradePending,
}: {
  lodestar: Address;
  cfg: Cfg;
  lockedUntil: bigint;
  listingLive: boolean;
  successor?: Address;
  upgradePending: boolean;
}) {
  const l = { address: lodestar, abi: lodestarAbi } as const;
  const [split, setSplit] = useState({ burn: cfg.burnBps / 100, holders: cfg.holdersBps / 100, treasury: cfg.treasuryBps / 100 });
  const [toHolders, setToHolders] = useState(cfg.tokenToHolders);
  const [sure, setSure] = useState(false);
  const sum = split.burn + split.holders + split.treasury;
  return (
    <Card title="Steward controls" right={<span className="muted small">Only the steward sees this</span>}>
      <h4>Change the split</h4>
      <SplitInputs split={split} setSplit={setSplit} />
      <TokenRoute name="steward-token-route" value={toHolders} onChange={setToHolders} />
      <TxButton
        disabledReason={sum !== 100 ? `Splits add up to ${sum}%, not 100%` : undefined}
        request={() => ({
          ...l,
          functionName: "proposeConfig",
          args: [{ ...cfg, burnBps: Math.round(split.burn * 100), holdersBps: Math.round(split.holders * 100), treasuryBps: Math.round(split.treasury * 100), tokenToHolders: toHolders }],
        })}
      >
        Propose (takes effect after 12 hours)
      </TxButton>
      <h4>Lock the creator role</h4>
      {lockedUntil >= 2n ** 63n ? (
        <p className="muted small">Locked for good. The fee stream can only leave this router by an upgrade to a newer Lodestar, below.</p>
      ) : (
        <>
          <p className="muted small">Promise holders the fee stream stays with this router, apart from an upgrade announced 7 days ahead. Current lock: {lockedUntil > 0n ? `until ${date(lockedUntil)}` : "none"}.</p>
          <label className="check">
            <input type="checkbox" checked={sure} onChange={(e) => setSure(e.target.checked)} />
            Lock it for good. I understand I can't unlock it later.
          </label>
          <TxButton className="btn btn-sm" disabledReason={!sure ? "Tick the box first" : undefined} request={() => ({ ...l, functionName: "lockCreatorRole", args: [2n ** 64n - 1n] })}>
            Lock forever
          </TxButton>
        </>
      )}
      <h4>Upgrade to a newer Lodestar</h4>
      {!successor || successor === ZERO ? (
        <p className="muted small">Monarchy hasn't published a newer Lodestar. If it does, you can propose moving the creator role to it here, with 7 days' notice to holders.</p>
      ) : (
        <>
          <p className="muted small">
            Monarchy has published a newer Lodestar. Proposing moves the creator role to this token's router there after 7 days' notice, shown to everyone on this page. You can
            cancel until it is carried out.
          </p>
          <TxButton className="btn btn-sm" request={() => ({ ...l, functionName: "proposeUpgrade" })}>
            {upgradePending ? "Propose again (restarts the 7 days)" : "Propose upgrade"}
          </TxButton>
        </>
      )}
      {listingLive && (
        <>
          <h4>Listing set-aside</h4>
          <p className="muted small">
            This router still saves 20% of its creator quote fees toward a HyperCore listing. Leaving sends all of them through the split. What
            is already saved stays on Ascend's listing desk, where anyone can send it back to the router.
          </p>
          <TxButton className="btn btn-sm btn-ghost" request={() => ({ ...l, functionName: "closeListing" })}>
            Leave the listing set-aside
          </TxButton>
        </>
      )}
    </Card>
  );
}

// ==================================================================== activation wizard

const DEFAULT_TIERS = [
  { name: "Peasant", days: 1, mult: 0.5 },
  { name: "Knight", days: 3, mult: 1 },
  { name: "Duke", days: 7, mult: 2 },
  { name: "Monarch", days: 30, mult: 4 },
];
type TierChoice = (typeof DEFAULT_TIERS)[number];
/** The lock lengths and multipliers a tier can pick from. Every step stays inside Exile's rules: at least an hour, at most 5x. */
const TIER_DAYS = [1, 2, 3, 5, 7, 14, 21, 30, 45, 60, 90, 180, 365];
const TIER_MULTS = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5];
/** Treasury stream windows on offer, inside Sandfall's 1 to 365 day range. */
const WINDOW_DAYS = [1, 3, 7, 14, 30, 60, 90, 180, 365];
const dayCount = (n: number) => (n === 365 ? "1 year" : `${n} day${n === 1 ? "" : "s"}`);

/** The four tiers with their names fixed: each picks a lock length and a multiplier from a list. Every choice stays
 * pickable; one that breaks the order (each tier longer than the one before, its multiplier no lower) is outlined,
 * and `tierRules` says what to fix before the table can be activated. */
function TierPicker({ tiers, setTiers }: { tiers: TierChoice[]; setTiers: (t: TierChoice[]) => void }) {
  const edit = (i: number, patch: Partial<TierChoice>) => setTiers(tiers.map((t, j) => (j === i ? { ...t, ...patch } : t)));
  return (
    <div className="tier-pick" role="table" aria-label="Exile reward tiers">
      <div className="tier-pick-row tier-pick-head" role="row">
        <span role="columnheader">Tier</span>
        <span role="columnheader">Lock at least</span>
        <span role="columnheader">Multiplier</span>
      </div>
      {tiers.map((t, i) => {
        const prev = tiers[i - 1];
        const next = tiers[i + 1];
        const daysBad = (!!prev && t.days <= prev.days) || (!!next && next.days <= t.days);
        const multBad = (!!prev && t.mult < prev.mult) || (!!next && next.mult < t.mult);
        return (
          <div key={t.name} className="tier-pick-row" role="row">
            <span className="tier-pick-name" role="cell">
              <TierBadge name={t.name} />
              <span className="muted small">{tagline(t.name)}</span>
            </span>
            <span role="cell">
              <select className="input input-sm" aria-label={`${t.name} lock length`} aria-invalid={daysBad} value={t.days} onChange={(e) => edit(i, { days: Number(e.target.value) })}>
                {TIER_DAYS.map((n) => (
                  <option key={n} value={n}>
                    {dayCount(n)}
                  </option>
                ))}
              </select>
            </span>
            <span role="cell">
              <select className="input input-sm" aria-label={`${t.name} multiplier`} aria-invalid={multBad} value={t.mult} onChange={(e) => edit(i, { mult: Number(e.target.value) })}>
                {TIER_MULTS.map((m) => (
                  <option key={m} value={m}>
                    {m}x
                  </option>
                ))}
              </select>
            </span>
          </div>
        );
      })}
    </div>
  );
}

/** The settings a creator picks when activating, on any launchpad: the split, where token-side fees go, the tiers,
 * the Team Treasury stream and the creator lock. `problem` is why the deploy can't go out yet, in words. */
export function useActivationSettings() {
  const [split, setSplit] = useState({ burn: 20, holders: 50, treasury: 30 });
  const [toHolders, setToHolders] = useState(true);
  const [treasury, setTreasury] = useState("");
  const [windowDays, setWindowDays] = useState(DEFAULT_TREASURY_WINDOW_DAYS);
  const [tiers, setTiers] = useState(DEFAULT_TIERS);
  const [lockForever, setLockForever] = useState(true);
  const sum = split.burn + split.holders + split.treasury;
  // The stream's recipient can never be changed, so it is never filled in silently: the creator types it
  // or presses "Use my wallet", and the button stays off until the field holds a valid address.
  const recipient = isAddress(treasury) ? treasury : undefined;
  // the same rules Exile and Sandfall check on deploy, so the button never sends a deploy that has to revert
  const tierProblem = tierRules(tiers);
  const windowBad = !(windowDays >= 1 && windowDays <= 365);
  const problem =
    sum !== 100
      ? `Splits add up to ${sum}%`
      : tierProblem
        ? "Fix the reward tiers"
        : !recipient
          ? "Enter the Team Treasury recipient"
          : windowBad
            ? "The stream window is 1 to 365 days"
            : undefined;
  /** LodestarFactory.deploy's params for these settings. `swapper` 0 takes the factory's default. */
  const params = (token: Address, quote: Address, swapper: Address) => ({
    token,
    quote,
    cfg: { burnBps: split.burn * 100, holdersBps: split.holders * 100, treasuryBps: split.treasury * 100, swapper, maxSlippageBps: 1000, tokenToHolders: toHolders },
    treasuryRecipient: recipient ?? ZERO,
    treasuryWindow: Math.round(windowDays * 86400),
    tiers: tiers.map((t) => ({ minDuration: Math.round(t.days * 86400), multiplierBps: Math.round(t.mult * 10_000), label: stringToHex(t.name, { size: 32 }) })),
    // no HyperCore listing savings: the creator's whole fee share reaches the router
    enrolListing: false,
    listingCap: 0n,
    // locked for good: the largest unlock time the router accepts
    creatorLockUntil: lockForever ? 2n ** 64n - 1n : 0n,
  });
  return { split, setSplit, toHolders, setToHolders, treasury, setTreasury, windowDays, setWindowDays, tiers, setTiers, lockForever, setLockForever, tierProblem, problem, params };
}

export type ActivationSettingsState = ReturnType<typeof useActivationSettings>;

/** The settings form. `tokenRoute` offers the choice for token-side fees, which only Ascend pools have. */
export function ActivationSettings({ s, tokenRoute = true }: { s: ActivationSettingsState; tokenRoute?: boolean }) {
  const { address } = useConnection();
  const badTreasury = s.treasury !== "" && !isAddress(s.treasury);
  return (
    <div className="form-block">
      <h5>{tokenRoute ? "Split of the quote-side fees" : "Split of the creator fees"}</h5>
      <SplitInputs split={s.split} setSplit={s.setSplit} />
      {tokenRoute && (
        <>
          <h5>Token-side fees</h5>
          <TokenRoute name="activate-token-route" value={s.toHolders} onChange={s.setToHolders} />
        </>
      )}
      <h5>Exile reward tiers</h5>
      <p className="muted small">
        The four tier names are the same on every Monarchy token, so holders always know what a Duke lock means. Pick how long each tier's
        lock has to be and how big a share it earns.
      </p>
      <TierPicker tiers={s.tiers} setTiers={s.setTiers} />
      {s.tierProblem && <p className="warn small">{s.tierProblem}</p>}
      <div className="form">
        <label>
          Team Treasury recipient
          <div className="input-row">
            <input className="input mono-input" placeholder="0x…" value={s.treasury} onChange={(e) => s.setTreasury(e.target.value.trim())} spellCheck={false} autoComplete="off" />
            <button type="button" className="btn btn-ghost btn-sm" disabled={!address} onClick={() => address && s.setTreasury(address)}>
              Use my wallet
            </button>
          </div>
        </label>
      </div>
      <p className={badTreasury ? "warn small field-help" : "muted small field-help"}>
        {badTreasury
          ? "That isn't a valid address yet."
          : "This address receives the Team Treasury stream. It can never be changed, not even by the steward, so check it twice."}
      </p>
      <label className="field">
        <span className="field-label">Treasury stream window</span>
        <select className="input" style={{ maxWidth: 220 }} value={s.windowDays} onChange={(e) => s.setWindowDays(Number(e.target.value))}>
          {WINDOW_DAYS.map((n) => (
            <option key={n} value={n}>
              {dayCount(n)}
            </option>
          ))}
        </select>
      </label>
      <p className="muted small field-help">
        Each distribute adds the Team Treasury share to a Sandfall stream, which pays it out to the recipient bit by bit over this window
        instead of all at once, so holders can watch it flow. It can't be changed later.
      </p>
      <h5>Creator role</h5>
      <label className="check">
        <input type="checkbox" checked={s.lockForever} onChange={(e) => s.setLockForever(e.target.checked)} />
        Lock the creator role to this router forever
      </label>
      <p className="muted small">
        {s.lockForever
          ? "Holders can see the fee stream can't be moved away from this router, and you can't unlock it later. One exception: a move to this token's router on a newer Monarchy factory, which Monarchy and you both have to approve, announced to holders 7 days ahead."
          : "Without a lock the steward could hand the creator role away later. You can still lock it forever from the steward controls."}
      </p>
    </div>
  );
}

function Activate({ d, token, quote, predicted, poolId }: { d: Deployment; token: Address; quote: Address; predicted: Address; poolId: `0x${string}` }) {
  const { address } = useConnection();
  const lp = { address: d.launchpad, abi: iAscendLaunchpadAbi } as const;
  const r = useReadContracts({
    allowFailure: false,
    contracts: [
      { ...lp, functionName: "poolCreator", args: [poolId] },
      { ...lp, functionName: "pendingCreator", args: [poolId] },
      { ...lp, functionName: "creatorOwedQuote", args: [poolId] },
      { ...lp, functionName: "creatorOwedToken", args: [poolId] },
    ],
    query: POLL.query,
  });
  const s = useActivationSettings();

  if (!r.data) return <LoadingCard />;
  const [creator, pendingCreator, owedQ, owedT] = r.data;
  if (creator === ZERO)
    return (
      <Card>
        <Empty title="No Ascend pool found">This token has no Ascend pool with this quote asset. Check the address and try again.</Empty>
      </Card>
    );
  const you = !!address && creator.toLowerCase() === address.toLowerCase();
  const handedOver = pendingCreator.toLowerCase() === predicted.toLowerCase();

  return (
    <Card title="Activate Lodestar" right={<Badge tone="grey">2 transactions</Badge>}>
      <div className="summary">
        <Row k="Ascend pool" v={<span className="mono">{poolId.slice(0, 10)}…</span>} />
        <Row k="Current creator" v={<><Addr address={creator} /> {you && <Badge tone="green">you</Badge>}</>} />
        <Row k="Router address" v={<Addr address={predicted} />} />
      </div>
      {(owedQ > 0n || owedT > 0n) && (
        <p className="warn small">
          This pool has unclaimed creator fees. They move to the router when it takes over. Claim them first on Ascend if you want them yourself.
        </p>
      )}
      <ol className="steps">
        <li className={handedOver ? "done" : ""}>
          <h4>1. Hand the creator role to the router</h4>
          <p className="muted small">On Ascend's launchpad. You keep your dev-buy tokens; only the creator fee stream moves.</p>
          <TxButton
            disabledReason={!you ? "Only the current creator can do this" : handedOver ? "Done" : undefined}
            request={() => ({ ...lp, functionName: "transferCreator", args: [poolId, predicted] })}
          >
            Hand over creator role
          </TxButton>
        </li>
        <li>
          <h4>2. Activate</h4>
          <p className="muted small">Creates the router, its Exile reward pool and its Sandfall treasury stream, and accepts the role, in one transaction.</p>
          <ActivationSettings s={s} />
          <TxButton
            disabledReason={!you ? "Only the current creator can activate" : !handedOver ? "Do step 1 first" : s.problem}
            request={() => ({
              address: d.factory,
              abi: lodestarFactoryAbi,
              functionName: "deploy",
              gas: 6_000_000n,
              // the buyback route is the AscendSwapper this deployment recorded, never the factory's default of the day
              args: [s.params(token, quote, d.swapper)],
            })}
          >
            Activate Lodestar
          </TxButton>
        </li>
      </ol>
    </Card>
  );
}

// ==================================================================== shared

/** What Exile's _validateTiers would refuse, in words, or undefined when the tiers are fine. Checked on the
 * values the deploy sends: seconds and basis points, rounded the same way. */
function tierRules(tiers: { name: string; days: number; mult: number }[]): string | undefined {
  if (tiers.length === 0 || tiers.length > 8) return "Use 1 to 8 tiers.";
  const sec = (t: { days: number }) => Math.round(t.days * 86400);
  const bps = (t: { mult: number }) => Math.round(t.mult * 10_000);
  for (let i = 0; i < tiers.length; i++) {
    const t = tiers[i];
    if (!t.name.trim()) return `Tier ${i + 1} needs a name.`;
    if (new TextEncoder().encode(t.name).length > 32) return `"${t.name}" is too long: names fit 32 bytes.`;
    if (!(sec(t) >= 3600)) return `${t.name} must be at least 1 hour long.`;
    if (!(bps(t) >= 1 && bps(t) <= 50_000)) return `${t.name}'s multiplier must be above 0x and at most 5x.`;
    if (i > 0 && !(sec(t) > sec(tiers[i - 1]))) return `${t.name}'s lock must be longer than ${tiers[i - 1].name}'s (${dayCount(tiers[i - 1].days)}).`;
    if (i > 0 && bps(t) < bps(tiers[i - 1])) return `${t.name}'s multiplier can't be lower than ${tiers[i - 1].name}'s (${tiers[i - 1].mult}x).`;
  }
  return undefined;
}

export function LoadingCard() {
  return (
    <Card title={<Skel w="9em" h="1.1em" />}>
      <Skel block h="12px" w="100%" style={{ borderRadius: 999, marginBottom: 16 }} />
      <div className="stats stats-4">
        {[0, 1, 2, 3].map((i) => (
          <Skel key={i} block h="84px" w="auto" />
        ))}
      </div>
    </Card>
  );
}

function SplitBar({ burn, holders, treasury }: { burn: number; holders: number; treasury: number }) {
  return (
    <div className="split">
      <div className="split-bar">
        <div className="seg seg-burn" style={{ width: `${burn / 100}%` }} />
        <div className="seg seg-holders" style={{ width: `${holders / 100}%` }} />
        <div className="seg seg-treasury" style={{ width: `${treasury / 100}%` }} />
      </div>
      <div className="split-legend">
        <span><i className="dot seg-burn" /> Buyback and burn {pct(burn)}</span>
        <span><i className="dot seg-holders" /> Holder rewards {pct(holders)}</span>
        <span><i className="dot seg-treasury" /> Team Treasury {pct(treasury)}</span>
      </div>
    </div>
  );
}

type Split = { burn: number; holders: number; treasury: number };

/** One bar, two handles: left of the first is buyback and burn, between them holder rewards, right of the
 * second the Team Treasury. It always adds up to 100%, and a handle pushes the other one along. */
function SplitInputs({ split, setSplit }: { split: Split; setSplit: (s: Split) => void }) {
  const a = split.burn;
  const b = split.burn + split.holders;
  const set = (na: number, nb: number) => setSplit({ burn: na, holders: nb - na, treasury: 100 - nb });
  return (
    <div className="slider3">
      <Slider
        className="slider3-track"
        max={100}
        values={[a, b]}
        onChange={(i, v) => (i === 0 ? set(v, Math.max(b, v)) : set(Math.min(a, v), v))}
        labels={["Buyback and burn share", "Buyback and holder rewards share, the rest goes to the Team Treasury"]}
        valueTexts={[`${a}%`, `${b}%`]}
      >
        <div className="slider3-bar" aria-hidden="true">
          <div className="seg seg-burn" style={{ width: `${a}%` }} />
          <div className="seg seg-holders" style={{ width: `${b - a}%` }} />
          <div className="seg seg-treasury" style={{ width: `${100 - b}%` }} />
        </div>
      </Slider>
      <div className="slider3-legend">
        <div>
          <span className="lg-k"><i className="dot seg-burn" />Buyback and burn</span>
          <b>{split.burn}%</b>
        </div>
        <div>
          <span className="lg-k"><i className="dot seg-holders" />Holder rewards</span>
          <b>{split.holders}%</b>
        </div>
        <div>
          <span className="lg-k"><i className="dot seg-treasury" />Team Treasury</span>
          <b>{split.treasury}%</b>
        </div>
      </div>
    </div>
  );
}
