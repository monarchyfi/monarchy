import { test } from "node:test";
import assert from "node:assert/strict";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import worker, { uploadMessage, PER_WALLET_PER_DAY, PER_IP_PER_DAY, MAX_IMAGE_BYTES } from "./worker.mjs";

// throwaway keys made for each run
const alice = privateKeyToAccount(generatePrivateKey());
const bob = privateKeyToAccount(generatePrivateKey());
const png = (n = 100) => new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, ...new Uint8Array(n)]);
const now = () => Math.floor(Date.now() / 1000);

function setup() {
  const counts = new Map();
  const store = new Map();
  return {
    store,
    env: {
      PIN_MODE: "mock",
      MOCK_STORE: store,
      CHAIN_ID: "99901",
      ALLOWED_ORIGINS: "https://monarchy.fi",
      LIMITS: { get: async (k) => counts.get(k) ?? null, put: async (k, v) => void counts.set(k, v) },
    },
  };
}

async function upload(env, { bytes = png(), signer = alice, wallet = signer.address, expires = now() + 600, sign = true, type = "image/png", ip } = {}) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  const sha256 = "0x" + [...digest].map((x) => x.toString(16).padStart(2, "0")).join("");
  const message = uploadMessage({ wallet, chainId: 99901, sha256, expires });
  const form = new FormData();
  form.set("file", new Blob([bytes], { type }), "coin.png");
  form.set("wallet", wallet);
  form.set("expires", String(expires));
  form.set("signature", sign ? await signer.signMessage({ message }) : "0x");
  const res = await worker.fetch(new Request("https://pin.example/v1/image", { method: "POST", body: form, headers: { origin: "https://monarchy.fi", ...(ip ? { "cf-connecting-ip": ip } : {}) } }), env);
  return { status: res.status, body: await res.json(), cors: res.headers.get("access-control-allow-origin") };
}

test("pins a signed picture and answers its ipfs link", async () => {
  const { env, store } = setup();
  const r = await upload(env);
  assert.equal(r.status, 200);
  assert.match(r.body.imageUri, /^ipfs:\/\/bafkrei[a-z2-7]+$/);
  assert.equal(r.cors, "https://monarchy.fi");
  assert.ok(store.has(r.body.cid));
});

test("the same file gets the same link", async () => {
  const { env } = setup();
  assert.equal((await upload(env)).body.cid, (await upload(env)).body.cid);
});

test("refuses what Ascend refuses", async () => {
  const { env } = setup();
  const svg = new TextEncoder().encode('<svg xmlns="http://www.w3.org/2000/svg"/>');
  assert.equal((await upload(env, { bytes: svg, type: "image/svg+xml" })).status, 415);
  assert.equal((await upload(env, { bytes: png(MAX_IMAGE_BYTES) })).status, 413);
  assert.equal((await upload(env, { bytes: png(MAX_IMAGE_BYTES - 8) })).status, 200);
});

test("needs the wallet's own, unexpired signature over this picture", async () => {
  const { env } = setup();
  assert.equal((await upload(env, { sign: false })).status, 401);
  assert.equal((await upload(env, { signer: bob, wallet: alice.address })).status, 401);
  assert.equal((await upload(env, { expires: now() - 1 })).status, 401);
  assert.equal((await upload(env, { expires: now() + 3600 })).status, 401);
});

test("ten a wallet a day", async () => {
  const { env } = setup();
  for (let i = 0; i < PER_WALLET_PER_DAY; i++) assert.equal((await upload(env, { bytes: png(10 + i) })).status, 200);
  const r = await upload(env, { bytes: png(99) });
  assert.equal(r.status, 429);
  assert.equal((await upload(env, { signer: bob })).status, 200);
});

test("fresh wallets can't get past the IP and daily caps", async () => {
  const { env } = setup();
  for (let i = 0; i < PER_IP_PER_DAY; i++) {
    const signer = privateKeyToAccount(generatePrivateKey());
    assert.equal((await upload(env, { signer, bytes: png(10 + i), ip: "203.0.113.7" })).status, 200);
  }
  assert.equal((await upload(env, { signer: privateKeyToAccount(generatePrivateKey()), ip: "203.0.113.7" })).status, 429);
  assert.equal((await upload(env, { signer: bob, ip: "198.51.100.2" })).status, 200, "another connection still can");

  const { env: small } = setup();
  small.MAX_UPLOADS_PER_DAY = "3";
  for (let i = 0; i < 3; i++) assert.equal((await upload(small, { signer: privateKeyToAccount(generatePrivateKey()), bytes: png(i) })).status, 200);
  const full = await upload(small, { signer: bob });
  assert.equal(full.status, 429);
  assert.match(full.body.error, /full for today/);
});

test("refuses to pin for real without the LIMITS store", async () => {
  const { env } = setup();
  delete env.LIMITS;
  env.PIN_MODE = "pinata";
  assert.equal((await upload(env)).status, 503);
});
