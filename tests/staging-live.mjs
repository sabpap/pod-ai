// Read-only checks of pod staging's WebSocket channels, as live.md describes them. Prints one line per
// check ("ok   ..." or "FAIL ...") and a last line "N passed, M failed". Subscribes only; sends nothing.
// Usage: node tests/staging-live.mjs ACCOUNT
const WS = 'wss://staging-rpc.podtestnet.dev';
const ACCOUNT = (process.argv[2] || '').toLowerCase();
const NV = '0x0000000000000000000000000000000000000000000000000000000000000007';
let pass = 0, failed = 0;
const ok = (n) => { pass += 1; console.log(`ok   ${n}`); };
const bad = (n, why) => { failed += 1; console.log(`FAIL ${n}${why ? ': ' + why : ''}`); };

const now = (await (await fetch('https://staging-rpc.podtestnet.dev/v1/clob/status')).json()).solution_now;

// sub(params, ms): subscribe, collect for ms, return {reply, results, errors}
function sub(params, ms = 4000) {
  return new Promise((resolve) => {
    const ws = new WebSocket(WS);
    const out = { reply: null, results: [], errors: [] };
    const done = () => { try { ws.close(); } catch { /* closing anyway */ } resolve(out); };
    const t = setTimeout(done, ms);
    ws.onopen = () => ws.send(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_subscribe', params }));
    ws.onmessage = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id === 1) { out.reply = m; if (m.error) { clearTimeout(t); done(); } return; }
      if (m.method === 'eth_subscription') {
        if (m.params.error) out.errors.push(m.params.error); else out.results.push(m.params.result);
      }
    };
    ws.onerror = () => {};
  });
}
const subscribed = (r) => r.reply && typeof r.reply.result === 'string';

try {
  let r = await sub(['pod_markets', { orderbook_ids: [NV], since: now }]);
  subscribed(r) && r.results.length > 0 && r.results[0].orderbook_id === NV && 'mark_price' in r.results[0]
    ? ok('pod_markets with since: NVDA stats arrive') : bad('pod_markets with since', JSON.stringify(r.reply));

  r = await sub(['pod_positions', { account: ACCOUNT, since: now }]);
  subscribed(r) && r.results.length >= 1 && r.results[0].account === ACCOUNT && 'timestamp' in r.results[0].data
    ? ok('pod_positions with since: the current state at once, {account, data.timestamp}') : bad('pod_positions with since', JSON.stringify(r).slice(0, 200));

  r = await sub(['pod_positions', { account: ACCOUNT }], 3000);
  subscribed(r) && r.results.length === 0
    ? ok('pod_positions without since: subscribed, nothing sent (quiet account)') : bad('pod_positions without since', `${r.results.length} updates`);

  r = await sub(['pod_triggers', { account: ACCOUNT, since: now }]);
  subscribed(r) && r.results.length >= 1 && Array.isArray(r.results[0].triggers) && r.results[0].account === ACCOUNT
    ? ok('pod_triggers with since: the current list at once') : bad('pod_triggers with since', JSON.stringify(r).slice(0, 200));

  r = await sub(['pod_orderbook', { orderbook_ids: [NV], depth: 1 }]);
  subscribed(r) && r.results.length > 0 && 'buys' in r.results[0] && 'sells' in r.results[0]
    ? ok('pod_orderbook depth 1: book snapshots') : bad('pod_orderbook', JSON.stringify(r.reply));

  r = await sub(['pod_candles', { orderbook_ids: [NV], since: now - 5000000 }]);
  const c = r.results[0] || {};
  subscribed(r) && 'orderbook' in c && 'timestamp_us' in c && 'price' in c && 'volume' in c && c.timestamp_us > now - 5000000
    ? ok('pod_candles with since 5 s back: replays rounds after since, {orderbook, timestamp_us, price, volume}') : bad('pod_candles', JSON.stringify(r).slice(0, 200));

  r = await sub(['pod_orders_v2', { bidder: ACCOUNT, since: now }], 2500);
  subscribed(r) ? ok('pod_orders_v2 with bidder: subscribed') : bad('pod_orders_v2', JSON.stringify(r.reply));
  r = await sub(['pod_orders_v2', { bidders: [ACCOUNT, '0x752f038fa0aa50397deda3a7a56d6bc13a743c17'] }], 2500);
  subscribed(r) ? ok('pod_orders_v2 with bidders: subscribed') : bad('pod_orders_v2 bidders', JSON.stringify(r.reply));
  r = await sub(['pod_activity', { account: ACCOUNT, since: now }], 2500);
  subscribed(r) ? ok('pod_activity: subscribed') : bad('pod_activity', JSON.stringify(r.reply));
  r = await sub(['pod_receipts', { account: ACCOUNT }], 2500);
  subscribed(r) ? ok('pod_receipts with account: subscribed') : bad('pod_receipts', JSON.stringify(r.reply));
  r = await sub(['pod_receipts', { tx_hashes: ['0x' + '00'.repeat(31) + '01'] }], 2500);
  subscribed(r) ? ok('pod_receipts with tx_hashes: subscribed') : bad('pod_receipts tx_hashes', JSON.stringify(r.reply));
  for (const ch of ['pod_orders', 'pod_withdrawals', 'pod_transfers']) {
    r = await sub([ch, {}], 2000);
    subscribed(r) ? ok(`${ch}: subscribed`) : bad(ch, JSON.stringify(r.reply));
  }

  r = await sub(['newHeads']);
  const h = r.results[0] || {};
  const secs = parseInt(h.timestamp, 16), nowS = Date.now() / 1000;
  subscribed(r) && r.results.length >= 2 && Math.abs(secs - nowS) < 120
    ? ok('newHeads: blocks arrive, timestamp is hex seconds') : bad('newHeads', JSON.stringify(h).slice(0, 200));

  r = await sub(['pod_markets', { orderbook_ids: [NV], since: String(now) }]);
  r.reply && r.reply.error && r.reply.error.code === -32602
    ? ok('since as a string is refused (-32602)') : bad('since as a string', JSON.stringify(r.reply));

  r = await sub(['pod_orderbook', { orderbook_ids: [NV], since: now - 3 * 3600 * 1000000 }]);
  r.reply && r.reply.error && /since too old/.test(r.reply.error.message)
    ? ok('since 3 hours old is refused: since too old') : bad('since 3 hours old', JSON.stringify(r.reply));

  r = await sub(['pod_orderbook', { orderbook_ids: [NV], depth: 1, since: now - 2 * 3600 * 1000000 }], 2500);
  subscribed(r) && r.results.length > 100
    ? ok(`since 2 hours old is replayed (${r.results.length} frames in 2.5 s)`) : bad('since 2 hours old', JSON.stringify(r.reply));

  r = await sub(['pod_positions', {}], 2000);
  r.reply && r.reply.error ? ok('pod_positions without account is refused') : bad('pod_positions without account', JSON.stringify(r.reply));
} finally {
  console.log(`${pass} passed, ${failed} failed`);
  process.exit(failed === 0 ? 0 : 1);
}
