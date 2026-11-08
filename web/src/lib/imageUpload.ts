import type { Address, Hex } from "viem";

/** Monarchy's picture upload service (services/image-pin), which pins a coin's picture to IPFS the way Ascend's own
 * form does. Unset, the launch form takes no picture. */
export const UPLOAD_URL = (import.meta.env.VITE_IMAGE_UPLOAD_URL as string | undefined)?.replace(/\/+$/, "") || undefined;
/** The gateway pictures are shown through: Pinata's public gateway, the one Ascend's site uses. */
export const IPFS_GATEWAY = ((import.meta.env.VITE_IPFS_GATEWAY as string | undefined) || "https://gateway.pinata.cloud/ipfs").replace(/\/+$/, "");

/** How long a signed upload stays valid, in seconds (the service takes up to 15 minutes). */
const EXPIRES_IN = 10 * 60;
const CID = /^(Qm[1-9A-HJ-NP-Za-km-z]{44}|b[a-z2-7]{20,110})$/;

/** The text the wallet signs. services/image-pin/worker.mjs builds the same. */
export const uploadMessage = (p: { wallet: Address; chainId: number; sha256: Hex; expires: number }) =>
  `Monarchy: pin this coin picture to IPFS\n\nWallet: ${p.wallet}\nChain: ${p.chainId}\nPicture SHA-256: ${p.sha256}\nExpires: ${p.expires}`;

async function sha256(bytes: Uint8Array): Promise<Hex> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as Uint8Array<ArrayBuffer>));
  return `0x${[...digest].map((x) => x.toString(16).padStart(2, "0")).join("")}`;
}

/** Pictures this page uploaded, shown from memory while the gateway catches up (as Ascend's site does). */
const local = new Map<string, string>();

/** Signs for and uploads a picture, and answers its ipfs:// link. `sign` is the wallet's message signer. */
export async function uploadImage(p: {
  bytes: Uint8Array;
  type: string;
  wallet: Address;
  chainId: number;
  sign: (message: string) => Promise<Hex>;
  onStep?: (step: "signing" | "uploading") => void;
}): Promise<string> {
  if (!UPLOAD_URL) throw new Error("Picture uploads aren't set up on this site.");
  const expires = Math.floor(Date.now() / 1000) + EXPIRES_IN;
  p.onStep?.("signing");
  const signature = await p.sign(uploadMessage({ wallet: p.wallet, chainId: p.chainId, sha256: await sha256(p.bytes), expires }));
  p.onStep?.("uploading");
  const blob = new Blob([p.bytes as Uint8Array<ArrayBuffer>], { type: p.type });
  const form = new FormData();
  form.set("file", blob, "coin");
  form.set("wallet", p.wallet);
  form.set("expires", String(expires));
  form.set("signature", signature);
  let res: Response;
  try {
    res = await fetch(`${UPLOAD_URL}/v1/image`, { method: "POST", body: form });
  } catch {
    throw new Error("Couldn't reach the picture upload. Check your connection and try again.");
  }
  const body = (await res.json().catch(() => ({}))) as { imageUri?: string; cid?: string; error?: string };
  if (!res.ok || !body.cid || !CID.test(body.cid) || body.imageUri !== `ipfs://${body.cid}`) throw new Error(body.error ?? "Uploading the image failed. Please try again.");
  local.set(body.imageUri, URL.createObjectURL(blob));
  return body.imageUri;
}

/** Where to show a coin's picture from its ipfs:// link, or undefined for anything else (the link on chain is
 * whatever the steward sent). */
export function imageUrl(uri: string | undefined): string | undefined {
  if (!uri) return undefined;
  const mine = local.get(uri);
  if (mine) return mine;
  const cid = uri.startsWith("ipfs://") ? uri.slice(7) : "";
  return CID.test(cid) ? `${IPFS_GATEWAY}/${cid}` : undefined;
}
