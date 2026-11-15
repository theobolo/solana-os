// Firedancer GUI relay, the part that is the same wherever it runs (Bun: server.ts,
// Cloudflare: worker/src/index.ts): it takes the Firedancer GUI websocket's
// messages and builds the badge-sized ones (Relay), and hands each badge those of
// the validator it follows (Hub).
//
// To a badge:
//   {"t":"f", "e", "ok", "fail"}   ten times a second: the estimated slot and the
//                      cluster's TPS (successful, failed). Nothing else: every window's
//                      details come in "w" messages, only when they change.
//   {"t":"slot", ...}  each of the followed validator's slots, as soon as it completes or
//                      is skipped
//   {"t":"info", ...}  the followed validator: identity, name, country, stake, rank,
//                      epoch, blocks, skips, its next 24 windows and last 16 blocks
//   {"t":"w", ...}     one leader window in full: start, leader name, 1 if the followed
//                      validator's, its stake (SOL) and country, and for each of its 4
//                      slots [state, tx, failed tx, fees (lamports, base + priority), tips
//                      (lamports), ms, CU %]. Sent whenever it changes (the two windows
//                      before the current one, the current one and the two next), and the
//                      last 16 and the next 2 to a client that connects or follows another.
//   {"t":"list", "l"}  the answer to "list": the 20 biggest validators by stake, each
//                      [identity, name, stake (SOL), version, country]
//
// From a badge:
//   {"t":"follow", "id": identity}   follow that validator; {"t":"follow", "s": slot}
//                      the leader of that slot; {"t":"follow"} the default one (IDENTITY,
//                      or the dashboard's own). "n" (optional, a number) comes back in
//                      the answer's info, so the badge knows it from the 2 s infos still
//                      on their way. The answer: info, the windows, a frame.
//                      /live?v=<identity> says it when connecting.
//   {"t":"list"}
//   Anything else is ignored: the badge sends "{}" twice a second to keep its Wi-Fi awake.
//
// Slot state digits: 0 future, 1 being made, 2 completed, 3 notarized / confirmed,
// 4 rooted / finalized, 5 skipped.

const LAMPORTS = 1_000_000_000n;
const MINUTE = 60_000;
const BASE58 = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;

type Own = { windows: number[]; rank: number; stake: bigint };
type Epoch = {
  epoch: number; start: number; end: number;
  keys: string[]; leaders: number[];                 // the schedule: keys[leaders[(slot - start) / 4]]
  stakes: bigint[]; total: bigint;                   // stake of each of keys, and their sum
  own: Map<string, Own>;                             // a validator's windows, stake and rank, worked out when asked
};

const LEVEL: Record<string, number> = {
  incomplete: 1, completed: 2, notarized: 3, optimistically_confirmed: 3,
  rooted: 4, finalized: 4, skip_notarized: 5, skipped: 5,
};

export type Vote = { bps: number; stake: bigint; delinquent: boolean };
type Block = { s: number; tx: number; skip: boolean };
type Win = { leader: string | null; m: { t: 'w'; s: number; n: string; o: number; k: number; c: string; d: number[][] } };

/** A validator the relay follows for some badges, and what is only about it. */
export class Follow {
  vote: Vote | null = null;
  sent = new Map<number, 'ok' | 'skip'>();          // what badges heard about each of its slots
  blocks: Block[] = [];                              // its last 16 slots, newest first
  constructor(public id: string) {}
}

export class Relay {
  epochs = new Map<number, Epoch>();
  names = new Map<string, string>();                 // identity -> validator name
  slots = new Map<number, { st: number; ok: number; fail: number; ms: number; base: number; tip: number; cu: number }>();
  stakes = new Map<string, bigint>();               // identity -> stake (lamports), this epoch
  countries = new Map<string, string>();            // identity -> country code (gossip)
  versions = new Map<string, string>();             // identity -> software version (gossip)
  votes = new Map<string, string>();                // identity -> vote account (gossip)
  private peersRead = new Set<string>();            // identities a peers message told us about
  private sentW = new Map<number, string>();        // window start -> what we last sent of it
  skipped = new Set<number>();                       // the cluster's slots skipped for good
  est = 0; root = 0; slotNs = 400_000_000; tpsOk = 0; tpsFail = 0;
  upstream = 'connecting';
  main: Follow;                                      // the default validator, IDENTITY or the dashboard's own
  private others = new Map<string, Follow>();        // the ones badges chose
  private dormant = new Map<string, any>();          // ones no badge follows now, as snapshot() keeps them

  voteKey = '';                    // the dashboard's own vote account
  version = '';                    // the dashboard's Firedancer version
  private pinned: boolean;         // the identity was given, not the dashboard's own

  /** identity: the default validator, or '' for the dashboard's own (it says which: summary
   *  identity_key and vote_key). send: a message for the badges following `to`, or all.
   *  later: run fn in ms. */
  constructor(identity: string, private send: (m: object, to?: Follow) => void,
              private later: (fn: () => void, ms: number) => void, private log: (s: string) => void = () => {}) {
    this.pinned = identity !== '';
    this.main = new Follow(identity);
  }

  /** Every validator followed, the default one first. */
  follows() { return [this.main, ...this.others.values()]; }

  /** The Follow of an identity, made if new: the default one for '' or what isn't an identity. */
  follow(id: string): Follow {
    if (!id || id === this.main.id || !BASE58.test(id)) return this.main;
    let f = this.others.get(id);
    if (f) return f;
    if (this.others.size >= 64) return this.main;
    f = new Follow(id);
    const d = this.dormant.get(id);
    if (d) { this.take(f, d); this.dormant.delete(id); }
    for (const [s, x] of [...this.slots].sort((a, b) => b[0] - a[0])) {   // its blocks still in memory
      if (f.blocks.length >= 16) break;
      if (x.st < 2 || this.leaderOf(s) !== id || f.sent.has(s)) continue;
      f.sent.set(s, x.st === 5 ? 'skip' : 'ok');
      f.blocks.push({ s, tx: x.ok + x.fail, skip: x.st === 5 });
    }
    f.blocks.sort((a, b) => b.s - a.s);
    this.others.set(id, f);
    return f;
  }

  /** Let go of the chosen validators no badge follows any more (snapshot() still keeps them). */
  keep(inUse: Set<Follow>) {
    for (const [id, f] of this.others) {
      if (inUse.has(f)) continue;
      this.others.delete(id);
      this.dormant.delete(id);
      this.dormant.set(id, this.pack(f));
      while (this.dormant.size > 16) this.dormant.delete(this.dormant.keys().next().value!);
    }
  }

  /** A validator's leader windows, stake and rank in an epoch. */
  private own(e: Epoch | undefined, id: string): Own {
    if (!e) return { windows: [], rank: 0, stake: 0n };
    let o = e.own.get(id);
    if (o) return o;
    const idx = id ? e.keys.indexOf(id) : -1;
    const windows: number[] = [];
    if (idx >= 0) e.leaders.forEach((x, n) => { if (x === idx) windows.push(e.start + 4 * n); });
    const my = idx >= 0 ? e.stakes[idx] : 0n;
    o = { windows, rank: idx >= 0 ? e.stakes.filter((x) => x > my).length + 1 : 0, stake: my };
    if (e.own.size > 80) e.own.clear();
    e.own.set(id, o);
    return o;
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
    // After the first full list, peers/update is hundreds of gossip changes a second
    // ("info":null) about peers we know: only a name, or a peer we never read, matters.
    if (m && m[1] === 'peers' && !text.includes('"info":{') && this.knownPeers(text)) return;
    let j: unknown;
    try { j = JSON.parse(text); } catch { return; }
    this.handle(j);
  }

  /** Whether every peer a peers message names was read before. */
  private knownPeers(text: string) {
    for (const p of text.matchAll(/"identity_pubkey":"(\w+)"/g)) if (!this.peersRead.has(p[1])) return false;
    return true;
  }

  private epochOf(s: number) { for (const e of this.epochs.values()) if (s >= e.start && s <= e.end) return e; }
  private leaderOf(s: number): string | null {
    const e = this.epochOf(s);
    return e ? e.keys[e.leaders[Math.floor((s - e.start) / 4)]] ?? null : null;
  }
  /** The identity of slot s's leader, if the schedule has it. */
  leaderAt(s: number) { return this.leaderOf(s); }
  private nameOf(id: string | null) {
    if (!id) return '?';
    const n = (this.names.get(id) ?? id.slice(0, 4) + '..' + id.slice(-4)).replace(/[^\x20-\x7e]/g, '').trim();
    return n.slice(0, 16).trim() || id.slice(0, 8);
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
      else if (key === 'identity_key' && !this.pinned && typeof value === 'string' && value !== this.main.id) {
        const f = this.main;                         // the same object: badges following "the default" keep it
        f.id = value; f.vote = null; f.blocks = []; f.sent.clear();
        this.log(`following the dashboard's validator ${value}`);
      } else if (key === 'vote_key' && !this.pinned && typeof value === 'string') this.voteKey = value;
    } else if (topic === 'epoch' && key === 'new') this.onEpoch(value);
    else if (topic === 'peers' && key === 'update') {
      for (const p of [...(value.add ?? []), ...(value.update ?? [])]) {
        const id = p.identity_pubkey ?? p.identity;
        if (!id) continue;
        this.peersRead.add(id);
        if (p.info?.name) this.names.set(id, p.info.name);
        if (p.gossip?.country_code) this.countries.set(id, String(p.gossip.country_code).slice(0, 2).toUpperCase());
        if (p.gossip?.version) this.versions.set(id, String(p.gossip.version).slice(0, 12));
        if (p.vote?.[0]?.vote_account) this.votes.set(id, p.vote[0].vote_account);
      }
    } else if (topic === 'slot' && key === 'skipped_history_cluster') {
      for (const s of value as number[]) this.skipped.add(s);
    }
  }

  private onEpoch(v: any) {
    const keys = v.staked_pubkeys as string[];
    const stakes = (v.staked_lamports as string[]).map(BigInt);
    const e: Epoch = { epoch: v.epoch, start: v.start_slot, end: v.end_slot, keys, leaders: v.leader_slots,
                       stakes, total: stakes.reduce((a, b) => a + b, 0n), own: new Map() };
    this.epochs.set(v.epoch, e);
    for (const n of [...this.epochs.keys()]) if (n < v.epoch - 1) this.epochs.delete(n);
    if (!this.stakes.size || v.start_slot <= this.est) {     // this epoch's (the next one comes early)
      this.stakes = new Map(keys.map((k, i) => [k, stakes[i]]));
    }
    const oldest = Math.min(...[...this.epochs.values()].map((x) => x.start));
    for (const s of this.skipped) if (s < oldest) this.skipped.delete(s);
    this.log(`epoch ${v.epoch}: ${keys.length} validators`);
  }

  private onSlot(p: any) {
    let st = LEVEL[p.level as string] ?? 1;
    if (p.skipped === true) st = 5;
    const ok = p.success_transaction_cnt ?? 0, fail = p.failed_transaction_cnt ?? 0, tx = ok + fail;
    const big = (v: unknown) => Math.min(Number(BigInt(String(v ?? 0).split('.')[0] || '0')), 2147483647);
    this.slots.set(p.slot, { st, ok, fail, ms: Math.round((p.duration_nanos ?? 0) / 1e6), base: big(p.transaction_fee) + big(p.priority_fee), tip: big(p.tips),
      cu: p.max_compute_units > 0 ? Math.round((p.compute_units ?? 0) * 100 / p.max_compute_units) : 0 });
    if (p.level === 'skipped' || (p.skipped === true && (p.level === 'rooted' || p.level === 'finalized'))) this.skipped.add(p.slot);
    const now: 'ok' | 'skip' | null = st === 5 ? 'skip' : st >= 2 ? 'ok' : null;
    const leader = this.leaderOf(p.slot);
    if (!now || !leader) return;
    for (const f of this.follows()) {
      if (f.id !== leader || f.sent.get(p.slot) === now) continue;
      f.sent.set(p.slot, now);
      const b = f.blocks.find((x) => x.s === p.slot);
      if (b) { b.tx = tx; b.skip = now === 'skip'; }
      else { f.blocks.unshift({ s: p.slot, tx, skip: now === 'skip' }); f.blocks.length = Math.min(f.blocks.length, 16); }
      const fee = BigInt(p.transaction_fee ?? 0) + BigInt(p.priority_fee ?? 0) + BigInt(p.tips ?? 0);
      this.send({ t: 'slot', s: p.slot, i: p.slot % 4, st: now, tx, fee: Number(fee) }, f);
      if (p.slot % 4 === 3) this.later(() => this.send(this.info(f), f), 400); // the next countdown, right away
    }
  }

  /** Ten times a second: where the cluster is and its TPS. */
  frame() {
    return { t: 'f', e: this.est, ok: Math.round(this.tpsOk), fail: Math.round(this.tpsFail) };
  }

  /** What a badge following f shows of it. */
  info(f: Follow = this.main) {
    const est = this.est, e = this.epochOf(est);
    const mine = this.own(e, f.id), all = mine.windows;
    const past = all.filter((w) => w + 3 <= this.root).length * 4;
    const starts = new Set(all);
    let skips = 0;
    for (const s of this.skipped) if (starts.has(s - (s % 4))) skips++;
    const upcoming = [...this.epochs.values()].flatMap((x) => this.own(x, f.id).windows).filter((w) => w + 3 >= est).sort((a, b) => a - b).slice(0, 24);
    const stake = f.vote?.stake ?? mine.stake;
    return {
      t: 'info',
      id: f.id,
      def: f === this.main ? 1 : 0,                            // the default validator
      name: this.nameOf(f.id),
      cc: this.countries.get(f.id) ?? '',
      stake: Number(stake / LAMPORTS),                         // SOL, fits a badge's 32-bit integers
      share: e && e.total > 0n ? Number((stake * 100000n) / e.total) / 1000 : 0,
      rank: mine.rank,
      ver: f === this.main && this.version ? this.version : this.versions.get(f.id) ?? '',   // its Firedancer (or other) version
      comm: f.vote ? f.vote.bps / 100 : null,
      delinq: f.vote?.delinquent ?? false,
      epoch: e?.epoch ?? 0,
      pct: e ? Math.floor(((est - e.start) * 100) / (e.end - e.start + 1)) : 0,
      slot: est,
      sd: Math.round(this.slotNs / 1e6),                       // ms per slot
      leader: all.length * 4,
      done: past - skips,
      skip: skips,
      next: upcoming,                                          // its next window starts (the first may be under way)
      last: f.blocks.map((b) => [b.tx, b.skip ? 1 : 0]),       // its last 16 slots, newest first
      up: this.upstream,
    };
  }

  /** The 20 biggest validators, for a badge to pick one. */
  list() {
    const top = [...this.stakes].sort((a, b) => (b[1] > a[1] ? 1 : b[1] < a[1] ? -1 : 0)).slice(0, 20);
    return { t: 'list', l: top.map(([id, st]) => [id, this.nameOf(id), Number(st / LAMPORTS), this.versions.get(id) ?? '', this.countries.get(id) ?? '']) };
  }

  /** One leader window in full (see the top of this file), and its leader. */
  window(w: number): Win {
    const id = this.leaderOf(w);
    const d = [];
    for (let s = w; s < w + 4; s++) {
      const x = this.slots.get(s);
      d.push(x ? [x.st, x.ok + x.fail, x.fail, x.base, x.tip, x.ms, x.cu] : [s <= this.est ? 1 : 0, 0, 0, 0, 0, 0, 0]);
    }
    const stake = id ? this.stakes.get(id) ?? 0n : 0n;
    return { leader: id, m: { t: 'w', s: w, n: this.nameOf(id), o: 0, k: Number(stake / LAMPORTS), c: (id && this.countries.get(id)) || '', d } };
  }

  /** A window as a badge following f gets it: "o" is 1 if it is f's. */
  static wire(x: Win, f: Follow) {
    x.m.o = x.leader !== null && x.leader === f.id ? 1 : 0;
    return JSON.stringify(x.m);
  }

  /** The windows that changed since we last said: the two before, the current one, the two next. */
  changedWindows() {
    const cur = this.est - (this.est % 4), out: Win[] = [];
    for (let w = cur - 8; w <= cur + 8; w += 4) {
      const x = this.window(w), k = JSON.stringify(x);
      if (this.sentW.get(w) !== k) { this.sentW.set(w, k); out.push(x); }
    }
    for (const w of this.sentW.keys()) if (w < cur - 64) this.sentW.delete(w);
    return out;
  }

  /** The last n windows, the current one and the two next, oldest first: for a client that connects. */
  history(n: number) {
    const cur = this.est - (this.est % 4), out: Win[] = [];
    for (let w = cur - 4 * n; w <= cur + 8; w += 4) out.push(this.window(w));
    return out;
  }

  /** Forget slots the carousel no longer shows. Call now and then. */
  prune() {
    for (const s of this.slots.keys()) if (s < this.est - 400) this.slots.delete(s);
    for (const f of this.follows()) for (const s of f.sent.keys()) if (s < this.est - 2_000_000) f.sent.delete(s);
  }

  private pack(f: Follow) {
    return { id: f.id, blocks: f.blocks, sent: [...f.sent].slice(-200), vote: f.vote && { ...f.vote, stake: String(f.vote.stake) } };
  }
  private take(f: Follow, y: any) {
    f.blocks = y.blocks ?? [];
    f.sent = new Map(y.sent ?? []);
    if (y.vote) f.vote = { ...y.vote, stake: BigInt(y.vote.stake) };
  }

  /** What a relay starting again can't get back from the dashboard, which replays only the
   *  slots around the tip: the followed validators' last blocks (until their next window,
   *  hours maybe) and vote accounts, the slots the carousel shows. As JSON, for storage. */
  snapshot(): string {
    const others = [...[...this.others.values()].map((f) => this.pack(f)), ...this.dormant.values()].slice(0, 16);
    return JSON.stringify({
      at: Date.now(), main: this.pack(this.main), others,
      slots: [...this.slots].filter(([s]) => s >= this.est - 80),
    });
  }

  /** Takes back a snapshot() of the same default validator: everything but the slots,
   *  which only while they can still be on screen (and their states haven't moved on since). */
  restore(json: string) {
    const x = JSON.parse(json);
    if (!x.main || (this.pinned ? x.main.id !== this.main.id : !x.main.id)) return;
    this.main.id = x.main.id;                        // so the dashboard's identity_key keeps what follows
    this.take(this.main, x.main);
    for (const y of x.others ?? []) if (y.id !== this.main.id) this.dormant.set(y.id, y);
    if (Date.now() - x.at < 2 * MINUTE) this.slots = new Map(x.slots);
  }

  /** Commission, stake and delinquency of every followed validator: the GUI's peers topic
   *  leaves them at 0. pinnedVote: the default validator's vote account, if given. */
  async readVotes(rpcUrl: string, pinnedVote: string) {
    for (const f of this.follows()) await this.readVote(f, rpcUrl, f === this.main ? pinnedVote || this.voteKey : '');
  }

  /** From RPC (getVoteAccounts), else from Stakewiz: public RPC nodes refuse some clouds' addresses. */
  async readVote(f: Follow, rpcUrl: string, voteKey = '') {
    const votePubkey = voteKey || this.votes.get(f.id);
    if (!votePubkey) return;
    try {
      const r = await fetch(rpcUrl, { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'getVoteAccounts', params: [{ votePubkey }] }) });
      const res = ((await r.json()) as any).result;
      const v = res.current[0] ?? res.delinquent[0];
      if (v) {
        f.vote = { bps: v.inflationRewardsCommissionBps ?? v.commission * 100, stake: BigInt(v.activatedStake),
                   delinquent: res.delinquent.length > 0 };
        return;
      }
    } catch (e) { this.log('rpc: ' + String(e)); }
    try {
      const v = (await (await fetch(`https://api.stakewiz.com/validator/${votePubkey}`)).json()) as any;
      if (typeof v.commission === 'number' && typeof v.activated_stake === 'number') {
        f.vote = { bps: v.commission, stake: BigInt(Math.round(v.activated_stake * 1e6)) * 1000n, delinquent: v.delinquent === true };
      }
    } catch (e) { this.log('stakewiz: ' + String(e)); }
  }
}

// ---------------------------------------------------------------- the badges' sockets
export interface Sock { send(s: string): void }

/** The badges connected to a relay, each with the validator it follows. */
export class Hub {
  private clients = new Map<Sock, Follow>();
  private waiting = new Set<Sock>();      // came before the feed: the windows are still to send
  private lastFrame = '';

  /** chose: a badge started following f (read its vote account, say). */
  constructor(public relay: Relay, private chose: (f: Follow) => void = () => {}) {}

  get size() { return this.clients.size; }

  /** For the Relay: m to every badge following `to`, or to all of them. */
  deliver(m: object, to?: Follow) {
    const s = JSON.stringify(m);
    for (const [c, f] of this.clients) if (!to || f === to) this.put(c, s);
  }

  private put(c: Sock, s: string) { try { c.send(s); } catch { this.remove(c); } }

  /** A badge connected, asking for an identity ('' or none: the default validator). */
  add(c: Sock, id = '') { this.set(c, this.relay.follow(id)); }

  remove(c: Sock) {
    this.clients.delete(c);
    this.waiting.delete(c);
    this.relay.keep(new Set(this.clients.values()));
  }

  /** A message from a badge (top of this file). */
  message(c: Sock, text: string) {
    let m: any;
    try { m = JSON.parse(text); } catch { return; }
    if (m?.t === 'list') this.put(c, JSON.stringify(this.relay.list()));
    else if (m?.t === 'follow') {
      const id = typeof m.s === 'number' ? this.relay.leaderAt(m.s) ?? '' : typeof m.id === 'string' ? m.id : '';
      this.set(c, this.relay.follow(id), typeof m.n === 'number' ? m.n : undefined);
      this.relay.keep(new Set(this.clients.values()));
    }
  }

  private set(c: Sock, f: Follow, n?: number) {
    const fresh = ![...this.clients.values()].includes(f);
    this.clients.set(c, f);
    if (fresh && !f.vote) this.chose(f);
    this.put(c, JSON.stringify(n === undefined ? this.relay.info(f) : { ...this.relay.info(f), n }));
    if (this.relay.est && this.relay.epochs.size) {
      for (const w of this.relay.history(16)) this.put(c, Relay.wire(w, f));
      this.put(c, JSON.stringify(this.relay.frame()));
    } else this.waiting.add(c);
  }

  /** Every FRAME_MS: the windows that changed, the frame if it moved. */
  tick() {
    if (!this.clients.size || !this.relay.est) return;
    if (this.waiting.size && this.relay.epochs.size) {
      const h = this.relay.history(16);
      for (const c of this.waiting) { const f = this.clients.get(c); if (f) for (const w of h) this.put(c, Relay.wire(w, f)); }
      this.waiting.clear();
    }
    const changed = this.relay.changedWindows();
    if (changed.length) {
      const by = new Map<Follow, string[]>();          // each follow's view of them, made once
      for (const [c, f] of this.clients) {
        let ws = by.get(f);
        if (!ws) by.set(f, ws = changed.map((w) => Relay.wire(w, f)));
        for (const s of ws) this.put(c, s);
      }
    }
    const s = JSON.stringify(this.relay.frame());
    if (s === this.lastFrame) return;
    this.lastFrame = s;
    for (const c of this.clients.keys()) this.put(c, s);
  }

  /** Every 2 s: each badge, its validator's info. */
  infos() { for (const f of new Set(this.clients.values())) this.deliver(this.relay.info(f), f); }
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
