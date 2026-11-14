// Galaxy Live relay for Bun: follows a Firedancer GUI websocket and hands the badge
// app (main.lua) a live, badge-sized view of the cluster and of ONE validator
// (Galaxy by default). The same relay for Cloudflare Workers: worker/.
//
//   GET /live      the badge's WebSocket (badge_ticket checked, see LUA_API.md "ws")
//   GET /status    the latest info and frame as JSON, for you
//
// Why a relay: the Firedancer GUI sends two ~370 KB leader schedules on connect
// and hundreds of messages a second; a badge closes a socket on any message over
// 4 KB and holds 8. The relay keeps the schedule and the slots' states and sends
// a whole carousel frame every FRAME_MS when something changed, each of our slots
// as it is made, and an info message every 2 s (core.ts has the formats).
//
// Run it behind HTTPS on port 443 at the host the app lists:
//
//   PUBLIC_URL=https://galaxy.example.com PORT=8080 bun server.ts
//
// Env: FD_WS (Firedancer GUI websocket), IDENTITY and VOTE (the validator's keys),
// RPC_URL (for commission, stake and delinquency), APP (the badge app id),
// FRAME_MS (default 100), DEV_NO_TICKET=1 to let any client in (local tests only).

import { Relay, fromBadgeSocket } from './core.ts';

const FD_WS = process.env.FD_WS ?? 'wss://fd-mainnet.stakingfacilities.com/websocket';
const IDENTITY = process.env.IDENTITY ?? '9eGrDohdNTAo61DRHyfMuqKWXqYnA3i254Wiszxe8FoY'; // Galaxy
const VOTE = process.env.VOTE ?? 'CvSb7wdQAFpHuSpTYTJnX5SYH4hCfQ9VuGnqrKaKwycB';
const RPC_URL = process.env.RPC_URL ?? 'https://api.mainnet-beta.solana.com';
const APP = process.env.APP ?? 'galaxy-live';
const FRAME_MS = Number(process.env.FRAME_MS ?? 100);
const BADGE_SERVER = process.env.BADGE_SERVER ?? 'https://badge-api.solana.com';
const PUBLIC_URL = process.env.PUBLIC_URL ?? 'https://galaxy.example.com';
const HOST = new URL(PUBLIC_URL).host;
const DEV = process.env.DEV_NO_TICKET === '1';

const clients = new Set<any>();
function broadcast(m: object) {
  const s = JSON.stringify(m);
  for (const c of clients) c.send(s);
}
const relay = new Relay(IDENTITY, broadcast, (fn, ms) => setTimeout(fn, ms), console.log);

relay.readVote(RPC_URL, VOTE);
setInterval(() => relay.readVote(RPC_URL, VOTE), 5 * 60_000);
setInterval(() => relay.prune(), 10_000);

// ---------------------------------------------------------------- upstream
let delay = 1000;
function connect() {
  relay.upstream = 'connecting';
  const ws = new WebSocket(FD_WS, process.env.HTTPS_PROXY ? ({ proxy: process.env.HTTPS_PROXY } as any) : undefined);
  ws.onopen = () => { relay.upstream = 'live'; delay = 1000; console.log('upstream open'); };
  ws.onmessage = (ev) => {
    try { relay.handle(JSON.parse(typeof ev.data === 'string' ? ev.data : new TextDecoder().decode(ev.data as ArrayBuffer))); } catch {}
  };
  ws.onclose = () => {
    relay.upstream = 'reconnecting';
    console.log(`upstream closed, again in ${delay} ms`);
    setTimeout(connect, delay);
    delay = Math.min(delay * 2, 30_000);
  };
  ws.onerror = () => {};
}
connect();

// ---------------------------------------------------------------- badges
let lastFrame = '';
setInterval(() => {
  if (!clients.size || !relay.est) return;
  for (const w of relay.changedWindows()) broadcast(w);
  const s = JSON.stringify(relay.frame());
  if (s === lastFrame) return;                 // nothing moved
  lastFrame = s;
  for (const c of clients) c.send(s);
}, FRAME_MS);
setInterval(() => broadcast(relay.info()), 2000);

Bun.serve<{ badge: string }>({
  port: Number(process.env.PORT ?? 8080),
  async fetch(req, server) {
    const u = new URL(req.url);
    if (u.pathname === '/status') return Response.json({ info: relay.info(), frame: relay.frame() });
    if (u.pathname === '/live') {
      const who = DEV ? { badge: 'dev', user: 'dev' } : await fromBadgeSocket(PUBLIC_URL + u.pathname + u.search, APP, HOST, BADGE_SERVER);
      if (who && server.upgrade(req, { data: { badge: who.badge } })) return undefined;
      return new Response('no', { status: 403 });
    }
    return new Response('Galaxy Live relay', { status: 404 });
  },
  websocket: {
    open(ws) {
      clients.add(ws);
      ws.send(JSON.stringify(relay.info()));
      if (relay.est) { for (const w of relay.history(16)) ws.send(JSON.stringify(w)); ws.send(JSON.stringify(relay.frame())); }
    },
    close(ws) { clients.delete(ws); },
    message() {},
  },
});
console.log(`relay for ${IDENTITY} on :${process.env.PORT ?? 8080}, upstream ${FD_WS}, frames every ${FRAME_MS} ms`);
