import { useMemo, useState, type ReactNode } from "react";
import { useBalance, useConnection, useReadContract, useReadContracts } from "wagmi";
import { formatUnits, isAddress, type Address } from "viem";
import { exileAbi, mockERC20Abi, sandfallAbi } from "../abi";
import { TxButton, WithApproval } from "../components/Tx";
import { ConnectPrompt } from "../components/States";
import { Addr, Badge, Card, Empty, Row, Sym } from "../components/Ui";
import { useDeployment, ZERO } from "../lib/deployments";
import { date, duration, fmt } from "../lib/format";
import { POLL, useNow, usePageTitle } from "../lib/hooks";
import { useLodestarCore } from "../lib/monarchy";
import { NoDeployment } from "../components/States";
import { safeParse } from "./Exile";
import { UnlockChart, unlockedAt } from "../components/UnlockChart";
import { Slider } from "../components/Slider";
import { PageMark } from "../components/NavGlyphs";

const KINDS = ["Linear", "Steps", "Rolling"];
/** A step stream's badge, named by its step when it is one the form offers. */
function stepTitle(stepSeconds: number): string {
  return stepSeconds === 86400 ? "Daily steps" : stepSeconds === 7 * 86400 ? "Weekly steps" : stepSeconds === 30 * 86400 ? "Monthly steps" : "Steps";
}

export function SandfallPage() {
  usePageTitle("Sandfall");
  const d = useDeployment();
  const core = useLodestarCore();
  const { address } = useConnection();
  const sf = { address: d?.sandfall, abi: sandfallAbi } as const;
  const lists = useReadContracts({
    allowFailure: false,
    contracts: [
      { ...sf, functionName: "streamsOf", args: [address ?? ZERO] },
      { ...sf, functionName: "createdBy", args: [address ?? ZERO] },
    ],
    query: { enabled: !!d && !!address, ...POLL.query },
  });
  const [toMe, byMe] = lists.data ?? [[], []];
  const mine = useMemo(() => [...toMe].reverse().filter((id) => id !== core.treasuryStreamId), [toMe, core.treasuryStreamId]);
  const created = useMemo(() => [...byMe].reverse().filter((id) => !toMe.includes(id)), [byMe, toMe]);

  if (!d) return <NoDeployment />;
  return (
    <div className="page">
      <header className="page-head">
        <h1>
          <PageMark page="sandfall" />
          Sandfall
        </h1>
        <p className="muted">
          Vesting streams in any token or native HYPE. The creator decides at creation whether a stream can be
          cancelled, and every stream shows it. Streams can't be transferred.
        </p>
      </header>

      {core.treasuryStreamId !== undefined && (
        <Card
          title={
            <>
              <Sym s={core.tokenMeta?.symbol} /> Team Treasury
            </>
          }
          right={<span className="muted small">Fed by Lodestar on every distribute</span>}
        >
          <StreamCard sandfall={d.sandfall} id={core.treasuryStreamId} rollingTitle />
        </Card>
      )}

      <CreateStream sandfall={d.sandfall} quote={core.quote} token={core.token} quoteSymbol={core.quoteMeta?.symbol} tokenSymbol={core.tokenMeta?.symbol} />

      <Card title="Streams to me">
        {!address && <ConnectPrompt>What is vesting to you shows up here once a wallet is connected.</ConnectPrompt>}
        {address && !lists.data && (
          <div className="locks">
            <div className="lock skeleton" />
          </div>
        )}
        {address && lists.data && mine.length === 0 && <Empty title="Nothing vesting to you yet">Streams sent to this wallet will show up here, with what you can claim.</Empty>}
        <div className="locks">
          {mine.map((id) => (
            <StreamCard key={id.toString()} sandfall={d.sandfall} id={id} />
          ))}
        </div>
      </Card>

      {created.length > 0 && (
        <Card title="Streams I created">
          <div className="locks">
            {created.map((id) => (
              <StreamCard key={id.toString()} sandfall={d.sandfall} id={id} />
            ))}
          </div>
        </Card>
      )}
    </div>
  );
}

const DAY = 86400;
const UNITS = { hours: 3600, days: DAY, weeks: 7 * DAY, months: 30 * DAY, years: 365 * DAY } as const;
type Unit = keyof typeof UNITS;
const STEPS = { daily: DAY, weekly: 7 * DAY, monthly: 30 * DAY } as const;
type Freq = "continuous" | keyof typeof STEPS;
const FREQ_LABEL: Record<Freq, string> = { continuous: "every second", daily: "every day", weekly: "every week", monthly: "every month" };
const MONTH = 30 * DAY;
// common vesting lengths; months are 30 days, so monthly steps divide them evenly
const LENGTHS = [
  { v: 7 * DAY, title: "1 week" },
  { v: MONTH, title: "1 month" },
  { v: 3 * MONTH, title: "3 months" },
  { v: 6 * MONTH, title: "6 months" },
  { v: 12 * MONTH, title: "12 months" },
  { v: 24 * MONTH, title: "24 months" },
  { v: 48 * MONTH, title: "48 months" },
];
// the cliff slider snaps to these, keeping only the ones shorter than the stream
const CLIFFS = [0, 3600, 6 * 3600, 12 * 3600, DAY, 3 * DAY, 7 * DAY, 14 * DAY, MONTH, 2 * MONTH, 3 * MONTH, 6 * MONTH, 9 * MONTH, 12 * MONTH, 18 * MONTH, 24 * MONTH, 36 * MONTH];

/** A length of time in the largest whole unit that fits: "3 months", "2 weeks", "6 hours". */
export function spanLabel(sec: number): string {
  const units: [number, string][] = [
    [MONTH, "month"],
    [7 * DAY, "week"],
    [DAY, "day"],
    [3600, "hour"],
  ];
  for (const [u, name] of units) {
    if (sec >= u && sec % u === 0) {
      const n = sec / u;
      return `${n} ${name}${n === 1 ? "" : "s"}`;
    }
  }
  return duration(sec);
}

function Choice<T extends string | number>({ value, onChange, options, cols }: { value: T; onChange: (v: T) => void; options: { v: T; title: string; sub?: string; off?: boolean }[]; cols?: number }) {
  return (
    <div className={`choice choice-${cols ?? 3}`} role="radiogroup">
      {options.map((o) => (
        <button key={o.v} type="button" role="radio" aria-checked={value === o.v} className={value === o.v ? "on" : ""} disabled={o.off} onClick={() => onChange(o.v)}>
          <b>{o.title}</b>
          {o.sub && <span>{o.sub}</span>}
        </button>
      ))}
    </div>
  );
}

function Step({ n, title, children }: { n: number; title: string; children: ReactNode }) {
  return (
    <div className="create-step">
      <div className="create-step-h">
        <span className="create-step-n">{n}</span>
        {title}
      </div>
      {children}
    </div>
  );
}

function SpanInput({ label, value, unit, onValue, onUnit, min = 0 }: { label?: string; value: number; unit: Unit; onValue: (n: number) => void; onUnit: (u: Unit) => void; min?: number }) {
  return (
    <label className="field">
      {label && <span className="field-label">{label}</span>}
      <div className="input-row">
        <input className="input" type="number" min={min} value={value} onChange={(e) => onValue(Math.max(0, Number(e.target.value)))} />
        <select className="input input-unit" value={unit} onChange={(e) => onUnit(e.target.value as Unit)}>
          {Object.keys(UNITS).map((u) => (
            <option key={u} value={u}>
              {u}
            </option>
          ))}
        </select>
      </div>
    </label>
  );
}

/** Create a stream the way Streamflow lays it out: numbered steps on the left, a live summary and chart on the right. */
function CreateStream({ sandfall, quote, token, quoteSymbol, tokenSymbol }: { sandfall: Address; quote?: Address; token?: Address; quoteSymbol?: string; tokenSymbol?: string }) {
  const [assetChoice, setAssetChoice] = useState<"quote" | "token" | "native" | "other">("quote");
  const [other, setOther] = useState("");
  const [recipient, setRecipient] = useState("");
  const [amount, setAmount] = useState("");
  const [lengthPick, setLengthPick] = useState<number | "custom">(12 * MONTH);
  const [length, setLength] = useState(12);
  const [lengthUnit, setLengthUnit] = useState<Unit>("months");
  const [cliffWant, setCliffWant] = useState(0);
  const [freqWant, setFreqWant] = useState<Freq>("monthly");
  const [cancellable, setCancellable] = useState<"no" | "yes">("no");
  const now = useNow(15_000);

  const asset: Address | undefined =
    assetChoice === "quote" ? quote : assetChoice === "token" ? token : assetChoice === "native" ? ZERO : isAddress(other) ? other : undefined;
  const isNative = assetChoice === "native";
  const meta = useReadContracts({
    allowFailure: false,
    contracts: [
      { address: asset, abi: mockERC20Abi, functionName: "decimals" },
      { address: asset, abi: mockERC20Abi, functionName: "symbol" },
    ],
    query: { enabled: !!asset && !isNative, staleTime: Infinity },
  });
  const { address } = useConnection();
  const bal = useReadContract({ address: asset, abi: mockERC20Abi, functionName: "balanceOf", args: [address ?? ZERO], query: { enabled: !!asset && !isNative && !!address, ...POLL.query } });
  const native = useBalance({ address, query: { enabled: isNative && !!address, ...POLL.query } });
  const balance = isNative ? native.data?.value : bal.data;
  // Eleos, Kleos and Boxa coins pay HYPE dividends to whoever holds them, and Sandfall can't take HYPE that way,
  // so a coin vested here earns dividends nobody can ever claim
  const d = useDeployment();
  const harvest = useReadContract({ address: d?.exile, abi: exileAbi, functionName: "harvestOf", args: [asset ?? ZERO], query: { enabled: !!d?.pads && !!asset && !isNative, staleTime: 60_000 } });
  const paysDividends = !!harvest.data && harvest.data[0] !== 0n;
  const decimals = isNative ? 18 : Number(meta.data?.[0] ?? 18);
  const sym = isNative ? "HYPE" : (meta.data?.[1] ?? (assetChoice === "quote" ? quoteSymbol : assetChoice === "token" ? tokenSymbol : "")) ?? "";
  const value = safeParse(amount, decimals);

  // streams start a minute out so the transaction lands before the stream begins
  const startFor = (t: number) => t + 60;
  const lengthS = lengthPick === "custom" ? Math.round(length * UNITS[lengthUnit]) : lengthPick;
  // the cliff can only be picked from lengths shorter than the stream, so it always ends before the stream does
  const cliffOpts = CLIFFS.filter((c) => c < lengthS);
  const cliffIdx = Math.max(0, cliffOpts.filter((c) => c <= cliffWant).length - 1);
  const cliffS = cliffOpts[cliffIdx] ?? 0;
  // steps longer than the stream are greyed out; if the chosen one no longer fits, fall back to the next that does
  const fits = (f: Freq) => f === "continuous" || STEPS[f] <= lengthS;
  const order: Freq[] = ["monthly", "weekly", "daily", "continuous"];
  const freq: Freq = fits(freqWant) ? freqWant : (order.slice(order.indexOf(freqWant)).find(fits) ?? "continuous");
  const step = freq === "continuous" ? 0 : STEPS[freq];
  const start = startFor(now);
  const schedule = { start, cliff: start + cliffS, end: start + lengthS, step };

  const overBalance = balance !== undefined && value > balance;
  const reason = !asset
    ? "Pick a token"
    : !isAddress(recipient)
      ? "Enter a recipient"
      : value === 0n
        ? "Enter an amount"
        : overBalance
          ? "More than your balance"
          : lengthS === 0
            ? "Set how long it vests"
            : cliffS >= lengthS
              ? "The cliff must end before the stream does"
              : step > lengthS
                ? "Each unlock step must fit inside the stream"
                : undefined;

  const total = Number(formatUnits(value, decimals));
  const periods = step ? Math.ceil(lengthS / step) : 0;
  const atCliff = cliffS > 0 ? unlockedAt(schedule, schedule.cliff) : 0;

  const send = (
    <TxButton
      disabledReason={reason}
      request={() => {
        if (!asset) return undefined;
        const s = startFor(Math.floor(Date.now() / 1000));
        return {
          address: sandfall,
          abi: sandfallAbi,
          functionName: "createFixed",
          args: [asset, recipient as Address, value, BigInt(s), BigInt(s + cliffS), BigInt(s + lengthS), step, cancellable === "yes"],
          value: isNative ? value : undefined,
        };
      }}
      onDone={() => setAmount("")}
    >
      Create stream
    </TxButton>
  );

  return (
    <Card title="New vesting stream" className="card-flush">
      <div className="create">
        <div className="create-form">
          <Step n={1} title="Token">
            <Choice
              value={assetChoice}
              onChange={setAssetChoice}
              cols={4}
              options={[
                { v: "quote", title: quoteSymbol ?? "Quote", sub: "Fee asset" },
                { v: "token", title: tokenSymbol ?? "Token", sub: "This token" },
                { v: "native", title: "HYPE", sub: "Native" },
                { v: "other", title: "Other", sub: "Any ERC-20" },
              ]}
            />
            {assetChoice === "other" && <input className="input" aria-label="Token address" placeholder="Token address, 0x…" value={other} onChange={(e) => setOther(e.target.value.trim())} />}
            {d?.pads && !isNative && (
              <p className={paysDividends ? "warn small" : "muted small"}>
                {paysDividends
                  ? "Don't vest this coin here. It pays its holders HYPE dividends, and the dividends earned by coins sitting in Sandfall can never be claimed by anyone. Lock it in Exile instead, where they reach the lockers."
                  : "Don't vest Eleos, Kleos or Boxa coins here: they pay holders HYPE dividends, and the dividends earned by coins sitting in Sandfall can never be claimed. Lock them in Exile instead."}
              </p>
            )}
          </Step>

          <Step n={2} title="Recipient and amount">
            <label className="field">
              <span className="field-label">Recipient wallet</span>
              <input className="input" placeholder="0x…" value={recipient} onChange={(e) => setRecipient(e.target.value.trim())} />
            </label>
            <label className="field">
              <span className="field-label">Amount{sym ? ` (${sym})` : ""}</span>
              <input className="input" inputMode="decimal" placeholder="0.0" value={amount} onChange={(e) => setAmount(e.target.value)} />
            </label>
          </Step>

          <Step n={3} title="Schedule">
            <span className="field-label">Vests over</span>
            <Choice
              value={lengthPick}
              onChange={setLengthPick}
              cols={4}
              options={[...LENGTHS.map((l) => ({ v: l.v as number | "custom", title: l.title })), { v: "custom", title: "Custom" }]}
            />
            {lengthPick === "custom" && <SpanInput label="Custom length" value={length} unit={lengthUnit} onValue={setLength} onUnit={setLengthUnit} min={1} />}
            <CliffSlider options={cliffOpts} index={cliffIdx} length={lengthS} onPick={setCliffWant} />
            <span className="field-label">Unlocks</span>
            <Choice
              value={freq}
              onChange={setFreqWant}
              cols={4}
              options={[
                { v: "continuous", title: "Linear", sub: "Every second" },
                { v: "daily", title: "Daily", sub: "Steps", off: !fits("daily") },
                { v: "weekly", title: "Weekly", sub: "Steps", off: !fits("weekly") },
                { v: "monthly", title: "Monthly", sub: "30 day steps", off: !fits("monthly") },
              ]}
            />
          </Step>

          <Step n={4} title="Who can cancel">
            <Choice
              value={cancellable}
              onChange={setCancellable}
              cols={2}
              options={[
                { v: "no", title: "Nobody", sub: "Final once created" },
                { v: "yes", title: "Only me", sub: "Unvested part returns to me" },
              ]}
            />
            <p className={cancellable === "yes" ? "warn small" : "muted small"}>
              {cancellable === "yes"
                ? "What has vested stays claimable by the recipient. They see an amber Cancellable badge on the stream."
                : "Nobody can stop or change this stream after it is created, not even you."}
            </p>
          </Step>
        </div>

        <aside className="create-side">
          <h5>Unlock schedule</h5>
          <UnlockChart schedule={schedule} total={total || 100} />
          <div className="lock-body">
            <Row k="Recipient gets" v={value ? `${fmt(value, decimals)} ${sym}` : "…"} />
            <Row k="Starts" v={date(start)} />
            {cliffS > 0 && <Row k="At the cliff" v={`${Math.round(atCliff * 100)}% on ${date(schedule.cliff)}`} />}
            <Row k="Then" v={step ? `${total ? (total / periods).toLocaleString(undefined, { maximumFractionDigits: 4 }) : "1/" + periods} ${total ? sym : "of it"} ${FREQ_LABEL[freq]}` : `a little ${FREQ_LABEL[freq]}`} />
            <Row k="Fully vested" v={date(schedule.end)} />
            <Row k="Cancellable" v={cancellable === "yes" ? <Badge tone="amber">By me</Badge> : <Badge tone="green">No</Badge>} />
          </div>
          {isNative ? send : <WithApproval token={asset} spender={sandfall} amount={reason ? 0n : value}>{send}</WithApproval>}
        </aside>
      </div>
    </Card>
  );
}

/** A share of the stream as a whole percent, with "under 1%" for the shortest cliffs on long streams. */
const share = (f: number) => (f > 0 && f < 0.01 ? "Under 1%" : `${Math.round(f * 100)}%`);

/** The cliff as a slider over lengths shorter than the stream, with a few of them marked underneath. */
function CliffSlider({ options, index, length, onPick }: { options: number[]; index: number; length: number; onPick: (sec: number) => void }) {
  const last = options.length - 1;
  const value = options[index] ?? 0;
  // mark at most five stops, spread along the slider, always including both ends
  const marks = last <= 4 ? options.map((_, i) => i) : [0, Math.round(last / 4), Math.round(last / 2), Math.round((3 * last) / 4), last];
  return (
    <div className="dur cliff">
      <div className="dur-top">
        <span className="field-label">Cliff</span>
        <span className="dur-read">
          <span className="dur-value">{value ? spanLabel(value) : "None"}</span>
          <span className="dur-note">{value ? `${share(value / length)} of the stream, then it starts unlocking` : "Starts unlocking right away"}</span>
        </span>
      </div>
      <Slider max={Math.max(1, last)} values={[index]} disabled={last === 0} onChange={(_, i) => onPick(options[i] ?? 0)} labels={["Cliff length"]} valueTexts={[value ? spanLabel(value) : "No cliff"]} />
      <div className="dur-marks">
        {[...new Set(marks)].map((i) => (
          <button key={i} type="button" className={`dur-mark ${i === index ? "on" : ""}`} style={{ left: `${last ? (i / last) * 100 : 0}%` }} onClick={() => onPick(options[i])}>
            {options[i] ? spanLabel(options[i]) : "None"}
          </button>
        ))}
      </div>
    </div>
  );
}

function StreamCard({ sandfall, id, rollingTitle }: { sandfall: Address; id: bigint; rollingTitle?: boolean }) {
  const { address } = useConnection();
  const sf = { address: sandfall, abi: sandfallAbi } as const;
  const r = useReadContracts({
    allowFailure: false,
    contracts: [
      { ...sf, functionName: "stream", args: [id] },
      { ...sf, functionName: "claimable", args: [id] },
      { ...sf, functionName: "vestedAmount", args: [id] },
    ],
    query: POLL.query,
  });
  const [s, claimable, vested] = r.data ?? [];
  const isNative = s?.asset === ZERO;
  const meta = useReadContracts({
    allowFailure: false,
    contracts: [
      { address: s?.asset, abi: mockERC20Abi, functionName: "decimals" },
      { address: s?.asset, abi: mockERC20Abi, functionName: "symbol" },
    ],
    query: { enabled: !!s && !isNative, staleTime: Infinity },
  });
  const now = useNow();
  if (!s) return <div className="lock skeleton" />;
  const [dec, sym] = isNative ? [18, "HYPE"] : (meta.data ?? [18, ""]);
  const decimals = Number(dec);
  const total = s.total;
  const progress = total > 0n ? Number(((vested ?? 0n) * 10_000n) / total) / 100 : 0;
  const rolling = s.kind === 2;
  const finish = rolling ? Number(s.periodFinish) : Number(s.end);

  return (
    <div className="lock">
      <div className="lock-top">
        <div className="lock-badges">
          <Badge tone="silver">{rollingTitle && rolling ? `Rolling ${Number(s.window) / 86400} day stream` : s.kind === 1 ? stepTitle(Number(s.stepSeconds)) : KINDS[s.kind]}</Badge>
          {s.cancelled ? <Badge tone="red">Cancelled</Badge> : s.cancellable ? <Badge tone="amber">Cancellable</Badge> : <Badge tone="green">Not cancellable</Badge>}
        </div>
        <span className="muted mono">#{id.toString()}</span>
      </div>
      <div className="progress">
        <div className="progress-bar" style={{ width: `${progress}%` }} />
      </div>
      {!rolling && !s.cancelled && (
        <UnlockChart
          height={130}
          schedule={{ start: Number(s.start), cliff: Number(s.cliff), end: Number(s.end), step: Number(s.stepSeconds) }}
          total={Number(formatUnits(total, decimals))}
          now={now}
        />
      )}
      <div className="lock-body">
        <Row k="Vested" v={`${fmt(vested, decimals, 4)} / ${fmt(total, decimals)} ${sym}`} />
        <Row k="Claimed" v={`${fmt(s.claimed, decimals, 4)} ${sym}`} />
        <Row k="From" v={<Addr address={s.creator} />} />
        <Row k="To" v={<Addr address={s.recipient} />} />
        {!rolling && Number(s.cliff) > Number(s.start) && <Row k="Cliff" v={date(Number(s.cliff))} />}
        {rolling ? (
          <Row k="Window" v={`${Number(s.window) / 86400} days, refilled by each top-up`} />
        ) : s.cancelled ? (
          // cancel stops vesting: what had vested stays claimable, the rest went back to the creator
          <Row k="Vesting" v="Stopped when it was cancelled" />
        ) : (
          <Row k="Fully vested" v={finish > now ? `in ${duration(finish - now)}` : date(finish)} />
        )}
        {rolling && finish > now && <Row k="Current window ends" v={`in ${duration(finish - now)}`} />}
      </div>
      <div className="lock-actions">
        {address === s.recipient && (
          <TxButton className="btn btn-sm" disabledReason={!claimable ? "Nothing to claim yet" : undefined} request={() => ({ ...sf, functionName: "claim", args: [id] })}>
            Claim {fmt(claimable, decimals, 4)} {sym}
          </TxButton>
        )}
        {address === s.creator && s.cancellable && !s.cancelled && (
          <TxButton className="btn btn-sm btn-danger" request={() => ({ ...sf, functionName: "cancel", args: [id] })}>
            Cancel stream
          </TxButton>
        )}
        {address === s.creator && !s.cancellable && (
          <button className="btn btn-sm btn-ghost" disabled title="This stream was created as not cancellable">
            Cancel (locked)
          </button>
        )}
      </div>
    </div>
  );
}
