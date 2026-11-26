// A fake pod JSON-RPC server for the tests: it answers what cast and pod-send.sh ask, records every
// raw transaction it is sent, and never forwards anything. Nothing reaches pod.
//
//   node tests/fake-rpc.mjs PORT_FILE LOG_FILE
//
// Environment:
//   FAKE_CHAIN_ID    chain id to report, hex (default 0x1f916, pod staging)
//   FAKE_NONCE       pending nonce to report, hex (default 0x7)
//   FAKE_SEND        "ok" (default) or an error code to answer eth_sendRawTransaction with: 996, 3, -32025
//   FAKE_TX_HASH     the hash to answer a send with (default: a fixed dummy)
//   FAKE_TX_SUCCESS  "true" (default) or "false": what pod_getTxStatus reports once finalized
import http from 'node:http';
import fs from 'node:fs';

const [portFile, logFile] = process.argv.slice(2);
const env = (k, d) => process.env[k] ?? d;
const log = (o) => fs.appendFileSync(logFile, JSON.stringify(o) + '\n');

// Error(string) revert data for "CLOB validation failed: Deadline is not aligned to auction interval".
function revertData(reason) {
  const hex = Buffer.from(reason, 'utf8').toString('hex');
  const len = reason.length.toString(16).padStart(64, '0');
  const padded = hex.padEnd(Math.ceil(hex.length / 64) * 64, '0');
  return '0x08c379a0' + '20'.padStart(64, '0') + len + padded;
}

function answer(req) {
  const ok = (result) => ({ jsonrpc: '2.0', id: req.id, result });
  const err = (code, message, data) => ({ jsonrpc: '2.0', id: req.id, error: { code, message, ...(data !== undefined ? { data } : {}) } });
  log({ method: req.method, params: req.method === 'eth_sendRawTransaction' ? req.params : undefined });
  switch (req.method) {
    case 'eth_chainId': return ok(env('FAKE_CHAIN_ID', '0x1f916'));
    case 'eth_getTransactionCount': return ok(env('FAKE_NONCE', '0x7'));
    case 'eth_estimateGas': return ok('0x5208');
    case 'eth_gasPrice': return ok('0x3b9aca00');
    case 'eth_maxPriorityFeePerGas': return ok('0x0');
    case 'eth_feeHistory': return ok({ oldestBlock: '0x1', baseFeePerGas: ['0x3b9aca00', '0x3b9aca00'], gasUsedRatio: [0], reward: [['0x0']] });
    case 'eth_getBlockByNumber': return ok({ number: '0x1', hash: '0x' + '11'.repeat(32), parentHash: '0x' + '00'.repeat(32), timestamp: '0x6b085f0f', baseFeePerGas: '0x3b9aca00', gasLimit: '0x0', gasUsed: '0x0', transactions: [] });
    case 'pod_status': return ok({ read_only: false, paused: false });
    case 'eth_sendRawTransaction': {
      const mode = env('FAKE_SEND', 'ok');
      if (mode === '996') return err(996, 'Past nonce: tx nonce 7, expected 8', 'past_nonce');
      if (mode === '3') return err(3, 'execution reverted', revertData('CLOB validation failed: Deadline is not aligned to auction interval'));
      if (mode === '-32025') return err(-32025, 'not available in your region');
      return ok(env('FAKE_TX_HASH', '0x' + 'ab'.repeat(32)));
    }
    case 'pod_getTxStatus':
      return ok({ status: 'finalized', tx_hash: req.params[0], account: '0x0', nonce: 7, success: env('FAKE_TX_SUCCESS', 'true') === 'true', gas_used: 21000 });
    default: return err(-32601, `fake: method ${req.method} not handled`);
  }
}

const server = http.createServer((rq, rs) => {
  let body = '';
  rq.on('data', (c) => { body += c; });
  rq.on('end', () => {
    let parsed;
    try { parsed = JSON.parse(body); } catch { rs.writeHead(400); rs.end(); return; }
    const out = Array.isArray(parsed) ? parsed.map(answer) : answer(parsed);
    rs.writeHead(200, { 'content-type': 'application/json' });
    rs.end(JSON.stringify(out));
  });
});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(portFile, String(server.address().port)));
for (const s of ['SIGTERM', 'SIGINT']) process.on(s, () => { server.close(); process.exit(0); });
