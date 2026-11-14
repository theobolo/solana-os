// Galaxy Live relay: follows a Firedancer GUI websocket and hands the badge app
// (apps/galaxy/main.lua) a live, badge-sized view of the cluster and of ONE
// validator (Galaxy by default).
//
//   GET /live      the badge's WebSocket (badge_ticket checked, see LUA_API.md "ws")
//   GET /status    the latest info and frame as JSON, for you
//
// Why a relay: the Firedancer GUI sends two ~370 KB leader schedules on connect
// and hundreds of messages a second; a badge closes a socket on any message over
// 4 KB and holds 8. The relay keeps the schedule and the slots' states and sends:
//
//   {"t":"f", ...}     every FRAME_MS (100 ms) when something changed: the leader
//                      carousel, i.e. the 2 next leader windows, the current one and
//                      the 2 before, each [start, leader name, 1 if ours, 4 state
//                      digits, tx, [ok, fail] x 4], plus the estimated slot and the cluster's TPS
//                      (ok, fail). A whole picture each time, so a lost or late
//                      frame costs nothing.
//   {"t":"slot", ...}  each of our slots, as soon as it completes or is skipped
//   {"t":"info", ...}  every 2 s: stake, rank, epoch, blocks, skips, our next 24 windows
//
// Slot state digits: 0 future, 1 being made, 2 completed, 3 notarized / confirmed,
// 4 rooted / finalized, 5 skipped.
//
// Run it with Bun behind HTTPS on port 443 at the host the app lists:
//
//   PUBLIC_URL=https://galaxy.example.com PORT=8080 bun server.ts
//
// Env: FD_WS (Firedancer GUI websocket), IDENTITY and VOTE (the validator's keys),
// RPC_URL (for commission, stake and delinquency), APP (the badge app id),
// FRAME_MS (default 100), DEV_NO_TICKET=1 to let any client in (local tests only).

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
const MINUTE = 60_000;
const LAMPORTS = 1_000_000_000n;

// ---------------------------------------------------------------- cluster state
type Epoch = {
  epoch: number; start: number; end: number;
  keys: string[]; leaders: number[];                 // the schedule: keys[leaders[(slot - start) / 4]]
  windows: number[]; rank: number; stake: bigint; total: bigint;   // ours
};
const epochs = new Map<number, Epoch>();
const names = new Map<string, string>();             // identity -> validator name
const slots = new Map<number, { st: number; ok: number; fail: number }>();  // recent slots' state
const ourBlocks: { s: number; tx: number; skip: boolean }[] = [];  // our last 16 slots, newest first
const sent = new Map<number, 'ok' | 'skip'>();       // what badges heard about each of our slots
const skipped = new Set<number>();                   // our slots skipped for good
let est = 0, root = 0, slotNs = 400_000_000, tpsOk = 0, tpsFail = 0;
let upstream = 'connecting';

const epochOf = (s: number) => [...epochs.values()].find((e) => s >= e.start && s <= e.end);
function leaderOf(s: number): string | null {
  const e = epochOf(s);
  return e ? e.keys[e.leaders[Math.floor((s - e.start) / 4)]] ?? null : null;
}
const isOurs = (s: number) => leaderOf(s) === IDENTITY;
function nameOf(id: string | null) {
  if (!id) return '?';
  const n = (names.get(id) ?? id.slice(0, 4) + '..' + id.slice(-4)).replace(/[^\x20-\x7e]/g, '').trim();
  return n.slice(0, 16) || id.slice(0, 8);
}

function onEpoch(v: any) {
  const keys = v.staked_pubkeys as string[];
  const idx = keys.indexOf(IDENTITY);
  const windows: number[] = [];
  if (idx >= 0) (v.leader_slots as number[]).forEach((x, n) => { if (x === idx) windows.push(v.start_slot + 4 * n); });
  const stakes = (v.staked_lamports as string[]).map(BigInt);
  const my = idx >= 0 ? stakes[idx] : 0n;
  epochs.set(v.epoch, {
    epoch: v.epoch, start: v.start_slot, end: v.end_slot, keys, leaders: v.leader_slots, windows,
    rank: idx >= 0 ? stakes.filter((s) => s > my).length + 1 : 0, stake: my,
    total: stakes.reduce((a, b) => a + b, 0n),
  });
  for (const e of [...epochs.keys()]) if (e < v.epoch - 1) epochs.delete(e);
  console.log(`epoch ${v.epoch}: ${windows.length} leader windows, stake rank ${epochs.get(v.epoch)!.rank}`);
}

const LEVEL: Record<string, number> = {
  incomplete: 1, completed: 2, notarized: 3, optimistically_confirmed: 3,
  rooted: 4, finalized: 4, skip_notarized: 5, skipped: 5,
};

function onSlot(p: any) {
  let st = LEVEL[p.level as string] ?? 1;
  if (p.skipped === true) st = 5;
  const ok = p.success_transaction_cnt ?? 0, fail = p.failed_transaction_cnt ?? 0, tx = ok + fail;
  slots.set(p.slot, { st, ok, fail });
  if (!isOurs(p.slot)) return;
  if (p.level === 'skipped' || (p.skipped === true && (p.level === 'rooted' || p.level === 'finalized'))) skipped.add(p.slot);
  const now: 'ok' | 'skip' | null = st === 5 ? 'skip' : st >= 2 ? 'ok' : null;
  if (now && sent.get(p.slot) !== now) {
    sent.set(p.slot, now);
    const b = ourBlocks.find((x) => x.s === p.slot);
    if (b) { b.tx = tx; b.skip = now === 'skip'; }
    else { ourBlocks.unshift({ s: p.slot, tx, skip: now === 'skip' }); ourBlocks.length = Math.min(ourBlocks.length, 16); }
    const fee = BigInt(p.transaction_fee ?? 0) + BigInt(p.priority_fee ?? 0) + BigInt(p.tips ?? 0);
    broadcast({ t: 'slot', s: p.slot, i: p.slot % 4, st: now, tx, fee: Number(fee) });
    if (p.slot % 4 === 3) setTimeout(() => broadcast(info()), 400); // the next countdown, right away
  }
}

function onPeers(v: any) {
  for (const p of [...(v.add ?? []), ...(v.update ?? [])]) {
    const id = p.identity_pubkey ?? p.identity;
    if (id && p.info?.name) names.set(id, p.info.name);
  }
}

// The GUI's peers topic leaves commission and last vote at 0: read them from RPC.
let vote: { bps: number; stake: bigint; delinquent: boolean } | null = null;
async function readVote() {
  try {
    const r = await fetch(RPC_URL, { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'getVoteAccounts', params: [{ votePubkey: VOTE }] }) });
    const res = (await r.json()).result;
    const v = res.current[0] ?? res.delinquent[0];
    if (v) vote = { bps: v.inflationRewardsCommissionBps ?? v.commission * 100, stake: BigInt(v.activatedStake),
                    delinquent: res.delinquent.length > 0 };
  } catch (e) { console.log('rpc:', String(e)); }
}
readVote();
setInterval(readVote, 5 * MINUTE);

// ---------------------------------------------------------------- what badges get
function frame() {
  const cur = est - (est % 4);
  const rows = [];
  for (let w = cur + 8; w >= cur - 8; w -= 4) {            // 2 next, current, 2 before
    let cells = '', tx = 0;
    const per: number[] = [];                              // ok, fail for each of the 4 slots
    for (let s = w; s < w + 4; s++) {
      const x = slots.get(s);
      cells += x ? x.st : s <= est ? 1 : 0;
      tx += x ? x.ok + x.fail : 0;
      per.push(x?.ok ?? 0, x?.fail ?? 0);
    }
    const id = leaderOf(w);
    rows.push([w, nameOf(id), id === IDENTITY ? 1 : 0, cells, tx, per]);
  }
  return { t: 'f', e: est, ok: Math.round(tpsOk), fail: Math.round(tpsFail), r: rows };
}

function info() {
  const e = epochOf(est);
  const all = e ? e.windows : [];
  const past = all.filter((w) => w + 3 <= root).length * 4;
  let skips = 0;
  for (const s of skipped) if (e && s >= e.start && s <= e.end) skips++;
  const upcoming = [...epochs.values()].flatMap((x) => x.windows).filter((w) => w + 3 >= est).sort((a, b) => a - b).slice(0, 24);
  const stake = vote?.stake ?? e?.stake ?? 0n;
  return {
    t: 'info',
    name: nameOf(IDENTITY),
    stake: Number(stake / LAMPORTS),                         // SOL, fits a badge's 32-bit integers
    share: e && e.total > 0n ? Number((stake * 100000n) / e.total) / 1000 : 0,
    rank: e?.rank ?? 0,
    comm: vote ? vote.bps / 100 : null,
    delinq: vote?.delinquent ?? false,
    epoch: e?.epoch ?? 0,
    pct: e ? Math.floor(((est - e.start) * 100) / (e.end - e.start + 1)) : 0,
    slot: est,
    sd: Math.round(slotNs / 1e6),                            // ms per slot
    leader: all.length * 4,
    done: past - skips,
    skip: skips,
    next: upcoming,                                          // our next window starts (the first may be under way)
    last: ourBlocks.map((b) => [b.tx, b.skip ? 1 : 0]),      // our last 16 slots, newest first
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
      else if (key === 'estimated_tps') { tpsOk = value.success ?? 0; tpsFail = value.failed ?? 0; }
    } else if (topic === 'epoch' && key === 'new') onEpoch(value);
    else if (topic === 'peers' && key === 'update') onPeers(value);
    else if (topic === 'slot' && key === 'skipped_history_cluster') {
      for (const s of value as number[]) if (isOurs(s)) skipped.add(s);
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

// forget old slots
setInterval(() => { for (const s of slots.keys()) if (s < est - 400) slots.delete(s); }, 10_000);

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
let lastFrame = '';
setInterval(() => {
  if (!clients.size || !est) return;
  const s = JSON.stringify(frame());
  if (s === lastFrame) return;                 // nothing moved
  lastFrame = s;
  for (const c of clients) c.send(s);
}, FRAME_MS);
setInterval(() => broadcast(info()), 2000);

Bun.serve<{ badge: string }>({
  port: Number(process.env.PORT ?? 8080),
  async fetch(req, server) {
    const u = new URL(req.url);
    if (u.pathname === '/status') return Response.json({ info: info(), frame: frame() });
    if (u.pathname === '/live') {
      const who = DEV ? { badge: 'dev', user: 'dev' } : await fromBadgeSocket(PUBLIC_URL + u.pathname + u.search);
      if (who && server.upgrade(req, { data: { badge: who.badge } })) return undefined;
      return new Response('no', { status: 403 });
    }
    return new Response('Galaxy Live relay', { status: 404 });
  },
  websocket: {
    open(ws) { clients.add(ws); ws.send(JSON.stringify(info())); if (est) ws.send(JSON.stringify(frame())); },
    close(ws) { clients.delete(ws); },
    message() {},
  },
});
console.log(`relay for ${IDENTITY} on :${process.env.PORT ?? 8080}, upstream ${FD_WS}, frames every ${FRAME_MS} ms`);
