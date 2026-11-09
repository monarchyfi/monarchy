// Monarchy's coin picture upload: pins a picture to IPFS for the launch form, the way Ascend's own form does
// (https://app.ascendlaunch.xyz/launch). It takes what Ascend takes, a PNG, JPEG, GIF or WebP file under 2 MB, signed
// for by the wallet that will launch or edit the coin, and answers with its ipfs:// link, which the launch then keeps
// on chain. The Pinata key never leaves this service. Wallets cost nothing to make, so on top of 10 uploads a wallet a
// day there are 20 an IP address a day and 300 a day in all (MAX_UPLOADS_PER_DAY), which keeps a script with fresh
// wallets from filling the Pinata plan; without the LIMITS store it refuses to pin at all.
//
// A Cloudflare Worker (see wrangler.toml), or any runtime with fetch, FormData and Web Crypto (dev.mjs runs it on
// Node). Settings: PINATA_JWT (secret), ALLOWED_ORIGINS (the site's origins, comma separated), RPC_URL (Elysium, so
// smart-contract wallets can sign too), CHAIN_ID (99901), and a KV namespace bound as LIMITS for the daily count.
import { createPublicClient, getAddress, http, isAddress, isHex, verifyMessage } from "viem";

export const MAX_IMAGE_BYTES = 2 * 1024 * 1024;
export const PER_WALLET_PER_DAY = 10;
export const PER_IP_PER_DAY = 20;
/** Every upload in a day, all wallets together; MAX_UPLOADS_PER_DAY overrides it. */
export const ALL_PER_DAY = 300;
/** How far ahead a signature may expire, in seconds. */
export const MAX_EXPIRY = 15 * 60;

/** The text the wallet signs. web/src/lib/imageUpload.ts builds the same. */
export const uploadMessage = ({ wallet, chainId, sha256, expires }) =>
  `Monarchy: pin this coin picture to IPFS\n\nWallet: ${wallet}\nChain: ${chainId}\nPicture SHA-256: ${sha256}\nExpires: ${expires}`;

/** The picture's format from its first bytes, as Ascend checks it. */
export function imageType(b) {
  const at = (i, s) => b.length >= i + s.length && [...s].every((c, j) => b[i + j] === c.charCodeAt(0));
  if (at(0, "\x89PNG")) return "image/png";
  if (at(0, "\xff\xd8\xff")) return "image/jpeg";
  if (at(0, "GIF87a") || at(0, "GIF89a")) return "image/gif";
  if (at(0, "RIFF") && at(8, "WEBP")) return "image/webp";
  return undefined;
}

class Refused extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

const hex = (buf) => "0x" + [...new Uint8Array(buf)].map((x) => x.toString(16).padStart(2, "0")).join("");

/** A CIDv1 for raw bytes (what IPFS gives a small file), for the mock pinner used in local tests. */
function rawCid(digest) {
  const bytes = new Uint8Array([0x01, 0x55, 0x12, 0x20, ...new Uint8Array(digest)]);
  const abc = "abcdefghijklmnopqrstuvwxyz234567";
  let bits = 0;
  let value = 0;
  let out = "b";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += abc[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += abc[(value << (5 - bits)) & 31];
  return out;
}

async function checkSignature(env, wallet, message, signature) {
  try {
    if (await verifyMessage({ address: wallet, message, signature })) return true;
  } catch {
    // not a plain wallet signature; a smart-contract wallet is checked on chain below
  }
  if (!env.RPC_URL) return false;
  try {
    const client = createPublicClient({ transport: http(env.RPC_URL) });
    return await client.verifyMessage({ address: wallet, message, signature });
  } catch {
    return false;
  }
}

async function pinToPinata(env, file, type, sha256) {
  const form = new FormData();
  form.set("file", new Blob([file], { type }), `coin-${sha256.slice(2, 18)}`);
  form.set("network", "public");
  form.set("name", `monarchy-coin-${sha256.slice(2, 18)}`);
  const res = await fetch(env.PINATA_UPLOAD_URL || "https://uploads.pinata.cloud/v3/files", {
    method: "POST",
    headers: { authorization: `Bearer ${env.PINATA_JWT}` },
    body: form,
  });
  if (!res.ok) throw new Refused(502, "Pinning the image failed. Please try again.");
  const cid = (await res.json())?.data?.cid;
  if (typeof cid !== "string" || !/^(Qm[1-9A-HJ-NP-Za-km-z]{44}|b[a-z2-7]{20,110})$/.test(cid))
    throw new Refused(502, "Pinning the image failed. Please try again.");
  return cid;
}

/** Checks the upload and pins it; answers { imageUri, cid }. */
export async function pin(request, env, now = Math.floor(Date.now() / 1000)) {
  const declared = Number(request.headers.get("content-length") ?? 0);
  if (declared > MAX_IMAGE_BYTES + 64 * 1024) throw new Refused(413, "The image must be under 2 MB.");
  let form;
  try {
    form = await request.formData();
  } catch {
    throw new Refused(400, "Send the picture as a form upload.");
  }
  const file = form.get("file");
  const wallet = String(form.get("wallet") ?? "");
  const expires = Number(form.get("expires"));
  const signature = String(form.get("signature") ?? "");
  const chainId = Number(env.CHAIN_ID || 99901);
  if (!file || typeof file === "string") throw new Refused(400, "Choose an image.");
  if (file.size > MAX_IMAGE_BYTES) throw new Refused(413, "The image must be under 2 MB.");
  const bytes = new Uint8Array(await file.arrayBuffer());
  const type = imageType(bytes);
  if (!type) throw new Refused(415, "The image must be a PNG, JPEG, GIF or WebP.");
  if (!isAddress(wallet)) throw new Refused(400, "Connect a wallet first.");
  if (!Number.isInteger(expires) || expires <= now || expires > now + MAX_EXPIRY)
    throw new Refused(401, "The signature has expired. Please sign again.");
  if (!isHex(signature)) throw new Refused(401, "Sign the upload with your wallet.");

  const sha256 = hex(await crypto.subtle.digest("SHA-256", bytes));
  const address = getAddress(wallet);
  const message = uploadMessage({ wallet: address, chainId, sha256, expires });
  if (!(await checkSignature(env, address, message, signature)))
    throw new Refused(401, "The signature doesn't match this wallet and picture.");

  // the daily counts go up before pinning, so parallel uploads can't slip past them (much: the store isn't atomic)
  if (!env.LIMITS && env.PIN_MODE !== "mock") throw new Refused(503, "Picture uploads are paused. Please try again later.");
  const day = new Date(now * 1000).toISOString().slice(0, 10);
  // Cloudflare sets this header itself; a request can't choose it
  const ip = request.headers.get("cf-connecting-ip");
  const counts = [
    [`uploads:${day}:${address.toLowerCase()}`, PER_WALLET_PER_DAY, `Each wallet can upload ${PER_WALLET_PER_DAY} pictures a day. Try again tomorrow.`],
    ...(ip ? [[`uploads-ip:${day}:${ip}`, PER_IP_PER_DAY, "Too many pictures from this connection today. Try again tomorrow."]] : []),
    [`uploads-all:${day}`, Number(env.MAX_UPLOADS_PER_DAY) || ALL_PER_DAY, "Picture uploads are full for today. Try again tomorrow, or launch without a picture."],
  ];
  const used = await Promise.all(counts.map(([key]) => env.LIMITS?.get(key).then((v) => Number(v ?? 0))));
  counts.forEach(([, max, refusal], i) => {
    if ((used[i] ?? 0) >= max) throw new Refused(429, refusal);
  });
  await Promise.all(counts.map(([key], i) => env.LIMITS?.put(key, String((used[i] ?? 0) + 1), { expirationTtl: 2 * 24 * 60 * 60 })));

  const cid = env.PIN_MODE === "mock" ? rawCid(await crypto.subtle.digest("SHA-256", bytes)) : await pinToPinata(env, bytes, type, sha256);
  if (env.PIN_MODE === "mock") env.MOCK_STORE?.set(cid, { bytes, type });
  return { imageUri: `ipfs://${cid}`, cid };
}

function corsHeaders(request, env) {
  const origin = request.headers.get("origin") ?? "";
  const allowed = String(env.ALLOWED_ORIGINS ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  return {
    "access-control-allow-origin": allowed.includes(origin) ? origin : (allowed[0] ?? "null"),
    "access-control-allow-methods": "POST, OPTIONS",
    "access-control-allow-headers": "content-type",
    "access-control-max-age": "86400",
    vary: "origin",
  };
}

export default {
  async fetch(request, env) {
    const cors = corsHeaders(request, env);
    const json = (body, status) => new Response(JSON.stringify(body), { status, headers: { ...cors, "content-type": "application/json" } });
    const { pathname } = new URL(request.url);
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    if (request.method === "GET" && pathname === "/health") return json({ ok: true }, 200);
    if (request.method !== "POST" || pathname !== "/v1/image") return json({ error: "Not found" }, 404);
    try {
      return json(await pin(request, env), 200);
    } catch (e) {
      const status = e instanceof Refused ? e.status : 500;
      return json({ error: e instanceof Refused ? e.message : "The upload failed. Please try again." }, status);
    }
  },
};
