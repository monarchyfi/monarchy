import { defineChain } from "viem";
import { anvil } from "viem/chains";

export const elysiumTestnet = defineChain({
  id: 99801,
  name: "Elysium Testnet",
  nativeCurrency: { name: "HYPE", symbol: "HYPE", decimals: 18 },
  rpcUrls: { default: { http: ["https://testnet-rpc.elysium.kinetiq.xyz"] } },
  blockExplorers: {
    default: { name: "Elysium Explorer", url: "https://elysium.kinetiq.xyz/testnet-explorer" },
  },
  contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } },
  testnet: true,
});

/** Elysium mainnet, where Ascend v5, Volta, ElysPump, Boxa, Kleos and Montra run. VITE_MAINNET_RPC_URL points it at another node (a local
 * anvil fork for a rehearsal, say). */
export const elysiumMainnet = defineChain({
  id: 99901,
  name: "Elysium",
  nativeCurrency: { name: "HYPE", symbol: "HYPE", decimals: 18 },
  rpcUrls: { default: { http: [import.meta.env.VITE_MAINNET_RPC_URL || "https://rpc.eleos.fun"] } },
  blockExplorers: { default: { name: "Elysium Explore", url: "https://elysiumexplore.com" } },
  contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } },
});

export const localChain = anvil;

const explorers: Record<number, string> = {
  [elysiumTestnet.id]: elysiumTestnet.blockExplorers.default.url,
  [elysiumMainnet.id]: elysiumMainnet.blockExplorers.default.url,
};

export function explorerTx(chainId: number, hash: string): string | undefined {
  return explorers[chainId] && `${explorers[chainId]}/tx/${hash}`;
}

export function explorerAddress(chainId: number, address: string): string | undefined {
  return explorers[chainId] && `${explorers[chainId]}/address/${address}`;
}

/** A short, human name for a chain id. */
export function chainName(chainId: number | undefined): string {
  if (chainId === elysiumTestnet.id) return "Elysium testnet";
  if (chainId === elysiumMainnet.id) return "Elysium mainnet";
  if (chainId === localChain.id) return "Local demo chain";
  if (chainId === 1) return "Ethereum";
  if (chainId === 999) return "HyperEVM";
  return chainId ? `Chain ${chainId}` : "an unknown network";
}
