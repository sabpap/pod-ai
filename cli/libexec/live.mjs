// Follow pod live over its WebSocket and print one JSON line per update. Started by live.sh (pod live), which
// checks the arguments, resolves market names and accounts, and passes one JSON config as argv[2].
//
// Lines:
//   {"event":"watching", ...}            first line: what is being followed, its id, how to stop it
//   {...update...}                       one per update (throttled for market channels)
//   {"event":"notice","message":...}     connection lost, reconnected, updates missed
//   {"event":"condition met", ...}       last line when an --until condition holds; exit 0
//   {"event":"stopped","reason":...}     last line on --for time up, stop request or the end of receipts
// A refusal before anything starts is one {"ok":false,"step":"live",...} line, exit 1.
//
// Spec: specs/07-live.md.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import * as L from './live-lib.mjs';

const cfg = JSON.parse(process.argv[2]);
const ch = L.CHANNELS[cfg.channel];

let stopping = false;
const out = (o) => { if (!stopping || o.event) process.stdout.write(JSON.stringify(o) + '\n'); };
process.stdout.on('error', () => { stopping = true; cleanup(); process.exit(0); });   // reader went away

function refuse(error, fix) {
  try { cleanup(); } catch { /* not registered yet */ }
  process.stdout.write(JSON.stringify({ ok: false, step: 'live', error, ...(fix ? { fix } : {}) }) + '\n');
  process.exit(1);
}

let conds;
try { conds = (cfg.until || []).map((c) => L.parseCondition(c, cfg.channel)); }
catch (e) { refuse(e.message, 'pod live --help lists the fields for each channel.'); }
if (cfg.raw && conds.length) refuse('--raw prints pod\'s messages unchanged, so it cannot test conditions.', 'Drop --raw or --until.');

const every = (cfg.every_s ?? ch.every) * 1000;
const ctx = { markets: cfg.markets || {}, market: cfg.filter_market || null, order: cfg.order ? cfg.order.toLowerCase() : null, cache: new Map() };
const human = (s) => (s === 0 ? 'every change' : s % 3600 === 0 ? `${s / 3600}h` : s % 60 === 0 ? `${s / 60}m` : `${s}s`);

// --- registry: lets `pod live list` and `pod live stop` find this listener ---------------------------------

const id = 'l' + crypto.randomBytes(3).toString('hex');
const regDir = path.join(cfg.home, 'live');
const regFile = path.join(regDir, `${id}.json`);
function cleanup() { try { fs.unlinkSync(regFile); } catch { /* already gone */ } }
try {
  fs.mkdirSync(regDir, { recursive: true, mode: 0o700 });
  fs.writeFileSync(regFile, JSON.stringify({
    id, pid: process.pid, channel: cfg.channel, what: cfg.what, until: conds.map((c) => c.text),
    every: human(every / 1000), started: new Date().toISOString(),
    ends: cfg.for_s ? new Date(Date.now() + cfg.for_s * 1000).toISOString() : null,
  }), { mode: 0o600 });
} catch (e) { refuse(`Could not register the listener in ${regDir}: ${e.message}`); }

// --- finishing -----------------------------------------------------------------------------------------------

let ws = null;
function finish(event, extra = {}, code = 0) {
  if (stopping) return;
  if (event === 'stopped') flushAll();   // the last changes and the bar still open are not lost
  out({ event, ...extra, at: new Date().toISOString() });
  stopping = true;
  cleanup();
  try { ws && ws.close(); } catch { /* closing anyway */ }
  process.stdout.write('', () => process.exit(code));
}
for (const sig of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(sig, () => finish('stopped', { reason: 'stopped on request' }));
// Node's timers overflow past 24.8 days, so a long --for is waited out in steps of at most an hour.
if (cfg.for_s) {
  const endAt = Date.now() + cfg.for_s * 1000;
  const tick = () => {
    const left = endAt - Date.now();
    if (left <= 0) finish('stopped', { reason: `time up (${human(cfg.for_s)})` });
    else setTimeout(tick, Math.min(left, 3600000));
  };
  tick();
}

// --- printing, throttled -------------------------------------------------------------------------------

const started = Date.now();
const lastPrint = new Map(), lastSig = new Map(), pending = new Map(), bars = new Map(), lastClose = new Map();
let rounds = { n: 0, row: null, since: Date.now() };

function flushKey(k) {
  const row = pending.get(k);
  if (!row) return;
  const now = Date.now();
  if (now - (lastPrint.get(k) || 0) < every) return;
  pending.delete(k);
  const sig = L.signature(cfg.channel, row);
  if (sig === lastSig.get(k)) return;   // changes only
  out(L.visible(row)); lastPrint.set(k, now); lastSig.set(k, sig);
}
function flushBars(force = false) {
  for (const [k, bar] of bars) {
    const now = Date.now();
    if (!force && now - (lastPrint.get(k) || started) < every) continue;
    bars.delete(k); lastPrint.set(k, now);
    if (bar.volume === 0n && lastClose.get(k) === bar.close) continue;   // nothing traded, price unchanged
    lastClose.set(k, bar.close);
    out(L.barRow(bar));
  }
}
function flushRounds() {
  const now = Date.now();
  if (!rounds.row || now - (lastPrint.get('rounds') || 0) < every) return;
  const secs = (now - rounds.since) / 1000;
  out({ ...L.visible(rounds.row), rounds_since_last_line: rounds.n, per_second: L.fixed(rounds.n / secs, 2) });
  lastPrint.set('rounds', now); rounds = { n: 0, row: null, since: now };
}
setInterval(() => { for (const k of [...pending.keys()]) flushKey(k); flushBars(); flushRounds(); }, 1000).unref();
function flushAll() {
  for (const [k, row] of [...pending]) {
    pending.delete(k);
    const sig = L.signature(cfg.channel, row);
    if (sig !== lastSig.get(k)) { out(L.visible(row)); lastSig.set(k, sig); }
  }
  flushBars(true);
}

function emit(row) {
  if (cfg.channel === 'bars') {
    if (every === 0) { out(L.visible(row)); return; }
    bars.set(row._key, L.foldBar(bars.get(row._key), row)); return;
  }
  if (cfg.channel === 'rounds') {
    if (every === 0) { out(L.visible(row)); return; }
    rounds.n += 1; rounds.row = row; flushRounds(); return;
  }
  if (every === 0) { out(L.visible(row)); return; }
  pending.set(row._key, row); flushKey(row._key);
}

// --- decoding and conditions -------------------------------------------------------------------------------

let lastTs = null, lastBook = null;
const seenTx = new Set();

function tsOf(r) {
  switch (cfg.channel) {
    case 'market': case 'book': case 'triggers': return r.timestamp;
    case 'bars': case 'receipts': return r.timestamp_us;
    case 'orders': return r.batch;
    case 'positions': return r.data && r.data.timestamp;
    case 'activity': return Object.keys(r || {})[0];
    default: return null;
  }
}

function decode(r) {
  switch (cfg.channel) {
    case 'market': return L.decodeMarket(r, ctx);
    case 'book': return L.decodeBook(r, ctx, cfg.depth || 1);
    case 'bars': return L.decodeTick(r, ctx);
    case 'orders': return L.decodeOrders(r, ctx);
    case 'positions': return L.decodePositions(r, ctx);
    case 'triggers': return L.decodeTriggers(r, ctx);
    case 'activity': return L.decodeActivity(r, ctx);
    case 'receipts': return L.decodeReceipts(r);
    case 'rounds': return L.decodeHead(r);
    default: return [];
  }
}

const rawLast = new Map();     // --raw: when each market's message was last printed
const stateSeen = new Map();   // state channels: the newest timestamp per market or account

// Pod's state channels (market, positions, triggers) may push the same round twice (the starting
// snapshot, then the live push of that round) or, rarely, an older one late. Pod says to keep the
// highest timestamp per market or account and drop the rest.
function staleState(result) {
  if (!ch.state) return false;
  const ts = tsOf(result);
  if (ts === null || ts === undefined) return false;
  const key = cfg.channel === 'market' ? result.orderbook_id : cfg.channel;
  if (stateSeen.has(key) && Number(ts) <= stateSeen.get(key)) return true;
  stateSeen.set(key, Number(ts));
  return false;
}

function handle(result) {
  if (stopping || result === null || result === undefined) return;
  if (!cfg.raw && staleState(result)) return;
  const ts = tsOf(result);
  if (ts !== null && ts !== undefined && (lastTs === null || Number(ts) >= Number(lastTs))) {
    lastTs = Number(ts);
    if (cfg.channel === 'orders') lastBook = result.book;
  }
  if (cfg.raw) {
    const key = result.orderbook_id || result.orderbook || result.book || 'all';
    if (every === 0 || Date.now() - (rawLast.get(key) || 0) >= every) { out({ raw: result }); rawLast.set(key, Date.now()); }
    return;
  }
  for (const row of decode(result)) {
    for (const c of conds) {
      if (L.holds(c, row)) return finish('condition met', { condition: c.text, ...L.visible(row) });
    }
    emit(row);
    if (cfg.channel === 'receipts' && cfg.txs && cfg.txs.length) {
      seenTx.add(String(row.tx).toLowerCase());
      if (cfg.txs.every((t) => seenTx.has(t.toLowerCase()))) return finish('stopped', { reason: 'every receipt asked for has arrived' });
    }
  }
}

// --- connection ----------------------------------------------------------------------------------------------

function params(since, sinceBook) {
  if (cfg.channel === 'rounds') return null;
  const p = {};
  if (ch.scope === 'market') p.orderbook_ids = cfg.market_ids;
  if (cfg.channel === 'book') p.depth = Math.max(cfg.depth || 1, 1);
  if (ch.scope === 'accounts') {
    if (cfg.accounts.length === 1) p.bidder = cfg.accounts[0]; else p.bidders = cfg.accounts;
    if (cfg.filter_market) p.orderbook_ids = [cfg.filter_market];
  }
  if (ch.scope === 'account') p.account = cfg.accounts[0];
  if (ch.scope === 'tx') {
    if (cfg.txs && cfg.txs.length) p.tx_hashes = cfg.txs;
    if (cfg.accounts && cfg.accounts.length) p.account = cfg.accounts[0];
  }
  if (since !== null && since !== undefined) p.since = Number(since);
  if (sinceBook) p.since_book = sinceBook;
  return p;
}

let subscribedOnce = false, lostAt = null, resumedWith = null, failures = 0, lastMsgAt = Date.now();
let waits995 = 0, gapNoted = false;

function subscribe(since, sinceBook) {
  resumedWith = since;
  const p = params(since, sinceBook);
  ws.send(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_subscribe', params: p ? [ch.pod, p] : [ch.pod] }));
}

// Where to start. State channels get `since` = the current round, so pod sends the current state at
// once instead of waiting for the next change. On a reconnect every channel but rounds resumes from
// the last round seen, which pod replays without a gap.
function startSince() {
  if (lostAt !== null) return cfg.channel === 'rounds' ? null : lastTs;
  return ch.state ? cfg.now_us : null;
}

function connect() {
  ws = new WebSocket(cfg.ws_url);
  ws.onopen = () => { lastMsgAt = Date.now(); subscribe(startSince(), lostAt !== null && cfg.channel === 'orders' ? lastBook : null); };
  ws.onmessage = (ev) => {
    lastMsgAt = Date.now();
    let m;
    try { m = JSON.parse(typeof ev.data === 'string' ? ev.data : ev.data.toString()); } catch { return; }
    if (m.id === 1) {
      if (m.error) {
        const msg = m.error.message || '';
        // 995 on a state channel: this node has not reached the asked round yet. Wait and ask again,
        // so the current state still comes first; after 5 s, go on without it.
        if (m.error.code === 995 && ch.state && waits995 < 5) {
          waits995 += 1;
          setTimeout(() => { if (!stopping && ws.readyState === 1) subscribe(resumedWith, null); }, 1000);
          return;
        }
        if (/since too old/i.test(msg) || m.error.code === 995) {
          if (subscribedOnce) {
            out({ event: 'notice', message: 'Pod no longer holds the updates missed while disconnected; continuing live from now. Check the REST views for what happened in between.' });
            gapNoted = true;
          }
          subscribe(null);
          return;
        }
        if (!subscribedOnce) refuse(`Pod refused the subscription: ${msg}${m.error.data ? ` (${JSON.stringify(m.error.data)})` : ''}.`);
        out({ event: 'notice', message: `Pod refused to resubscribe: ${msg}. Retrying.` });
        try { ws.close(); } catch { /* reconnect follows */ }
        return;
      }
      if (!subscribedOnce) {
        subscribedOnce = true;
        out({
          event: 'watching', id, channel: cfg.channel, what: cfg.what,
          until: conds.map((c) => c.text), every: human(every / 1000),
          for: cfg.for_s ? human(cfg.for_s) : 'until stopped or the session ends',
          stop: `pod live stop ${id}`,
        });
      } else if (lostAt !== null) {
        const gap = Math.round((Date.now() - lostAt) / 1000);
        const how = resumedWith !== null && resumedWith !== undefined ? '; caught up, no updates missed'
          : gapNoted ? '' : cfg.channel === 'rounds' ? '; rounds in between were not reported' : '; updates in between may be missing';
        out({ event: 'notice', message: `Reconnected after ${gap} s${how}.` });
        lostAt = null; gapNoted = false;
      }
      failures = 0; waits995 = 0;
      return;
    }
    if (m.method === 'eth_subscription' && m.params) {
      if (m.params.error) {
        const d = m.params.error.data || {};
        out({ event: 'notice', message: `Pod closed the stream (${m.params.error.code}: ${m.params.error.message}); resuming.` });
        lostAt = lostAt ?? Date.now();
        subscribe(d.resume_since ?? (cfg.channel === 'rounds' ? null : lastTs), d.resume_since_book ?? null);
        return;
      }
      handle(m.params.result);
    }
  };
  ws.onerror = () => { /* onclose follows */ };
  ws.onclose = () => {
    if (stopping) return;
    failures += 1;
    if (!subscribedOnce && failures >= 4) refuse(`Could not open pod's live connection at ${cfg.ws_url}.`, 'Check the network, then try again; pod status tells whether pod answers.');
    if (subscribedOnce && lostAt === null) {
      lostAt = Date.now();
      out({ event: 'notice', message: 'Connection to pod lost; reconnecting.' });
    }
    setTimeout(connect, Math.min(30000, 1000 * 2 ** Math.min(failures - 1, 5)));
  };
}

// A connection can die without closing. Ask pod something every 30 s; reconnect after 75 s of silence.
setInterval(() => {
  if (stopping || !ws || ws.readyState !== 1) return;
  if (Date.now() - lastMsgAt > 75000) { try { ws.close(); } catch { /* reconnect follows */ } return; }
  ws.send(JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'eth_chainId', params: [] }));
}, 30000);

connect();
