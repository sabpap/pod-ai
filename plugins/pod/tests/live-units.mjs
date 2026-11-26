// Offline tests of the live listener's decoding and conditions (scripts/live-lib.mjs). No network.
// Usage: node plugins/pod/tests/live-units.mjs

import * as L from '../scripts/live-lib.mjs';

let pass = 0, failed = 0;
function eq(name, got, want) {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) { pass += 1; console.log(`ok   ${name}`); }
  else { failed += 1; console.log(`FAIL ${name}: got ${g}, want ${w}`); }
}
function throws(name, fn, pattern) {
  try { fn(); failed += 1; console.log(`FAIL ${name}: did not throw`); }
  catch (e) { if (pattern.test(e.message)) { pass += 1; console.log(`ok   ${name}`); } else { failed += 1; console.log(`FAIL ${name}: ${e.message}`); } }
}

const NV = '0x0000000000000000000000000000000000000000000000000000000000000007';
const SP = '0x0000000000000000000000000000000000000000000000000000000000000001';
const ctx = () => ({ markets: { [NV]: { label: 'NVDA perp', type: 'perp' }, [SP]: { label: 'NVDAx spot', type: 'spot' } }, market: null, order: null, cache: new Map() });

// numbers
eq('hex amount', L.amount('0x82ff658cf0b3f0000'), '151.03');
eq('decimal amount', L.amount('150930000000000000000'), '150.93');
eq('negative amount', L.amount('-2648957182430000'), '-0.00264895718243');
eq('exact past doubles', L.amount('159369070615689195693819566'), '159369070.615689195693819566');
eq('zero', L.amount('0x0'), '0');
eq('smallest unit', L.amount('1'), '0.000000000000000001');
eq('no amount', L.amount(undefined), null);
eq('no liquidation price', L.priceOrNull('0x0'), null);
eq('fixed trims zeros', L.fixed(0.5, 4), '0.5');
eq('fixed rounds', L.fixed(0.36734, 2), '0.37');
eq('fixed negative zero', L.fixed(-0.00001, 2), '0');
eq('time on the second', L.usTime(1795710282000000), '2026-11-26T16:24:42Z');
eq('time between rounds', L.usTime('1795710282500000'), '2026-11-26T16:24:42.500Z');
eq("pod's never", L.usTime('18446744073709551615'), null);

// conditions
eq('alias mark', L.parseCondition('mark < 140', 'market').field, 'mark_price');
eq('dollar and percent signs', L.parseCondition('spread_pct >= 0.5%', 'book').value, '0.5');
eq('double equals', L.parseCondition('status == filled', 'orders').op, '=');
throws('unknown field', () => L.parseCondition('colour = red', 'market'), /no field 'colour'/);
throws('not a condition', () => L.parseCondition('mark', 'market'), /not a condition/);
throws('alias of another channel', () => L.parseCondition('mark < 1', 'book'), /no field 'mark'/);
const c = (t, ch) => L.parseCondition(t, ch);
eq('number below', L.holds(c('mark < 140', 'market'), { mark_price: '139.99' }), true);
eq('number not below', L.holds(c('mark < 140', 'market'), { mark_price: '140' }), false);
eq('numbers compare as numbers', L.holds(c('price > 9', 'market'), { price: '10.5' }), true);
eq('text equals, any case', L.holds(c('status = Filled', 'orders'), { status: 'filled' }), true);
eq('text not equal', L.holds(c('status != filled', 'orders'), { status: 'partly filled' }), true);
eq('missing field never holds', L.holds(c('liquidation_price < 1', 'positions'), {}), false);
eq('size 0 closes', L.holds(c('size = 0', 'positions'), { size: '0' }), true);

// market
const m = L.decodeMarket({ orderbook_id: NV, timestamp: 1795710282500000, last_clearing_price: '149630000000000000000', mark_price: '150275451221539000000',
  oracle_price: '150290000000000000000', price_change_24h: 534, funding_rate: '100000000000000', internal: true, status: 'active', volume_24h: '0', open_interest: '6612971942605723346007020' }, ctx())[0];
eq('perp leads with mark', [m.price, m.price_kind], ['150.275451221539', 'mark']);
eq('change in percent', m.change_24h_pct, '5.34');
eq('funding in percent', [m.funding_rate_pct, m.funding_who_pays], ['0.01', 'longs pay shorts']);
eq('mark vs oracle', m.mark_vs_oracle_pct, '-0.0097');
eq('stale oracle flagged', m.oracle_stale, true);
const s = L.decodeMarket({ orderbook_id: SP, timestamp: 1, last_clearing_price: '188470000000000000000', price_change_24h: 0 }, ctx())[0];
eq('spot leads with last traded', [s.price, s.price_kind], ['188.47', 'last traded']);
const z = L.decodeMarket({ orderbook_id: NV, mark_price: '0', last_clearing_price: '1614470000000000000000', oracle_price: '0x0' }, ctx())[0];
eq('a zero mark is no price', [z.price, z.price_kind, z.mark_price, z.oracle_price], ['1614.47', 'last traded', undefined, undefined]);
eq('negative funding', L.decodeMarket({ orderbook_id: NV, funding_rate: '-100000000000000' }, ctx())[0].funding_who_pays, 'shorts pay longs');

// book
const b = L.decodeBook({ orderbook_id: NV, timestamp: 1, clearing_price: '0x0',
  buys: { '149550000000000000000': { volume: '0xde0b6b3a7640000' }, '149570000000000000000': { volume: '0x1bc16d674ec80000' } },
  sells: { '150220000000000000000': { volume: '0xde0b6b3a7640000' }, '150200000000000000000': { volume: '0xde0b6b3a7640000' } } }, ctx(), 2)[0];
eq('best bid is the highest buy', [b.best_bid, b.bid_size], ['149.57', '2']);
eq('best ask is the lowest sell', b.best_ask, '150.2');
eq('spread', [b.spread, b.mid], ['0.63', '149.885']);
eq('levels best first', [b.bids[0][0], b.asks[1][0]], ['149.57', '150.22']);
eq('no last price on 0x0', b.last_price, undefined);

// bars
const t1 = L.decodeTick({ orderbook: NV, price: '150000000000000000000', volume: '2000000000000000000', timestamp_us: 1795710282000000 }, ctx())[0];
const t2 = L.decodeTick({ orderbook: NV, price: '152000000000000000000', volume: '1000000000000000000', timestamp_us: 1795710282500000 }, ctx())[0];
const t3 = L.decodeTick({ orderbook: NV, price: '149000000000000000000', volume: '0', timestamp_us: 1795710283000000 }, ctx())[0];
const bar = L.barRow([t1, t2, t3].reduce((a, t) => L.foldBar(a, t), null));
eq('bar prices', [bar.open, bar.high, bar.low, bar.close], ['150', '152', '149', '149']);
eq('bar volume and value', [bar.volume, bar.value_usd, bar.rounds], ['3', '452', 3]);

// orders
const k = ctx();
const o1 = L.decodeOrders({ book: NV, batch: 1795710282500000, orders: [{ id: '0xaa', tx: '0x1', n: 1, px: '150000000000000000000', sz: '-500000000000000000' }],
  events: [{ k: 'new', o: 0 }] }, k)[0];
eq('new order', [o1.event, o1.status, o1.side, o1.size, o1.price], ['new', 'resting', 'sell', '0.5', '150']);
const o2 = L.decodeOrders({ book: NV, batch: 1795710283000000, orders: [],
  events: [{ k: 'fill', id: '0xaa', b: '200000000000000000', q: '30020000000000000000', f: '13509000000000000', tb: '200000000000000000' }] }, k)[0];
eq('fill of an order seen earlier', [o2.side, o2.filled_size, o2.fill_price, o2.status], ['sell', '0.2', '150.1', 'partly filled']);
const o3 = L.decodeOrders({ book: NV, batch: 1795710283500000, orders: [],
  events: [{ k: 'fill', id: '0xaa', b: '300000000000000000', q: '45000000000000000000', tb: '500000000000000000', st: 'filled' }] }, k)[0];
eq('last fill closes the order', o3.status, 'filled');
const kf = { ...ctx(), order: '0xbb' };
eq('order filter', L.decodeOrders({ book: NV, batch: 1, orders: [], events: [{ k: 'cancel', id: '0xaa' }] }, kf).length, 0);

// activity
const a = L.decodeActivity({ 1795710282500000: [
  { k: 'fill', id: '0xaa', book: NV, b: '10000000000000000', q: '1510300000000000000', f: '679635000000000', st: 'filled', pa: '0' },
  { k: 'termination', id: '0xbb', book: NV, st: 'expired', expr: 'ttl' }] }, ctx());
eq('activity fill', [a[0].kind, a[0].status, a[0].position_after], ['fill', 'filled', '0']);
eq('activity text', a[0].description, 'filled: 0.01 NVDA perp for $1.5103, fee $0.000679635 · order filled · position now 0');
eq('expiry text', a[1].description, 'order expired · NVDA perp (reached its end time)');

// positions
const pos = { account: '0xabc', data: { timestamp: 1795710282500000, account_value: '99871398567039761000', cash: '99961264779926901000', total_unrealized_pnl: '-89866212887140000',
  positions: [{ kind: 'perp', orderbook_id: NV, side: 'long', size: '10000000000000000', entry_price: '0x821a9e6e1c4cb0000', mark_price: '0x823cf2d0d2b1f0000',
    notional: '0x14d7d4c4ca5b0d00', margin: '0x10a7c0fe4b8d000', unrealized_pnl: '1163348538960000', liquidation_price: '0x0', funding_accrued: '3524122310000' }] } };
const pa = L.decodePositions(pos, ctx())[0];
eq('account summary', [pa.account_value_usd, pa.positions, pa.holdings], ['99.871398567039761', 1, 0]);
const pm = L.decodePositions(pos, { ...ctx(), market: NV })[0];
eq('one market', [pm.side, pm.size, pm.liquidation_price], ['long', '0.01', undefined]);
eq('no position means size 0', L.decodePositions({ data: { positions: [] } }, { ...ctx(), market: SP })[0].size, '0');

// triggers
const tr = L.decodeTriggers({ timestamp: 1, triggers: [
  { orderbook_id: NV, trigger_type: 'stop_loss', size: '0', trigger_price: '0x7b9b939f31ceb0000', limit_price: '0x0' },
  { orderbook_id: NV, trigger_type: 'take_profit', size: '-5000000000000000', trigger_price: '170000000000000000000', limit_price: '0x0' }] }, ctx())[0];
eq('whole-position trigger', tr.triggers[0], 'stop_loss: close the whole NVDA perp position at $142.51');
eq('sized trigger', tr.triggers[1], 'take_profit: sell 0.005 NVDA perp at $170');
eq('trigger count', tr.count, 2);

// rounds and receipts
eq('round number', L.decodeHead({ number: '0xdbbefa', timestamp: '0x6b085f0f' })[0].round, 14401274);
eq('receipt', L.decodeReceipts({ timestamp_us: 1795710282000000, receipts: [{ tx_hash: '0x1', status: false }] })[0].ok, false);

console.log(`${pass} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
