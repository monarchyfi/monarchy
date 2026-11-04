import { createConfig, createStorage, http } from "wagmi";
import { injected, mock } from "wagmi/connectors";
import type { Chain } from "viem";
import { elysiumMainnet, elysiumTestnet, localChain } from "./chains";
import { deployedChainIds } from "./deployments";

const deployed = deployedChainIds();

// The chain the app reads before a wallet connects, and the one it asks wallets to switch to.
// Production always targets Elysium testnet. A dev server targets the local anvil demo when
// deployments/31337.json exists. VITE_CHAIN_ID overrides both (for example to test a build locally).
const envChain = Number(import.meta.env.VITE_CHAIN_ID) || undefined;
export const TARGET_CHAIN_ID: number =
  envChain ?? (import.meta.env.DEV && deployed.includes(localChain.id) ? localChain.id : elysiumTestnet.id);

const known: Chain[] = [elysiumTestnet, elysiumMainnet, localChain];
export const targetChain: Chain = known.find((c) => c.id === TARGET_CHAIN_ID) ?? elysiumTestnet;
// Other chains are only listed when there is a Monarchy deployment for them.
const others = known.filter((c) => c.id !== targetChain.id && deployed.includes(c.id));
const chains = [targetChain, ...others] as [Chain, ...Chain[]];

// `?mock` on a dev server connects anvil's first account without a browser wallet (for local testing).
export const useMock = import.meta.env.DEV && typeof location !== "undefined" && new URLSearchParams(location.search).has("mock");

const browserStorage = typeof window !== "undefined" ? window.localStorage : undefined;

export const config = createConfig({
  chains,
  connectors: useMock
    ? [mock({ accounts: ["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"], features: { reconnect: true } })]
    : [injected()],
  transports: {
    [elysiumTestnet.id]: http(),
    [elysiumMainnet.id]: http(),
    [localChain.id]: http("http://127.0.0.1:8545"),
  },
  // A separate key on the dev server, so a chain remembered from the live site doesn't override the local default.
  storage: createStorage({ storage: browserStorage, key: import.meta.env.DEV ? "monarchy-dev" : "wagmi" }),
});

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}
