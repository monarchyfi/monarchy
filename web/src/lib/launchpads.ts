import { concat, getContractAddress, type Address, type Hex } from "viem";

/** The launchpads on Elysium mainnet Monarchy routes for. The order is the one the forge scripts use. */
export const PAD_KEYS = ["eleos", "kleos", "boxa"] as const;
export type PadKey = (typeof PAD_KEYS)[number];

export type PadInfo = {
  key: PadKey;
  name: string;
  site: string;
  /** Boxa proposes the router and the router accepts; Eleos and Kleos hand the role over in one call. */
  twoStep: boolean;
};

export const PADS: Record<PadKey, PadInfo> = {
  eleos: { key: "eleos", name: "Eleos", site: "https://eleos.fun", twoStep: false },
  kleos: { key: "kleos", name: "Kleos", site: "https://thekleos.xyz", twoStep: false },
  boxa: { key: "boxa", name: "Boxa", site: "https://boxa.club", twoStep: true },
};

/** One launchpad's Monarchy contracts, as DeployLaunchpads records them. */
export type PadDeployment = {
  source: Address; // the launchpad's fee-source adapter
  factory: Address; // its LodestarFactory
  poolManagers: Address[]; // the Uniswap v4 pool managers its hooks use
  swappers: Address[]; // one V4Swapper per pool manager, in the same order
};

/** deployments/launchpads/<chainId>.json: one shared core and a factory per launchpad. The routers aren't listed;
 * each factory's allLodestars is the list. */
export type LaunchpadsDeployment = {
  chainId: number;
  owner: Address;
  exile: Address;
  sandfall: Address;
  lodestarImpl: Address;
  observer: Address;
  startBlock: number;
  launchpads: Partial<Record<PadKey, PadDeployment>>;
};

// rehearsal.json is a local fork's file (tools/rehearse-launchpads.sh); a dev server only reads it when asked to
// with VITE_LAUNCHPADS_REHEARSAL=1, and then in place of the real one.
const files = import.meta.glob<LaunchpadsDeployment>("../../../deployments/launchpads/*.json", { eager: true, import: "default" });
const rehearsal = import.meta.env.DEV && !!import.meta.env.VITE_LAUNCHPADS_REHEARSAL;

export const launchpadsByChain: Record<number, LaunchpadsDeployment> = {};
for (const [path, d] of Object.entries(files)) {
  if (path.endsWith("/rehearsal.json") !== rehearsal) continue;
  launchpadsByChain[Number(d.chainId)] = { ...d, chainId: Number(d.chainId), startBlock: Number(d.startBlock) };
}

/** The launchpads with a factory on this deployment, in the scripts' order. */
export function padsOf(d?: LaunchpadsDeployment): { info: PadInfo; pad: PadDeployment }[] {
  if (!d) return [];
  return PAD_KEYS.flatMap((k) => {
    const pad = d.launchpads[k];
    return pad && pad.factory ? [{ info: PADS[k], pad }] : [];
  });
}

/** The V4Swapper a launchpad keeps for a pool manager, or undefined. */
export function swapperFor(pad: PadDeployment, poolManager?: Address): Address | undefined {
  if (!poolManager) return undefined;
  const i = pad.poolManagers.findIndex((p) => p.toLowerCase() === poolManager.toLowerCase());
  const s = i >= 0 ? pad.swappers[i] : undefined;
  return s && !/^0x0{40}$/i.test(s) ? s : undefined;
}

/** The address a factory's router for `poolId` has, worked out here rather than asked of the RPC: LodestarFactory
 * deploys each router as an OpenZeppelin minimal clone of the shared implementation with CREATE2, salted with the
 * pool id. The page hands the creator role only to this address, so a node that lies about `predict` or
 * `lodestarOf` can't redirect it. Both inputs come from the committed deployments file. */
export function routerAddress(lodestarImpl: Address, factory: Address, poolId: Hex): Address {
  const initCode = concat(["0x3d602d80600a3d3981f3363d3d373d3d3d363d73", lodestarImpl, "0x5af43d82803e903d91602b57fd5bf3"]);
  return getContractAddress({ opcode: "CREATE2", from: factory, salt: poolId, bytecode: initCode });
}
