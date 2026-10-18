// The spike's checks. Each returns a JSON-able result with `ok`. Steps that
// reload the page mid-way keep their phase in the host (see main.ts).
import { fauxAssistantMessage, fauxProvider, fauxText, fauxToolCall } from "@earendil-works/pi-ai/providers/faux";
import { createModels } from "@earendil-works/pi-ai/models";
import type { Conversation, Harness } from "@earendil-works/pi-durable";
import { createExpectAssertions, createStorageConformance } from "@earendil-works/pi-durable/testing";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { createSpikeModels, ctx, openHarness, openStorage, sleepSignals } from "./agent";
import { base64ToBytes, bytesToBase64, call, type Config, log } from "./bridge";
import { expect } from "./expect";
import { rawFetch } from "./proxy";
import { BridgeSqlite, stats } from "./sqlite";
import { interactive, listLogins, logout, oauthMock } from "./login";

export interface StepContext {
  config: Config;
  phase: number;
  /** Remember the phase, then reload the page; the step runs again with it. */
  reloadAt(phase: number): Promise<never>;
}
export type Result = { ok: boolean; [key: string]: unknown };
type Step = (c: StepContext, args: string[]) => Promise<Result>;

const ms = (start: number) => Math.round(performance.now() - start);
const sleep = (n: number) => new Promise((r) => setTimeout(r, n));

// -- helpers ----------------------------------------------------------------------

async function readProject(path: string): Promise<string | null> {
  try {
    return new TextDecoder().decode(base64ToBytes(await call<string>("fs.read", { path })));
  } catch {
    return null;
  }
}

async function writeProject(path: string, text: string) {
  await call("fs.write", { path, data: bytesToBase64(new TextEncoder().encode(text)) });
}

type Line = { kind: string; role?: string; tool?: string; isError?: boolean; stop?: string; text: string };

async function transcript(root: Conversation): Promise<Line[]> {
  const page = await root.entries({}, 500, undefined, ctx);
  return [...page.items].reverse().map((entry: any) => {
    const m = entry.model?.[0];
    const content = Array.isArray(m?.content) ? m.content : typeof m?.content === "string" ? [{ type: "text", text: m.content }] : [];
    const text = content
      .map((c: any) => (c.type === "text" ? c.text : c.type === "toolCall" ? `[call ${c.name} ${JSON.stringify(c.arguments)}]` : `[${c.type}]`))
      .join("");
    return { kind: entry.kind, role: m?.role, tool: m?.toolName, isError: m?.isError, stop: m?.stopReason, text };
  });
}

const lastAnswer = (lines: Line[]) => lines.filter((l) => l.kind === "pi.assistant").at(-1)?.text ?? "";

async function ask(root: Conversation, content: string, requestId?: string) {
  const submission = await root.submit({ type: "input", content, ...(requestId ? { requestId } : {}) }, ctx);
  return submission.wait(ctx);
}

async function mock(c: StepContext, path: string, init?: RequestInit) {
  return (await fetch(`${c.config.mockUrl}${path}`, init)).json();
}

// -- steps ------------------------------------------------------------------------

/** Startup: the bundle is loaded by now; time Harness.open on both storages. */
const boot: Step = async () => {
  const loadedMs = Math.round(performance.now());
  let t = performance.now();
  const memory = await openHarness((await openStorage(null, true)).storage, createModels());
  await memory.root(ctx);
  const memoryOpenMs = ms(t);
  await memory.close(ctx);
  t = performance.now();
  const sqlite = await openHarness((await openStorage("boot", true)).storage, createModels());
  await sqlite.root(ctx);
  const sqliteOpenMs = ms(t);
  await sqlite.close(ctx);
  return { ok: true, pageToModulesMs: loadedMs, memoryOpenMs, sqliteOpenMs };
};

/** pi-durable's storage conformance suite over the native SQLite bridge. */
const storage: Step = async () => {
  let n = 0;
  const cases = createStorageConformance({
    assertions: createExpectAssertions(expect),
    withStorage: async (use) => {
      const name = `conformance-${n++}`;
      await BridgeSqlite.delete(name);
      const { database } = await BridgeSqlite.open(name);
      const s = await SqliteStorage.open(database);
      try {
        await use(s);
      } finally {
        await s.close(ctx).catch(() => {});
        await BridgeSqlite.delete(name);
      }
    },
  });
  const failures: { name: string; error: string }[] = [];
  const t = performance.now();
  for (const testCase of cases) {
    try {
      await testCase.run();
    } catch (e) {
      failures.push({ name: testCase.name, error: String((e as Error)?.message ?? e).slice(0, 400) });
    }
  }
  return { ok: failures.length === 0, cases: cases.length, failed: failures.length, ms: ms(t), failures: failures.slice(0, 10) };
};

/** Bridge round trips, and the same agent runs on memory vs bridge SQLite. */
const bench: Step = async () => {
  const { database } = await BridgeSqlite.open("bench-rt");
  let t = performance.now();
  const N = 500;
  for (let i = 0; i < N; i++) await database.get("SELECT ? AS v", i);
  const roundTripMs = Number((ms(t) / N).toFixed(3));
  await database.close();

  const run = async (kind: "memory" | "sqlite", script: "tools" | "stream") => {
    const faux = fauxProvider({ tokensPerSecond: script === "stream" ? 2000 : undefined });
    const models = createModels();
    models.setProvider(faux.provider);
    const responses = [];
    if (script === "tools") {
      for (let i = 0; i < 20; i++) {
        responses.push(fauxAssistantMessage([fauxToolCall("noop", { n: i }, { id: `t${i}` })], { stopReason: "toolUse" }));
      }
      responses.push(fauxAssistantMessage([fauxText("done")]));
    } else {
      responses.push(fauxAssistantMessage([fauxText("word ".repeat(4000))]));
    }
    faux.setResponses(responses);
    const harness = await openHarness((await openStorage(kind === "sqlite" ? `bench-${script}` : null, true)).storage, models);
    const root = await harness.root(ctx, { agent: { model: { provider: "faux", modelId: "faux-1" } } });
    const calls = stats.calls;
    t = performance.now();
    const settled = await ask(root, "go");
    const result = { ms: ms(t), status: settled.status, bridgeCalls: stats.calls - calls };
    await harness.close(ctx);
    return result;
  };
  const tools = { memory: await run("memory", "tools"), sqlite: await run("sqlite", "tools") };
  const stream = { memory: await run("memory", "stream"), sqlite: await run("sqlite", "stream") };
  const ok = [tools.memory, tools.sqlite, stream.memory, stream.sqlite].every((r) => r.status === "done");
  return { ok, roundTripMs, twentyToolCalls: tools, streamedAnswer: stream };
};

/** read / edit / write over the project env, plus the errors the model should get. */
const tools: Step = async () => {
  await call("fs.reset");
  await writeProject("hello.py", 'print("hello")\n');
  const faux = fauxProvider();
  const models = createModels();
  models.setProvider(faux.provider);
  const tool = (name: string, args: Parameters<typeof fauxToolCall>[1], id: string) =>
    fauxAssistantMessage([fauxToolCall(name, args, { id })], { stopReason: "toolUse" });
  faux.setResponses([
    tool("read", { path: "hello.py" }, "r1"),
    tool("edit", { path: "hello.py", edits: [{ oldText: '"hello"', newText: '"hello, agent"' }] }, "e1"),
    tool("write", { path: "data/notes.txt", content: "notes\n" }, "w1"),
    tool("read", { path: "../outside.txt" }, "r2"),
    tool("read", { path: "missing.txt" }, "r3"),
    fauxAssistantMessage([fauxText("all done")]),
  ]);
  const harness = await openHarness((await openStorage("tools", true)).storage, models);
  const root = await harness.root(ctx, { agent: { model: { provider: "faux", modelId: "faux-1" } } });
  const t = performance.now();
  const settled = await ask(root, "go");
  const lines = await transcript(root);
  await harness.close(ctx);
  const results = lines.filter((l) => l.kind === "pi.tool-result");
  const hello = await readProject("hello.py");
  const notes = await readProject("data/notes.txt");
  const errors = results.filter((r) => r.isError).map((r) => r.text);
  return {
    ok: settled.status === "done" && hello === 'print("hello, agent")\n' && notes === "notes\n" && errors.length === 2,
    ms: ms(t),
    hello,
    notes,
    results: results.map((r) => `${r.tool}${r.isError ? " (error)" : ""}: ${r.text.slice(0, 80)}`),
  };
};

/** Does the scheme handler stream, or buffer until the end? */
const stream: Step = async (c) => {
  const t = performance.now();
  const response = await fetch(`${c.config.mockUrl}/stream?n=10&ms=200`);
  const reader = response.body!.getReader();
  const arrivals: number[] = [];
  let text = "";
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    arrivals.push(ms(t));
    text += new TextDecoder().decode(value);
  }
  const events = text.split("\n\n").filter((e) => e.startsWith("data:")).length;

  // Credentials: through the patched fetch the host injects the key; without the token it must not.
  const body = JSON.stringify({ model: "mock-1", max_tokens: 10, messages: [{ role: "user", content: "hi" }] });
  const init = { method: "POST", headers: { "content-type": "application/json", "x-api-key": "host-injected" }, body };
  const withToken = await fetch(`${c.config.mockUrl}/v1/messages`, init);
  await withToken.text();
  const proxy = new URL("/__http", location.href).href;
  const withoutToken = await rawFetch(`${proxy}?url=${encodeURIComponent(`${c.config.mockUrl}/v1/messages`)}`, init);
  await withoutToken.text();

  const streamed = arrivals.length >= 5 && arrivals[0] < 600 && arrivals.at(-1)! > 1500;
  return {
    ok: streamed && events === 10 && withToken.status === 200 && withoutToken.status === 401,
    chunks: arrivals.length,
    events,
    firstChunkMs: arrivals[0],
    lastChunkMs: arrivals.at(-1),
    credential: { withToken: withToken.status, injectedHeader: withToken.headers.get("X-Terrarium-Credential"), withoutToken: withoutToken.status },
  };
};

/** pi-ai's Anthropic client against the mock server, through the proxy: write tool round trip. */
const provider: Step = async (c) => {
  await call("fs.reset");
  await mock(c, "/reset", { method: "POST" });
  const harness = await openHarness((await openStorage("provider", true)).storage, createSpikeModels(c.config.mockUrl));
  const root = await harness.root(ctx, { agent: { model: { provider: "mock", modelId: "mock-1" } } });
  const t = performance.now();
  const settled = await ask(root, "[write] please");
  const lines = await transcript(root);
  await harness.close(ctx);
  const file = await readProject("from-model.txt");
  const answer = lastAnswer(lines);
  return {
    ok: settled.status === "done" && file === "written by the mock model\n" && answer.startsWith("saw tool result: error=false"),
    ms: ms(t),
    status: settled.status,
    reason: settled.status === "unanswered" ? (settled as any).reason : undefined,
    answer,
    mockStats: await mock(c, "/stats"),
  };
};

/**
 * The page goes away mid-turn (a reload; a crashed WebContent process looks the
 * same to the page) and comes back:
 *   phase 0: a slow streamed answer is running, and a SQLite transaction is open → reload
 *   phase 1: the transaction was rolled back; the answer completes after a retry;
 *            then the sleep tool starts → reload
 *   phase 2: the interrupted tool call came back as an error result, and the run finished
 */
const resume: Step = async (c) => {
  const models = createSpikeModels(c.config.mockUrl);
  const model = { provider: "mock", modelId: "mock-1" };
  const open = async (fresh: boolean) => {
    const opened = await openStorage("resume", fresh);
    const harness = await openHarness(opened.storage, models);
    const root = await harness.root(ctx, { agent: { model } });
    return { harness, root, database: opened.database!, rolledBack: opened.rolledBack };
  };

  if (c.phase === 0) {
    await mock(c, "/reset", { method: "POST" });
    const { root, database } = await open(true);
    await database.exec("CREATE TABLE IF NOT EXISTS probe (v TEXT)");
    void root.submit({ type: "input", content: "[slow] go", requestId: "slow-1" }, ctx);
    await sleep(1200); // about a third of the answer has streamed
    // Reload from inside an open transaction: the host must roll it back.
    await database.transaction(async (tx) => {
      await tx.run("INSERT INTO probe (v) VALUES ('uncommitted')");
      await c.reloadAt(1);
    });
  }

  if (c.phase === 1) {
    const { harness, root, database } = await open(false);
    const probe = await database.all<{ v: string }>("SELECT v FROM probe");
    harness.resume();
    const t = performance.now();
    const settled = await ask(root, "[slow] go", "slow-1"); // same request id: the same submission
    const answer = lastAnswer(await transcript(root));
    const slow = { status: settled.status, ms: ms(t), complete: answer.includes("chunk29"), answer: answer.slice(0, 80), probeRows: probe.length };
    await call("kv.set", { key: "resume.slow", value: JSON.stringify({ ...slow, rolledBackOnNavigation: c.config.rolledBackOnNavigation }) });
    const started = new Promise<void>((r) => (sleepSignals.started = r));
    void root.submit({ type: "input", content: "[sleep] go", requestId: "sleep-1" }, ctx);
    await started;
    await sleep(300);
    await c.reloadAt(2);
  }

  const { harness, root } = await open(false);
  harness.resume();
  const t = performance.now();
  const settled = await ask(root, "[sleep] go", "sleep-1");
  const lines = await transcript(root);
  await harness.close(ctx);
  const slow = JSON.parse((await call<string>("kv.get", { key: "resume.slow" })) ?? "{}");
  const sleepResult = lines.filter((l) => l.kind === "pi.tool-result" && l.tool === "sleep").at(-1);
  const stats = await mock(c, "/stats");
  return {
    ok:
      slow.status === "done" &&
      slow.complete &&
      slow.probeRows === 0 &&
      settled.status === "done" &&
      sleepResult?.isError === true &&
      lastAnswer(lines).startsWith("saw tool result: error=true"),
    slow,
    sleep: { status: settled.status, ms: ms(t), toolResult: sleepResult?.text, answer: lastAnswer(lines) },
    mockStats: stats,
    transcript: lines.map((l) => `${l.kind}${l.tool ? `(${l.tool})` : ""}${l.isError ? " error" : ""}${l.stop ? ` [${l.stop}]` : ""}: ${l.text.slice(0, 60)}`),
  };
};

/** Optional (--real): a real Anthropic model edits a file. The key stays in the host. */
const real: Step = async (c) => {
  if (!c.config.realKey) return { ok: true, skipped: "no key (run.sh --real)" };
  await call("fs.reset");
  await writeProject("hello.py", 'print("hello")\n');
  const models = createSpikeModels("");
  const ids = models.getModels().filter((m) => m.provider === "anthropic").map((m) => m.id);
  const modelId = ids.find((id) => id.includes("haiku")) ?? ids[0];
  const harness: Harness = await openHarness((await openStorage("real", true)).storage, models);
  const root = await harness.root(ctx, { agent: { model: { provider: "anthropic", modelId } } });
  const t = performance.now();
  const settled = await ask(root, "Read hello.py, then use the edit tool to make it print 'hello from the agent'. Answer in one short sentence.");
  const lines = await transcript(root);
  const usage = await harness.usage(ctx);
  await harness.close(ctx);
  const file = await readProject("hello.py");
  return {
    ok: settled.status === "done" && !!file?.includes("hello from the agent"),
    modelId,
    ms: ms(t),
    file,
    answer: lastAnswer(lines),
    tools: lines.filter((l) => l.kind === "pi.tool-result").map((l) => `${l.tool}${l.isError ? " (error)" : ""}`),
    usage,
  };
};

export const STEPS: Record<string, Step> = {
  boot,
  storage,
  bench,
  tools,
  stream,
  provider,
  resume,
  real,
  "oauth-mock": (c) => oauthMock(c),
  oauth: (c, args) => interactive(c, "oauth", args),
  apikey: (c, args) => interactive(c, "api_key", args),
  logins: () => listLogins(),
  logout: (c, args) => logout(c, args),
};
export const DEFAULT_STEPS = ["boot", "storage", "bench", "tools", "stream", "provider", "resume", "oauth-mock", "real"];
export { log };
