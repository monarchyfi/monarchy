import { useChainId } from "wagmi";
import type { Address, Hex } from "viem";
import { launchpadsByChain, type LaunchpadsDeployment } from "./launchpads";

export type Deployment = {
  chainId: number;
  mode: "real" | "mock" | "launchpads";
  launchpad: Address;
  desk: Address;
  poolManager: Address;
  vault: Address;
  quote: Address;
  exile: Address;
  sandfall: Address;
  lodestarImpl: Address;
  factory: Address;
  swapper: Address;
  token: Address;
  poolId: Hex;
  lodestar: Address;
  startBlock: number;
  /** Eleos, Kleos, Boxa and Ascend v5 on this chain (deployments/launchpads/<chainId>.json), which share this Exile and Sandfall. */
  pads?: LaunchpadsDeployment;
};

export const ZERO = "0x0000000000000000000000000000000000000000" as Address;

// deployments/<chainId>.json is written by the forge scripts; missing chains just aren't listed.
const files = import.meta.glob<Deployment>("../../../deployments/*.json", { eager: true, import: "default" });
const byChain: Record<number, Deployment> = {};
for (const d of Object.values(files)) byChain[d.chainId] = d;

// A chain with only the launchpads' deployment (Elysium mainnet, where Ascend v5 is one of the launchpads) still gets
// one, built from the shared core, so Exile, Sandfall and the Garden work there. It has no Ascend testnet launchpad and no featured
// token: every Ascend-only field is zero.
for (const pads of Object.values(launchpadsByChain)) {
  const d = byChain[pads.chainId];
  if (d) {
    byChain[pads.chainId] = { ...d, pads };
    continue;
  }
  byChain[pads.chainId] = {
    chainId: pads.chainId,
    mode: "launchpads",
    launchpad: ZERO,
    desk: ZERO,
    poolManager: ZERO,
    vault: ZERO,
    quote: ZERO, // native HYPE
    exile: pads.exile,
    sandfall: pads.sandfall,
    lodestarImpl: pads.lodestarImpl,
    factory: ZERO,
    swapper: ZERO,
    token: ZERO,
    poolId: "0x0000000000000000000000000000000000000000000000000000000000000000",
    lodestar: ZERO,
    startBlock: pads.startBlock,
    pads,
  };
}

export function useDeployment(): Deployment | undefined {
  const chainId = useChainId();
  return byChain[chainId];
}

export function deployedChainIds(): number[] {
  return Object.keys(byChain).map(Number);
}

export function isSet(a?: string): a is Address {
  return !!a && a !== ZERO;
}
