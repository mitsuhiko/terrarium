# agent

2026-10-15 - pi-durable 1.2.0 and pi-ai 1.2.0 in a WKWebView, iOS 27
simulator (iPhone 17). Not a real device.

**Questions:** Can pi-durable run in a web view on `app://` with native
storage, provider HTTP through the host and project files through the
bridge (D7)? Does it survive the page going away mid-turn (Q4, the local
half)? What does it cost?

**What it is:** A SwiftUI app with one WKWebView, built with `swiftc` like
`ios-host`. The page (Vite + TypeScript) runs pi-durable's Harness. The
host provides:
- `Sources/Sql.swift`: SQLite (the system library) behind pi-durable's
  `SqliteDatabase` facade (`web/src/sqlite.ts`). There is one connection per
  database, and every call is a bridge round trip. The page serializes the
  calls, so a transaction is `BEGIN IMMEDIATE` … `COMMIT` in call order.
  Before every navigation the host rolls back any transaction a page left
  open.
- `Sources/ProjectFiles.swift`: a project folder, read and written as base64.
  `web/src/env.ts` builds pi-durable's `ExecutionEnv` on top of it:
  - The agent sees the folder as `/`, and paths that leave it are refused.
  - `exec` answers `shell_unavailable`.
  - pi-durable's `read`, `write` and `edit` only use six of its methods.
- `Sources/SchemeHandler.swift`: the `/__http` proxy (D25), but streaming,
  and it adds API keys:
  - Every chunk URLSession delivers goes to the page right away.
  - A request carrying the launch token (`X-Terrarium-Token`) gets the API key
    header for its target host set natively. The page only holds a
    placeholder key.
- `mock/server.py`: a scripted Anthropic Messages server on the Mac
  (server-sent events, tool calls, slow answers). It returns 401 unless the
  host injected its key.

pi-ai's real Anthropic client (`anthropic-messages`) talks to the mock
through a patched `fetch` (`web/src/proxy.ts`). Other steps script the
model with pi-ai's faux provider.

```sh
./run.sh                    # all steps; prints JSON
./run.sh boot,storage       # some steps
./run.sh --real             # also edit a file with a real Anthropic model ($ANTHROPIC_API_KEY)
SIM=<udid> ./run.sh         # a specific simulator
```

## Results (iPhone 17 simulator, three runs, all steps pass)

| Step | Result |
|---|---|
| Bundle | Vite builds pi-durable, pi-ai (Anthropic) and chord for the browser as is. 190 KB of JS gzipped (650 KB minified); the Anthropic client is a lazy chunk. The only warning is a Bun-only `node:fs` path in pi-ai. |
| Startup | Modules loaded 31-62 ms after navigation. `Harness.open` + `root()`: 6 ms on memory, 23-57 ms on a new SQLite file. |
| Storage | pi-durable's storage conformance suite passes on the bridge adapter: **24/24**, in about 0.5 s. |
| Bridge round trip | 0.13-0.14 ms per SQLite call |
| 20 tool calls (faux model, trivial tool) | 40 ms on memory, **440 ms on SQLite**: 2757 bridge calls, about 138 per tool round, about 20 ms each |
| Streamed answer (about 10 s, partial commits every 100 ms) | The same time on memory and SQLite (9.9 vs 10.0 s); about 940 bridge calls |
| Tools over the project env | `read`, `edit` and `write` (including a new subdirectory) change the native files. `../outside.txt` and a missing file come back to the model as error results. |
| Streaming through the scheme handler | 10 server-sent events 200 ms apart arrive as 10 chunks, the first after 17-40 ms and the last after about 1.9 s. **`WKURLSchemeTask` streams to `fetch`**. |
| Credentials | Through the patched `fetch` the host injects the key (200, `X-Terrarium-Credential: injected`). The same request without the token gets no key (401). |
| Real client through the proxy | pi-ai's Anthropic SDK client streams a tool call from the mock, and the Harness runs `write` and sends the result back. The whole run takes 60-200 ms. |
| Reload in the middle of a streamed answer | The SQLite transaction open at the reload is rolled back by the host. After the reload, `submit` with the same `requestId` finds the submission and `harness.resume()` retries the generation. The partial answer stays as an `aborted` entry, and the full answer follows (2 requests to the mock). |
| Reload in the middle of a tool call | The call is not replay-safe, so the model gets "Tool sleep was interrupted and may have partially run" as an error result and answers. |
| Real Anthropic model | Not run (no key here); `./run.sh --real` does it |

## Takeaways

- **pi-durable runs in WKWebView unmodified.** Everything platform-specific is
  in this spike's host and adapters: SQLite over the bridge, a project
  `ExecutionEnv`, and `fetch` through the proxy.
- **Storage:** native SQLite through the bridge is correct (it passes the
  conformance suite) and fast enough for chat.
  - Streaming answers cost nothing extra.
  - Tool rounds cost about 20 ms each, from about 140 statements, each its
    own round trip. If that matters on a device, add a batched op (several
    statements per message) or do commits natively.
- **Credentials:** keys never need to enter the web view. The proxy adds
  them per target host, and only for requests with the page's token, which
  workers (user Python, agent-written Python) don't have.
- **Streaming:** the proxy can stream, and the app's buffered `/__http`
  (D25) should switch to this delegate-based version. Python's `requests` /
  `httpx` would then stream too.
- **Durability (local half of Q4):** reloading the page works as a crash
  stand-in.
  - Same `requestId` plus `resume()` picks the turn up again.
  - An interrupted model answer retries.
  - An interrupted tool call that is not replay-safe becomes an error result
    the model sees.
  - The host must roll back an open transaction whenever the page goes away.
  - A real WebContent crash (jetsam) was not tried. Neither was the app being
    suspended in the background.
- Not covered here: memory on a device, the iPhone 14 Pro numbers,
  `run_python`/`check`/`format` (they wrap engine features that already
  exist), and the native UI.

## Sign-in (2026-10-15, iPhone 17 simulator)

**Question:** do pi-ai's OAuth and API-key sign-ins work in a WKWebView,
with the Keychain for storage?

**Added:**
- `Sources/Loopback.swift`: a loopback HTTP listener (`NWListener`,
  127.0.0.1 and ::1).
- `Sources/Keychain.swift`: credentials in the Keychain.
- `ASWebAuthenticationSession` and `clipboard.set` in `App.swift`.
- `web/src/shims/`: `node:http` on the listener, `node:crypto`'s
  `randomBytes`.
- `web/src/login.ts`: pi-ai's flows registered through Vite aliases, a
  Keychain `CredentialStore`, and HTML prompts standing in for a native
  sheet.
- In `mock/server.py`: an OAuth server (authorize, then a redirect to
  localhost; code exchange with PKCE; refresh).

```sh
./run.sh oauth-mock                    # automated
./run.sh oauth:anthropic:browser       # you sign in in the simulator
./run.sh apikey:openai                 # you paste a key
./run.sh logins / logout
```

| Check | Result |
|---|---|
| Bundling | All nine pi-ai OAuth flows bundle (31 KB) once `node:http` and `node:crypto` are aliased to shims. |
| `oauth-mock` (3 runs) | Passes end to end in about 1.5 s: an ephemeral sign-in sheet, the mock's authorize page, the redirect to `http://localhost:<port>/callback`, the native listener, pi-ai's own `startOAuthCallbackServer`, code exchange, Keychain, Bearer requests (the `claude-cli/…` User-Agent and `anthropic-beta` arrive), a forced refresh (new token), and a reload (the Keychain copy works). |
| Claude Pro/Max, browser login (real account) | The first try failed: the token endpoint answered **429 "Rate limited"**. Cause: the proxy forwarded WebKit's browser User-Agent. Checked from the Mac: an iPhone Safari or curl User-Agent gets 429, `node` or CFNetwork gets a normal 400 for a bad code. After the proxy stopped forwarding WebKit's User-Agent: signed in; `claude-haiku-4-5` answered "OK" (0.8 s); a forced refresh rotated the token; after a reload the Keychain copy still worked. |
| Other providers | Not tried (aborted to integrate). |

**Keychain in the simulator:** an ad-hoc signed app without entitlements
gets -34018. Signing with entitlements makes the simulator refuse to launch
the app. Embedding them in `__TEXT,__entitlements` through the linker, as
Xcode does, works (`Entitlements.plist`, `run.sh`).

**Not answered here:** on a device, the sign-in sheet runs in another
process. The simulator shares the Mac's network, so it can't show that the
sheet reaches the app's loopback listener (D33, Q22). Update 2026-10-17:
it does; the agent and its sign-in work in the app on the iPhone 14 Pro.
