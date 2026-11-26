# Section 2: Status

*Spec, 2026-11-26. Decided in the interview of 2026-11-26. Branch `4-cli`: this section now runs as `pod` commands; see [08-cli-and-hook.md](08-cli-and-hook.md) for the command map and the approval hook. The decisions and findings below are unchanged.*

Status answers one question: **can the AI act on pod right now, and if not, why not?** It also tells the agent what it can and cannot do. It runs on demand: when the user or agent asks with `pod status`, or when an agent runs it before other work. There is no session-start hook.

## Decisions

| # | Topic | Decision |
|---|---|---|
| T1 | At session start | **Nothing runs.** No session-start hook (decided 2026-11-26): a user-scope plugin would fire it in every session on the machine, in every project |
| T2 | When status runs | On demand only: `pod status`, or an agent running `pod status --quick` before other work |
| T3 | Wallet connected and funded, but the test transaction was denied or never run | Level **connected, untested**. Trading is allowed, with a warning. The first real accepted send then counts as the proof |
| T4 | How long a passed test counts | **Until a send fails** for a lasting reason (region block, blacklist, frozen account). Then the level drops to **problem** |
| T5 | Check before each trading action | **None.** The trading section sends and relies on pod's own error; the send result updates status (T4) |
| T6 | Capabilities | Status lists **every capability** with yes or no and why, including what pod does not do |
| T7 | Installed but not set up | Status says "not set up" and points to `pod setup`. Nothing is shown unless status is asked for |
| T8 | `pod status` | A **full check** by default: the quick check plus signing a test message (decision D1 in the design). `pod status --quick` skips the signing, for an agent that only needs the facts |

## Levels

One level, picked by the first rule that matches, top to bottom:

| Level | When | Can trade? |
|---|---|---|
| **not set up** | No profile | No |
| **problem** | Pod does not answer, or answers with the wrong chain; the wallet is missing (keystore deleted, Keychain entry gone, variable not set); the account is frozen; the test transaction failed; the last send failed for a lasting reason; the full check's signature does not match | No |
| **connected, read-only** | Pod is paused or read-only, or the account has no cash | No |
| **connected, untested** | Everything above is fine, but no test transaction has passed and no real send has been accepted | Yes, with a warning |
| **ready to trade** | Everything is fine, and a test passed or a real send was accepted since the last lasting failure | Yes |

## The checks

| # | Check | Call | Quick | Full |
|---|---|---|---|---|
| 1 | Profile exists | Read `~/.config/pod-plugin/profile.json` | ✓ | ✓ |
| 2 | Pod answers, right chain, open for writes | `GET /v1/clob/status`, `eth_chainId`, `pod_status` | ✓ | ✓ |
| 3 | Wallet present | Keystore: the file exists and a Keychain entry exists (the password is not read). Variable: it is set | ✓ | ✓ |
| 4 | Wallet signs as the profile's address | Sign a fixed message and verify it | | ✓ |
| 5 | Account | `GET /v1/clob/balances/{a}`, `/positions/{a}`, `/orders/{a}?status=active` | ✓ | ✓ |
| 6 | Account not frozen | `pod_getAccountDiagnostics`: `is_locked`, `needs_recovery` and `equivocating` all false | ✓ | ✓ |
| 7 | Proof of sending | From the profile: `test_transaction` and `last_send` | ✓ | ✓ |

The network calls run in parallel, so the quick check takes about one second. If pod does not answer within 5 seconds, the level is **problem** with "pod did not answer".

## What status reports

```json
{
  "ok": true,
  "level": "ready to trade",
  "check": "quick",
  "network": {"name": "staging", "chain_id": 129302, "writes_open": true},
  "wallet": {"type": "keystore", "keystore": "exotic-test-1", "address": "0x035A…DA70", "present": true, "signs": null},
  "account": {"account_value_usd": "100", "cash_usd": "100", "unrealized_pnl_usd": "0", "withdrawable_usd": "100",
              "open_positions": 0, "open_orders": 0, "frozen": false},
  "proof": {"test_transaction": "passed 2026-11-26T13:53:55Z", "last_send": null},
  "capabilities": [
    {"name": "read markets and prices", "can": true},
    {"name": "read any account", "can": true},
    {"name": "follow live updates", "can": true, "note": "needs a listener kept open by the harness"},
    {"name": "trade with this wallet", "can": true},
    {"name": "deposit, withdraw, transfer", "can": false, "why": "not part of pod"},
    {"name": "bot keys (delegation)", "can": false, "why": "not part of pod"},
    {"name": "recover a frozen account", "can": false, "why": "not part of pod"}
  ],
  "problems": [],
  "warnings": []
}
```

`problems` lists each failed check with its error and fix. `warnings` holds non-blocking notes, such as "untested: the first trade will be the proof". `signs` is null after a quick check, true or false after a full check.

## Recording sends (T4, T5)

`wallet.sh send` writes the outcome of every send into the profile as `last_send`:

| Outcome | Recorded | Effect on level |
|---|---|---|
| Accepted by pod | `{ok: true, at, tx}` | Counts as proof: untested becomes ready |
| Refused for a lasting reason: region (`-32025`), blacklist, frozen account | `{ok: false, lasting: true, at, error}` | Problem, until a later send is accepted or a test passes |
| Refused for a passing reason: timeout, nonce clash, pod busy | `{ok: false, lasting: false, at, error}` | No change |

A later passed test or accepted send clears a lasting failure.

## Scripts and files

| File | Job |
|---|---|
| `pod status [--quick]` | Runs the checks and prints the status object. Full check by default; `--quick` skips signing |
| `cli/libexec/wallet.sh send` | Also writes `last_send` (above) |
| `pod status --help` | The manual: what each level and field means |

## Not part of status

Fixing problems (each problem names its fix, usually `pod setup`), checks before trades (T5), a session-start hook (T1), a permanent status-line indicator.

## Implementation notes (2026-11-26)

Built in [cli](file:///Users/sabpap/Workspace/Clients/Laurium/pod-ai/cli/): `pod status` (`cli/libexec/status.sh`), the `/pod:status` skill, send recording in `wallet.sh` (helpers `send_failure_kind` and `record_send` in `lib.sh`). Setup now reports the same level names as status: its "set up" became "connected, untested".

| Finding | Effect |
|---|---|
| Staging sometimes drops a single request | Each status call is tried twice. Without this, one dropped read made the level "problem" in one smoke run out of four |
| Timing | Quick check about 0.6 s; full check about 2 s, most of it the Keychain read and signing |
| `pod_getAccountDiagnostics` returns `is_locked`, `needs_recovery`, `equivocating` | Any of them true means "frozen" |
| Only sends with the profile's own wallet are recorded | Setup's checks with a named wallet (`--keystore`, `--env`) never touch `last_send` |

Tests: 22 offline unit checks; 22 read-only smoke checks covering not set up, read-only, a missing variable, a lasting refusal, an accepted send clearing it, and a passing refusal ignored. Full and quick checks on the real profile both give "ready to trade".

## Change: value instead of cash in the summary line (2026-11-26)

After the dev wallet opened a small NVDA perp, the line still said "$100 cash": opening a perp only holds part of the cash as collateral (margin), so cash barely moves. The line now shows the **account value** (cash plus unrealized profit or loss), at most 4 decimals so a small trade stays visible: `pod: ready to trade · 0x035A…Da70 · value $99.9971 · 1 position · 0 orders`. The `account` object adds `unrealized_pnl_usd`. Each position's details (size, prices, margin, liquidation price) belong to the Account section, not to status. Version 0.2.1.

## Change: settings shown (2026-11-26)

Status always reports the trading settings (`approval`, `market_band_pct`, `default_ttl`, with defaults filled in, and the same `in_words`), and its summary line ends with "asks before trading" or "trades without asking". Setup's final answer reports them too, and setup now saves the defaults into the profile. They are changed with the new `/pod:settings` skill (in branch `4-cli`: `pod settings`). They are not in the Account section, because account reads any address while the settings belong to this machine's connected wallet. Version 0.4.1.
