import { useState } from "react";
import { useSearchParams } from "react-router-dom";
import { useBytecode, useConnection, useReadContract, useReadContracts } from "wagmi";
import { isAddress, type Address, type Hex } from "viem";
import {
  ascendV5FeeSourceAbi,
  exileAbi,
  iAscendV5EscrowAbi,
  iAscendV5LaunchpadAbi,
  iAscendV5SeatAbi,
  iBoxaHookAbi,
  iEleosHookAbi,
  iKleosHookAbi,
  lodestarAbi,
  lodestarFactoryAbi,
  v4FeeSourceAbi,
} from "../abi";
import { PageMark } from "../components/NavGlyphs";
import { TxButton } from "../components/Tx";
import { Addr, Amt, Badge, Card, Empty, Row } from "../components/Ui";
import { isSet, ZERO } from "../lib/deployments";
import { date, duration, fmt, pct } from "../lib/format";
import { POLL, useNow, usePageTitle } from "../lib/hooks";
import {
  ascendPoolId,
  padNames,
  padsOf,
  PADS,
  routerAddress,
  swapperFor,
  type LaunchpadsDeployment,
  type PadDeployment,
  type PadInfo,
  type PadKey,
} from "../lib/launchpads";
import { useTokenMeta } from "../lib/monarchy";
import { Switch } from "./Exile";
import { ActivationSettings, LoadingCard, Router, useActivationSettings, type RouterEnv } from "./Lodestar";

/** IFeeSource.Handover.OneStep */
const ONE_STEP = 1;

type Choice = "auto" | PadKey;

/** The Lodestar page on a chain with Eleos, Kleos, Boxa and Ascend v5: paste a coin, the page finds its launchpad (or
 * the creator picks it), then shows its router or the activation steps that launchpad needs. */
export function PadsLodestar({ pads }: { pads: LaunchpadsDeployment }) {
  usePageTitle("Lodestar");
  const [params] = useSearchParams();
  const [input, setInput] = useState(() => params.get("token") ?? "");
  const fromUrl = params.get("launchpad") as PadKey | null;
  const [choice, setChoice] = useState<Choice>(() => (fromUrl && fromUrl in PADS ? fromUrl : "auto"));
  const list = padsOf(pads);
  const names = padNames(list);
  const token = isAddress(input) ? input : undefined;
  const badInput = input !== "" && !token;
  return (
    <div className="page">
      <header className="page-head">
        <h1>
          <PageMark page="lodestar" />
          Lodestar
        </h1>
        <p className="muted">
          Your coin's creator fees, paid to the holders who lock it. A Lodestar holds your coin's creator role on {names} and routes your
          creator fees the way you set it: to Exile lockers, into buyback and burn, or to a Team Treasury streamed through Sandfall. Locked
          coins keep earning the coin's own holder dividends too. Later changes wait 12 hours, in public. No fees.
        </p>
      </header>
      <Card title="Coin">
        <label className="field">
          <span className="field-label">Coin address</span>
          <input className="input mono-input" placeholder="0x…" value={input} onChange={(e) => setInput(e.target.value.trim())} spellCheck={false} autoComplete="off" />
        </label>
        <p className="muted small field-help">
          {badInput ? "That isn't a valid address yet." : `Paste a coin launched on ${names} to view or activate its Lodestar.`}
        </p>
        <div className="field">
          <span className="field-label">Launchpad</span>
          <Switch
            options={[{ key: "auto", label: "Find it" }, ...list.map(({ info }) => ({ key: info.key, label: info.name }))]}
            value={choice}
            onChange={(k) => setChoice(k as Choice)}
          />
        </div>
        <p className="muted small field-help">
          {choice === "auto"
            ? "The page asks each launchpad whether it knows the coin. Pick one yourself if you'd rather."
            : `Looking for the coin on ${PADS[choice].name} only.`}
        </p>
      </Card>
      {token && <PadToken key={token} pads={pads} token={token} choice={choice} />}
    </div>
  );
}

type Found = {
  info: PadInfo;
  pad: PadDeployment;
  /** the router this launchpad's factory made for the coin, if any */
  router?: Address;
  predicted?: Address;
  poolId?: Hex;
  /** the pair's quote: native HYPE (ZERO) on Eleos, Kleos and Boxa, the ERC-20 the pool was found with on Ascend */
  quote: Address;
  /** the coin trades through a hook this launchpad's adapter knows, whatever it is quoted in */
  onHook: boolean;
  /** the network's answer for the router address disagrees with the one worked out from the deployments file */
  mismatch: boolean;
};

const same = (a?: string, b?: string) => !!a && !!b && a.toLowerCase() === b.toLowerCase();

type Probe = { i: number; kind: "of" | "predict" | "hook"; quote: Address };

/** The reads that place a coin: per launchpad its router (`lodestarOf`) and `predict`, which only the coin's own
 * launchpad answers without reverting. Eleos, Kleos and Boxa are asked for the HYPE pair plus `hookOf`, which a coin
 * on a known hook answers even when it is quoted in something else; Ascend is asked for each of its quote assets. */
function probesOf(list: { info: PadInfo }[]): Probe[] {
  return list.flatMap(({ info }, i): Probe[] =>
    info.quotes
      ? [{ i, kind: "of", quote: ZERO }, ...info.quotes.map((q) => ({ i, kind: "predict" as const, quote: q.address }))]
      : [
          { i, kind: "of", quote: ZERO },
          { i, kind: "predict", quote: ZERO },
          { i, kind: "hook", quote: ZERO },
        ],
  );
}

function PadToken({ pads, token, choice }: { pads: LaunchpadsDeployment; token: Address; choice: Choice }) {
  const list = padsOf(pads);
  const probes = probesOf(list);
  const r = useReadContracts({
    allowFailure: true,
    contracts: probes.map(({ i, kind, quote }) => {
      const { pad } = list[i];
      if (kind === "of") return { address: pad.factory, abi: lodestarFactoryAbi, functionName: "lodestarOf", args: [token] } as const;
      if (kind === "predict") return { address: pad.factory, abi: lodestarFactoryAbi, functionName: "predict", args: [token, quote] } as const;
      return { address: pad.source, abi: v4FeeSourceAbi, functionName: "hookOf", args: [token] } as const;
    }),
    query: POLL.query,
  });
  if (!r.data) return <LoadingCard />;
  const results = r.data;
  const found: Found[] = list.map(({ info, pad }, i) => {
    const mine = probes.map((p, j) => ({ p, res: results[j] })).filter(({ p }) => p.i === i);
    const of = mine.find(({ p }) => p.kind === "of")?.res;
    const pr = mine.find(({ p, res }) => p.kind === "predict" && res.status === "success");
    const hk = mine.find(({ p }) => p.kind === "hook")?.res;
    const router = of?.status === "success" && isSet(of.result as Address) ? (of.result as Address) : undefined;
    const p = pr?.res.status === "success" ? (pr.res.result as readonly [Address, Hex]) : undefined;
    // the address the role goes to is never the RPC's word: derive it from the deployments file and the pool id, and
    // flag any answer (predict's or lodestarOf's) that doesn't match it
    // on Ascend the pool id itself is worked out here too (the pair, the fee flag and the launchpad), so nothing about
    // where the role goes rests on the RPC
    const localId = p && info.quotes && pr ? ascendPoolId(token, pr.p.quote) : undefined;
    const poolId = localId ?? p?.[1];
    const expected = poolId ? routerAddress(pads.lodestarImpl, pad.factory, poolId) : undefined;
    const mismatch =
      !!expected && (!same(p?.[0], expected) || (!!router && !same(router, expected)) || (!!localId && localId.toLowerCase() !== p?.[1].toLowerCase()));
    return { info, pad, router, predicted: expected, poolId, quote: pr?.p.quote ?? ZERO, onHook: hk?.status === "success", mismatch };
  });
  // the RPC failing every read looks like "on no launchpad"; say so instead
  if (results.every((x) => x.status === "failure" && !/revert/i.test(String(x.error))))
    return (
      <Card>
        <Empty title="Can't reach the network">The launchpads didn't answer. Try again in a moment.</Empty>
      </Card>
    );

  const hit = found.find((f) => f.router) ?? found.find((f) => f.predicted);
  const target = choice === "auto" ? hit : found.find((f) => f.info.key === choice);
  if (!target) {
    const quoted = found.find((f) => f.onHook);
    return (
      <Card>
        <Empty title={quoted ? `On ${quoted.info.name}, but not paired with HYPE` : `Not found on ${padNames(list)}`}>
          {quoted
            ? `This coin trades through one of ${quoted.info.name}'s hooks against something other than native HYPE. Monarchy routes HYPE-paired coins only there.`
            : "None of the launchpads knows this coin. Check the address, or pick the launchpad yourself above. A coin on a brand-new hook generation shows up once Monarchy adds it."}
        </Empty>
      </Card>
    );
  }
  if (!target.router && !target.predicted) {
    return (
      <Card>
        <Empty title={`${target.info.name} doesn't know this coin`}>
          {target.onHook
            ? `It trades on ${target.info.name} against something other than native HYPE, which Monarchy doesn't route.`
            : hit
              ? `It's on ${hit.info.name}. Switch the launchpad above, or go back to "Find it".`
              : target.info.quotes
                ? `It has no ${target.info.name} launch pool against ${target.info.quotes.map((q) => q.symbol).join(", ")}. Check the address.`
                : `It isn't on any ${target.info.name} hook Monarchy knows. Check the address.`}
        </Empty>
      </Card>
    );
  }
  if (target.mismatch)
    return (
      <Card>
        <Empty title="The network gave a wrong router address">
          The RPC's answer for this coin's router doesn't match the address worked out from Monarchy's deployment, so the page won't
          send the creator role anywhere. Switch your wallet or the site to another Elysium RPC and try again. The right address is{" "}
          <Addr address={target.predicted} />.
        </Empty>
      </Card>
    );
  return (
    <>
      {choice === "auto" && (
        <p className="muted small pad-found">
          Found on <b className="text">{target.info.name}</b>
          {target.info.quotes && <>, paired with {target.info.quotes.find((q) => same(q.address, target.quote))?.symbol}</>}.{" "}
          <a href={target.info.site} target="_blank" rel="noreferrer">
            {target.info.site.replace("https://", "")} <span aria-hidden="true">↗</span>
          </a>
        </p>
      )}
      <PadRouterOrActivate pads={pads} f={target} token={token} />
    </>
  );
}

function PadRouterOrActivate({ pads, f, token }: { pads: LaunchpadsDeployment; f: Found; token: Address }) {
  if (f.info.delayed) return <AscendPad pads={pads} f={f} token={token} />;
  return <V4PadRouterOrActivate pads={pads} f={f} token={token} />;
}

function V4PadRouterOrActivate({ pads, f, token }: { pads: LaunchpadsDeployment; f: Found; token: Address }) {
  const router = f.router;
  const isCreator = useReadContract({ address: router, abi: lodestarAbi, functionName: "isCreator", query: { enabled: !!router, ...POLL.query } });
  const env: RouterEnv = { exile: pads.exile, factory: f.pad.factory, venue: f.info.name, priceRef: "the 30 minute average price" };
  if (router && isCreator.data === undefined) return <LoadingCard />;
  // a one-step activation whose handover hasn't landed yet: the router exists and the creator still has to send it
  // the role, so the steps stay up until it holds the role
  if (router && (isCreator.data || f.info.twoStep)) return <Router env={env} lodestar={router} />;
  const predicted = router ?? f.predicted;
  if (!predicted || !f.poolId) return <LoadingCard />;
  return <PadActivate pads={pads} f={f} token={token} predicted={predicted} poolId={f.poolId} />;
}

function PadActivate({ pads, f, token, predicted, poolId }: { pads: LaunchpadsDeployment; f: Found; token: Address; predicted: Address; poolId: Hex }) {
  const { address } = useConnection();
  const { info, pad } = f;
  const src = { address: pad.source, abi: v4FeeSourceAbi } as const;
  const fac = { address: pad.factory, abi: lodestarFactoryAbi } as const;
  const r = useReadContracts({
    allowFailure: false,
    contracts: [
      { ...src, functionName: "handover" },
      { ...src, functionName: "creator", args: [token, poolId] },
      { ...src, functionName: "pendingCreator", args: [token, poolId] },
      { ...src, functionName: "holdersShareBps", args: [token, poolId] },
      { ...src, functionName: "dividendClaim", args: [token] },
      { ...src, functionName: "hookOf", args: [token] },
      { address: pads.exile, abi: exileAbi, functionName: "isRegistrar", args: [pad.factory] },
      { ...fac, functionName: "defaultSwapper" },
      { ...fac, functionName: "defaultSwapperSetAt" },
      { ...fac, functionName: "DEFAULT_SWAPPER_DELAY" },
    ],
    query: POLL.query,
  });
  const code = useBytecode({ address: predicted, query: POLL.query });
  const creator = r.data?.[1];
  const hook = r.data?.[5][0];
  // Eleos holds a coin's unpaid creator fees per coin, so they would move with the role: offer to pay them out first
  const eleos = info.key === "eleos";
  const el = useReadContracts({
    allowFailure: false,
    contracts: [
      { address: hook, abi: iEleosHookAbi, functionName: "processable", args: [token] },
      { address: hook, abi: iEleosHookAbi, functionName: "book", args: [token] },
    ],
    query: { enabled: eleos && !!hook, ...POLL.query },
  });
  const owed = useReadContract({
    ...src,
    functionName: "owed",
    args: [token, poolId, creator ?? ZERO],
    query: { enabled: !!creator, ...POLL.query },
  });
  // the role sent to another coin's router from this factory (a pasted address, two coins mixed up): that router
  // can't hand it back, and only Monarchy's rescueDeploy can move it into this coin's router
  const other = useReadContract({ address: creator, abi: lodestarAbi, functionName: "token", query: { enabled: !!creator && !same(creator, predicted), retry: false } });
  const otherRouter = useReadContract({ ...fac, functionName: "lodestarOf", args: [other.data ?? ZERO], query: { enabled: !!other.data && !same(other.data, token) } });
  const [tokenMeta] = useTokenMeta([token]);
  const s = useActivationSettings();
  const [route, setRoute] = useState<"default" | "v4">("default");

  if (!r.data || code.isLoading) return <LoadingCard />;
  const [handover, , pending, holdersBps, [, claimSelector], [, hookInfo], registrar, defaultSwapper, setAt, delay] = r.data;
  const twoStep = handover !== ONE_STEP;
  const deployed = !!code.data && code.data !== "0x";
  const you = same(address, creator);
  const v4 = swapperFor(pad, hookInfo.poolManager);
  const swapper = route === "v4" && v4 ? v4 : ZERO;
  const now = Math.floor(Date.now() / 1000);
  const defaultTooNew = swapper === ZERO && now < Number(setAt) + Number(delay);
  const sym = tokenMeta?.symbol;

  // nothing on chain says who sent the role to an address with no router yet, so only Monarchy can deploy it
  if (!twoStep && !deployed && same(creator, predicted))
    return (
      <Card title="Activate Lodestar">
        <Empty title="The role went to the router before it existed">
          The creator role already sits at this coin's router address, but the router hasn't been deployed, and nothing on chain proves who
          sent it. Ask Monarchy to deploy it for you: the factory owner checks who handed the role over and deploys the router with your
          settings in one transaction. Router address: <Addr address={predicted} />
        </Empty>
      </Card>
    );
  if (!twoStep && !!other.data && !same(other.data, token) && same(otherRouter.data, creator))
    return (
      <Card title="Activate Lodestar">
        <Empty title="The role went to another coin's router">
          This coin's creator role sits at <Addr address={creator} />, the Lodestar of a different coin. That router can't hand back a role
          that isn't its own coin's, and nothing on chain proves who sent it. Ask Monarchy to recover it: the factory owner checks who
          handed the role over, deploys this coin's router with your settings and moves the role into it in the same transaction.
          This coin's router address: <Addr address={predicted} />
        </Empty>
      </Card>
    );
  if (claimSelector === "0x00000000" && holdersBps > 0n)
    return (
      <Card>
        <Empty title="This coin can't be activated">
          It pays its holders a share of the tax that Exile can't pass on to lockers (a holder share on Kleos's multi-quote hook, paid in
          stock tokens). Coins without a holder share on that hook work.
        </Empty>
      </Card>
    );
  const notReady = claimSelector !== "0x00000000" && !registrar;

  const handedOver = twoStep ? same(pending, predicted) : same(creator, predicted);
  const eleosDue = eleos && !!el.data?.[0][0];
  const eleosOwed = eleos ? (el.data?.[1].creatorOwed ?? 0n) : 0n;
  const owedQuote = owed.data?.[1] ?? 0n;
  const youOnly = !you ? "Only the coin's creator can do this" : undefined;

  const deployStep = (
    <>
      <p className="muted small">
        Creates the router, its Exile reward pool and its Sandfall treasury stream{twoStep ? ", and accepts the role," : ""} in one transaction.
        {holdersBps > 0n ? ` ${sym ?? "The coin"} pays its holders ${Number(holdersBps) / 100}% of the tax; Exile claims that for the coins locked in it and passes it on to lockers.` : ""}
      </p>
      <ActivationSettings s={s} tokenRoute={false} />
      <h5>Buyback and burn</h5>
      <div className="check-list">
        <label className="check">
          <input type="radio" name="pad-route" checked={route === "default"} onChange={() => setRoute("default")} />
          {isSet(defaultSwapper)
            ? "Buy back through Monarchy's default route for new routers"
            : "Keep the buyback share in reserve for now. The steward can turn buybacks on later, behind the 12 hour timelock."}
        </label>
        {v4 && !same(v4, defaultSwapper) && (
          <label className="check">
            <input type="radio" name="pad-route" checked={route === "v4"} onChange={() => setRoute("v4")} />
            Buy back and burn from the start, through Monarchy's V4Swapper for this coin's pool
          </label>
        )}
      </div>
      <TxButton
        headroom
        disabledReason={
          youOnly ??
          (deployed
            ? "Done"
            : notReady
              ? `Monarchy is still finishing its setup on ${info.name}`
              : twoStep && !handedOver
                ? "Do step 1 first"
                : defaultTooNew
                  ? "Monarchy changed the default buyback route in the last 12 hours. Pick the V4Swapper or try again later."
                  : s.problem)
        }
        request={() => ({ address: pad.factory, abi: lodestarFactoryAbi, functionName: "deploy", args: [s.params(token, ZERO, swapper)] })}
      >
        Activate Lodestar
      </TxButton>
    </>
  );

  const steps: { title: string; done: boolean; body: React.ReactNode }[] = [];
  if (twoStep) {
    steps.push({
      title: "Propose the router as creator",
      done: handedOver,
      body: (
        <>
          <p className="muted small">On {info.name}'s hook. The router accepts the role in the next step, and nobody else can deploy it. Fees you earned before stay yours to claim on {info.name}.</p>
          <TxButton
            headroom
            disabledReason={youOnly ?? (handedOver ? "Done" : undefined)}
            request={() => hook && { address: hook, abi: iBoxaHookAbi, functionName: "proposeCreator", args: [poolId, predicted] }}
          >
            Propose router
          </TxButton>
          <RouterCheck predicted={predicted} />
        </>
      ),
    });
    steps.push({ title: "Activate", done: deployed, body: deployStep });
  } else {
    if (eleos && !deployed)
      steps.push({
        title: "Collect what you've earned (optional)",
        done: !eleosDue && eleosOwed === 0n,
        body: (
          <>
            <p className="muted small">
              Eleos keeps a coin's unpaid creator fees with the coin, so they move to the router with the role. Collect them first to keep
              them, or skip this to send them to your lockers.{owedQuote > 0n ? <> Owed to you now: <Amt value={owedQuote} decimals={18} symbol="HYPE" />.</> : null}
            </p>
            {eleosDue ? (
              <TxButton headroom disabledReason={youOnly} request={() => hook && { address: hook, abi: iEleosHookAbi, functionName: "process", args: [token] }}>
                Split the pending tax
              </TxButton>
            ) : (
              <TxButton headroom disabledReason={youOnly ?? (eleosOwed === 0n ? "Nothing to collect" : undefined)} request={() => hook && { address: hook, abi: iEleosHookAbi, functionName: "payCreator", args: [token] }}>
                Pay me my creator fees
              </TxButton>
            )}
          </>
        ),
      });
    steps.push({ title: "Activate", done: deployed, body: deployStep });
    steps.push({
      title: "Hand the creator role to the router",
      done: handedOver,
      body: (
        <>
          <p className="muted small">
            On {info.name}'s hook, once the router exists (never before: a role sent to an empty address can only be recovered by Monarchy).
            The router earns from the moment the role arrives.{info.key === "kleos" ? " Fees you earned before stay yours to claim on Kleos." : ""}
          </p>
          <TxButton
            headroom
            disabledReason={youOnly ?? (!deployed ? "Activate first" : handedOver ? "Done" : undefined)}
            request={() => hook && { address: hook, abi: info.key === "kleos" ? iKleosHookAbi : iEleosHookAbi, functionName: "transferCreator", args: [token, predicted] }}
          >
            Hand over creator role
          </TxButton>
          <RouterCheck predicted={predicted} />
        </>
      ),
    });
  }

  return (
    <Card title="Activate Lodestar" right={<Badge tone="grey">{info.name}</Badge>}>
      <div className="summary">
        <Row k="Coin" v={<>{sym && <b className="text">{sym}</b>} <Addr address={token} /></>} />
        <Row k={`Creator on ${info.name}`} v={<><Addr address={creator} /> {you && <Badge tone="green">you</Badge>}</>} />
        <Row k="Router address" v={<><Addr address={predicted} /> {deployed && <Badge tone="green">deployed</Badge>}</>} />
        <Row k="Hook" v={<Addr address={hook} />} />
      </div>
      {notReady && <p className="warn small">Monarchy is still finishing its setup on {info.name}. Activations open within a day of launch.</p>}
      <ol className="steps">
        {steps.map((st, i) => (
          <li key={st.title} className={st.done ? "done" : ""}>
            <h4>
              {i + 1}. {st.title}
            </h4>
            {st.body}
          </li>
        ))}
      </ol>
    </Card>
  );
}

/** The address the role goes to, next to the button, as the activation script prints it. */
function RouterCheck({ predicted }: { predicted: Address }) {
  return (
    <p className="muted small">
      Sends the role to <Addr address={predicted} /> (<span className="mono">{predicted}</span>), worked out from Monarchy's deployments file. Your
      wallet should show the same address.
    </p>
  );
}

// ==================================================================== Ascend v5

/** What the page reads about an Ascend v5 pool: its escrow (which holds the creator role), the escrow's hand-off
 * state and held fees, the pool's fee, and whether the pool opted in to Ascend's community takeovers. */
function useAscendPool(source: Address, poolId?: Hex) {
  const src = { address: source, abi: ascendV5FeeSourceAbi } as const;
  const a = useReadContracts({
    allowFailure: false,
    contracts: [
      { ...src, functionName: "escrowOf", args: [poolId ?? "0x"] },
      { ...src, functionName: "takeoverRegistry", args: [poolId ?? "0x"] },
      { ...src, functionName: "launchpad" },
    ],
    query: { enabled: !!poolId, ...POLL.query },
  });
  const [escrow, takeover, launchpad] = a.data ?? [];
  const e = { address: escrow, abi: iAscendV5EscrowAbi } as const;
  const b = useReadContracts({
    allowFailure: false,
    contracts: [
      { ...e, functionName: "recipient" },
      { ...e, functionName: "pendingRecipient" },
      { ...e, functionName: "recipientReadyAt" },
      { ...e, functionName: "held" },
      { ...e, functionName: "phase" },
      { ...e, functionName: "deadline" },
      { address: launchpad, abi: iAscendV5LaunchpadAbi, functionName: "currentFee", args: [poolId ?? "0x"] },
    ],
    query: { enabled: !!escrow && !!launchpad, ...POLL.query },
  });
  if (!a.data || !b.data || !escrow) return undefined;
  const [recipient, pending, readyAt, held, phase, deadline, feePips] = b.data;
  return { escrow, takeover: isSet(takeover) ? takeover : undefined, recipient, pending, readyAt: Number(readyAt), held, phase, deadline: Number(deadline), feePips };
}

type AscendPoolState = NonNullable<ReturnType<typeof useAscendPool>>;

/** The least gas a distribute on an Ascend v5 router is sent with, as the keeper does (ASCEND_DISTRIBUTE_GAS). */
const ASCEND_DISTRIBUTE_GAS = 2_000_000n;

/** The pool's fee in percent: Ascend keeps it in pips (1,000,000 = 100%). */
const feePct = (pips: number) => pct(pips / 100);

/** An Ascend v5 coin: its router once it holds the role, otherwise the three activation steps (with the router
 * below them once it exists, for the 48 hours it waits). */
function AscendPad({ pads, f, token }: { pads: LaunchpadsDeployment; f: Found; token: Address }) {
  const router = f.router;
  const pool = useAscendPool(f.pad.source, f.poolId);
  const isCreator = useReadContract({ address: router, abi: lodestarAbi, functionName: "isCreator", query: { enabled: !!router, ...POLL.query } });
  const predicted = router ?? f.predicted;
  if (!predicted || !f.poolId || !pool || (router && isCreator.data === undefined)) return <LoadingCard />;
  const env: RouterEnv = {
    exile: pads.exile,
    factory: f.pad.factory,
    venue: "Ascend",
    priceRef: "Ascend's average price",
    lockNote: pool.takeover ? "This pool also opted in to Ascend's community takeovers, which can replace the router whatever the lock says." : undefined,
    // the escrow refuses to pay the router with less than about 600,000 gas left, and distribute carries on
    // without the payout rather than revert, so a wallet's estimate alone would route nothing
    distributeGas: ASCEND_DISTRIBUTE_GAS,
  };
  if (router && isCreator.data)
    return (
      <>
        <Router env={env} lodestar={router} />
        <AscendPoolCard pool={pool} quote={f.quote} lodestar={router} />
      </>
    );
  return (
    <>
      <AscendActivate f={f} token={token} predicted={predicted} pool={pool} />
      {router && <Router env={env} lodestar={router} />}
    </>
  );
}

/** The takeover warning, worded for before and after the hand-off. */
function TakeoverNote({ active }: { active: boolean }) {
  return (
    <p className="warn small">
      This pool opted in to Ascend's community takeovers. If Ascend approves someone's takeover request, that person becomes the
      recipient after a 48 hour notice and replaces {active ? "this router" : "the router"}, even with the creator role locked: the lock
      only binds Monarchy and the steward. Credits the router has already earned are still routed; held and future fees go to the new
      recipient.
    </p>
  );
}

/** Held fees, in words: Ascend pays only part of each fee while the coin is under its graduation line. */
function HeldNote({ pool, qd, qs, after }: { pool: AscendPoolState; qd: number; qs?: string; after: "router" | "you" }) {
  if (pool.phase !== 0 || pool.held === 0n) return null;
  return (
    <p className="muted small">
      Ascend is holding {fmt(pool.held, qd)} {qs} of creator fees until the coin graduates
      {pool.deadline > 0 ? <> (it has until {date(pool.deadline)})</> : null}. Held fees go to whoever is the recipient at graduation
      {after === "router" ? ", so once the router has accepted they go to it and through your split." : ", which is this router."}
    </p>
  );
}

/** Ascend's side of an active router: the pool's fee, held fees and takeovers. */
function AscendPoolCard({ pool, quote, lodestar }: { pool: AscendPoolState; quote: Address; lodestar: Address }) {
  const [qm] = useTokenMeta([quote]);
  return (
    <Card title="On Ascend" right={<Badge tone="grey">Ascend v5</Badge>}>
      <div className="summary">
        <Row k="Pool fee" v={`${feePct(pool.feePips)}, set at launch`} />
        <Row k="Escrow" v={<Addr address={pool.escrow} />} />
        <Row k="Community takeovers" v={pool.takeover ? <Badge tone="amber">Opted in</Badge> : <Badge tone="grey">Not opted in</Badge>} />
      </div>
      <HeldNote pool={pool} qd={qm?.decimals ?? 18} qs={qm?.symbol} after="you" />
      {pool.takeover && <TakeoverNote active={same(pool.recipient, lodestar)} />}
    </Card>
  );
}

function AscendActivate({ f, token, predicted, pool }: { f: Found; token: Address; predicted: Address; pool: AscendPoolState }) {
  const { address } = useConnection();
  const now = useNow();
  const { info, pad, quote } = f;
  const fac = { address: pad.factory, abi: lodestarFactoryAbi } as const;
  const esc = { address: pool.escrow, abi: iAscendV5EscrowAbi } as const;
  const r = useReadContracts({
    allowFailure: false,
    contracts: [
      { ...fac, functionName: "defaultSwapper" },
      { ...fac, functionName: "defaultSwapperSetAt" },
      { ...fac, functionName: "DEFAULT_SWAPPER_DELAY" },
      { ...esc, functionName: "claimable", args: [pool.recipient] },
    ],
    query: POLL.query,
  });
  // Holder Rewards, Buyback and Custom mix coins pay Ascend's seat contract, which names the escrow it sits on
  const seat = useReadContract({ address: pool.recipient, abi: iAscendV5SeatAbi, functionName: "escrow", query: { retry: false, staleTime: Infinity } });
  const code = useBytecode({ address: predicted, query: POLL.query });
  const [tokenMeta, quoteMeta] = useTokenMeta([token, quote]);
  const s = useActivationSettings();
  const [route, setRoute] = useState<"default" | "ascend">("ascend");

  if (!r.data || code.isLoading || seat.isLoading) return <LoadingCard />;
  const [defaultSwapper, setAt, delay, credited] = r.data;
  if (same(seat.data, pool.escrow))
    return (
      <Card>
        <Empty title="This coin can't move to Lodestar">
          Its creator fees go to Ascend's seat contract, which Holder Rewards, Buyback and Custom mix coins use. The seat's split is fixed
          at launch and it never hands the role on, so only Vanilla coins can move to Lodestar.
        </Empty>
      </Card>
    );

  const sym = tokenMeta?.symbol;
  const qs = quoteMeta?.symbol;
  const qd = quoteMeta?.decimals ?? 18;
  const you = same(address, pool.recipient);
  const youOnly = !you ? "Only the coin's recipient on Ascend can do this" : undefined;
  const deployed = !!code.data && code.data !== "0x";
  const accepted = same(pool.recipient, predicted);
  const proposed = same(pool.pending, predicted);
  const otherPending = isSet(pool.pending) && !proposed ? pool.pending : undefined;
  const ready = proposed && now >= pool.readyAt;
  const ours = swapperFor(pad, pad.poolManagers[0]);
  const swapper = route === "ascend" && ours ? ours : ZERO;
  const defaultTooNew = swapper === ZERO && now < Number(setAt) + Number(delay);

  const steps: { title: string; done: boolean; body: React.ReactNode }[] = [
    {
      title: "Propose the router as recipient",
      done: proposed || accepted,
      body:
        proposed || accepted ? (
          <>
            <p className="muted small">
              Proposed on the coin's Ascend escrow. Until the router accepts, the fees Ascend credits still go to you{you ? ", and you can call the hand-off off" : ""}.
            </p>
            {proposed && you && (
              <TxButton className="btn btn-ghost" request={() => ({ ...esc, functionName: "proposeRecipient", args: [ZERO] })}>
                Call off the hand-off
              </TxButton>
            )}
          </>
        ) : (
        <>
          <p className="muted small">
            On the coin's Ascend escrow, which holds its creator role. This starts Ascend's 48 hour wait, after which the router accepts
            (step 3). Until then you can call it off, and the fees Ascend credits as people trade still go to you. What it has credited to
            you{credited > 0n ? <> ({fmt(credited, qd)} {qs} so far)</> : null} stays yours to claim on Ascend.
          </p>
          <HeldNote pool={pool} qd={qd} qs={qs} after="router" />
          {otherPending && (
            <p className="warn small">
              A hand-off to <Addr address={otherPending} /> is already waiting. Proposing the router replaces it.
            </p>
          )}
          <TxButton headroom disabledReason={youOnly} request={() => ({ ...esc, functionName: "proposeRecipient", args: [predicted] })}>
            Propose router
          </TxButton>
          <RouterCheck predicted={predicted} />
        </>
      ),
    },
    {
      title: "Activate",
      done: deployed,
      body: deployed ? (
        <p className="muted small">The router is deployed, with its Exile reward pool and its Team Treasury stream. Its settings are below.</p>
      ) : (
        <>
          <p className="muted small">
            Creates the router, its Exile reward pool and its Sandfall treasury stream in one transaction. Ascend pays the creator fees in{" "}
            {qs ?? "the quote asset"}, so lockers and the Team Treasury are paid in {qs ?? "it"} too.
          </p>
          <ActivationSettings s={s} tokenRoute={false} />
          <h5>Buyback and burn</h5>
          <div className="check-list">
            {ours && (
              <label className="check">
                <input type="radio" name="ascend-route" checked={route === "ascend"} onChange={() => setRoute("ascend")} />
                Buy back and burn from the start, through Monarchy's swapper for Ascend's launch pools (it pays the pool's {feePct(pool.feePips)}{" "}
                fee like any buyer)
              </label>
            )}
            <label className="check">
              <input type="radio" name="ascend-route" checked={route === "default"} onChange={() => setRoute("default")} />
              {isSet(defaultSwapper)
                ? "Buy back through Monarchy's default route for new routers"
                : "Keep the buyback share in reserve for now. The steward can turn buybacks on later, behind the 12 hour timelock."}
            </label>
          </div>
          <TxButton
            headroom
            disabledReason={
              youOnly ??
              (deployed
                ? "Done"
                : !proposed
                  ? "Do step 1 first"
                  : defaultTooNew
                    ? "Monarchy changed the default buyback route in the last 12 hours. Pick Monarchy's swapper or try again later."
                    : s.problem)
            }
            request={() => ({ address: pad.factory, abi: lodestarFactoryAbi, functionName: "deploy", args: [s.params(token, quote, swapper)] })}
          >
            Activate Lodestar
          </TxButton>
        </>
      ),
    },
    {
      title: "Accept after Ascend's 48 hours",
      done: accepted,
      body: (
        <>
          <p className="muted small">
            Ascend lets a new recipient accept only 48 hours after it was proposed. After that anyone can send this, you included, and from
            then on the escrow pays the router.
            {proposed && !accepted ? (
              ready ? (
                <b className="text"> The wait is over.</b>
              ) : (
                <>
                  {" "}
                  Ready in <b className="text">{duration(pool.readyAt - now)}</b> ({date(pool.readyAt)}).
                </>
              )
            ) : null}
          </p>
          <TxButton
            headroom
            disabledReason={
              accepted ? "Done" : !proposed ? "Do step 1 first" : !deployed ? "Activate first" : !ready ? `Ascend's wait ends in ${duration(pool.readyAt - now)}` : undefined
            }
            request={() => ({ address: predicted, abi: lodestarAbi, functionName: "acceptCreator" })}
          >
            Accept the creator role
          </TxButton>
        </>
      ),
    },
  ];

  return (
    <Card title="Activate Lodestar" right={<Badge tone="grey">{info.name}</Badge>}>
      <div className="summary">
        <Row k="Coin" v={<>{sym && <b className="text">{sym}</b>} <Addr address={token} /></>} />
        <Row k="Pair" v={`${sym ?? "Coin"} / ${qs ?? "…"}`} />
        <Row k="Pool fee" v={`${feePct(pool.feePips)}, set at launch`} />
        <Row k="Recipient on Ascend" v={<><Addr address={pool.recipient} /> {you && <Badge tone="green">you</Badge>}</>} />
        <Row k="Escrow" v={<Addr address={pool.escrow} />} />
        <Row k="Router address" v={<><Addr address={predicted} /> {deployed && <Badge tone="green">deployed</Badge>}</>} />
      </div>
      {pool.takeover && <TakeoverNote active={false} />}
      <ol className="steps">
        {steps.map((st, i) => (
          <li key={st.title} className={st.done ? "done" : ""}>
            <h4>
              {i + 1}. {st.title}
            </h4>
            {st.body}
          </li>
        ))}
      </ol>
    </Card>
  );
}
