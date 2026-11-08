// Runs the picture upload service on Node for local testing, with a stand-in for Pinata: pictures are kept in
// memory under the CID IPFS would give them and served back at /ipfs/<cid>, like a gateway.
//   PORT=8790 ALLOWED_ORIGINS=http://127.0.0.1:5199 RPC_URL=http://127.0.0.1:8548 node dev.mjs
// Set PINATA_JWT (and leave PIN_MODE unset) to pin for real.
import { createServer } from "node:http";
import worker from "./worker.mjs";

const store = new Map();
const counts = new Map();
const env = {
  ...process.env,
  PIN_MODE: process.env.PINATA_JWT ? process.env.PIN_MODE : "mock",
  MOCK_STORE: store,
  LIMITS: { get: async (k) => counts.get(k) ?? null, put: async (k, v) => void counts.set(k, v) },
};
const port = Number(process.env.PORT ?? 8790);

createServer(async (req, res) => {
  const url = `http://127.0.0.1:${port}${req.url}`;
  const ipfs = /^\/ipfs\/([A-Za-z0-9]+)$/.exec(req.url ?? "");
  if (req.method === "GET" && ipfs) {
    const hit = store.get(ipfs[1]);
    res.writeHead(hit ? 200 : 404, { "content-type": hit?.type ?? "text/plain", "access-control-allow-origin": "*" });
    return res.end(hit ? Buffer.from(hit.bytes) : "not pinned here");
  }
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const body = chunks.length ? Buffer.concat(chunks) : undefined;
  const r = await worker.fetch(new Request(url, { method: req.method, headers: req.headers, body: req.method === "GET" || req.method === "HEAD" ? undefined : body }), env);
  res.writeHead(r.status, Object.fromEntries(r.headers));
  res.end(Buffer.from(await r.arrayBuffer()));
}).listen(port, "127.0.0.1", () => console.log(`picture upload service (${env.PIN_MODE === "mock" ? "mock pinning" : "Pinata"}) on http://127.0.0.1:${port}`));
