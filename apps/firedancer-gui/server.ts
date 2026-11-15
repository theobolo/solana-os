// Firedancer GUI relay for Bun: follows a Firedancer GUI websocket and hands the badge
// app (main.lua) a live, badge-sized view of the cluster and of ONE validator
// (the dashboard's own by default). The same relay for Cloudflare Workers: worker/.
//
//   GET /live      the badge's WebSocket (badge_ticket checked, see LUA_API.md "ws");
//                  ?v=<identity> follows that validator (core.ts: "follow", "list")
//   GET /status    the latest info and frame as JSON, for you
//
// Why a relay: the Firedancer GUI sends two ~370 KB leader schedules on connect
// and hundreds of messages a second; a badge closes a socket on any message over
// 4 KB and holds 8. The relay keeps the schedule and the slots' states and sends the
// slot every FRAME_MS when it moved, a leader window when it changed, each of the
// followed validator's slots as it is made, and an info message every 2 s (core.ts
// has the formats).
//
// Run it behind HTTPS on port 443 at the host the app lists:
//
//   PUBLIC_URL=https://relay.example.com PORT=8080 bun server.ts
//
// Env: FD_WS (Firedancer GUI websocket), IDENTITY and VOTE (the validator's keys),
// RPC_URL (for commission, stake and delinquency), APP (the badge app id),
// FRAME_MS (default 100), DEV_NO_TICKET=1 to let any client in (local tests only).

import { Relay, Hub, Follow, fromBadgeSocket } from './core.ts';

const FD_WS = process.env.FD_WS ?? 'wss://gui.firedancer.io/websocket';
const IDENTITY = process.env.IDENTITY ?? '';   // the validator to follow; empty: the dashboard's own
const VOTE = process.env.VOTE ?? '';           // its vote account, with IDENTITY
const RPC_URL = process.env.RPC_URL ?? 'https://api.mainnet-beta.solana.com';
const APP = process.env.APP ?? 'firedancer-gui';
const FRAME_MS = Number(process.env.FRAME_MS ?? 100);
const BADGE_SERVER = process.env.BADGE_SERVER ?? 'https://badge-api.solana.com';
const PUBLIC_URL = process.env.PUBLIC_URL ?? 'https://relay.example.com';
const HOST = new URL(PUBLIC_URL).host;
const DEV = process.env.DEV_NO_TICKET === '1';

const relay: Relay = new Relay(IDENTITY, (m, to) => hub.deliver(m, to), (fn, ms) => setTimeout(fn, ms), console.log);
const readVote = (f: Follow) => relay.readVote(f, RPC_URL, f === relay.main ? VOTE || relay.voteKey : '');
const hub = new Hub(relay, readVote);

setTimeout(() => relay.readVotes(RPC_URL, VOTE), 8000);   // once the dashboard has said which validator is its own
setInterval(() => relay.readVotes(RPC_URL, VOTE), 5 * 60_000);
setInterval(() => relay.prune(), 10_000);

// ---------------------------------------------------------------- upstream
let delay = 1000;
function connect() {
  relay.upstream = 'connecting';
  const ws = new WebSocket(FD_WS, process.env.HTTPS_PROXY ? ({ proxy: process.env.HTTPS_PROXY } as any) : undefined);
  ws.onopen = () => { relay.upstream = 'live'; delay = 1000; console.log('upstream open'); };
  ws.onmessage = (ev) => {
    relay.handleRaw(typeof ev.data === 'string' ? ev.data : new TextDecoder().decode(ev.data as ArrayBuffer));
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
setInterval(() => hub.tick(), FRAME_MS);
setInterval(() => hub.infos(), 2000);

Bun.serve<{ badge: string; v: string }>({
  port: Number(process.env.PORT ?? 8080),
  async fetch(req, server) {
    const u = new URL(req.url);
    if (u.pathname === '/status') return Response.json({ info: relay.info(), frame: relay.frame() });
    if (u.pathname === '/live') {
      const who = DEV ? { badge: 'dev', user: 'dev' } : await fromBadgeSocket(PUBLIC_URL + u.pathname + u.search, APP, HOST, BADGE_SERVER);
      if (who && server.upgrade(req, { data: { badge: who.badge, v: u.searchParams.get('v') ?? '' } })) return undefined;
      return new Response('no', { status: 403 });
    }
    return new Response('Firedancer GUI relay', { status: 404 });
  },
  websocket: {
    open(ws) { hub.add(ws, ws.data.v); },
    close(ws) { hub.remove(ws); },
    message(ws, text) { if (typeof text === 'string') hub.message(ws, text); },
  },
});
console.log(`relay for ${IDENTITY || "the dashboard's validator"} on :${process.env.PORT ?? 8080}, upstream ${FD_WS}, frames every ${FRAME_MS} ms`);
