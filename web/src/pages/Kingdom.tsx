import type { ReactNode } from "react";
import { Link } from "react-router-dom";
import { useReadContracts } from "wagmi";
import { exileAbi, lodestarAbi, mockERC20Abi } from "../abi";
import { TokenFeeFlow } from "../components/FeeFlow";
import { GateGlyph, HourglassGlyph, PageMark, StarGlyph } from "../components/NavGlyphs";
import { NoDeployment } from "../components/States";
import { tagline, TierBadge } from "../components/Tiers";
import { Addr, Amt, Badge, Card, Skel, Stat } from "../components/Ui";
import { isMonarchy, MONARCHY_SETTINGS } from "../lib/constants";
import { useDeployment } from "../lib/deployments";
import { fmt, label, mult } from "../lib/format";
import { POLL, usePageTitle } from "../lib/hooks";
import { dayLabel, useDripDays, useLockedTotal, useLodestarCore } from "../lib/monarchy";
import { days } from "./Home";

// Lodestar burns to this address; Ascend tokens reject 0x…dEaD
const DEAD = "0xdEAD000000000000000042069420694206942069";

/** The overview the landing page leaves out: the promises, the three features (locking first), the court, where fees go and live numbers. */
export function KingdomPage() {
  usePageTitle("Kingdom");
  const d = useDeployment();
  const core = useLodestarCore();
  const qd = core.quoteMeta?.decimals ?? 6;
  const qs = core.quoteMeta?.symbol;
  const ts = core.tokenMeta?.symbol;
  const td = core.tokenMeta?.decimals ?? 18;
  const l = { address: core.lodestar, abi: lodestarAbi } as const;
  const stats = useReadContracts({
    allowFailure: false,
    contracts: [
      { ...l, functionName: "totalTokenBurned" },
      { ...l, functionName: "totalBuybackTokensBurned" },
      { ...l, functionName: "totalHoldersQuote" },
      { ...l, functionName: "totalTreasuryQuote" },
      { ...l, functionName: "totalBuybackQuote" },
      { address: core.token, abi: mockERC20Abi, functionName: "balanceOf", args: [DEAD] },
      { address: core.token, abi: mockERC20Abi, functionName: "totalSupply" },
      { address: d?.exile, abi: exileAbi, functionName: "poolInfo", args: [core.exilePoolId ?? 0n] },
      { ...l, functionName: "creatorLockedUntil" },
      { ...l, functionName: "totalTokenToHolders" },
      { ...l, functionName: "config" },
    ],
    query: { enabled: !!core.lodestar && !!core.token && core.exilePoolId !== undefined, ...POLL.query },
  });
  const [feeBurned, buybackBurned, holders, treasury, buybackQuote, dead, supply, pool, lockedUntil, tokenToHolders, cfg] = stats.data ?? [];
  const now = BigInt(Math.floor(Date.now() / 1000));
  const dripPerDay = pool ? (pool.periodFinish > now ? (pool.rewardRate * 86400n) / 10n ** 18n : 0n) : undefined;
  const drip = useDripDays();
  const locked = useLockedTotal(core.token);
  // until MONARCHY is the token this deployment's Lodestar routes for, the sample token's numbers fill the card
  const live = !!d && !!core.lodestar;
  const standIn = !!ts && !!core.token && !isMonarchy(core.token);
  // the court shows the tiers MONARCHY will launch with until its own router is live
  const tiers = isMonarchy(core.token) && pool ? pool.tiers.map((t) => ({ ...t, name: label(t.label) })) : MONARCHY_SETTINGS.tiers;
  const topBps = Math.max(...tiers.map((t) => t.multiplierBps));
  const burnShare = dead !== undefined && supply ? `${fmt((dead * 10_000n) / supply, 2, 2)}% of supply` : undefined;

  return (
    <div className="page">
      <div className="page-head">
        <h1>
          <PageMark page="kingdom" />
          Kingdom
        </h1>
        <p>
          Monarchy is free tooling for every token on Elysium. Lock any token, LP or NFT in Exile until a date you choose, and
          stream any token or HYPE through Sandfall on a schedule anyone can check, with no launchpad needed. When a coin's
          creator enrolls it in Lodestar, its creator fees go to the holders who lock it, more the longer they lock. That works
          for coins on Ascend, Volta, Montra, ElysPump, Boxa and Kleos. Every lock, stream and payout shows in the Garden, and
          Monarchy keeps none of it.
        </p>
      </div>

      <ul className="seals" aria-label="Guarantees">
        <li className="seal seal-main">
          <span className="seal-big">0%</span>
          <span className="seal-text">
            <b>No fees.</b> Monarchy takes nothing, on any feature.
          </span>
        </li>
        <li className="seal">
          <span className="seal-text">
            <b>Any token.</b> Lock or stream any token on Elysium. No launchpad, router or permission needed.
          </span>
        </li>
        <li className="seal">
          <span className="seal-text">
            <b>Lock to earn.</b> On a coin enrolled in Lodestar, longer locks earn a bigger share of every fee.
          </span>
        </li>
        <li className="seal">
          <span className="seal-text">
            <b>No sweep.</b> Funds only go where the contracts say. Changes wait 12 hours in public, and a router moves only after 7 days' notice.
          </span>
        </li>
      </ul>

      <div className="grid3">
        <Feature
          to="/exile"
          title="Exile"
          kicker="Lock to earn"
          icon={<GateGlyph />}
          cls="nl-exile"
          ours={
            live && (
              <>
                <span>Holders of MONARCHY can lock it in Exile for rewards: the holder share of every fee, bigger for longer locks.</span>
                <Link className="feature-ours-go" to={core.token ? `/garden?token=${core.token}` : "/garden"}>
                  See its locks in the Garden <span aria-hidden="true">→</span>
                </Link>
              </>
            )
          }
        >
          Lock any token, v2 LP or NFT until a date you choose. Locks can be extended, never shortened or cancelled. On a coin
          enrolled in Lodestar the lock also earns: holding alone earns nothing, and longer locks earn a bigger share of its fees,
          paid as a {dayLabel(drip)} drip.
        </Feature>
        <Feature
          to="/sandfall"
          title="Sandfall"
          kicker="Vesting in the open"
          icon={<HourglassGlyph />}
          cls="nl-sandfall"
          ours={
            live && (
              <span>
                Its Team Treasury share streams out here in the open, never in one lump: <Amt value={treasury} decimals={qd} symbol={qs} /> so far.
              </span>
            )
          }
        >
          Stream any token or HYPE to anyone on a schedule anyone can read: linear, after a cliff, or in daily, weekly or monthly
          steps. For team and contributor vesting, investor unlocks or a treasury. Every stream shows whether its creator can
          cancel it.
        </Feature>
        <Feature
          to="/lodestar"
          title="Lodestar"
          kicker="Fees to lockers"
          icon={<StarGlyph />}
          cls="nl-lodestar"
          ours={
            live && (
              <>
                <span>
                  Holds MONARCHY's creator role at <Addr address={core.lodestar} />.
                </span>
                {lockedUntil === undefined ? <Skel w="10em" /> : lockedUntil >= 2n ** 63n ? <Badge tone="gold">Locked to it forever</Badge> : <Badge tone="amber">Not locked yet</Badge>}
              </>
            )
          }
        >
          Takes your coin's creator role and pays its fees to the holders who lock it. You keep your dev buy, and you can send a
          share to buyback and burn or to a Team Treasury that streams through Sandfall.
        </Feature>
      </div>

      <Card title="The court" right={<span className="muted small">Lock longer, earn more</span>}>
        <div className="tiers">
          {tiers.map((t) => (
            <div key={t.name} className={`tier tier-${t.name.toLowerCase()}`}>
              <TierBadge name={t.name} />
              <div className="tier-bars" aria-hidden="true">
                {tierBars(t.multiplierBps, topBps)}
              </div>
              <div className="tier-mult">{mult(t.multiplierBps)}</div>
              <div className="tier-len">{days(t.minDuration)} lock</div>
              <div className="tier-tag">{tagline(t.name) ?? ""}</div>
            </div>
          ))}
        </div>
        <p className="muted small">No lock, no rewards. Rewards stop the moment a lock ends.</p>
      </Card>

      <TokenFeeFlow />

      {!d && <NoDeployment inline />}

      {d && core.lodestar && (
        <Card
          className="kingdom"
          title="The Monarchy"
          right={
            <span className="live">
              <i className="live-dot" /> Live from Lodestar
            </span>
          }
        >
          <p className="kingdom-lead">
            Most coins ask holders to trust the team with the fees. <b>MONARCHY runs on its own features instead</b>, the same
            contracts Monarchy offers every coin, with the same zero fees and the same timelocks. Nothing here is special to it,
            and each feature above shows how MONARCHY uses it.
            {standIn && <span className="faint"> Until MONARCHY launches, the sample token {ts} stands in.</span>}
          </p>
          <div className="stats stats-3">
            <Stat className="stat-feature" label="Paid to lockers" value={<Amt value={holders} decimals={qd} symbol={qs} />} hint={dripPerDay === undefined ? <Skel w="8em" /> : `${fmt(dripPerDay, qd)} ${qs ?? ""} a day dripping now`} />
            <Stat
              label={ts ? `Locked ${ts}` : "Locked"}
              value={<Amt value={locked?.amount} decimals={td} symbol={ts} compact />}
              hint={locked ? `${locked.locks} ${locked.locks === 1 ? "lock" : "locks"} by ${locked.lockers} ${locked.lockers === 1 ? "holder" : "holders"}` : <Skel w="9em" />}
            />
            <Stat label="Team Treasury" value={<Amt value={treasury} decimals={qd} symbol={qs} />} hint="Streamed through Sandfall" />
            {cfg?.tokenToHolders ? (
              <Stat label="Token fees to lockers" value={<Amt value={tokenToHolders} decimals={td} symbol={ts} compact />} hint="Dripped to Exile lockers" />
            ) : (
              <Stat label="Burned from token fees" value={<Amt value={feeBurned} decimals={td} symbol={ts} compact />} hint="Sent straight to the burn address" />
            )}
            <Stat label="Bought back and burned" value={<Amt value={buybackBurned} decimals={td} symbol={ts} compact />} hint={buybackQuote === undefined ? <Skel w="7em" /> : `${fmt(buybackQuote, qd)} ${qs ?? ""} spent`} />
            <Stat label="Burned in total" value={<Amt value={dead} decimals={td} symbol={ts} compact />} hint={burnShare ?? <Skel w="7em" />} />
          </div>
        </Card>
      )}
    </div>
  );
}

/** A tier's multiplier as eight signal bars, scaled so the top tier fills them all. */
function tierBars(bps: number, topBps: number): string {
  const n = Math.max(1, Math.min(8, Math.round((bps * 8) / topBps)));
  return "▮".repeat(n) + "▯".repeat(8 - n);
}

/** One feature, and under it how MONARCHY itself uses it. The "Open" link stretches over the whole card, and the links
 * inside the MONARCHY part sit above it. */
function Feature({ to, title, kicker, icon, cls, ours, children }: { to: string; title: string; kicker: string; icon: ReactNode; cls: string; ours?: ReactNode; children: ReactNode }) {
  return (
    <div className={`card feature ${cls}`}>
      <div className="feature-top">
        <span className="feature-icon" aria-hidden="true">
          {icon}
        </span>
        <span className="kicker">{kicker}</span>
      </div>
      <h3>{title}</h3>
      <p>{children}</p>
      {ours && (
        <div className="feature-ours">
          <span className="feature-ours-k">How MONARCHY uses it</span>
          {ours}
        </div>
      )}
      <Link to={to} className="feature-go">
        Open {title} <span aria-hidden="true">→</span>
      </Link>
    </div>
  );
}
