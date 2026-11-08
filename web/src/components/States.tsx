import { useBlockNumber, useChainId, useConnection } from "wagmi";
import { chainName, elysiumMainnet } from "../lib/chains";
import { useNetwork } from "../lib/network";
import { SwitchButton } from "./Connect";
import { Card, Empty } from "./Ui";

/** A slim strip above the nav: which network this is, and that tokens here are test tokens. */
export function TestnetStrip() {
  // the chain the app reads from: the wallet's when it sits on a supported one, otherwise the target
  const chainId = useChainId();
  const local = chainId === 31337;
  if (chainId === elysiumMainnet.id)
    return (
      <div className="strip" role="note">
        <span className="strip-dot" />
        <span>
          <b>Elysium mainnet.</b> Coins on Eleos, Kleos, Boxa and Ascend, with real value.
        </span>
      </div>
    );
  return (
    <div className="strip" role="note">
      <span className="strip-dot" />
      {local ? (
        <span>
          <b>Local demo chain.</b> Mock Ascend on anvil, for development.
        </span>
      ) : (
        <span>
          <b>Elysium testnet.</b> Test tokens only, with no real value.
        </span>
      )}
    </div>
  );
}

/** Shown under the nav when the wallet is on a network Monarchy doesn't run on, or the RPC is down. */
export function NetworkNotice() {
  const { wrongNetwork, walletChainId, target } = useNetwork();
  const block = useBlockNumber({ chainId: target.id, query: { refetchInterval: 15_000, retry: 1 } });
  if (wrongNetwork) {
    return (
      <div className="notice notice-warn" role="alert">
        <div>
          <b>Wrong network.</b> Your wallet is on {chainName(walletChainId)}. Monarchy runs on {chainName(target.id)}.
        </div>
        <SwitchButton className="btn-sm" />
      </div>
    );
  }
  if (block.isError && block.data === undefined) {
    return (
      <div className="notice" role="status">
        <div>
          <b>Can't reach {chainName(target.id)} right now.</b> Numbers will fill in as soon as the network answers.
        </div>
      </div>
    );
  }
  return null;
}

/** For pages that need a Monarchy deployment on the current chain. */
export function NoDeployment({ inline }: { inline?: boolean }) {
  const { isConnected } = useConnection();
  const { target } = useNetwork();
  const card = (
      <Card>
        <Empty
          title="Monarchy isn't on this network"
          action={isConnected ? <SwitchButton /> : <ConnectHint />}
        >
          Switch your wallet to {chainName(target.id)} to use Lodestar, Exile and Sandfall.
        </Empty>
      </Card>
  );
  return inline ? card : <div className="page">{card}</div>;
}

/** Empty state for wallet-specific lists. The only connect button is the one at the top right. */
export function ConnectPrompt({ children }: { children: string }) {
  return (
    <Empty title="No wallet connected" action={<ConnectHint />}>
      {children}
    </Empty>
  );
}

/** Points at the connect button in the top right corner. */
export function ConnectHint() {
  return (
    <span className="connect-hint">
      Connect wallet at the top right <span aria-hidden="true">↗</span>
    </span>
  );
}
