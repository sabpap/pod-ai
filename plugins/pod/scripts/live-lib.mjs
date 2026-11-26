// Decoding, conditions and output shaping for live.mjs. Pure functions, no network: tests import
// this file directly (tests/live-units.mjs).
//
// Pod scales amounts and prices by 10^18 and sends them as 0x hex or decimal strings. They are
// converted with BigInt, so every amount stays exact; only computed percentages are rounded.

// --- numbers ------------------------------------------------------------------------------------------

export function big(v) {
  if (v === null || v === undefined || v === '') return null;
  if (typeof v === 'bigint') return v;
  if (typeof v === 'number') return BigInt(Math.trunc(v));
  const s = String(v).trim();
  if (s.startsWith('-0x') || s.startsWith('-0X')) return -BigInt(s.slice(1));
  return BigInt(s);
}

// A 10^n-scaled integer as an exact decimal string: "150930000000000000000" -> "150.93".
export function amount(v, n = 18) {
  const b = big(v);
  if (b === null) return null;
  const neg = b < 0n;
  const d = (neg ? -b : b).toString().padStart(n + 1, '0');
  const int = d.slice(0, d.length - n);
  const frac = d.slice(d.length - n).replace(/0+$/, '');
  const out = int + (frac ? '.' + frac : '');
  return neg && out !== '0' ? '-' + out : out;
}

// Pod sends 0 for "none" in some price fields (e.g. no liquidation price).
export function priceOrNull(v) {
  const a = amount(v);
  return a === null || a === '0' ? null : a;
}

// A computed float as a short decimal string: at most n decimals, no trailing zeros.
export function fixed(x, n) {
  if (x === null || x === undefined || !Number.isFinite(x)) return null;
  let s = x.toFixed(n);
  if (s.includes('.')) s = s.replace(/0+$/, '').replace(/\.$/, '');
  return s === '-0' ? '0' : s;
}

const num = (s) => (s === null || s === undefined ? null : Number(s));

// Microseconds as ISO-8601 UTC; milliseconds only when the time is not on a whole second.
export function usTime(us) {
  if (us === null || us === undefined) return null;
  const n = Number(big(us));
  if (!Number.isFinite(n) || n > 1e17) return null;   // pod's "never" is 2^64 - 1
  return new Date(Math.floor(n / 1000)).toISOString().replace('.000Z', 'Z');
}

// Drop null, undefined, empty-string and empty-array fields.
export function clean(o) {
  const out = {};
  for (const [k, v] of Object.entries(o)) {
    if (v === null || v === undefined || v === '' || (Array.isArray(v) && v.length === 0)) continue;
    out[k] = v;
  }
  return out;
}

const usd = (a) => (a === null ? 'none' : a.startsWith('-') ? '-$' + a.slice(1) : '$' + a);

// --- channels -----------------------------------------------------------------------------------------
//
// scope: market (needs markets), accounts (one or more), account (exactly one), tx (receipts), none.
// state: pod sends a current snapshot (state channels); otherwise only what changed (delta).
// every: default seconds between lines for this channel (0 = every change).
// fields: what a condition may test.

export const CHANNELS = {
  market: {
    pod: 'pod_markets', scope: 'market', state: true, every: 30,
    fields: ['market', 'price', 'price_kind', 'last_price', 'mark_price', 'oracle_price', 'oracle_stale',
      'change_24h_pct', 'high_24h', 'low_24h', 'volume_24h_usd', 'funding_rate_pct', 'funding_who_pays',
      'open_interest_usd', 'mark_vs_oracle_pct', 'status'],
  },
  book: {
    pod: 'pod_orderbook', scope: 'market', state: false, every: 30,
    fields: ['market', 'best_bid', 'best_ask', 'mid', 'spread', 'spread_pct', 'bid_size', 'ask_size', 'last_price'],
  },
  bars: {
    pod: 'pod_candles', scope: 'market', state: false, every: 30,
    fields: ['market', 'price', 'volume'],
  },
  orders: {
    pod: 'pod_orders_v2', scope: 'accounts', state: false, every: 0,
    fields: ['market', 'event', 'status', 'side', 'size', 'price', 'filled_size', 'fill_price', 'value_usd',
      'fee_usd', 'total_filled', 'order_id', 'account', 'reason'],
  },
  positions: {
    pod: 'pod_positions', scope: 'account', state: true, every: 0,
    fields: ['account_value_usd', 'cash_usd', 'unrealized_pnl_usd', 'positions', 'holdings',
      'market', 'side', 'size', 'entry_price', 'mark_price', 'value_usd', 'margin_usd',
      'liquidation_price', 'liquidation_distance_pct', 'funding_owed_usd'],
  },
  triggers: {
    pod: 'pod_triggers', scope: 'account', state: true, every: 0,
    fields: ['count'],
  },
  activity: {
    pod: 'pod_activity', scope: 'account', state: false, every: 0,
    fields: ['kind', 'status', 'market', 'order_id', 'position_after', 'realized_pnl_usd', 'description'],
  },
  receipts: {
    pod: 'pod_receipts', scope: 'tx', state: false, every: 0,
    fields: ['tx', 'ok'],
  },
  rounds: {
    pod: 'newHeads', scope: 'none', state: false, every: 30,
    fields: ['round'],
  },
};

// Short names accepted in conditions.
export const ALIASES = {
  mark: 'mark_price', last: 'last_price', oracle: 'oracle_price', bid: 'best_bid', ask: 'best_ask',
  pnl: 'unrealized_pnl_usd', change: 'change_24h_pct', funding: 'funding_rate_pct',
};

// --- conditions -----------------------------------------------------------------------------------------

// "mark < 140", "status = filled", "spread_pct >= 0.5". Returns {field, op, value, text} or throws.
export function parseCondition(text, channel) {
  const m = String(text).match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(<=|>=|!=|==|=|<|>)\s*(.+?)\s*$/);
  if (!m) throw new Error(`'${text}' is not a condition. Write FIELD OP VALUE, e.g. "mark < 140" or "status = filled".`);
  let field = m[1].toLowerCase();
  field = ALIASES[field] && CHANNELS[channel].fields.includes(ALIASES[field]) ? ALIASES[field] : field;
  if (!CHANNELS[channel].fields.includes(field)) {
    throw new Error(`The ${channel} channel has no field '${m[1]}'. Fields: ${CHANNELS[channel].fields.join(', ')}.`);
  }
  const op = m[2] === '==' ? '=' : m[2];
  const value = m[3].replace(/^["']|["']$/g, '').replace(/^\$/, '').replace(/%$/, '').replace(/,/g, '');
  return { field, op, value, text: `${field} ${op} ${m[3]}` };
}

const isNum = (v) => v !== null && v !== undefined && v !== '' && typeof v !== 'boolean' && Number.isFinite(Number(v));

export function holds(cond, row) {
  const got = row[cond.field];
  if (got === null || got === undefined) return false;
  if (isNum(got) && isNum(cond.value)) {
    const a = Number(got), b = Number(cond.value);
    switch (cond.op) {
      case '<': return a < b; case '<=': return a <= b; case '>': return a > b;
      case '>=': return a >= b; case '=': return a === b; case '!=': return a !== b;
    }
  }
  const a = String(got).toLowerCase(), b = String(cond.value).toLowerCase();
  if (cond.op === '=') return a === b;
  if (cond.op === '!=') return a !== b;
  return false;
}

// --- decoding: one pod message -> rows ------------------------------------------------------------------
// ctx: {markets: {id: {label, type}}, market: id|null (filter), order: id|null (filter), cache: Map}

const label = (ctx, id) => (ctx.markets[id] && ctx.markets[id].label) || id;
const isPerp = (ctx, id) => ctx.markets[id] && ctx.markets[id].type === 'perp';

export function decodeMarket(r, ctx) {
  // Pod sends 0 for a price it does not have (e.g. a halted market): that is no price.
  const last = priceOrNull(r.last_clearing_price), mark = priceOrNull(r.mark_price), oracle = priceOrNull(r.oracle_price);
  const perp = isPerp(ctx, r.orderbook_id);
  const [price, kind] = perp && mark !== null ? [mark, 'mark'] : [last, last === null ? null : 'last traded'];
  const fr = r.funding_rate === undefined || r.funding_rate === null ? null : Number(amount(r.funding_rate));
  return [clean({
    time: usTime(r.timestamp), market: label(ctx, r.orderbook_id), price, price_kind: kind,
    last_price: last, mark_price: mark, oracle_price: oracle, oracle_stale: r.internal ? true : null,
    change_24h_pct: r.price_change_24h === undefined || r.price_change_24h === null ? null : fixed(r.price_change_24h / 100, 2),
    high_24h: priceOrNull(r.high_24h), low_24h: priceOrNull(r.low_24h), volume_24h_usd: amount(r.volume_24h),
    funding_rate_pct: fr === null ? null : fixed(fr * 100, 6),
    funding_who_pays: fr === null ? null : fr > 0 ? 'longs pay shorts' : fr < 0 ? 'shorts pay longs' : 'nobody',
    open_interest_usd: amount(r.open_interest),
    mark_vs_oracle_pct: mark !== null && oracle !== null && Number(oracle) !== 0
      ? fixed((Number(mark) - Number(oracle)) / Number(oracle) * 100, 4) : null,
    status: r.status,
    _key: r.orderbook_id, _ts: r.timestamp,
  })];
}

function levels(side) {
  return Object.entries(side || {}).map(([p, v]) => [amount(p), amount(v.volume)])
    .sort((a, b) => Number(a[0]) - Number(b[0]));
}

export function decodeBook(r, ctx, depth = 1) {
  const bids = levels(r.buys).reverse(), asks = levels(r.sells);
  const bid = bids[0] || null, ask = asks[0] || null;
  const mid = bid && ask ? (Number(bid[0]) + Number(ask[0])) / 2 : null;
  return [clean({
    time: usTime(r.timestamp), market: label(ctx, r.orderbook_id),
    best_bid: bid && bid[0], best_ask: ask && ask[0], mid: fixed(mid, 8),
    spread: mid === null ? null : fixed(Number(ask[0]) - Number(bid[0]), 8),
    spread_pct: mid === null ? null : fixed((Number(ask[0]) - Number(bid[0])) / mid * 100, 4),
    bid_size: bid && bid[1], ask_size: ask && ask[1], last_price: priceOrNull(r.clearing_price),
    bids: depth > 1 ? bids.slice(0, depth) : null, asks: depth > 1 ? asks.slice(0, depth) : null,
    _key: r.orderbook_id, _ts: r.timestamp,
  })];
}

export function decodeTick(r, ctx) {
  return [clean({
    time: usTime(r.timestamp_us), market: label(ctx, r.orderbook), price: amount(r.price),
    volume: amount(r.volume), _key: r.orderbook, _ts: r.timestamp_us,
    _price: big(r.price), _volume: big(r.volume),
  })];
}

// Folds per-round ticks into one bar per market for the --every window.
export function foldBar(bar, tick) {
  const p = tick._price, v = tick._volume || 0n;
  if (!bar) return { market: tick.market, from: tick.time, to: tick.time, open: p, high: p, low: p, close: p, volume: v, value: p * v / 10n ** 18n, rounds: 1, _ts: tick._ts };
  return {
    ...bar, to: tick.time, high: p > bar.high ? p : bar.high, low: p < bar.low ? p : bar.low, close: p,
    volume: bar.volume + v, value: bar.value + p * v / 10n ** 18n, rounds: bar.rounds + 1, _ts: tick._ts,
  };
}
export function barRow(bar) {
  return clean({
    from: bar.from, to: bar.to, market: bar.market, open: amount(bar.open), high: amount(bar.high), low: amount(bar.low),
    close: amount(bar.close), volume: amount(bar.volume), value_usd: amount(bar.value), rounds: bar.rounds,
  });
}

const sideOf = (sz) => (sz === null || sz === undefined ? null : String(sz).startsWith('-') ? 'sell' : 'buy');
const absAmount = (v) => { const a = amount(v); return a === null ? null : a.replace(/^-/, ''); };

function fillPrice(b, q) {
  const bb = big(b), qq = big(q);
  if (bb === null || qq === null || bb === 0n) return null;
  // q / b, both scaled by 10^18: keep 10 decimals, then trim.
  const p = qq * 10n ** 28n / bb;   // price * 10^28
  const s = amount(p, 28).replace(/(\.\d{10})\d+$/, '$1');
  return s.includes('.') ? s.replace(/0+$/, '').replace(/\.$/, '') : s;
}

export function decodeOrders(frame, ctx) {
  const rows = [];
  const time = usTime(frame.batch);
  for (const o of frame.orders || []) ctx.cache.set(o.id, { ...o, book: frame.book });
  for (const e of frame.events || []) {
    const ent = e.o !== undefined ? (frame.orders || [])[e.o] : ctx.cache.get(e.id) || null;
    const id = ent ? ent.id : e.id;
    if (ctx.order && String(id).toLowerCase() !== ctx.order) continue;
    if (ctx.market && frame.book !== ctx.market) continue;
    const acct = frame.accts ? frame.accts[e.a !== undefined ? e.a : ent && ent.a] : null;
    const status = e.k === 'new' ? 'resting' : e.k === 'fill' ? (e.st || 'partly filled')
      : e.k === 'cancel' ? (e.st || 'canceled') : e.k === 'expire' ? 'expired' : e.k === 'reject' ? 'refused'
      : e.k === 'modify' ? 'resting' : e.k === 'cancel_reject' || e.k === 'modify_reject' ? 'unchanged' : e.k;
    const row = {
      time, market: label(ctx, frame.book), event: e.k, status, order_id: id, account: acct,
      side: ent ? sideOf(ent.sz) : null, size: ent ? absAmount(ent.sz) : null, price: ent ? amount(ent.px) : null,
      filled_size: amount(e.b), fill_price: e.k === 'fill' ? fillPrice(e.b, e.q) : null,
      value_usd: amount(e.q), fee_usd: amount(e.f), total_filled: amount(e.tb),
      new_price: e.k === 'modify' ? amount(e.px) : null, new_size: e.k === 'modify' ? amount(e.sz) : null,
      reason: e.why || e.code || null,
    };
    const what = row.side ? `${row.side} ${row.size} ${row.market} at ${usd(row.price)}` : `order ${String(id).slice(0, 10)}… on ${row.market}`;
    row.description =
      e.k === 'new' ? `new order: ${what}${ent && ent.type === 'market' ? ' (market)' : ''}`
      : e.k === 'fill' ? `filled ${row.filled_size} at ${usd(row.fill_price)}${row.fee_usd ? `, fee ${usd(row.fee_usd)}` : ''} · ${e.st ? `${what}: ${e.st}` : `${what}: ${row.total_filled} filled so far`}`
      : e.k === 'cancel' ? `cancelled: ${what}${e.st ? ` (${e.st.replace(/_/g, ' ')})` : ''}`
      : e.k === 'expire' ? `expired: ${what}`
      : e.k === 'reject' ? `refused: ${what}${e.why ? ` (${e.why})` : ''}`
      : e.k === 'modify' ? `changed: ${what} → ${usd(row.new_price)}, size ${row.new_size}`
      : e.k === 'cancel_reject' ? `cancel refused: ${what}${row.reason ? ` (${row.reason})` : ''}`
      : e.k === 'modify_reject' ? `change refused: ${what}${row.reason ? ` (${row.reason})` : ''}`
      : `${e.k}: ${what}`;
    rows.push(clean({ ...row, _key: id, _ts: frame.batch, _book: frame.book }));
  }
  return rows;
}

export function describeActivity(e, ctx) {
  const m = (id) => label(ctx, id);
  switch (e.k) {
    case 'order': {
      const side = e.side || sideOf(e.initial_size);
      const flags = [e.order_type, e.post_only && 'maker-only', e.ioc && 'immediate-or-cancel', e.reduce_only && 'reduce-only'].filter(Boolean);
      return `${e.kind && e.kind !== 'user_signed' ? e.kind + ' ' : ''}order: ${side} ${absAmount(e.initial_size)} ${m(e.orderbook_id)} at ${usd(amount(e.price))} (${flags.join(', ')}) · ${e.status}${e.invalid_reason ? ': ' + e.invalid_reason : ''}`;
    }
    case 'fill':
      return `filled: ${amount(e.b)} ${m(e.book)} for ${usd(amount(e.q))}` + (e.f ? `, fee ${usd(amount(e.f))}` : '')
        + (e.pnl ? `, realized ${usd(amount(e.pnl))}` : '') + (e.st ? ` · order ${e.st}` : '')
        + (e.pa !== undefined ? ` · position now ${amount(e.pa)}` : '');
    case 'modify': return `order changed: price ${usd(amount(e.old_px))} → ${usd(amount(e.px))}, size ${amount(e.old_sz)} → ${amount(e.sz)}`;
    case 'termination':
      return `order ${e.st} · ${m(e.book)}` + (e.expr === 'ttl' ? ' (reached its end time)' : e.expr === 'ioc' ? ' (unfilled rest of an immediate-or-cancel order)' : '');
    case 'backstop':
      return (e.book ? `forced close: ${amount(e.sz)} ${m(e.book)} moved to the backstop at ${usd(amount(e.mark))}` : 'forced close: remaining cash swept to the backstop')
        + `, equity ${usd(amount(e.eq))}, realized ${usd(amount(e.pnl))}`;
    case 'settlement': return `market settled: position ${amount(e.sz)} ${m(e.book)} closed at ${usd(amount(e.px))}, realized ${usd(amount(e.pnl))}`;
    case 'bridge_transfer': {
      const a = amount(e.amt);
      return (a.startsWith('-') ? `withdrawal ${usd(a.slice(1))}` : `deposit ${usd(a)}`) + (e.err ? ` · refused: ${e.err}` : '');
    }
    case 'transfer': {
      const a = amount(e.amt);
      return (a.startsWith('-') ? `sent ${usd(a.slice(1))} to ${e.cp}` : `received ${usd(a)} from ${e.cp}`) + (e.err ? ` · refused: ${e.err}` : '');
    }
    case 'modify_reject': return `order change refused: ${e.why}`;
    case 'cancel_reject': return `cancel refused: ${e.why}`;
    default: return e.k;
  }
}

export function decodeActivity(frame, ctx) {
  const rows = [];
  for (const [ts, entries] of Object.entries(frame || {})) {
    for (const e of entries) {
      const book = e.orderbook_id || e.book || null;
      const id = e.k === 'order' ? e.order_id : e.id;
      if (ctx.market && book !== ctx.market) continue;
      if (ctx.order && String(id).toLowerCase() !== ctx.order) continue;
      rows.push(clean({
        time: usTime(ts), kind: e.k, market: book ? label(ctx, book) : null, order_id: id,
        status: e.st || (e.k === 'order' ? e.status : null),
        position_after: e.pa !== undefined ? amount(e.pa) : null,
        realized_pnl_usd: e.pnl !== undefined ? amount(e.pnl) : null,
        description: describeActivity(e, ctx), tx: e.tx_hash || e.tx || null,
        _key: `${ts}:${rows.length}`, _ts: ts,
      }));
    }
  }
  return rows;
}

function position(p, ctx) {
  if (p.kind === 'spot') {
    return clean({ market: label(ctx, p.orderbook_id), side: 'holding', size: amount(p.balance), mark_price: amount(p.mark_price),
      unrealized_pnl_usd: amount(p.unrealized_pnl) });
  }
  const mark = num(amount(p.mark_price)), liq = priceOrNull(p.liquidation_price);
  return clean({
    market: label(ctx, p.orderbook_id), side: p.side, size: absAmount(p.size), entry_price: amount(p.entry_price),
    mark_price: amount(p.mark_price), value_usd: amount(p.notional), margin_usd: amount(p.margin),
    unrealized_pnl_usd: amount(p.unrealized_pnl), liquidation_price: liq,
    liquidation_distance_pct: liq === null || !mark ? null
      : fixed((p.side === 'long' ? mark - Number(liq) : Number(liq) - mark) / mark * 100, 2),
    funding_owed_usd: amount(p.funding_accrued),
  });
}

export function decodePositions(u, ctx) {
  const d = u.data || {};
  const list = d.positions || [];
  const time = usTime(d.timestamp);
  if (ctx.market) {
    const p = list.find((x) => x.orderbook_id === ctx.market);
    return [p ? clean({ time, ...position(p, ctx), _key: ctx.market, _ts: d.timestamp })
      : clean({ time, market: label(ctx, ctx.market), size: '0', note: 'no open position', _key: ctx.market, _ts: d.timestamp })];
  }
  const perps = list.filter((p) => p.kind !== 'spot'), spots = list.filter((p) => p.kind === 'spot');
  return [clean({
    time, account: u.account, account_value_usd: amount(d.account_value), cash_usd: amount(d.cash),
    unrealized_pnl_usd: amount(d.total_unrealized_pnl), positions: perps.length, holdings: spots.length,
    list: list.slice(0, 20).map((p) => {
      const x = position(p, ctx);
      return x.side === 'holding' ? `${x.size} ${x.market}` : `${x.side} ${x.size} ${x.market} · profit or loss ${usd(x.unrealized_pnl_usd)}`;
    }),
    _key: 'account', _ts: d.timestamp,
  })];
}

export function decodeTriggers(u, ctx) {
  const list = (u.triggers || []).filter((t) => !ctx.market || t.orderbook_id === ctx.market);
  return [clean({
    time: usTime(u.timestamp), account: u.account, count: list.length,
    triggers: list.slice(0, 20).map((t) => {
      const whole = String(big(t.size)) === '0';
      // Size 0 sizes from the position when the trigger fires: it closes the whole position, either side.
      return `${t.trigger_type}: ${whole ? 'close the whole' : `${sideOf(t.size)} ${absAmount(t.size)}`} ${label(ctx, t.orderbook_id)}${whole ? ' position' : ''} at ${usd(amount(t.trigger_price))}`
        + (priceOrNull(t.limit_price) ? `, limit ${usd(priceOrNull(t.limit_price))}` : '');
    }),
    _key: 'triggers', _ts: u.timestamp,
  })];
}

export function decodeReceipts(f) {
  return (f.receipts || []).map((r) => clean({ time: usTime(f.timestamp_us), tx: r.tx_hash, ok: r.status, _key: r.tx_hash, _ts: f.timestamp_us }));
}

export function decodeHead(h) {
  const round = parseInt(h.number, 16), sec = parseInt(h.timestamp, 16);
  return [clean({ time: Number.isFinite(sec) ? new Date(sec * 1000).toISOString().replace('.000Z', 'Z') : null, round, _key: 'rounds' })];
}

// What counts as "changed" for the throttled channels: a line is printed only when this differs.
export function signature(channel, row) {
  switch (channel) {
    case 'market': return [row.price, row.last_price, row.oracle_price, row.status].join('|');
    case 'book': return [row.best_bid, row.best_ask].join('|');
    default: return JSON.stringify(row);
  }
}

// The row as printed: internal fields (starting with _) removed.
export function visible(row) {
  const out = {};
  for (const [k, v] of Object.entries(row)) if (!k.startsWith('_')) out[k] = v;
  return out;
}
