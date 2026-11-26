// A fake pod WebSocket for tests/live-reconnect.sh. It plays one script:
//   connection 1: answers the subscription, sends rounds 1-3 of the NVDA perp book, then drops.
//   connection 2: expects since = round 3, sends round 4, then closes the stream the way pod does
//                 (an error with resume_since = round 4); on the resubscription it expects since =
//                 round 4 and sends round 5, whose best bid is 200.
// Every subscription it receives is printed as one JSON line, for the test to check.
// Usage: deno run --allow-net tests/fake-pod-ws.ts PORT

const port = Number(Deno.args[0]);
const BOOK = "0x0000000000000000000000000000000000000000000000000000000000000007";
const R = (n: number) => 1795710000000000 + n * 500000;
const E18 = "000000000000000000";
let conns = 0;

function frame(n: number, bid: number) {
  return JSON.stringify({
    jsonrpc: "2.0", method: "eth_subscription",
    params: {
      subscription: "0xsub",
      result: {
        orderbook_id: BOOK, timestamp: R(n), buys_count: 1, sells_count: 1, clearing_price: "0x0",
        buys: { [`${bid}${E18}`]: { volume: "0xde0b6b3a7640000" } },
        sells: { [`${bid + 1}${E18}`]: { volume: "0xde0b6b3a7640000" } },
      },
    },
  });
}

Deno.serve({ port, hostname: "127.0.0.1", onListen: () => console.log(JSON.stringify({ listening: port })) }, (req) => {
  const { socket, response } = Deno.upgradeWebSocket(req);
  const conn = ++conns;
  let subs = 0;
  socket.onmessage = (e) => {
    const m = JSON.parse(String(e.data));
    if (m.method === "eth_chainId") { socket.send(JSON.stringify({ jsonrpc: "2.0", id: m.id, result: "0x1f916" })); return; }
    if (m.method !== "eth_subscribe") return;
    subs += 1;
    const p = m.params[1] || {};
    console.log(JSON.stringify({ conn, sub: subs, channel: m.params[0], since: p.since ?? null }));
    socket.send(JSON.stringify({ jsonrpc: "2.0", id: m.id, result: "0xsub" }));
    if (conn === 1) {
      for (const n of [1, 2, 3]) socket.send(frame(n, 150));
      setTimeout(() => socket.close(), 300);
    } else if (conn === 2 && subs === 1) {
      socket.send(frame(4, 151));
      setTimeout(() => socket.send(JSON.stringify({
        jsonrpc: "2.0", method: "eth_subscription",
        params: { subscription: "0xsub", error: { code: -32020, message: "subscriber fell behind", data: { resumable: true, resume_since: R(4) } } },
      })), 200);
    } else {
      setTimeout(() => socket.send(frame(5, 200)), 200);
    }
  };
  return response;
});
