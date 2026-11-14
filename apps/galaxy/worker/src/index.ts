// Galaxy Live relay on Cloudflare Workers: one Durable Object holds the websocket
// to the Firedancer GUI and the badges' sockets, and sends them what core.ts builds.
//
//   GET /live      the badge's WebSocket (badge_ticket checked, see LUA_API.md "ws")
//   GET /status    whether it is following the feed, and the latest info and frame
//
// The object follows the feed only while a badge is connected (and 30 s after the
// last one left), so it costs nothing when nobody is watching: the first badge
// waits a second or two for the leader schedule.
//
//   cd apps/galaxy/worker && npx wrangler deploy
//
// Settings are the [vars] of wrangler.toml.

import { Relay, fromBadgeSocket } from '../../core';

interface Env {
  RELAY: DurableObjectNamespace;
  FD_WS: string; IDENTITY: string; VOTE: string; RPC_URL: string; APP: string;
  BADGE_SERVER: string; FRAME_MS: string; DEV_NO_TICKET?: string;
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const path = new URL(req.url).pathname;
    if (path === '/live' || path === '/status') return env.RELAY.get(env.RELAY.idFromName('relay')).fetch(req);
    return new Response('Galaxy Live relay', { status: 404 });
  },
};

export class RelayDO {
  private clients = new Set<WebSocket>();
  private relay: Relay;
  private up: WebSocket | null = null;
  private timers: ReturnType<typeof setInterval>[] = [];
  private idle: ReturnType<typeof setTimeout> | null = null;
  private delay = 1000;
  private lastFrame = '';

  constructor(_state: DurableObjectState, private env: Env) {
    this.relay = this.fresh();
  }

  private fresh() {
    const r = new Relay(this.env.IDENTITY, (m) => this.broadcast(m), (fn, ms) => setTimeout(fn, ms), console.log);
    r.upstream = 'idle';
    return r;
  }

  private broadcast(m: object) {
    const s = JSON.stringify(m);
    for (const c of this.clients) { try { c.send(s); } catch { this.clients.delete(c); } }
  }

  private start() {
    if (this.idle) { clearTimeout(this.idle); this.idle = null; }
    if (this.timers.length) return;
    this.connect();
    this.relay.readVote(this.env.RPC_URL, this.env.VOTE);
    this.timers = [
      setInterval(() => {
        if (!this.clients.size || !this.relay.est) return;
        const s = JSON.stringify(this.relay.frame());
        if (s === this.lastFrame) return;
        this.lastFrame = s;
        for (const c of this.clients) { try { c.send(s); } catch { this.clients.delete(c); } }
      }, Number(this.env.FRAME_MS || 100)),
      setInterval(() => this.broadcast(this.relay.info()), 2000),
      setInterval(() => this.relay.prune(), 10_000),
      setInterval(() => this.relay.readVote(this.env.RPC_URL, this.env.VOTE), 5 * 60_000),
    ];
  }

  private stop() {
    for (const t of this.timers) clearInterval(t);
    this.timers = [];
    const up = this.up;
    this.up = null;
    try { up?.close(1000, 'idle'); } catch {}
    this.relay = this.fresh();               // the schedule comes again on the next connect
  }

  private connect() {
    if (!this.timers.length && this.up === null && !this.clients.size) return;
    this.relay.upstream = 'connecting';
    const ws = new WebSocket(this.env.FD_WS);
    this.up = ws;
    ws.addEventListener('open', () => { this.relay.upstream = 'live'; this.delay = 1000; });
    ws.addEventListener('message', (ev) => {
      try { this.relay.handle(JSON.parse(typeof ev.data === 'string' ? ev.data : new TextDecoder().decode(ev.data as ArrayBuffer))); } catch {}
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
      return Response.json({ badges: this.clients.size, info: this.relay.info(), frame: this.relay.est ? this.relay.frame() : null });
    }
    if (req.headers.get('Upgrade') !== 'websocket') return new Response('a WebSocket, please', { status: 426 });
    const who = this.env.DEV_NO_TICKET === '1' ? { badge: 'dev', user: 'dev' }
      : await fromBadgeSocket(req.url, this.env.APP, u.host, this.env.BADGE_SERVER);
    if (!who) return new Response('no', { status: 403 });

    const [client, server] = Object.values(new WebSocketPair());
    server.accept();
    this.clients.add(server);
    this.start();
    const gone = () => {
      this.clients.delete(server);
      if (!this.clients.size && !this.idle) this.idle = setTimeout(() => { this.idle = null; if (!this.clients.size) this.stop(); }, 30_000);
    };
    server.addEventListener('close', gone);
    server.addEventListener('error', gone);
    server.send(JSON.stringify(this.relay.info()));
    if (this.relay.est) server.send(JSON.stringify(this.relay.frame()));
    return new Response(null, { status: 101, webSocket: client });
  }
}
