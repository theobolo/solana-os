// Galaxy Live relay: follows a Firedancer GUI websocket and hands the badge app
// (apps/galaxy/main.lua) a compact live view of ONE validator.
//
//   GET /live      the badge's WebSocket (badge_ticket checked, see LUA_API.md "ws")
//   GET /status    the same state as JSON, for you
//
// Why a relay: the Firedancer GUI sends two ~370 KB leader schedules on connect
// and hundreds of messages a second; a badge closes a socket on any message over
// 4 KB and buffers 8. The relay keeps the schedule, picks out the validator's
// leader slots and sends the badge a few hundred bytes now and then:
//
//   {"t":"info", ...}        every 5 s and on connect: stake, rank, epoch, next leader window
//   {"t":"slot","s":N,"i":0..3,"st":"ok"|"skip","tx":n,"fee":lamports}
//                            each of the validator's slots, as soon as it completes or is skipped
//
// Run it with Bun behind HTTPS on port 443 at the host the app lists:
//
//   PUBLIC_URL=https://galaxy.example.com PORT=8080 bun server.ts
//
// Env: FD_WS (Firedancer GUI websocket), IDENTITY (the validator's identity key),
// VOTE (its vote account) and RPC_URL (for commission, stake and delinquency),
// APP (the badge app id), DEV_NO_TICKET=1 to let any client in (local tests only).

const FD_WS = process.env.FD_WS ?? 'wss://fd-mainnet.stakingfacilities.com/websocket';
const IDENTITY = process.env.IDENTITY ?? '9eGrDohdNTAo61DRHyfMuqKWXqYnA3i254Wiszxe8FoY'; // Galaxy
const VOTE = process.env.VOTE ?? 'CvSb7wdQAFpHuSpTYTJnX5SYH4hCfQ9VuGnqrKaKwycB';         // Galaxy's vote account
const RPC_URL = process.env.RPC_URL ?? 'https://api.mainnet-beta.solana.com';
const APP = process.env.APP ?? 'galaxy-live';
const BADGE_SERVER = process.env.BADGE_SERVER ?? 'https://badge-api.solana.com';
const PUBLIC_URL = process.env.PUBLIC_URL ?? 'https://galaxy.example.com';
const HOST = new URL(PUBLIC_URL).host;
const DEV = process.env.DEV_NO_TICKET === '1';
const MINUTE = 60_000;
const LAMPORTS = 1_000_000_000n;

// ---------------------------------------------------------------- validator state
type Epoch = { epoch: number; start: number; end: number; windows: number[]; rank: number; stake: bigint; total: bigint };
const epochs = new Map<number, Epoch>();
const mine = new Map<number, { i: number }>();       // slot -> index in its window, both epochs
const status = new Map<number, 'ok' | 'skip'>();     // what we told badges about each of our slots
const skipped = new Set<number>();                   // our slots skipped for good
let est = 0, root = 0, slotNs = 400_000_000;         // estimated slot, root slot, slot duration
let peer: { name?: string; stake?: string; commission?: number; lastVote?: number; delinquent?: boolean } = {};
let upstream = 'connecting';

function onEpoch(v: any) {
  const idx = (v.staked_pubkeys as string[]).indexOf(IDENTITY);
  const windows: number[] = [];
  if (idx >= 0) (v.leader_slots as number[]).forEach((x, n) => { if (x === idx) windows.push(v.start_slot + 4 * n); });
  // stake rank from the epoch's stake table
  const stakes = (v.staked_lamports as string[]).map(BigInt);
  const my = idx >= 0 ? stakes[idx] : 0n;
  const total = stakes.reduce((a, b) => a + b, 0n);
  const rank = idx >= 0 ? stakes.filter((s) => s > my).length + 1 : 0;
  epochs.set(v.epoch, { epoch: v.epoch, start: v.start_slot, end: v.end_slot, windows, rank, stake: my, total });
  for (const w of windows) for (let i = 0; i < 4; i++) mine.set(w + i, { i });
  // forget epochs we no longer need
  for (const e of [...epochs.keys()]) if (e < v.epoch - 1) {
    for (const w of epochs.get(e)!.windows) for (let i = 0; i < 4; i++) { mine.delete(w + i); status.delete(w + i); skipped.delete(w + i); }
    epochs.delete(e);
  }
  console.log(`epoch ${v.epoch}: ${windows.length} leader windows, stake rank ${rank}`);
}

function onSlot(p: any) {
  const m = mine.get(p.slot);
  if (!m) return;
  const lv = p.level as string;
  let st: 'ok' | 'skip' | null = null;
  if (lv === 'skipped' || lv === 'skip_notarized' || p.skipped === true) st = 'skip';
  else if (lv !== 'incomplete') st = 'ok';
  if (lv === 'skipped' || (p.skipped === true && (lv === 'rooted' || lv === 'finalized'))) skipped.add(p.slot);
  if (st && status.get(p.slot) !== st) {
    status.set(p.slot, st);
    const fee = BigInt(p.transaction_fee ?? 0) + BigInt(p.priority_fee ?? 0) + BigInt(p.tips ?? 0);
    broadcast({ t: 'slot', s: p.slot, i: m.i, st, tx: (p.success_transaction_cnt ?? 0) + (p.failed_transaction_cnt ?? 0), fee: Number(fee) });
    if (m.i === 3) setTimeout(() => broadcast(info()), 400); // the next window's countdown, right away
  }
}

function onPeers(v: any) {
  for (const p of [...(v.add ?? []), ...(v.update ?? [])]) {
    if ((p.identity_pubkey ?? p.identity) !== IDENTITY) continue;
    const vote = (p.vote ?? [])[0] ?? {};
    peer = { name: p.info?.name ?? peer.name, stake: vote.activated_stake, commission: vote.commission,
             lastVote: vote.last_vote, delinquent: vote.delinquent };
  }
}

// The GUI's peers topic leaves commission and last vote at 0: read them from RPC.
async function readVote() {
  try {
    const r = await fetch(RPC_URL, { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'getVoteAccounts', params: [{ votePubkey: VOTE }] }) });
    const res = (await r.json()).result;
    const v = res.current[0] ?? res.delinquent[0];
    if (!v) return;
    vote = { bps: v.inflationRewardsCommissionBps ?? v.commission * 100, stake: BigInt(v.activatedStake),
             delinquent: res.delinquent.length > 0 };
  } catch (e) { console.log('rpc:', String(e)); }
}
let vote: { bps: number; stake: bigint; delinquent: boolean } | null = null;
readVote();
setInterval(readVote, 5 * MINUTE);

function info() {
  const e = [...epochs.values()].find((x) => est >= x.start && est <= x.end);
  const all = e ? e.windows : [];
  const past = all.filter((w) => w + 3 <= root).length * 4;
  let skips = 0;
  for (const s of skipped) if (e && s >= e.start && s <= e.end) skips++;
  const next = [...epochs.values()].flatMap((x) => x.windows).filter((w) => w + 3 >= est).sort((a, b) => a - b)[0];
  const stake = vote?.stake ?? (peer.stake ? BigInt(peer.stake) : e?.stake ?? 0n);
  return {
    t: 'info',
    name: peer.name ?? 'Galaxy',
    stake: Number(stake / LAMPORTS),                         // SOL, fits a badge's 32-bit integers
    share: e && e.total > 0n ? Number((stake * 100000n) / e.total) / 1000 : 0,  // % of all stake
    rank: e?.rank ?? 0,
    comm: vote ? vote.bps / 100 : null,                      // %
    delinq: vote?.delinquent ?? peer.delinquent ?? false,
    epoch: e?.epoch ?? 0,
    pct: e ? Math.floor(((est - e.start) * 100) / (e.end - e.start + 1)) : 0,
    slot: est,
    leader: all.length * 4,                                  // leader slots this epoch
    done: past - skips,                                      // produced so far (rooted)
    skip: skips,
    next: next ?? null,                                      // next (or current) window's first slot
    nextIn: next ? Math.max(0, Math.round(((next - est) * slotNs) / 1e8) / 10) : null, // seconds
    up: upstream,
  };
}

// ---------------------------------------------------------------- upstream
let delay = 1000;
function connect() {
  upstream = 'connecting';
  const ws = new WebSocket(FD_WS, process.env.HTTPS_PROXY ? ({ proxy: process.env.HTTPS_PROXY } as any) : undefined);
  ws.onopen = () => { upstream = 'live'; delay = 1000; console.log('upstream open'); };
  ws.onmessage = (ev) => {
    let j: any;
    try { j = JSON.parse(typeof ev.data === 'string' ? ev.data : new TextDecoder().decode(ev.data as ArrayBuffer)); } catch { return; }
    const { topic, key, value } = j;
    if (topic === 'slot' && key === 'update') onSlot(value.publish);
    else if (topic === 'summary') {
      if (key === 'estimated_slot') est = value;
      else if (key === 'root_slot') root = value;
      else if (key === 'estimated_slot_duration_nanos') slotNs = value;
    } else if (topic === 'epoch' && key === 'new') onEpoch(value);
    else if (topic === 'peers' && key === 'update') onPeers(value);
    else if (topic === 'slot' && key === 'skipped_history_cluster') {
      for (const s of value as number[]) if (mine.has(s)) skipped.add(s);
    }
  };
  ws.onclose = () => {
    upstream = 'reconnecting';
    console.log(`upstream closed, again in ${delay} ms`);
    setTimeout(connect, delay);
    delay = Math.min(delay * 2, 30_000);
  };
  ws.onerror = () => {};
}
connect();

// ---------------------------------------------------------------- badge ticket (LUA_API.md "ws")
const keys = new Map<string, CryptoKey>();
const seen = new Map<string, number>();
let fetching: Promise<void> | null = null;
let fetchedAt = 0;

async function badgeKey(id: string): Promise<CryptoKey | null> {
  if (!keys.has(id) && !fetching && Date.now() - fetchedAt > MINUTE) {
    fetchedAt = Date.now();
    fetching = (async () => {
      const k = await (await fetch(`${BADGE_SERVER}/api/http/key`)).json();
      const raw = Uint8Array.from(atob(k.key), (c) => c.charCodeAt(0));
      keys.set(k.id, await crypto.subtle.importKey('raw', raw, 'Ed25519', false, ['verify']));
    })().catch(() => { fetchedAt = 0; }).finally(() => { fetching = null; });
  }
  if (!keys.has(id) && fetching) await fetching;
  return keys.get(id) ?? null;
}

function once(key: string, time: number): boolean {
  const now = Date.now();
  for (const [k, t] of seen) if (now - t > MINUTE) seen.delete(k);
  if (seen.has(key)) return false;
  seen.set(key, time);
  return true;
}

async function fromBadgeSocket(url: string) {
  const ticket = new URL(url).searchParams.get('badge_ticket') ?? '';
  const [a, badge, user, time, request, keyId, sig, extra] = ticket.split('.');
  if (extra !== undefined || a !== APP || !sig || !request || !(Math.abs(Date.now() - Number(time)) < MINUTE)) return null;
  const key = await badgeKey(keyId);
  if (!key) return null;
  const signed = ['badge-ws-v1', HOST, APP, badge, user, time, request].join('\n');
  const raw = Uint8Array.from(atob(sig.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));
  if (!(await crypto.subtle.verify('Ed25519', key, raw, new TextEncoder().encode(signed)))) return null;
  if (!once(request, Number(time))) return null;
  return { badge, user };
}

// ---------------------------------------------------------------- badges
const clients = new Set<any>();
function broadcast(m: object) {
  const s = JSON.stringify(m);
  for (const c of clients) c.send(s);
}
setInterval(() => broadcast(info()), 5000);

Bun.serve<{ badge: string }>({
  port: Number(process.env.PORT ?? 8080),
  async fetch(req, server) {
    const u = new URL(req.url);
    if (u.pathname === '/status') return Response.json(info());
    if (u.pathname === '/live') {
      const who = DEV ? { badge: 'dev', user: 'dev' } : await fromBadgeSocket(PUBLIC_URL + u.pathname + u.search);
      if (who && server.upgrade(req, { data: { badge: who.badge } })) return undefined;
      return new Response('no', { status: 403 });
    }
    return new Response('Galaxy Live relay', { status: 404 });
  },
  websocket: {
    open(ws) { clients.add(ws); ws.send(JSON.stringify(info())); },
    close(ws) { clients.delete(ws); },
    message() {},
  },
});
console.log(`relay for ${IDENTITY} on :${process.env.PORT ?? 8080}, upstream ${FD_WS}`);
