// Galaxy Live relay on Cloudflare Workers: one Durable Object holds the websocket
// to the Firedancer GUI and the badges' sockets, and sends them what core.ts builds.
//
//   GET /live      the badge's WebSocket (badge_ticket checked, see LUA_API.md "ws")
//   GET /status    whether it is following the feed, and the latest info and frame
//   GET /app/galaxy-live.apk?k=<PHONE_KEY>  the Android relay app (android/), from KV
//   GET /install   a page for a phone: installs the app on the badge over USB, then feeds
//                  it over Bluetooth from GET /phone?k=<PHONE_KEY> (the same messages)
//
// The object follows the feed only while a badge is connected (and 30 s after the
// last one left), so it costs nothing when nobody is watching: the first badge
// waits a second or two for the leader schedule.
//
//   cd apps/galaxy/worker && npx wrangler deploy
//
// Settings are the [vars] of wrangler.toml.

import { Relay, fromBadgeSocket } from '../../core';
import page from './install.html';
import mainLua from '../../main.lua';
import manifest from '../../app.json';

interface Env {
  RELAY: DurableObjectNamespace;
  FD_WS: string; IDENTITY: string; VOTE: string; RPC_URL: string; APP: string;
  BADGE_SERVER: string; FRAME_MS: string; DEV_NO_TICKET?: string;
  PHONE_KEY?: string;
  FILES: KVNamespace;                     // galaxy-live.apk (it holds PHONE_KEY: served with the key only)                    // a secret: lets the /install page's phone follow the relay
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const u = new URL(req.url);
    // The phone page: installs the app over USB and feeds the badge over Bluetooth.
    if (u.pathname === '/install') return new Response(page, { headers: { 'Content-Type': 'text/html; charset=utf-8' } });
    if (u.pathname === '/app/main.lua') return new Response(mainLua, { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
    if (u.pathname === '/app/app.json') return new Response(JSON.stringify(manifest, null, 2) + '\n', { headers: { 'Content-Type': 'application/json' } });
    if (u.pathname === '/app/galaxy-live.apk') {
      const k = u.searchParams.get('k') ?? '';
      if (!env.PHONE_KEY || k.length !== env.PHONE_KEY.length || !sameText(k, env.PHONE_KEY)) return new Response('no', { status: 403 });
      const apk = await env.FILES.get('galaxy-live.apk', 'arrayBuffer');
      if (!apk) return new Response('no app uploaded yet', { status: 404 });
      return new Response(apk, { headers: { 'Content-Type': 'application/vnd.android.package-archive',
        'Content-Disposition': 'attachment; filename="galaxy-live.apk"', 'Cache-Control': 'no-store' } });
    }
    if (u.pathname === '/phone') {
      if (req.headers.get('Upgrade') !== 'websocket') return new Response('a WebSocket, please', { status: 426 });
      const k = u.searchParams.get('k') ?? '';
      if (!env.PHONE_KEY || k.length !== env.PHONE_KEY.length || !sameText(k, env.PHONE_KEY)) return new Response('no', { status: 403 });
      return env.RELAY.get(env.RELAY.idFromName(RELAY_NAME)).fetch(req);
    }
    if (u.pathname !== '/live' && u.pathname !== '/status') return new Response('Galaxy Live relay', { status: 404 });
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
const RELAY_NAME = 'relay-5';

function sameText(a: string, b: string) {   // compared in full, whatever differs
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

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
    r.vote = this.relay?.vote ?? null;       // keep what we know of the vote account
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
    setTimeout(() => this.relay.readVote(this.env.RPC_URL, this.env.VOTE), 8000);   // once we know which validator
    this.timers = [
      setInterval(() => {
        if (!this.clients.size || !this.relay.est) return;
        for (const w of this.relay.changedWindows()) this.broadcast(w);
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
      if (!this.relay.vote) await this.relay.readVote(this.env.RPC_URL, this.env.VOTE);
      return Response.json({ badges: this.clients.size, info: this.relay.info(), frame: this.relay.est ? this.relay.frame() : null });
    }
    // /live: the Worker above has checked the badge's ticket.
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
    if (this.relay.est) {
      for (const w of this.relay.history(16)) server.send(JSON.stringify(w));
      server.send(JSON.stringify(this.relay.frame()));
    }
    return new Response(null, { status: 101, webSocket: client });
  }
}
