// Galaxy Live relay, the part that is the same wherever it runs (Bun: server.ts,
// Cloudflare: worker/src/index.ts): it takes the Firedancer GUI websocket's
// messages and builds the badge-sized ones.
//
//   {"t":"f", "e", "ok", "fail"}   ten times a second: the estimated slot and the
//                      cluster's TPS (successful, failed). Nothing else: every window's
//                      details come in "w" messages, only when they change.
//   {"t":"slot", ...}  each of our slots, as soon as it completes or is skipped
//   {"t":"info", ...}  stake, rank, epoch, blocks, skips, our next 24 windows, last 16 blocks
//   {"t":"w", ...}     one leader window in full: start, leader name, 1 if ours, its stake
//                      (SOL) and country, and for each of its 4 slots [state, tx, failed tx,
//                      fees (lamports, base + priority), tips (lamports), ms, CU %]. Sent
//                      whenever it changes (the two windows before the current one, the
//                      current one and the two next), and the last 16 and the next 2 to a
//                      client that connects.
//
// Slot state digits: 0 future, 1 being made, 2 completed, 3 notarized / confirmed,
// 4 rooted / finalized, 5 skipped.

const LAMPORTS = 1_000_000_000n;
const MINUTE = 60_000;

type Epoch = {
  epoch: number; start: number; end: number;
  keys: string[]; leaders: number[];                 // the schedule: keys[leaders[(slot - start) / 4]]
  stakes: bigint[]; total: bigint;                   // stake of each of keys, and their sum
  own?: { id: string; windows: number[]; rank: number; stake: bigint };   // the followed validator's, worked out when asked
};

const LEVEL: Record<string, number> = {
  incomplete: 1, completed: 2, notarized: 3, optimistically_confirmed: 3,
  rooted: 4, finalized: 4, skip_notarized: 5, skipped: 5,
};

export type Vote = { bps: number; stake: bigint; delinquent: boolean };

export class Relay {
  epochs = new Map<number, Epoch>();
  names = new Map<string, string>();                 // identity -> validator name
  slots = new Map<number, { st: number; ok: number; fail: number; fee: number; ms: number; base: number; tip: number; cu: number }>();
  stakes = new Map<string, bigint>();               // identity -> stake (lamports), this epoch
  countries = new Map<string, string>();            // identity -> country code (gossip)
  private sentW = new Map<number, string>();        // window start -> what we last sent of it
  sent = new Map<number, 'ok' | 'skip'>();           // what badges heard about each of our slots
  skipped = new Set<number>();                       // our slots skipped for good
  ourBlocks: { s: number; tx: number; skip: boolean }[] = [];   // our last 16 slots, newest first
  est = 0; root = 0; slotNs = 400_000_000; tpsOk = 0; tpsFail = 0;
  upstream = 'connecting';
  vote: Vote | null = null;

  voteKey = '';                    // the followed validator's vote account
  version = '';                    // the dashboard's Firedancer version
  private pinned: boolean;         // the identity was given, not the dashboard's own

  /** identity: the validator to follow, or '' for the dashboard's own (it says which: summary
   *  identity_key and vote_key). send: a message for every badge. later: run fn in ms. */
  constructor(private identity: string, private send: (m: object) => void,
              private later: (fn: () => void, ms: number) => void, private log: (s: string) => void = () => {}) {
    this.pinned = identity !== '';
  }

  /** The followed validator's leader windows, stake and rank in an epoch. */
  private own(e: Epoch | undefined) {
    if (!e) return { id: this.identity, windows: [] as number[], rank: 0, stake: 0n };
    if (e.own?.id === this.identity) return e.own;
    const idx = this.identity ? e.keys.indexOf(this.identity) : -1;
    const windows: number[] = [];
    if (idx >= 0) e.leaders.forEach((x, n) => { if (x === idx) windows.push(e.start + 4 * n); });
    const my = idx >= 0 ? e.stakes[idx] : 0n;
    e.own = { id: this.identity, windows, rank: idx >= 0 ? e.stakes.filter((x) => x > my).length + 1 : 0, stake: my };
    return e.own;
  }

  // The topics the relay reads. The dashboard sends much more (megabytes of gossip, shreds and
  // tile metrics): those are dropped on their first bytes, unparsed.
  private static WANTED = new Set(['slot/update', 'slot/skipped_history_cluster', 'epoch/new', 'peers/update',
    'summary/estimated_slot', 'summary/root_slot', 'summary/estimated_slot_duration_nanos', 'summary/estimated_tps',
    'summary/identity_key', 'summary/vote_key', 'summary/version']);

  /** One message from the Firedancer GUI websocket, as text. */
  handleRaw(text: string) {
    const m = /^\{"topic":"([a-z_]+)","key":"([a-z_]+)"/.exec(text.length > 96 ? text.slice(0, 96) : text);
    if (m && !Relay.WANTED.has(m[1] + '/' + m[2])) return;
    let j: unknown;
    try { j = JSON.parse(text); } catch { return; }
    this.handle(j);
  }

  private epochOf(s: number) { for (const e of this.epochs.values()) if (s >= e.start && s <= e.end) return e; }
  private leaderOf(s: number): string | null {
    const e = this.epochOf(s);
    return e ? e.keys[e.leaders[Math.floor((s - e.start) / 4)]] ?? null : null;
  }
  private nameOf(id: string | null) {
    if (!id) return '?';
    const n = (this.names.get(id) ?? id.slice(0, 4) + '..' + id.slice(-4)).replace(/[^\x20-\x7e]/g, '').trim();
    return n.slice(0, 16) || id.slice(0, 8);
  }

  /** One message from the Firedancer GUI websocket, parsed. */
  handle(j: any) {
    const { topic, key, value } = j ?? {};
    if (topic === 'slot' && key === 'update') this.onSlot(value.publish);
    else if (topic === 'summary') {
      if (key === 'estimated_slot') this.est = value;
      else if (key === 'root_slot') this.root = value;
      else if (key === 'estimated_slot_duration_nanos') this.slotNs = value;
      else if (key === 'estimated_tps') { this.tpsOk = value.success ?? 0; this.tpsFail = value.failed ?? 0; }
      else if (key === 'version') this.version = String(value);
      else if (key === 'identity_key' && !this.pinned && typeof value === 'string' && value !== this.identity) {
        this.identity = value;                       // follow the dashboard's own validator
        this.vote = null; this.ourBlocks = []; this.sent.clear(); this.skipped.clear();
        this.log(`following the dashboard's validator ${value}`);
      } else if (key === 'vote_key' && !this.pinned && typeof value === 'string') this.voteKey = value;
    } else if (topic === 'epoch' && key === 'new') this.onEpoch(value);
    else if (topic === 'peers' && key === 'update') {
      for (const p of [...(value.add ?? []), ...(value.update ?? [])]) {
        const id = p.identity_pubkey ?? p.identity;
        if (id && p.info?.name) this.names.set(id, p.info.name);
        if (id && p.gossip?.country_code) this.countries.set(id, String(p.gossip.country_code).slice(0, 2).toUpperCase());
      }
    } else if (topic === 'slot' && key === 'skipped_history_cluster') {
      for (const s of value as number[]) if (this.leaderOf(s) === this.identity) this.skipped.add(s);
    }
  }

  private onEpoch(v: any) {
    const keys = v.staked_pubkeys as string[];
    const stakes = (v.staked_lamports as string[]).map(BigInt);
    const e: Epoch = { epoch: v.epoch, start: v.start_slot, end: v.end_slot, keys, leaders: v.leader_slots,
                       stakes, total: stakes.reduce((a, b) => a + b, 0n) };
    this.epochs.set(v.epoch, e);
    for (const n of [...this.epochs.keys()]) if (n < v.epoch - 1) this.epochs.delete(n);
    if (!this.stakes.size || v.start_slot <= this.est) {     // this epoch's (the next one comes early)
      this.stakes = new Map(keys.map((k, i) => [k, stakes[i]]));
    }
    this.log(`epoch ${v.epoch}: ${keys.length} validators`);
  }

  private onSlot(p: any) {
    let st = LEVEL[p.level as string] ?? 1;
    if (p.skipped === true) st = 5;
    const ok = p.success_transaction_cnt ?? 0, fail = p.failed_transaction_cnt ?? 0, tx = ok + fail;
    const lamports = Number(BigInt(p.transaction_fee ?? 0) + BigInt(p.priority_fee ?? 0) + BigInt(p.tips ?? 0));
    const big = (v: unknown) => Math.min(Number(BigInt(String(v ?? 0).split('.')[0] || '0')), 2147483647);
    this.slots.set(p.slot, { st, ok, fail, fee: lamports, ms: Math.round((p.duration_nanos ?? 0) / 1e6),
      base: big(p.transaction_fee) + big(p.priority_fee), tip: big(p.tips),
      cu: p.max_compute_units > 0 ? Math.round((p.compute_units ?? 0) * 100 / p.max_compute_units) : 0 });
    if (this.leaderOf(p.slot) !== this.identity) return;
    if (p.level === 'skipped' || (p.skipped === true && (p.level === 'rooted' || p.level === 'finalized'))) this.skipped.add(p.slot);
    const now: 'ok' | 'skip' | null = st === 5 ? 'skip' : st >= 2 ? 'ok' : null;
    if (now && this.sent.get(p.slot) !== now) {
      this.sent.set(p.slot, now);
      const b = this.ourBlocks.find((x) => x.s === p.slot);
      if (b) { b.tx = tx; b.skip = now === 'skip'; }
      else { this.ourBlocks.unshift({ s: p.slot, tx, skip: now === 'skip' }); this.ourBlocks.length = Math.min(this.ourBlocks.length, 16); }
      const fee = BigInt(p.transaction_fee ?? 0) + BigInt(p.priority_fee ?? 0) + BigInt(p.tips ?? 0);
      this.send({ t: 'slot', s: p.slot, i: p.slot % 4, st: now, tx, fee: Number(fee) });
      if (p.slot % 4 === 3) this.later(() => this.send(this.info()), 400); // the next countdown, right away
    }
  }

  /** Ten times a second: where the cluster is and its TPS. */
  frame() {
    return { t: 'f', e: this.est, ok: Math.round(this.tpsOk), fail: Math.round(this.tpsFail) };
  }

  info() {
    const est = this.est, e = this.epochOf(est);
    const mine = this.own(e), all = mine.windows;
    const past = all.filter((w) => w + 3 <= this.root).length * 4;
    let skips = 0;
    for (const s of this.skipped) if (e && s >= e.start && s <= e.end) skips++;
    const upcoming = [...this.epochs.values()].flatMap((x) => this.own(x).windows).filter((w) => w + 3 >= est).sort((a, b) => a - b).slice(0, 24);
    const stake = this.vote?.stake ?? mine.stake;
    return {
      t: 'info',
      name: this.nameOf(this.identity),
      stake: Number(stake / LAMPORTS),                         // SOL, fits a badge's 32-bit integers
      share: e && e.total > 0n ? Number((stake * 100000n) / e.total) / 1000 : 0,
      rank: mine.rank,
      ver: this.version,                                       // the dashboard's Firedancer version
      comm: this.vote ? this.vote.bps / 100 : null,
      delinq: this.vote?.delinquent ?? false,
      epoch: e?.epoch ?? 0,
      pct: e ? Math.floor(((est - e.start) * 100) / (e.end - e.start + 1)) : 0,
      slot: est,
      sd: Math.round(this.slotNs / 1e6),                       // ms per slot
      leader: all.length * 4,
      done: past - skips,
      skip: skips,
      next: upcoming,                                          // our next window starts (the first may be under way)
      last: this.ourBlocks.map((b) => [b.tx, b.skip ? 1 : 0]), // our last 16 slots, newest first
      up: this.upstream,
    };
  }

  /** One leader window in full (see the top of this file). */
  window(w: number) {
    const id = this.leaderOf(w);
    const d = [];
    for (let s = w; s < w + 4; s++) {
      const x = this.slots.get(s);
      d.push(x ? [x.st, x.ok + x.fail, x.fail, x.base, x.tip, x.ms, x.cu] : [s <= this.est ? 1 : 0, 0, 0, 0, 0, 0, 0]);
    }
    const stake = id ? this.stakes.get(id) ?? 0n : 0n;
    return { t: 'w', s: w, n: this.nameOf(id), o: id === this.identity ? 1 : 0, k: Number(stake / LAMPORTS),
             c: (id && this.countries.get(id)) || '', d };
  }

  /** The windows that changed since we last said: the two before, the current one, the two next. */
  changedWindows() {
    const cur = this.est - (this.est % 4), out = [];
    for (let w = cur - 8; w <= cur + 8; w += 4) {          // the two before, the current one, the two next
      const m = this.window(w), k = JSON.stringify(m);
      if (this.sentW.get(w) !== k) { this.sentW.set(w, k); out.push(m); }
    }
    for (const w of this.sentW.keys()) if (w < cur - 64) this.sentW.delete(w);
    return out;
  }

  /** The last n windows, the current one and the two next, oldest first: for a client that connects. */
  history(n: number) {
    const cur = this.est - (this.est % 4), out = [];
    for (let w = cur - 4 * n; w <= cur + 8; w += 4) out.push(this.window(w));
    return out;
  }

  /** Forget slots the carousel no longer shows. Call now and then. */
  prune() { for (const s of this.slots.keys()) if (s < this.est - 400) this.slots.delete(s); }

  /** Commission, stake and delinquency: the GUI's peers topic leaves them at 0. From RPC
   *  (getVoteAccounts), else from Stakewiz: public RPC nodes refuse some clouds' addresses. */
  async readVote(rpcUrl: string, pinnedVote: string) {
    const votePubkey = pinnedVote || this.voteKey;
    if (!votePubkey) return;
    try {
      const r = await fetch(rpcUrl, { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'getVoteAccounts', params: [{ votePubkey }] }) });
      const res = ((await r.json()) as any).result;
      const v = res.current[0] ?? res.delinquent[0];
      if (v) {
        this.vote = { bps: v.inflationRewardsCommissionBps ?? v.commission * 100, stake: BigInt(v.activatedStake),
                      delinquent: res.delinquent.length > 0 };
        return;
      }
    } catch (e) { this.log('rpc: ' + String(e)); }
    try {
      const v = (await (await fetch(`https://api.stakewiz.com/validator/${votePubkey}`)).json()) as any;
      if (typeof v.commission === 'number' && typeof v.activated_stake === 'number') {
        this.vote = { bps: v.commission, stake: BigInt(Math.round(v.activated_stake * 1e6)) * 1000n, delinquent: v.delinquent === true };
      }
    } catch (e) { this.log('stakewiz: ' + String(e)); }
  }
}

// ---------------------------------------------------------------- badge ticket (LUA_API.md "ws")
const keys = new Map<string, CryptoKey>();
const seen = new Map<string, number>();
let fetching: Promise<void> | null = null;
let fetchedAt = 0;

async function badgeKey(badgeServer: string, id: string): Promise<CryptoKey | null> {
  if (!keys.has(id) && !fetching && Date.now() - fetchedAt > MINUTE) {
    fetchedAt = Date.now();
    fetching = (async () => {
      const k = (await (await fetch(`${badgeServer}/api/http/key`)).json()) as any;
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

/** The badge and player opening a socket, or null. url: as the badge called it; host: its host. */
export async function fromBadgeSocket(url: string, app: string, host: string, badgeServer: string) {
  const ticket = new URL(url).searchParams.get('badge_ticket') ?? '';
  const [a, badge, user, time, request, keyId, sig, extra] = ticket.split('.');
  if (extra !== undefined || a !== app || !sig || !request || !(Math.abs(Date.now() - Number(time)) < MINUTE)) return null;
  const key = await badgeKey(badgeServer, keyId);
  if (!key) return null;
  const signed = ['badge-ws-v1', host, app, badge, user, time, request].join('\n');
  const raw = Uint8Array.from(atob(sig.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));
  if (!(await crypto.subtle.verify('Ed25519', key, raw, new TextEncoder().encode(signed)))) return null;
  if (!once(request, Number(time))) return null;   // one ticket, one socket
  return { badge, user };
}
