import { concat, encodeAbiParameters, getContractAddress, keccak256, type Address, type Hex } from "viem";

/** The launchpads on Elysium mainnet Monarchy routes for. The order is the one the forge scripts use. */
export const PAD_KEYS = ["eleos", "kleos", "boxa", "ascend"] as const;
export type PadKey = (typeof PAD_KEYS)[number];

export type QuoteInfo = { address: Address; symbol: string };

export type PadInfo = {
  key: PadKey;
  name: string;
  site: string;
  /** Boxa and Ascend propose the router and the router accepts; Eleos and Kleos hand the role over in one call. */
  twoStep: boolean;
  /** Ascend v5: the router can only accept 48 hours after it was proposed, so anyone accepts later. */
  delayed?: boolean;
  /** The ERC-20s the launchpad's pools are quoted in. Unset: native HYPE. */
  quotes?: QuoteInfo[];
};

/** Ascend v5's launchpad, the hook of every v5 launch pool (docs/ascend-v5.md). */
export const ASCEND_V5_LAUNCHPAD: Address = "0xe0dEF4221b9840a610D4e7d55812a79A6431a8eC";

/** An Ascend v5 launch pool's id, worked out here like the router address: Uniswap v4's pool key of the sorted pair,
 * the dynamic-fee flag, tick spacing 200 and the launchpad as hook (AscendV5FeeSource.poolKey). */
export function ascendPoolId(token: Address, quote: Address): Hex {
  const [c0, c1] = BigInt(token) < BigInt(quote) ? [token, quote] : [quote, token];
  return keccak256(
    encodeAbiParameters(
      [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
      [c0, c1, 0x800000, 200, ASCEND_V5_LAUNCHPAD],
    ),
  );
}

/** Ascend v5's quote assets (docs/ascend-v5.md). A HYPE pair is quoted in WHYPE. */
export const ASCEND_QUOTES: QuoteInfo[] = [
  { address: "0xbA876237B0F021A6c6D852d6c26E107997cC5E81", symbol: "WHYPE" },
  { address: "0xb47c4C8F73F009CC0C0d3f92B388d13E293F0B65", symbol: "USDC" },
  { address: "0xe45a355d9e9cAd2aD85F2d03E3eE3102A036acF0", symbol: "KNTQ" },
];

export const PADS: Record<PadKey, PadInfo> = {
  eleos: { key: "eleos", name: "Eleos", site: "https://eleos.fun", twoStep: false },
  kleos: { key: "kleos", name: "Kleos", site: "https://thekleos.xyz", twoStep: false },
  boxa: { key: "boxa", name: "Boxa", site: "https://boxa.club", twoStep: true },
  ascend: { key: "ascend", name: "Ascend", site: "https://ascendlaunch.xyz", twoStep: true, delayed: true, quotes: ASCEND_QUOTES },
};

/** "Eleos, Kleos, Boxa or Ascend", for the pads a deployment has. */
export function padNames(list: { info: PadInfo }[], last = "or"): string {
  const names = list.map(({ info }) => info.name);
  return names.length < 2 ? (names[0] ?? "") : `${names.slice(0, -1).join(", ")} ${last} ${names[names.length - 1]}`;
}

/** One launchpad's Monarchy contracts, as DeployLaunchpads records them. */
export type PadDeployment = {
  source: Address; // the launchpad's fee-source adapter
  factory: Address; // its LodestarFactory
  poolManagers: Address[]; // the Uniswap v4 pool managers its hooks use
  swappers: Address[]; // one buyback swapper per pool manager, in the same order (an AscendV5Swapper on Ascend)
  /** Ascend v5 only: the AscendV5Launcher, which launches a new coin with its router as fee owner from the first trade */
  launcher?: Address;
};

/** Ascend's coin page. */
export const ascendCoinUrl = (token: string) => `https://app.ascendlaunch.xyz/tokens/${token}`;

/** A link a creator typed, if it is safe to show: https only, or ipfs:// (shown through a public gateway). */
export function safeLink(raw: string | undefined, allowIpfs = false): string | undefined {
  const v = raw?.trim();
  if (!v) return undefined;
  if (allowIpfs && /^ipfs:\/\/[A-Za-z0-9./_-]+$/.test(v)) return `https://ipfs.io/ipfs/${v.slice(7)}`;
  try {
    const u = new URL(v);
    return u.protocol === "https:" ? u.href : undefined;
  } catch {
    return undefined;
  }
}

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
    return pad && pad.factory && !/^0x0{40}$/i.test(pad.factory) ? [{ info: PADS[k], pad }] : [];
  });
}

/** The buyback swapper a launchpad keeps for a pool manager, or undefined. */
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
