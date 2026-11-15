// Firedancer GUI relay on Cloudflare Workers: one Durable Object holds the websocket
// to the Firedancer GUI and the badges' sockets, and sends them what core.ts builds.
//
//   GET /live      the badge's WebSocket (badge_ticket checked, see LUA_API.md "ws");
//                  ?v=<identity> follows that validator (core.ts: "follow", "list")
//   GET /status    whether it is following the feed, and the latest info and frame
//
// The object follows the feed only while a badge is connected (and 30 s after the
// last one left), so it costs nothing when nobody is watching: the first badge
// waits a second or so for the leader schedule. What the dashboard doesn't replay
// (our last blocks, the vote account, the slots on screen) is kept in the object's
// storage across those pauses (core.ts snapshot).
//
//   cd apps/firedancer-gui/worker && npx wrangler deploy
//
// Settings are the [vars] of wrangler.toml.

import { Relay, Hub, Follow, fromBadgeSocket } from '../../core';

interface Env {
  RELAY: DurableObjectNamespace;
  FD_WS: string; IDENTITY: string; VOTE: string; RPC_URL: string; APP: string;
  BADGE_SERVER: string; FRAME_MS: string; DEV_NO_TICKET?: string;
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const u = new URL(req.url);
    if (u.pathname !== '/live' && u.pathname !== '/status') return new Response('Firedancer GUI relay', { status: 404 });
    if (u.pathname === '/live') {
      // The ticket is checked here, not in the object: this code always runs with the
      // latest settings, while an object that is busy keeps the ones it started with.
      if (req.headers.get('Upgrade') !== 'websocket') return new Response('a WebSocket, please', { status: 426 });
      const who = env.DEV_NO_TICKET === '1' ? { badge: 'dev', user: 'dev' }
        : await fromBadgeSocket(req.url, env.APP, u.host, env.BADGE_SERVER);
      if (!who) return new Response('no', { status: 403 });
    }
    return env.RELAY.get(env.RELAY.idFromName(RELAY_NAME)).fetch(req);
  },
};

// The relay object's name. A running object keeps the code it started with while sockets
// hold it open, even across deploys: change this with any change to the relay so the next
// connection gets an object running the new code (the old one stops once its sockets go).
const RELAY_NAME = 'relay-8';

export class RelayDO {
  private relay: Relay;
  private hub: Hub;                          // the badges' sockets, each with the validator it follows
  private up: WebSocket | null = null;
  private timers: ReturnType<typeof setInterval>[] = [];
  private idle: ReturnType<typeof setTimeout> | null = null;
  private delay = 1000;
  private saved: string | undefined;         // the last snapshot, in storage too

  constructor(private state: DurableObjectState, private env: Env) {
    this.relay = this.fresh();
    this.hub = new Hub(this.relay, (f) => this.readVote(f));
    state.blockConcurrencyWhile(async () => {
      this.saved = await state.storage.get<string>('snapshot');
      if (this.saved) this.relay.restore(this.saved);
    });
  }

  private fresh() {
    const r = new Relay(this.env.IDENTITY, (m, to) => this.hub.deliver(m, to), (fn, ms) => setTimeout(fn, ms), console.log);
    r.upstream = 'idle';
    r.main.vote = this.relay?.main.vote ?? null;   // keep what we know of the vote account
    if (this.saved) r.restore(this.saved);
    if (this.hub) this.hub.relay = r;
    return r;
  }

  private readVote(f: Follow) {
    const r = this.relay;
    return r.readVote(f, this.env.RPC_URL, f === r.main ? this.env.VOTE || r.voteKey : '');
  }

  private save() {
    if (!this.relay.est) return;
    this.saved = this.relay.snapshot();
    this.state.storage.put('snapshot', this.saved).catch((e) => console.log('storage: ' + String(e)));
  }

  private start() {
    if (this.idle) { clearTimeout(this.idle); this.idle = null; }
    if (this.timers.length) return;
    this.connect();
    setTimeout(() => this.relay.readVotes(this.env.RPC_URL, this.env.VOTE), 8000);   // once we know which validators
    this.timers = [
      setInterval(() => this.hub.tick(), Number(this.env.FRAME_MS || 100)),
      setInterval(() => this.hub.infos(), 2000),
      setInterval(() => this.relay.prune(), 10_000),
      setInterval(() => this.save(), 60_000),
      setInterval(() => this.relay.readVotes(this.env.RPC_URL, this.env.VOTE), 5 * 60_000),
    ];
  }

  private stop() {
    for (const t of this.timers) clearInterval(t);
    this.timers = [];
    const up = this.up;
    this.up = null;
    try { up?.close(1000, 'idle'); } catch {}
    this.save();
    this.relay = this.fresh();               // the schedule comes again on the next connect
  }

  private connect() {
    if (!this.timers.length && this.up === null && !this.hub.size) return;
    this.relay.upstream = 'connecting';
    const ws = new WebSocket(this.env.FD_WS);
    this.up = ws;
    ws.addEventListener('open', () => { this.relay.upstream = 'live'; this.delay = 1000; });
    ws.addEventListener('message', (ev) => {
      this.relay.handleRaw(typeof ev.data === 'string' ? ev.data : new TextDecoder().decode(ev.data as ArrayBuffer));
    });
    const again = () => {
      if (this.up !== ws) return;            // stopped, or replaced already
      this.up = null;
      this.relay.upstream = 'reconnecting';
      setTimeout(() => { if (this.timers.length && !this.up) this.connect(); }, this.delay);
      this.delay = Math.min(this.delay * 2, 30_000);
    };
    ws.addEventListener('close', again);
    ws.addEventListener('error', again);
  }

  async fetch(req: Request): Promise<Response> {
    const u = new URL(req.url);
    if (u.pathname === '/status') {
      if (!this.relay.main.vote) await this.readVote(this.relay.main);
      return Response.json({ badges: this.hub.size, info: this.relay.info(), frame: this.relay.est ? this.relay.frame() : null });
    }
    // /live: the Worker above has checked the badge's ticket.
    const [client, server] = Object.values(new WebSocketPair());
    server.accept();
    this.hub.add(server, u.searchParams.get('v') ?? '');
    this.start();                            // after: it connects upstream only for a badge
    server.addEventListener('message', (ev) => { if (typeof ev.data === 'string') this.hub.message(server, ev.data); });
    const gone = () => {
      this.hub.remove(server);
      if (!this.hub.size && !this.idle) this.idle = setTimeout(() => { this.idle = null; if (!this.hub.size) this.stop(); }, 30_000);
    };
    server.addEventListener('close', gone);
    server.addEventListener('error', gone);
    return new Response(null, { status: 101, webSocket: client });
  }
}
