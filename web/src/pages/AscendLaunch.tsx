import { useMemo, useState } from "react";
import { useBalance, useConnection, useReadContract } from "wagmi";
import { bytesToHex, parseUnits, toHex, type Address } from "viem";
import { ascendV5LauncherAbi, lodestarAbi, mockERC20Abi } from "../abi";
import { TxButton, WithApproval } from "../components/Tx";
import { Addr, Badge, Card, Row } from "../components/Ui";
import { isSet, ZERO } from "../lib/deployments";
import { fmt } from "../lib/format";
import { POLL } from "../lib/hooks";
import {
  ascendCoinUrl,
  ascendPoolId,
  ASCEND_QUOTES,
  routerAddress,
  safeLink,
  swapperFor,
  type LaunchpadsDeployment,
  type PadDeployment,
} from "../lib/launchpads";
import { useTokenMeta } from "../lib/monarchy";
import { MAX_PICTURE, pictureUrl, shrinkPicture } from "../lib/picture";
import { Switch } from "./Exile";
import { ActivationSettings, useActivationSettings } from "./Lodestar";

/** AscendV5Launcher's limits, checked here first so the button never sends a launch that has to revert. */
const MAX_PLAN = 500;
const MAX_DESCRIPTION = 1000;
const MAX_LINK = 300;
const FEES = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
const same = (a?: string, b?: string) => !!a && !!b && a.toLowerCase() === b.toLowerCase();
const bytes = (s: string) => new TextEncoder().encode(s).length;

/** Why there are two ways onto Ascend, and the 48 hours. Shown above both the launch form and the activation. */
export function TwoWays({ launchable }: { launchable: boolean }) {
  return (
    <Card title="Two ways to put an Ascend coin on Monarchy">
      <div className="ways">
        <div className="way">
          <h4>
            Launch through Monarchy {launchable ? <Badge tone="green">no wait</Badge> : <Badge tone="grey">not deployed yet</Badge>}
          </h4>
          <p className="muted small">
            For a new coin. Monarchy launches it on Ascend with its router already set as the fee wallet, in the same transaction that
            creates the router. Fees go through your split from the very first trade. The coin trades on Ascend like any other: same pool,
            same 1% to 10% fee, same graduation rules.
          </p>
          <p className="muted small">
            Two differences. Community takeovers are off, and Ascend's site only lets a coin's fee wallet publish its picture and
            description. Here the fee wallet is the router, so Monarchy's launcher stores the picture on chain and this site shows it.
          </p>
        </div>
        <div className="way">
          <h4>
            Launch on Ascend, then switch <Badge tone="amber">48 hours</Badge>
          </h4>
          <p className="muted small">
            For a coin that's already live, or if you'd rather launch on Ascend's own site. Pick <b className="text">Pays creator</b> and
            leave community takeover off, then paste the coin here and activate. Holder Rewards, Buyback and Custom mix coins can't switch.
          </p>
          <p className="muted small">
            Moving a coin's fee wallet takes 48 hours. Until then, the fees Ascend pays out still go to the creator's wallet.
          </p>
        </div>
      </div>
      <details className="why">
        <summary>Why does switching take 48 hours?</summary>
        <p className="muted small">
          The wait is a rule in Ascend's own contract, the escrow that holds each coin's creator fees. A new fee wallet is announced on
          chain and can only take over 48 hours later. That way, nobody can redirect a coin's fees in one transaction, and holders see a
          change coming. Monarchy can't shorten it, and neither can Ascend: their contracts can't be upgraded.
        </p>
        <p className="muted small">
          During the wait, the creator's wallet keeps getting what Ascend pays out as people trade. Before the coin graduates, that's a
          tenth of the trading fee. The rest of the creator's share is held, and it goes to whoever is the fee wallet when the coin
          graduates. So if the router has taken over by then, the held fees go through your split too. A coin launched through Monarchy
          never has this gap, because its fee wallet is the router from the start.
        </p>
      </details>
    </Card>
  );
}

/** The launch form: a new Ascend v5 coin with its router as fee owner from the first trade (AscendV5Launcher). */
export function AscendLaunch({ pads, pad, onLaunched }: { pads: LaunchpadsDeployment; pad: PadDeployment; onLaunched: (token: Address) => void }) {
  const launcher = pad.launcher!;
  const { address } = useConnection();
  const [name, setName] = useState("");
  const [symbol, setSymbol] = useState("");
  const [quoteIdx, setQuoteIdx] = useState("0");
  const [fee, setFee] = useState(3);
  const [devBuy, setDevBuy] = useState("");
  const [picture, setPicture] = useState<Uint8Array>();
  const [description, setDescription] = useState("");
  const [website, setWebsite] = useState("");
  const [twitter, setTwitter] = useState("");
  const [telegram, setTelegram] = useState("");
  const [plan, setPlan] = useState("");
  const [route, setRoute] = useState<"ascend" | "reserve">("ascend");
  const [launched, setLaunched] = useState<Address>();
  // a new salt per visit: the launcher mixes in the wallet, so the coin's address is this wallet's alone
  const salt = useMemo(() => toHex(crypto.getRandomValues(new Uint8Array(32))), []);
  const s = useActivationSettings();

  const q = ASCEND_QUOTES[Number(quoteIdx)];
  const quote = q.address;
  const native = q.symbol === "WHYPE";
  const [qm] = useTokenMeta([quote]);
  const qd = qm?.decimals ?? 18;
  const shown = native ? "HYPE" : q.symbol;
  let devBuyWei = 0n;
  let badAmount = false;
  try {
    devBuyWei = devBuy.trim() ? parseUnits(devBuy.trim(), qd) : 0n;
  } catch {
    badAmount = true;
  }

  const coin = { name: name.trim(), symbol: symbol.trim(), quote, fee: fee * 10_000, devBuyQuote: devBuyWei, minDevOut: 0n, salt } as const;
  const profile = { image: picture ? bytesToHex(picture) : ("0x" as const), description: description.trim(), website: website.trim(), twitter: twitter.trim(), telegram: telegram.trim() };
  const ready = !!coin.name && !!coin.symbol && !badAmount;
  const predicted = useReadContract({
    address: launcher,
    abi: ascendV5LauncherAbi,
    functionName: "predict",
    args: address ? [address, coin] : undefined,
    query: { enabled: !!address && ready },
  });
  const [token, poolId, router] = predicted.data ?? [];
  // the router address is worked out here too, as for activations: a node that lies about `predict` can't send a
  // coin's fees anywhere but its own router (a wrong coin address only makes the launch revert)
  const expected = token ? routerAddress(pads.lodestarImpl, pad.factory, ascendPoolId(token, quote)) : undefined;
  const mismatch = !!router && !!expected && (!same(router, expected) || poolId !== ascendPoolId(token!, quote));

  const nativeBal = useBalance({ address, query: { enabled: !!address && native, ...POLL.query } });
  const tokenBal = useReadContract({ address: quote, abi: mockERC20Abi, functionName: "balanceOf", args: address ? [address] : undefined, query: { enabled: !!address && !native, ...POLL.query } });
  const balance = native ? nativeBal.data?.value : tokenBal.data;

  const ours = swapperFor(pad, pad.poolManagers[0]);
  const swapper = route === "ascend" && ours ? ours : ZERO;
  const badLink = [website, twitter, telegram].some((l) => l.trim() && !safeLink(l));
  const problem = !coin.name
    ? "Name your coin"
    : !coin.symbol
      ? "Give it a ticker"
      : coin.name.length > 32 || coin.symbol.length > 10
        ? "Keep the name to 32 characters and the ticker to 10"
        : badAmount
          ? "That first-buy amount isn't a number"
          : balance !== undefined && devBuyWei > balance
            ? `You don't have ${devBuy} ${shown}`
            : badLink
              ? "Links have to start with https://"
              : bytes(profile.description) > MAX_DESCRIPTION || [website, twitter, telegram].some((l) => bytes(l.trim()) > MAX_LINK)
                ? "The description or a link is too long"
                : bytes(plan.trim()) > MAX_PLAN
                  ? "The launch statement is limited to 500 characters"
                  : s.problem ?? (mismatch ? "The network's answer for the router address doesn't match. Try another RPC." : !token ? "Working out the coin's address…" : undefined);

  if (launched)
    return (
      <Card title="Launched" right={<Badge tone="green">fees to the router</Badge>}>
        <p className="muted">
          <b className="text">{coin.symbol}</b> is live on Ascend, and its router already holds the creator role. Every fee from the first
          trade goes through your split.
        </p>
        <div className="summary">
          <Row k="Coin" v={<Addr address={launched} />} />
          {router && <Row k="Router" v={<Addr address={router} />} />}
        </div>
        <div className="input-row">
          <button className="btn" onClick={() => onLaunched(launched)}>
            Open its router
          </button>
          <a className="btn btn-ghost" href={ascendCoinUrl(launched)} target="_blank" rel="noreferrer">
            See it on Ascend ↗
          </a>
        </div>
      </Card>
    );

  return (
    <Card title="Launch a coin on Ascend" right={<Badge tone="grey">Ascend v5</Badge>}>
      <p className="muted small">
        One transaction launches your coin on Ascend as a <b className="text">Pays creator</b> coin with its Lodestar router as the fee
        wallet, then creates the router, its Exile reward pool and its Team Treasury stream. You're the router's steward and you get the
        first buy. There's nothing to accept and no wait.
      </p>

      <h5>The coin</h5>
      <div className="form">
        <label className="field">
          <span className="field-label">Name</span>
          <input className="input" value={name} maxLength={32} onChange={(e) => setName(e.target.value)} placeholder="Monarch" />
        </label>
        <label className="field">
          <span className="field-label">Ticker</span>
          <input className="input" value={symbol} maxLength={10} onChange={(e) => setSymbol(e.target.value.toUpperCase().replace(/\s/g, ""))} placeholder="MNRC" />
        </label>
      </div>
      <p className="muted small field-help">The name and ticker are permanent.</p>
      <div className="field">
        <span className="field-label">Pair</span>
        <Switch options={ASCEND_QUOTES.map((x, i) => ({ key: String(i), label: x.symbol === "WHYPE" ? "HYPE" : x.symbol }))} value={quoteIdx} onChange={setQuoteIdx} />
      </div>
      <div className="form">
        <label className="field">
          <span className="field-label">Trading fee</span>
          <select className="input" value={fee} onChange={(e) => setFee(Number(e.target.value))}>
            {FEES.map((f) => (
              <option key={f} value={f}>
                {f}%
              </option>
            ))}
          </select>
        </label>
        <label className="field">
          <span className="field-label">First buy ({shown}, optional)</span>
          <input className="input" inputMode="decimal" value={devBuy} onChange={(e) => setDevBuy(e.target.value)} placeholder="0" />
        </label>
      </div>
      <p className="muted small field-help">
        The fee is fixed at launch. Everything above Ascend's base 1% is the creator's share, which the router splits. The first buy goes to
        your wallet and pays no fee{balance !== undefined ? <> (you have {fmt(balance, qd)} {shown})</> : null}.
      </p>

      <h5>Picture and links</h5>
      <p className="muted small">
        Ascend's site only lets a coin's fee wallet publish its art, and this coin's fee wallet is the router, so Monarchy keeps it and
        shows it here. The picture itself is stored on chain with the coin, so it needs no hosting and can't go missing. You can change
        it later as the router's steward.
      </p>
      <PicturePicker value={picture} onChange={setPicture} />
      <label className="field">
        <span className="field-label">Description</span>
        <textarea className="input textarea" rows={3} value={description} onChange={(e) => setDescription(e.target.value)} />
      </label>
      <div className="form form-3">
        <label className="field">
          <span className="field-label">Website</span>
          <input className="input" value={website} onChange={(e) => setWebsite(e.target.value)} placeholder="https://" spellCheck={false} />
        </label>
        <label className="field">
          <span className="field-label">X</span>
          <input className="input" value={twitter} onChange={(e) => setTwitter(e.target.value)} placeholder="https://x.com/…" spellCheck={false} />
        </label>
        <label className="field">
          <span className="field-label">Telegram</span>
          <input className="input" value={telegram} onChange={(e) => setTelegram(e.target.value)} placeholder="https://t.me/…" spellCheck={false} />
        </label>
      </div>
      <label className="field">
        <span className="field-label">Launch statement (optional)</span>
        <textarea className="input textarea" rows={2} value={plan} onChange={(e) => setPlan(e.target.value)} placeholder="What the first buy is for, and whether any of it will be sold." />
      </label>
      <p className="muted small field-help">
        Shown on Ascend's coin page. Ascend's own form asks for one when the first buy is more than about 10% of the supply.
      </p>

      <h5>The router</h5>
      <ActivationSettings s={s} tokenRoute={false} />
      <h5>Buyback and burn</h5>
      <div className="check-list">
        {ours && (
          <label className="check">
            <input type="radio" name="launch-route" checked={route === "ascend"} onChange={() => setRoute("ascend")} />
            Buy back and burn from the start, through Monarchy's swapper for Ascend's launch pools (it pays the pool's fee like any buyer)
          </label>
        )}
        <label className="check">
          <input type="radio" name="launch-route" checked={route === "reserve" || !ours} onChange={() => setRoute("reserve")} />
          Keep the buyback share in reserve for now. You can turn buybacks on later, behind the 12 hour timelock.
        </label>
      </div>

      <div className="summary">
        <Row k="Coin address" v={token ? <Addr address={token} /> : address ? "…" : "Connect to see it"} />
        <Row k="Router (fee wallet)" v={router && !mismatch ? <Addr address={router} /> : "…"} />
        <Row k="Community takeovers" v={<Badge tone="grey">Off</Badge>} />
        <Row k="Creator role" v={s.lockForever ? "Locked to the router for good" : "Not locked"} />
      </div>
      {mismatch && <p className="warn small">The network's answer for the router address doesn't match the one worked out here, so the page won't launch.</p>}
      <WithApproval token={native ? undefined : quote} spender={launcher} amount={native ? 0n : devBuyWei}>
        <TxButton
          headroom
          disabledReason={problem}
          onDone={() => token && setLaunched(token)}
          request={() =>
            token
              ? {
                  address: launcher,
                  abi: ascendV5LauncherAbi,
                  functionName: "launch",
                  args: [coin, s.params(token, quote, swapper), profile, plan.trim()],
                  value: native ? devBuyWei : 0n,
                }
              : undefined
          }
        >
          Launch {coin.symbol || "coin"}
        </TxButton>
      </WithApproval>
    </Card>
  );
}

/** A coin's picture from its bytes, shown only when they are a PNG, JPEG, WebP or GIF (and hidden if the browser can't
 * draw them after all). */
function CoinArt({ data }: { data?: Uint8Array | `0x${string}` }) {
  const src = useMemo(() => pictureUrl(data), [data]);
  const [broken, setBroken] = useState<string>();
  if (!src || broken === src) return null;
  return <img className="coin-art" src={src} alt="" onError={() => setBroken(src)} />;
}

/** Choose the coin's picture from a file. The file is shrunk here, in the browser, to fit on chain (at most 24 KB,
 * 256 pixels square), and goes out with the transaction. */
function PicturePicker({ value, onChange, current }: { value?: Uint8Array; onChange: (b?: Uint8Array) => void; current?: boolean }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const pick = async (file?: File) => {
    if (!file) return;
    setBusy(true);
    setError(undefined);
    try {
      onChange(await shrinkPicture(file));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="picture-pick">
      {value ? <CoinArt data={value} /> : <div className="coin-art coin-art-empty" aria-hidden="true" />}
      <div>
        <div className="input-row">
          <label className={`btn btn-ghost${busy ? " disabled" : ""}`}>
            {busy ? "Shrinking…" : value ? "Choose another picture" : current ? "Choose a new picture" : "Choose a picture"}
            <input
              type="file"
              accept="image/png,image/jpeg,image/webp,image/gif"
              hidden
              disabled={busy}
              onChange={(e) => {
                void pick(e.target.files?.[0]);
                e.target.value = "";
              }}
            />
          </label>
          {value && (
            <button className="btn btn-ghost" onClick={() => onChange(undefined)}>
              {current ? "Keep the current one" : "Remove"}
            </button>
          )}
        </div>
        <p className={`small field-help ${error ? "warn" : "muted"}`}>
          {error ??
            (value
              ? `${(value.length / 1000).toFixed(1)} KB, stored on chain with the transaction.`
              : `PNG, JPEG, WebP or GIF. Big pictures are cropped square and shrunk to ${MAX_PICTURE / 1000} KB here, before anything is sent.`)}
        </p>
      </div>
    </div>
  );
}

type Edit = { description: string; website: string; twitter: string; telegram: string; picture?: Uint8Array; removePicture: boolean };

/** A coin launched through Monarchy: its picture, description and links (kept by the launcher, since Ascend only
 * takes art from the fee wallet), editable by the router's steward. */
export function CoinProfileCard({ launcher, token, router }: { launcher: Address; token: Address; router: Address }) {
  const { address } = useConnection();
  const by = useReadContract({ address: launcher, abi: ascendV5LauncherAbi, functionName: "launcherOf", args: [token], query: { staleTime: Infinity } });
  const p = useReadContract({ address: launcher, abi: ascendV5LauncherAbi, functionName: "profileOf", args: [token], query: { enabled: isSet(by.data), ...POLL.query } });
  const steward = useReadContract({ address: router, abi: lodestarAbi, functionName: "steward", query: { enabled: isSet(by.data) } });
  const [edit, setEdit] = useState<Edit>();
  if (!isSet(by.data) || !p.data) return null;
  const prof = p.data;
  const hasPicture = !!pictureUrl(prof.image);
  const links = [
    ["Website", prof.website],
    ["X", prof.twitter],
    ["Telegram", prof.telegram],
  ].flatMap(([k, v]) => {
    const href = safeLink(v);
    return href ? [{ k, href }] : [];
  });
  const isSteward = same(address, steward.data);
  const e = edit;
  const set = (k: "description" | "website" | "twitter" | "telegram") => (ev: { target: { value: string } }) => e && setEdit({ ...e, [k]: ev.target.value });
  const badEdit =
    !!e &&
    ([e.website, e.twitter, e.telegram].some((l) => l.trim() && !safeLink(l)) ||
      bytes(e.description) > MAX_DESCRIPTION ||
      [e.website, e.twitter, e.telegram].some((l) => bytes(l) > MAX_LINK));
  return (
    <Card title="The coin" right={<Badge tone="green">launched through Monarchy</Badge>}>
      <div className="coin-profile">
        <CoinArt data={prof.image} />
        <div>
          {prof.description ? <p className="muted">{prof.description}</p> : <p className="muted small">No description yet.</p>}
          {links.length > 0 && (
            <p className="small">
              {links.map((l) => (
                <a key={l.k} className="tx-link" href={l.href} target="_blank" rel="noreferrer noopener nofollow">
                  {l.k} ↗{" "}
                </a>
              ))}
            </p>
          )}
          <p className="muted small">
            Launched by <Addr address={by.data} />. Ascend's site only takes art from a coin's fee wallet, which here is the router, so this is
            where the coin's picture and links live. The picture is stored on chain.
          </p>
        </div>
      </div>
      {isSteward && !e && (
        <button
          className="btn btn-ghost"
          onClick={() => setEdit({ description: prof.description, website: prof.website, twitter: prof.twitter, telegram: prof.telegram, removePicture: false })}
        >
          Edit
        </button>
      )}
      {isSteward && e && (
        <div className="form-block">
          <PicturePicker value={e.picture} onChange={(b) => setEdit((cur) => cur && { ...cur, picture: b, removePicture: false })} current={hasPicture} />
          {hasPicture && !e.picture && (
            <label className="check">
              <input type="checkbox" checked={e.removePicture} onChange={(ev) => setEdit({ ...e, removePicture: ev.target.checked })} />
              Remove the current picture
            </label>
          )}
          <label className="field">
            <span className="field-label">Description</span>
            <textarea className="input textarea" rows={3} value={e.description} onChange={set("description")} />
          </label>
          <div className="form form-3">
            <label className="field">
              <span className="field-label">Website</span>
              <input className="input" value={e.website} onChange={set("website")} spellCheck={false} />
            </label>
            <label className="field">
              <span className="field-label">X</span>
              <input className="input" value={e.twitter} onChange={set("twitter")} spellCheck={false} />
            </label>
            <label className="field">
              <span className="field-label">Telegram</span>
              <input className="input" value={e.telegram} onChange={set("telegram")} spellCheck={false} />
            </label>
          </div>
          <div className="input-row">
            <TxButton
              headroom
              disabledReason={badEdit ? "Links have to start with https://, and stay short" : undefined}
              onDone={() => setEdit(undefined)}
              request={() => ({
                address: launcher,
                abi: ascendV5LauncherAbi,
                functionName: "setProfile",
                // an empty picture keeps the one on chain, unless it is being removed
                args: [
                  token,
                  {
                    image: e.picture ? bytesToHex(e.picture) : "0x",
                    description: e.description.trim(),
                    website: e.website.trim(),
                    twitter: e.twitter.trim(),
                    telegram: e.telegram.trim(),
                  },
                  !e.picture && e.removePicture,
                ],
              })}
            >
              Save
            </TxButton>
            <button className="btn btn-ghost" onClick={() => setEdit(undefined)}>
              Cancel
            </button>
          </div>
        </div>
      )}
    </Card>
  );
}
