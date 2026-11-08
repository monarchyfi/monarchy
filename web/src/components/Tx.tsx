import { Fragment, useEffect, useId, useState, type CSSProperties, type ReactNode } from "react";
import { useChainId, useConnection, usePublicClient, useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import type { Abi, Address } from "viem";
import { useReadContract } from "wagmi";
import { mockERC20Abi } from "../abi";
import { chainName, explorerTx } from "../lib/chains";
import { short } from "../lib/format";
import { useNetwork } from "../lib/network";
import { Spinner } from "./Ui";

// Loose on purpose: each call site passes a typed abi + functionName; wagmi checks args there.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type WriteRequest = { address: Address; abi: Abi; functionName: string; args?: readonly unknown[]; value?: bigint; gas?: bigint } & Record<string, any>;

type Props = {
  /** May be async, for a step before the transaction (a picture upload); `preparing` labels the button meanwhile. */
  request: () => WriteRequest | undefined | Promise<WriteRequest | undefined>;
  preparing?: ReactNode;
  children: ReactNode;
  disabledReason?: string;
  onDone?: () => void;
  className?: string;
  /** Send 30% more gas than the estimate, like the keeper. For calls whose cost moves between the estimate and the
   * block: an Exile lock that lands in a later hour bucket than it was estimated in can run out of gas otherwise. */
  headroom?: boolean;
  /** Never send less gas than this. For a call with an inner step that checks its own gas floor and is allowed to
   * fail: a wallet's estimate finds the least gas at which the transaction succeeds, which is with that step
   * skipped (an Ascend v5 escrow refuses to pay out with less than about 600,000 gas left). */
  minGas?: bigint;
};

/** The extra gas `headroom` adds, in percent of the estimate. */
const HEADROOM_PCT = 30n;

/** Sends one transaction and shows pending / confirmed / error, with an explorer link when there is one. */
export function TxButton({ request, children, disabledReason, onDone, className, headroom, minGas, preparing }: Props) {
  const chainId = useChainId();
  const { isConnected, address } = useConnection();
  const client = usePublicClient({ chainId });
  const { wrongNetwork, target } = useNetwork();
  const qc = useQueryClient();
  const write = useWriteContract();
  const [hash, setHash] = useState<`0x${string}`>();
  const receipt = useWaitForTransactionReceipt({ hash });
  const [error, setError] = useState<string>();
  const [building, setBuilding] = useState(false);
  const tipId = useId();

  useEffect(() => {
    if (receipt.isSuccess) {
      qc.invalidateQueries();
      onDone?.();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [receipt.isSuccess]);

  const busy = building || write.isPending || (!!hash && receipt.isLoading);
  // Nothing is sent while the wallet sits on another chain; the notice under the nav offers the switch.
  const reason = !isConnected ? "Connect first" : wrongNetwork ? `Switch your wallet to ${chainName(target.id)} first` : disabledReason;
  // why the button is grey shows as a popup over it, on hover or on a tap
  const [tapped, setTapped] = useState(false);
  useEffect(() => {
    if (!tapped) return;
    const t = setTimeout(() => setTapped(false), 2200);
    return () => clearTimeout(t);
  }, [tapped]);
  const tip = reason && !busy ? reason : undefined;

  async function send() {
    setError(undefined);
    setHash(undefined);
    try {
      // inside the try: a request built from a bad input (a fraction where whole seconds go) throws here
      const built = request();
      let req: WriteRequest | undefined;
      if (built instanceof Promise) {
        setBuilding(true);
        try {
          req = await built;
        } finally {
          setBuilding(false);
        }
      } else req = built;
      if (!req) return;
      if ((headroom || minGas) && req.gas === undefined && client && address) {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const est = await client.estimateContractGas({ ...req, account: address } as any);
        const gas = headroom ? (est * (100n + HEADROOM_PCT)) / 100n : est;
        req = { ...req, gas: minGas && gas < minGas ? minGas : gas };
      }
      // Pinned to the chain the page reads from: if the wallet moved in the meantime, wagmi refuses to send
      // instead of sending the transaction somewhere else.
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const h = await write.mutateAsync({ chainId, ...req } as any);
      setHash(h);
    } catch (e) {
      setError(shortError(e));
    }
  }

  const link = hash ? explorerTx(chainId, hash) : undefined;
  const txRef = hash && (
    link ? (
      <a className="tx-link" href={link} target="_blank" rel="noreferrer">
        View transaction <span aria-hidden="true">↗</span>
      </a>
    ) : (
      <span className="mono muted" title={hash}>
        {short(hash)}
      </span>
    )
  );
  const done = !!hash && receipt.isSuccess;
  return (
    <div className="tx">
      <span className={`tx-btn ${tip ? "has-tip" : ""} ${tapped ? "show-tip" : ""}`} onPointerDown={() => tip && setTapped(true)}>
        <button
          className={`${className ?? "btn"} ${busy ? "is-busy" : ""} ${done && !busy ? "is-done" : ""}`}
          disabled={!!reason || busy}
          onClick={send}
          aria-busy={busy}
          aria-describedby={tip ? tipId : undefined}
        >
          {building ? (
            <>
              <Spinner /> {preparing ?? "Preparing"}
            </>
          ) : write.isPending ? (
            <>
              <Spinner /> Confirm in wallet
            </>
          ) : busy ? (
            <>
              <Spinner /> Confirming
            </>
          ) : (
            children
          )}
        </button>
        {tip && (
          <span className="tip" role="tooltip" id={tipId} key={tip} style={{ "--n": tip.length + (isConnected ? 0 : 2) } as CSSProperties}>
            <span className="tip-text">
              {tip}
              {!isConnected && <span aria-hidden="true"> ↗</span>}
            </span>
          </span>
        )}
      </span>
      {busy && !write.isPending && hash && <span className="tx-pending">Waiting for the block. {txRef}</span>}
      {done && (
        <span className="tx-ok" role="status">
          <span aria-hidden="true">✓</span> Confirmed. {txRef}
        </span>
      )}
      {receipt.isError && (
        <span className="tx-err" role="alert">
          Transaction failed. {txRef}
        </span>
      )}
      {error && (
        <span className="tx-err" role="alert">
          {error}
        </span>
      )}
    </div>
  );
}

/**
 * Shows an Approve button until `spender` may move `amount` of `token`, then the action button.
 * The approval is for exactly `amount`, never an unlimited allowance.
 */
export function WithApproval({
  token,
  spender,
  amount,
  children,
}: {
  token?: Address;
  spender?: Address;
  amount: bigint;
  children: ReactNode;
}) {
  const { address } = useConnection();
  const allowance = useReadContract({
    address: token,
    abi: mockERC20Abi,
    functionName: "allowance",
    args: address && spender ? [address, spender] : undefined,
    query: { enabled: !!token && !!address && !!spender, refetchInterval: 2000 },
  });
  const enough = allowance.data !== undefined && allowance.data >= amount;
  // The action spends the exact allowance, so the next poll can read 0 before its receipt is in. Remember
  // that this amount was approved, so the action button stays up to show its own result.
  const [approvedFor, setApprovedFor] = useState<bigint>();
  useEffect(() => {
    if (enough && amount > 0n) setApprovedFor(amount);
    else if (approvedFor !== undefined && approvedFor !== amount) setApprovedFor(undefined);
  }, [enough, amount, approvedFor]);
  // With nothing to approve yet, the action button shows why it is off ("Enter an amount", "Enter a recipient").
  // The keys keep the Approve button and the action button apart: without them React reuses one for the
  // other, and the action button opens already "Confirmed" with the approval's hash (and fires its onDone).
  if (!token || !spender || amount === 0n || enough || approvedFor === amount) return <Fragment key="action">{children}</Fragment>;
  return (
    <TxButton
      key="approve"
      request={() => ({ address: token, abi: mockERC20Abi, functionName: "approve", args: [spender, amount] })}
    >
      Approve
    </TxButton>
  );
}

export function shortError(e: unknown): string {
  const err = e as { shortMessage?: string; message?: string; cause?: { reason?: string; data?: { errorName?: string } } };
  const name = err.cause?.data?.errorName;
  if (name) return name;
  const msg = err.shortMessage ?? err.message?.split("\n")[0] ?? "Something went wrong.";
  if (/user (rejected|denied)/i.test(msg)) return "You cancelled it in your wallet.";
  return msg;
}
