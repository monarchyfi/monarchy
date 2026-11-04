import { useState } from "react";
import { useSearchParams } from "react-router-dom";
import { useBytecode, useConnection, useReadContract, useReadContracts } from "wagmi";
import { isAddress, type Address, type Hex } from "viem";
import { exileAbi, iBoxaHookAbi, iEleosHookAbi, iKleosHookAbi, lodestarAbi, lodestarFactoryAbi, v4FeeSourceAbi } from "../abi";
import { PageMark } from "../components/NavGlyphs";
import { TxButton } from "../components/Tx";
import { Addr, Amt, Badge, Card, Empty, Row } from "../components/Ui";
import { isSet, ZERO } from "../lib/deployments";
import { POLL, usePageTitle } from "../lib/hooks";
import { padsOf, PADS, routerAddress, swapperFor, type LaunchpadsDeployment, type PadDeployment, type PadInfo, type PadKey } from "../lib/launchpads";
import { useTokenMeta } from "../lib/monarchy";
import { Switch } from "./Exile";
import { ActivationSettings, LoadingCard, Router, useActivationSettings, type RouterEnv } from "./Lodestar";

/** IFeeSource.Handover.OneStep */
const ONE_STEP = 1;

type Choice = "auto" | PadKey;

/** The Lodestar page on a chain with Eleos, Kleos and Boxa: paste a coin, the page finds its launchpad (or the
 * creator picks it), then shows its router or the activation steps that launchpad needs. */
export function PadsLodestar({ pads }: { pads: LaunchpadsDeployment }) {
  usePageTitle("Lodestar");
  const [params] = useSearchParams();
  const [input, setInput] = useState(() => params.get("token") ?? "");
  const fromUrl = params.get("launchpad") as PadKey | null;
  const [choice, setChoice] = useState<Choice>(() => (fromUrl && fromUrl in PADS ? fromUrl : "auto"));
  const list = padsOf(pads);
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
          Your coin's creator fees, paid to the holders who lock it. A Lodestar holds your coin's creator role on Eleos, Kleos or Boxa and
          routes the creator share of the tax the way you set it: to Exile lockers, into buyback and burn, or to a Team Treasury streamed
          through Sandfall. Locked coins keep earning the coin's own holder dividends too. Later changes wait 12 hours, in public. No fees.
        </p>
      </header>
      <Card title="Coin">
        <label className="field">
          <span className="field-label">Coin address</span>
          <input className="input mono-input" placeholder="0x…" value={input} onChange={(e) => setInput(e.target.value.trim())} spellCheck={false} autoComplete="off" />
        </label>
        <p className="muted small field-help">
          {badInput ? "That isn't a valid address yet." : "Paste a coin launched on Eleos, Kleos or Boxa to view or activate its Lodestar."}
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
  /** the coin trades through a hook this launchpad's adapter knows, whatever it is quoted in */
  onHook: boolean;
  /** the network's answer for the router address disagrees with the one worked out from the deployments file */
  mismatch: boolean;
};

const same = (a?: string, b?: string) => !!a && !!b && a.toLowerCase() === b.toLowerCase();

/** Asks every launchpad's factory about the coin. Only the coin's own launchpad answers `predict` without reverting
 * (the others don't know its hook); a coin on a known hook but quoted in something other than HYPE answers
 * `hookOf` and still reverts `predict`. */
function PadToken({ pads, token, choice }: { pads: LaunchpadsDeployment; token: Address; choice: Choice }) {
  const list = padsOf(pads);
  const r = useReadContracts({
    allowFailure: true,
    contracts: list.flatMap(({ pad }) => [
      { address: pad.factory, abi: lodestarFactoryAbi, functionName: "lodestarOf", args: [token] } as const,
      { address: pad.factory, abi: lodestarFactoryAbi, functionName: "predict", args: [token, ZERO] } as const,
      { address: pad.source, abi: v4FeeSourceAbi, functionName: "hookOf", args: [token] } as const,
    ]),
    query: POLL.query,
  });
  if (!r.data) return <LoadingCard />;
  const found: Found[] = list.map(({ info, pad }, i) => {
    const [of, pr, hk] = [r.data[3 * i], r.data[3 * i + 1], r.data[3 * i + 2]];
    const router = of.status === "success" && isSet(of.result as Address) ? (of.result as Address) : undefined;
    const p = pr.status === "success" ? (pr.result as readonly [Address, Hex]) : undefined;
    // the address the role goes to is never the RPC's word: derive it from the deployments file and the pool id, and
    // flag any answer (predict's or lodestarOf's) that doesn't match it
    const expected = p ? routerAddress(pads.lodestarImpl, pad.factory, p[1]) : undefined;
    const mismatch = !!expected && (!same(p?.[0], expected) || (!!router && !same(router, expected)));
    return { info, pad, router, predicted: expected, poolId: p?.[1], onHook: hk.status === "success", mismatch };
  });
  // the RPC failing every read looks like "on no launchpad"; say so instead
  if (r.data.every((x) => x.status === "failure" && !/revert/i.test(String(x.error))))
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
        <Empty title={quoted ? `On ${quoted.info.name}, but not paired with HYPE` : "Not found on Eleos, Kleos or Boxa"}>
          {quoted
            ? `This coin trades through one of ${quoted.info.name}'s hooks against something other than native HYPE. Monarchy routes HYPE-paired coins only.`
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
          Found on <b className="text">{target.info.name}</b>.{" "}
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
