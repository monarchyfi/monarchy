import { useLayoutEffect, useRef, useState } from "react";
import { useReadContract } from "wagmi";
import { lodestarAbi } from "../abi";
import { isMonarchy, MONARCHY_SETTINGS } from "../lib/constants";
import { pct } from "../lib/format";
import { POLL } from "../lib/hooks";
import { useDripDays, useLodestarCore } from "../lib/monarchy";

/** The fee flow for the deployment's token, with its live split and token-side route. */
export function TokenFeeFlow() {
  const core = useLodestarCore();
  const drip = useDripDays();
  const cfg = useReadContract({ address: core.lodestar, abi: lodestarAbi, functionName: "config", query: { enabled: !!core.lodestar && isMonarchy(core.token), ...POLL.query } });
  // a sample token stands in for MNRCHY on testnet, so show the settings MNRCHY will launch with until it is live
  const c = isMonarchy(core.token) ? cfg.data : MONARCHY_SETTINGS;
  return <FeeFlow drip={drip} burn={c?.burnBps} holders={c?.holdersBps} treasury={c?.treasuryBps} tokenToHolders={c?.tokenToHolders} />;
}

type Dest = { key: string; mark: string; title: string; tag: string; body: string };

/** A coin's creator fees, through Lodestar, out to the four places they can go: token-side fees on one route, quote-side fees split three ways, lockers first. */
export function FeeFlow({ drip, burn, holders, treasury, tokenToHolders }: { drip: number; burn?: number; holders?: number; treasury?: number; tokenToHolders?: boolean }) {
  // the live numbers are MNRCHY's own split; every token on Lodestar picks its own
  const share = (bps?: number) => (bps === undefined ? "Quote share" : `${pct(bps)} for MNRCHY`);
  const tokenSide: Dest = {
    key: "fire",
    mark: "[+|x]",
    title: "Sent to lockers / burned",
    tag: tokenToHolders === undefined ? "All token-side fees" : `All token-side fees, ${tokenToHolders ? "sent to lockers" : "burned"} for MNRCHY`,
    body: `Sent to Exile lockers by default, paid in the token itself over ${drip} days. The creator can burn all of it instead.`,
  };
  const quoteSide: Dest[] = [
    { key: "hold", mark: "[+]", title: "Exile lockers", tag: share(holders), body: `Paid to locked holders by tier, over ${drip} days.` },
    { key: "burn", mark: "[∞]", title: "Buyback and burn", tag: share(burn), body: "Buys the token through its own pool, then burns it." },
    { key: "treas", mark: "[~]", title: "Sandfall treasury", tag: share(treasury), body: "Streamed to the Team Treasury in the open." },
  ];
  const { branch, list, h, ys } = useBranchTargets();
  const mid = h / 2;
  const fork = 30;
  const quoteYs = ys.slice(1);
  const quoteMid = quoteYs.length ? (quoteYs[0] + quoteYs[quoteYs.length - 1]) / 2 : mid;
  return (
    <section className="flow" aria-labelledby="flow-title">
      <div className="flow-head">
        <h2 id="flow-title">How lockers get paid</h2>
        <p className="muted">
          A Lodestar takes a coin's creator fees and pays them out on a public path: to the holders who lock, and any share the creator picks to buyback
          and burn or a Team Treasury. Nothing stops at Monarchy. The percentages below are MNRCHY's own, and each coin picks its own when it activates.
        </p>
      </div>
      <div className="flow-body">
        <div className="flow-node flow-src ascii-box">
          <div className="flow-kicker">Source</div>
          <div className="flow-title">Creator fees</div>
          <p>The creator's share of every swap fee on the coin's launchpad, in the token and the quote asset.</p>
        </div>
        <FlowArrow />
        <div className="flow-node flow-hub ascii-box">
          <span className="flow-glyph" aria-hidden="true">*</span>
          <div className="flow-title">Lodestar</div>
          <p>It takes 0% of the fees.</p>
        </div>
        <div ref={branch} className="flow-branch" aria-hidden="true">
          <svg viewBox={`0 0 64 ${h}`} preserveAspectRatio="none">
            {ys.length === 4 && (
              <>
                <path className="branch branch-fire" d={`M0 ${mid} C 40 ${mid}, 24 ${ys[0]}, 64 ${ys[0]}`} />
                <path className="branch branch-quote" d={`M0 ${mid} C 18 ${mid}, 12 ${quoteMid}, ${fork} ${quoteMid}`} />
                {quoteYs.map((y, i) => (
                  <path key={i} className={`branch branch-${quoteSide[i].key}`} d={`M${fork} ${quoteMid} C ${fork + 20} ${quoteMid}, ${fork + 14} ${y}, 64 ${y}`} />
                ))}
              </>
            )}
          </svg>
        </div>
        <FlowArrow className="flow-arrow-split" />
        <div ref={list} className="flow-dests">
          <div className="flow-group">
            <div className="flow-group-k">Token side</div>
            <ul>
              <DestItem d={tokenSide} />
            </ul>
          </div>
          <div className="flow-group">
            <div className="flow-group-k">Quote side</div>
            <ul>
              {quoteSide.map((d) => (
                <DestItem key={d.key} d={d} />
              ))}
            </ul>
          </div>
        </div>
      </div>
    </section>
  );
}

function DestItem({ d }: { d: Dest }) {
  return (
    <li className={`flow-dest dest-${d.key}`}>
      <span className="dest-mark" aria-hidden="true">
        {d.mark}
      </span>
      <div>
        <div className="flow-title">{d.title}</div>
        <div className="dest-tag">{d.tag}</div>
        <p>{d.body}</p>
      </div>
    </li>
  );
}

/** Where each destination's middle sits, measured against the branch drawing, so the lines land on the boxes. */
function useBranchTargets() {
  const branch = useRef<HTMLDivElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const [m, setM] = useState<{ h: number; ys: number[] }>({ h: 300, ys: [] });
  useLayoutEffect(() => {
    const s = branch.current;
    const l = list.current;
    if (!s || !l) return;
    const measure = () => {
      const top = s.getBoundingClientRect().top;
      const h = Math.max(1, s.getBoundingClientRect().height);
      const ys = [...l.querySelectorAll<HTMLElement>(".flow-dest")].map((el) => {
        const r = el.getBoundingClientRect();
        return Math.round((r.top + r.height / 2 - top) * 10) / 10;
      });
      setM((o) => (o.h === h && o.ys.join() === ys.join() ? o : { h, ys }));
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(l);
    ro.observe(s);
    return () => ro.disconnect();
  }, []);
  return { branch, list, ...m };
}

function FlowArrow({ className }: { className?: string }) {
  return (
    <div className={`flow-arrow ${className ?? ""}`} aria-hidden="true">
      <span>──▶</span>
    </div>
  );
}
