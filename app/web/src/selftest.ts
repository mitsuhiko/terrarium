// End-to-end checks for the app (run with #selftest): edit, run, input, plots,
// file write-back, console, UI apps, crash recovery. Runs in the engine page
// (D31) and drives the native app through the host (`app`), the focused
// editor page through the host as well. Reports via the bridge.
import { analysis } from "./analysis/client";
import { base64ToBytes, call, fs, locations } from "./host";
import { breakpoints } from "./debug/breakpoints";
import { session } from "./session";
import type { Trace } from "./trace";
import { turtleScenes } from "./turtle";
import navigationExample from "../../../uikit/examples/Navigation.py?raw";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function until<T>(fn: () => T | undefined | null | false | Promise<T | undefined | null | false>, timeout = 15000): Promise<T> {
  const t0 = performance.now();
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (performance.now() - t0 > timeout) throw new Error("timed out");
    await sleep(50);
  }
}

// The native UI app (D30), as the host's renderer sees it.
interface NativeNode {
  i: number;
  t: string;
  p: Record<string, any>;
  c?: NativeNode[];
}

const nativeTree = () =>
  call<{ visible: boolean; closeButton: boolean; restarting: boolean; tree: NativeNode; sheets: number[]; dialogs: { id: number; kind: string }[] }>(
    "test.ui",
    { action: "tree" },
  );
const nativeRenderStats = () => call<{ ops: number; ms: number }>("test.ui", { action: "stats" });
const nativeEvent = (id: number, event: string, args: unknown[] = []) => call("test.ui", { action: "event", id, event, args });

function findNodes(node: NativeNode, pred: (n: NativeNode) => boolean, out: NativeNode[] = []): NativeNode[] {
  if (pred(node)) out.push(node);
  for (const c of node.c ?? []) findNodes(c, pred, out);
  return out;
}

const untilNode = (pred: (n: NativeNode) => boolean) =>
  until(async () => {
    const t = await nativeTree();
    return t.visible ? findNodes(t.tree, pred)[0] : undefined;
  });

/** The native app, through the host's self-test hooks (SelfTest.swift). */
const appCall = <T = any>(method: string, ...args: unknown[]) => call<T>("app", { method, args });
const editorCall = <T = any>(method: string, ...args: unknown[]) => appCall<T>("editor", method, args);

const app = {
  openFile: (path: string) => appCall("openFile", path),
  openLocation: (path: string, line?: number, column?: number) => appCall("openLocation", path, line ?? null, column ?? null),
  currentFile: () => appCall<string | null>("currentFile"),
  editorPath: () => editorCall<string | null>("path"),
  run: () => appCall("run"),
  format: () => appCall("format"),
  goToDefinition: () => appCall("goToDefinition"),
  panes: () => appCall<{ tabs: string[]; active: string | null }[]>("panes"),
  setSplit: (on: boolean) => appCall("setSplit", on),
  closeTab: (path: string) => appCall("closeTab", path),
  showPane: (pane: string) => appCall("showPane", pane),
  wide: () => appCall<boolean>("wide"),
  setWide: (on: boolean) => appCall("setWide", on),
  editorShown: () => appCall<boolean>("editorShown"),
  tapTraceback: (text: string) => appCall<number>("tapTraceback", text),
  tapTraceFrame: (name: string) => appCall<string | null>("tapTraceFrame", name),
  focusField: (field: "console" | "input") => appCall("focusField", field),
  fieldValue: (field: "console" | "input") => appCall<string>("fieldValue", field),
  submitField: (field: "console" | "input") => appCall("submitField", field),
  blurFields: () => appCall("blurFields"),
  clearField: (field: "console" | "input") => appCall("clearField", field),
};

const lastTrace = (): Trace | undefined => session.getSnapshot().lines.findLast((l) => l.trace)?.trace;
const consoleText = () => session.getSnapshot().lines.filter((l) => l.kind !== "image" && l.kind !== "turtle").map((l) => l.text).join("");
const idle = () => session.getSnapshot().status === "idle";

export async function selftest() {
  const r: Record<string, unknown> = {};
  const log = (m: string) => call("log", m).catch(() => {});

  // #selftest&only=<substring> runs a subset.
  const only = new URLSearchParams(location.hash.slice(1)).get("only");

  async function step(name: string, fn: () => Promise<Record<string, unknown> | void>) {
    if (only && !new RegExp(only).test(name)) return;
    await appCall("hangs").catch(() => null); // only this step's
    const t0 = performance.now();
    try {
      r[name] = { ok: true, ...(await fn()), ms: Math.round(performance.now() - t0) };
    } catch (e) {
      const { status, debug, pausing } = session.getSnapshot();
      r[name] = { ok: false, error: String((e as Error).message ?? e), console: consoleText().slice(-400), session: { status, pausing, debug: debug && { reason: debug.reason, frames: debug.frames } } };
    }
    // Main-thread hangs during the step (Diagnostics): reported, not a failure.
    const hangs = await appCall<number[]>("hangs").catch(() => []);
    if (hangs.length) (r[name] as Record<string, unknown>).hangs = hangs;
    // Nothing a step showed stays up: a stray sheet or alert takes every touch.
    const presented = await appCall<string[]>("presented").catch(() => []);
    if (presented.length) {
      Object.assign(r[name] as Record<string, unknown>, { ok: false, leftOver: presented });
      await appCall("dismissPresented").catch(() => {});
    }
    await log(`${name}: ${JSON.stringify(r[name])}`);
  }

  async function runFile(path: string, code?: string) {
    await app.openFile(path);
    await until(async () => (await app.currentFile()) === path && (await app.editorPath()) === path);
    if (code !== undefined) await editorCall("setText", code);
    session.clear();
    const t0 = performance.now();
    await app.run();
    await until(() => session.getSnapshot().status !== "idle" || performance.now() - t0 > 3000);
    const done = until(idle, 120000);
    done.catch(() => {});
    return { done, t0 };
  }

  // engine_recovery ended the last page's process (D50): this page replaced
  // it. Check what it got from the host, then report everything.
  const stash = await appCall<string | null>("takeStash").catch(() => null);
  if (stash) {
    Object.assign(r, JSON.parse(stash));
    await step("engine_recovery", async () => {
      // The console came back, and the program that was running says why it ended.
      const text = await until(() => {
        const t = consoleText();
        return t.includes("before the end") && t.includes("Python was stopped") ? t : null;
      }, 15000).catch(() => {
        throw new Error(`restored: ${consoleText().slice(-400)}`);
      });
      const run = Object.values(session.getSnapshot().runs).find((x) => x.file === "Tests/recover.py");
      if (run?.status !== "crashed") throw new Error(`run: ${JSON.stringify(run)}`);
      // Python works in the new page, and the console keeps growing after the old lines.
      await fs.writeText("Tests/after.py", "print('alive after the reload')\n");
      const { done } = await runFile("Tests/after.py");
      await done;
      if (!consoleText().includes("alive after the reload")) throw new Error(consoleText().slice(-400));
      return { restoredChars: text.length };
    });
    await fs.remove("Tests").catch(() => {});
    await call("result", JSON.stringify(r, null, 2));
    return;
  }

  // Breakpoints live in the web view's storage, which --reset does not clear.
  breakpoints.clearAll();
  await app.setSplit(false); // a split view restored from the last session
  await appCall("setHalves", "editor", "console", true); // and what its halves showed (D59)

  // What this WebKit gives the engine page: Python needs isolation and shared memory (D9).
  await step("environment", async () => {
    const ua = navigator.userAgent.match(/OS ([\d_]+)/)?.[1]?.replace(/_/g, ".");
    let sabClone = "ok";
    try {
      structuredClone(new SharedArrayBuffer(4));
    } catch (e) {
      sabClone = String((e as Error).message ?? e);
    }
    return {
      ios: ua, crossOriginIsolated: self.crossOriginIsolated, secure: self.isSecureContext,
      sabClone,
      jspi: typeof (WebAssembly as any).Suspending === "function",
    };
  });

  await step("examples_seeded", async () => {
    const names = (await fs.list("Examples")).map((e) => e.name);
    if (!names.includes("Hello.py")) throw new Error(`examples: ${names}`);
    return { examples: names.length };
  });

  await step("edit_and_run", async () => {
    await fs.mkdir("Tests");
    await fs.writeText("Tests/edit.py", "");
    const { done, t0 } = await runFile("Tests/edit.py", "import sys\nprint('hi from', sys.version.split()[0])\nprint(sum(range(10)))\n");
    await done;
    await until(idle);
    const out = consoleText();
    if (!out.includes("hi from 3.14") || !out.includes("45")) throw new Error(out);
    const saved = await fs.readText("Tests/edit.py");
    if (!saved.includes("hi from")) throw new Error("edit was not saved before running");
    return { runMs: Math.round(performance.now() - t0) };
  });

  await step("input", async () => {
    await runFile("Examples/Hello.py");
    await until(() => session.getSnapshot().awaitingInput);
    session.submitInput("Armin");
    await until(idle);
    if (!consoleText().includes("Hello, Armin!")) throw new Error(consoleText());
  });

  await step("traceback", async () => {
    await fs.writeText("Tests/boom.py", "def f():\n    return 1 / 0\n\nf()\n");
    await runFile("Tests/boom.py");
    await until(idle);
    const out = consoleText();
    if (!out.includes("ZeroDivisionError") || !out.includes('File "boom.py", line 2')) throw new Error(out);
    if (out.includes("_pyodide")) throw new Error("pyodide frames not removed");
    // As data too (D45): the frames, their spans and source, the debugger's index.
    const trace = lastTrace();
    const exc = trace?.exceptions.at(-1);
    const [outer, inner] = exc?.frames ?? [];
    const ok = trace?.exceptions.length === 1 && exc!.type === "ZeroDivisionError" && exc!.message === "division by zero" &&
      exc!.frames.length === 2 && outer.name === "<module>" && outer.file === "boom.py" && outer.line === 4 && outer.col === 0 && outer.endCol === 3 &&
      inner.name === "f" && inner.line === 2 && inner.kind === "app" && inner.col === 11 && inner.endCol === 16 &&
      inner.context?.start === 1 && inner.context.lines[1] === "    return 1 / 0" && inner.debug === 0 && outer.debug === 1;
    if (!ok) throw new Error(JSON.stringify(trace));
  });

  await step("traceback_data", async () => {
    // A chain with a library frame, recursion, a SyntaxError, a ui-style report: each as data.
    const cases: [string, string, (t: Trace) => unknown][] = [
      ["Tests/tb_chain.py", "import json\n\ndef load(s):\n    try:\n        return json.loads(s)\n    except ValueError as e:\n        raise RuntimeError('bad config') from e\n\nload('{x')\n", (t) => {
        const [first, second] = t.exceptions;
        return t.exceptions.length === 2 && first.type === "json.decoder.JSONDecodeError" && second.chain === "cause" && second.type === "RuntimeError" &&
          first.frames.some((f) => f.kind === "library" && f.file?.startsWith("json/")) && first.frames[0].kind === "app" && first.frames[0].name === "load" &&
          t.text.includes("The above exception was the direct cause");
      }],
      ["Tests/tb_rec.py", "def r(n):\n    return r(n + 1)\n\nr(0)\n", (t) => {
        const f = t.exceptions[0].frames;
        return t.exceptions[0].type === "RecursionError" && f.length === 2 && (f[1].repeat ?? 0) > 100;
      }],
      ["Tests/tb_syntax.py", "x = 1\nif x = 2:\n    pass\n", (t) => {
        const e = t.exceptions[0];
        return e.type === "SyntaxError" && e.syntax?.line === 2 && e.syntax.file === "tb_syntax.py" && e.syntax.context?.lines.includes("if x = 2:") && e.syntax.col !== undefined;
      }],
      ["Tests/tb_name.py", "count = 1\nprint(conut)\n", (t) => {
        const e = t.exceptions[0];
        return e.type === "NameError" && e.message.includes("Did you mean: 'count'?") && e.frames[0].col === 6 && e.frames[0].endCol === 11;
      }],
    ];
    const got: Record<string, unknown> = {};
    for (const [path, code, check] of cases) {
      await fs.writeText(path, code);
      const { done } = await runFile(path);
      await done;
      await until(idle);
      const trace = lastTrace();
      if (!trace || !check(trace)) throw new Error(`${path}: ${JSON.stringify(trace ?? consoleText()).slice(0, 1500)}`);
      got[path] = trace.exceptions.map((e) => `${e.type}:${e.frames.length}`).join(" ");
    }
    // Console input: each input's source is there, a function from an earlier one too.
    await session.runConsole("def g(x):\n    return x[3]");
    await until(idle);
    await session.runConsole("g([1])");
    await until(() => idle() && lastTrace()?.exceptions[0]?.type === "IndexError");
    const frames = lastTrace()!.exceptions[0].frames;
    if (frames.length !== 2 || !/^<console-\d+>$/.test(frames[1].file ?? "") || frames[1].file === frames[0].file ||
        frames[1].context?.lines[1] !== "    return x[3]" || frames[0].context?.lines[0] !== "g([1])" || frames[1].kind !== "app") {
      throw new Error(`console: ${JSON.stringify(frames)}`);
    }
    // An exception the runtime catches and shows (a ui callback, a turtle event handler) comes as data too.
    await fs.writeText("Tests/tb_report.py", "import _terrarium_traceback\n\ndef handler():\n    {}['missing']\n\ntry:\n    handler()\nexcept Exception as e:\n    _terrarium_traceback.report(e)\nprint('still running')\n");
    const { done } = await runFile("Tests/tb_report.py");
    await done;
    await until(idle);
    const reported = lastTrace();
    const lines = session.getSnapshot().lines;
    const at = lines.findIndex((l) => l.trace);
    const after = lines.findIndex((l) => l.text.includes("still running"));
    if (reported?.exceptions[0]?.type !== "KeyError" || reported.exceptions[0].frames.at(-1)?.name !== "handler" || at < 0 || after < at) {
      throw new Error(JSON.stringify({ reported, lines }).slice(0, 1500));
    }
    if (session.getSnapshot().runs[lines[at].runId]?.status !== "ok") throw new Error("a reported exception failed the run");
    return got;
  });

  await step("console_repl", async () => {
    await runFile("Tests/edit.py", "x = 21\n");
    await until(idle);
    await session.runConsole("x * 2");
    await until(() => consoleText().includes("42"));
    await session.runConsole("import math; math.sqrt(x * 4 + 16)");
    await until(() => consoleText().includes("10.0"));
  });

  await step("files_write_back", async () => {
    await fs.remove("Examples/notes.txt").catch(() => {});
    await runFile("Examples/Files.py");
    await until(idle);
    const notes = await fs.readText("Examples/notes.txt");
    if (!notes.startsWith("Ran at")) throw new Error(`notes.txt: ${notes}`);
    return { notes: notes.trim().slice(0, 40) };
  });

  await step("sibling_import", async () => {
    await fs.writeText("Tests/helper.py", "def greet(n):\n    return f'hello {n}'\n");
    await fs.writeText("Tests/main.py", "from helper import greet\nprint(greet('module'))\n");
    await runFile("Tests/main.py");
    await until(idle);
    if (!consoleText().includes("hello module")) throw new Error(consoleText());
    // The folder is used in place: no bytecode next to the user's files.
    if (await fs.exists("Tests/__pycache__")) throw new Error("__pycache__ written into the project");
  });

  await step("project_files_in_place", async () => {
    // D35: the program works on the folder itself. Its writes are on disk
    // before it blocks, it sees edits made meanwhile, renames and deletions
    // happen right away, and SQLite leaves no journal behind.
    const dir = "Tests/live";
    await fs.mkdir(dir);
    await fs.writeText(`${dir}/live.py`, [
      "import os, sqlite3",
      "open('live.txt', 'w').write('one')",
      "print('read:', open('live.txt').read())",
      "db = sqlite3.connect('live.db')",
      "db.execute('create table if not exists t (x)')",
      "db.executemany('insert into t values (?)', [(i,) for i in range(1000)])",
      "db.commit()",
      "input('go? ')",
      "print('reread:', open('live.txt').read())",
      "os.rename('live.txt', 'moved.txt')",
      "os.makedirs('sub/deeper', exist_ok=True)",
      "open('sub/deeper/x.txt', 'w').write('x')",
      "os.remove('moved.txt')",
      "print('rows:', db.execute('select count(*) from t').fetchone()[0])",
      "",
    ].join("\n"));
    await runFile(`${dir}/live.py`);
    await until(() => session.getSnapshot().awaitingInput);
    if ((await fs.readText(`${dir}/live.txt`)) !== "one") throw new Error("live.txt not on disk while the program waits");
    if (!(await fs.exists(`${dir}/live.db`)) || (await fs.exists(`${dir}/live.db-journal`))) throw new Error("live.db missing, or a journal left behind");
    await fs.writeText(`${dir}/live.txt`, "two"); // like the editor saving it
    session.submitInput("");
    await until(idle);
    const out = consoleText();
    if (!out.includes("read: one") || !out.includes("reread: two") || !out.includes("rows: 1000")) throw new Error(out);
    const names = (await fs.list(dir)).map((e) => e.name).sort();
    if (names.join(",") !== "live.db,live.py,sub") throw new Error(`files: ${names}`);
    if ((await fs.readText(`${dir}/sub/deeper/x.txt`)) !== "x") throw new Error("sub/deeper/x.txt");
  });

  await step("files_after_sleep", async () => {
    // Q25: a file call right after time.sleep() isn't held up (WebKit answered
    // synchronous XHRs about a second late there), and data bigger than the
    // fetch relay's buffer goes through it whole, both ways.
    const dir = "Tests/sleepfs";
    await fs.mkdir(dir).catch(() => {});
    await fs.writeText(`${dir}/sleepfs.py`, [
      "import os, time",
      "data = os.urandom(3 << 20)",
      "open('big.bin', 'wb').write(data)",
      "assert open('big.bin', 'rb').read() == data",
      "os.remove('big.bin')",
      "slowest = 0",
      "for i in range(4):",
      "    time.sleep(2)",
      "    t = time.perf_counter()",
      "    os.path.exists(f'missing{i}')",
      "    slowest = max(slowest, time.perf_counter() - t)",
      "print('slowest:', round(slowest * 1000))",
      "",
    ].join("\n"));
    const { done } = await runFile(`${dir}/sleepfs.py`);
    await done;
    const m = /slowest: (\d+)/.exec(consoleText());
    if (!m) throw new Error(consoleText().slice(-600));
    if (Number(m[1]) > 300) throw new Error(`a file call after sleep took ${m[1]} ms`);
    return { slowestMs: Number(m[1]) };
  });

  await step("plot", async () => {
    await runFile("Examples/Plot.py");
    await until(idle, 30000);
    const images = session.getSnapshot().lines.filter((l) => l.kind === "image");
    if (!images.length) throw new Error(`no image; ${consoleText().slice(-300)}`);
    return { images: images.length, pngBytes: Math.round((images[0].text.length * 3) / 4) };
  });

  await step("stop", async () => {
    await runFile("Examples/Countdown.py");
    await until(() => consoleText().includes("9"));
    session.stop();
    await until(idle);
    const run = Object.values(session.getSnapshot().runs).at(-1);
    if (run?.status !== "stopped" || consoleText().includes("crashed")) throw new Error(`${run?.status}: ${consoleText()}`);
  });

  // -- processes (D47) ------------------------------------------------------------------

  const processCounts = () => (session as any).worker?.procs?.counts as { started: number; alive: number } | undefined;

  await step("processes", async () => {
    await fs.mkdir("Tests").catch(() => {});
    await fs.writeText("Tests/procs.py", "");
    const { done, t0 } = await runFile(
      "Tests/procs.py",
      [
        "import multiprocessing as mp, os, subprocess, sys",
        "from concurrent.futures import ProcessPoolExecutor",
        "",
        "def square(x):",
        "    return x * x",
        "",
        "def add(counter, n):",
        "    for _ in range(n):",
        "        with counter.get_lock():",
        "            counter.value += 1",
        "",
        "def write_file(path):",
        "    with open(path, 'w') as f:",
        "        f.write(f'from {os.getpid()}')",
        "",
        "if __name__ == '__main__':",
        "    with mp.Pool(2) as pool:",
        "        print('pool', sum(pool.map(square, range(10))))",
        "    counter = mp.Value('i', 0)",
        "    ps = [mp.Process(target=add, args=(counter, 50)) for _ in range(2)]",
        "    for p in ps: p.start()",
        "    for p in ps: p.join()",
        "    print('counter', counter.value)",
        "    p = mp.Process(target=write_file, args=('child.txt',))",
        "    p.start(); p.join()",
        "    print('file', open('child.txt').read().startswith('from '), p.exitcode)",
        "    with ProcessPoolExecutor(2) as ex:",
        "        print('executor', list(ex.map(square, [3, 4])))",
        "    out = subprocess.run([sys.executable, '-c', 'print(6 * 7)'], capture_output=True, text=True).stdout",
        "    print('subprocess', out.strip())",
        "",
      ].join("\n"),
    );
    await done;
    const out = consoleText();
    for (const want of ["pool 285", "counter 100", "file True 0", "executor [9, 16]", "subprocess 42"]) {
      if (!out.includes(want)) throw new Error(`missing ${want}: ${out.slice(-1500)}`);
    }
    const run = Object.values(session.getSnapshot().runs).at(-1);
    if (run?.status !== "ok") throw new Error(`${run?.status}: ${out.slice(-1500)}`);
    const counts = processCounts();
    if (!counts || counts.alive !== 1) throw new Error(`processes left: ${JSON.stringify(counts)}`);
    if (!(await fs.readText("Tests/child.txt")).startsWith("from ")) throw new Error("child.txt");
    return { runMs: Math.round(performance.now() - t0), processes: counts.started };
  });

  await step("processes_stop", async () => {
    await fs.writeText("Tests/procs_stop.py", "");
    await runFile(
      "Tests/procs_stop.py",
      [
        "import multiprocessing as mp, time",
        "",
        "def sleeper(ready):",
        "    ready.release()",
        "    time.sleep(600)",
        "",
        "if __name__ == '__main__':",
        "    ready = mp.Semaphore(0)",
        "    ps = [mp.Process(target=sleeper, args=(ready,)) for _ in range(2)]",
        "    for p in ps: p.start()",
        "    for p in ps: ready.acquire()",
        "    print('all sleeping', flush=True)",
        "    for p in ps: p.join()",
        "",
      ].join("\n"),
    );
    await until(() => consoleText().includes("all sleeping"), 60000);
    const t0 = performance.now();
    session.stop();
    await until(idle);
    const idleMs = Math.round(performance.now() - t0);
    await until(() => processCounts()?.alive === 1, 3000).catch(() => {
      throw new Error(`processes left: ${JSON.stringify(processCounts())}`);
    });
    const run = Object.values(session.getSnapshot().runs).at(-1);
    const out = consoleText();
    if (run?.status !== "stopped" || out.includes("crashed") || out.includes("Traceback")) throw new Error(`${run?.status}: ${out.slice(-1500)}`);
    return { idleMs, stopMs: Math.round(performance.now() - t0) };
  });

  await step("processes_packages_and_console", async () => {
    // A PyPI package (PEP 723) comes along to the children; in the console
    // (no file to re-import) a function from a module in the folder works.
    await fs.writeText("Tests/procs_helper.py", "def double(x):\n    return 2 * x\n");
    await fs.writeText("Tests/procs_pypi.py", "");
    const { done } = await runFile(
      "Tests/procs_pypi.py",
      [
        "# /// script",
        "# dependencies = ['humanize']",
        "# ///",
        "import multiprocessing as mp",
        "",
        "def words(n):",
        "    import humanize",
        "    return humanize.intword(n)",
        "",
        "if __name__ == '__main__':",
        "    with mp.Pool(2) as pool:",
        "        print('pypi', pool.map(words, [1_200_000, 3_000_000_000]))",
        "",
      ].join("\n"),
    );
    await done;
    if (!consoleText().includes("pypi ['1.2 million', '3.0 billion']")) throw new Error(consoleText().slice(-1500));
    await session.runConsole("import multiprocessing as mp, procs_helper\nwith mp.Pool(2) as p: print('console', p.map(procs_helper.double, [1, 2, 3]))");
    await until(() => consoleText().includes("console [2, 4, 6]") || /Error/.test(consoleText().slice(-400)), 60000);
    if (!consoleText().includes("console [2, 4, 6]")) throw new Error(consoleText().slice(-1500));
  });

  await step("processes_example", async () => {
    const { done } = await runFile("Examples/Processes.py");
    await done;
    const out = consoleText();
    for (const want of ["watered bed 3", "primes below 300,000", "x as fast", "The subprocess said: Hello from Python 3.14"]) {
      if (!out.includes(want)) throw new Error(`missing ${want}: ${out.slice(-1500)}`);
    }
    return { speed: out.match(/One process:.*/)?.[0], times: out.match(/That is .*/)?.[0] };
  });

  // -- turtle graphics (D29) ----------------------------------------------------------

  const lastScene = () => [...turtleScenes.values()].at(-1);
  /** The native turtle view: the color at turtle coordinates (x, y), and taps there. */
  const turtlePixel = (x: number, y: number) => call<number[]>("test.turtle", { action: "pixel", key: lastScene()!.key, x, y });
  const turtleTap = (x: number, y: number) => call("test.turtle", { action: "tap", key: lastScene()!.key, x, y });
  const turtleKey = (key: string) => call("test.turtle", { action: "key", key: lastScene()!.key, name: key });

  await step("turtle_draw_and_events", async () => {
    await fs.mkdir("Tests").catch(() => {});
    await fs.writeText("Tests/turtle_check.py", [
      "import turtle",
      "t = turtle.Turtle()",
      "t.speed(0)",
      "t.color('red', 'yellow')",
      "t.begin_fill()",
      "for _ in range(4):",
      "    t.forward(100)",
      "    t.left(90)",
      "t.end_fill()",
      "t.write('hi', font=('Arial', 16, 'bold'))",
      "screen = turtle.Screen()",
      "screen.onclick(lambda x, y: print(f'click {round(x)} {round(y)}'))",
      "def up():",
      "    print('key Up')",
      "    screen.bye()",
      "screen.onkey(up, 'Up')",
      "screen.listen()",
      "print('ready')",
      "turtle.done()",
      "print('after done')",
    ].join("\n"));
    const { done } = await runFile("Tests/turtle_check.py");
    await until(() => consoleText().includes("ready"));
    await until(() => lastScene()?.listening.keys);
    await sleep(300); // the host has the ops
    const inside = await turtlePixel(50, 50);
    const outside = await turtlePixel(-150, -150);
    if (!(inside[0] > 200 && inside[1] > 200 && inside[2] < 80)) throw new Error(`not yellow inside the square: ${inside}`);
    if (!outside.every((c) => c > 240)) throw new Error(`not white outside: ${outside}`);
    await turtleTap(-120, 80);
    await until(() => consoleText().includes("click -120 80"), 5000);
    await turtleKey("Up");
    await until(() => consoleText().includes("after done"), 5000);
    await done;
    await until(idle);
    const run = Object.values(session.getSnapshot().runs).at(-1);
    if (run?.status !== "ok") throw new Error(`${run?.status}: ${consoleText()}`);
    return { items: lastScene()!.items.size, inside, outside };
  });

  await step("turtle_timer_keeps_running_and_stop", async () => {
    // Handlers without done(): the program keeps running, as in IDLE.
    await fs.writeText("Tests/turtle_timer.py", "import turtle\nn = 0\ndef tick():\n    global n\n    n += 1\n    print('tick', n)\n    turtle.ontimer(tick, 50)\ntick()\n");
    await runFile("Tests/turtle_timer.py");
    await until(() => consoleText().includes("tick 4"));
    if (idle()) throw new Error("the program ended");
    session.stop();
    await until(idle);
    const run = Object.values(session.getSnapshot().runs).at(-1);
    if (run?.status !== "stopped" || consoleText().includes("Traceback")) throw new Error(`${run?.status}: ${consoleText()}`);
  });

  await step("turtle_example", async () => {
    const t0 = performance.now();
    await runFile("Examples/Turtle.py");
    await until(idle, 60000);
    const run = Object.values(session.getSnapshot().runs).at(-1);
    if (run?.status !== "ok") throw new Error(`${run?.status}: ${consoleText()}`);
    const scene = lastScene()!;
    if (scene.items.size < 10) throw new Error(`${scene.items.size} items`);
    return { ms: Math.round(performance.now() - t0), items: scene.items.size };
  });

  await step("turtle_catch_example", async () => {
    await runFile("Examples/Catch the Turtle.py");
    const scene = await until(() => lastScene()?.listening.pointer && lastScene());
    const score = () => [...scene.items.values()].filter((i) => i.type === "text").map((i) => i.o.text).join();
    await until(() => score().includes("Score: 0"));
    // Tap the middle of the turtle's shape (it hops every 1.3 s; try again if it moved away).
    for (let i = 0; i < 5 && !score().includes("Score: 1"); i++) {
      const shell = [...scene.items.values()].find((it) => it.type === "polygon" && it.o.fill === "#006400")!;
      const xs = shell.xy.filter((_, j) => j % 2 === 0), ys = shell.xy.filter((_, j) => j % 2 === 1);
      await turtleTap(xs.reduce((a, b) => a + b) / xs.length, -ys.reduce((a, b) => a + b) / ys.length);
      await sleep(400);
    }
    if (!score().includes("Score: 1")) throw new Error(`score: ${score()}`);
    session.stop();
    await until(idle);
    return { score: score() };
  });

  await step("ui_app", async () => {
    await runFile("Examples/Counter App.py");
    await until(() => session.getSnapshot().uiOpen);
    const plus = await untilNode((n) => n.t === "Button" && n.p.label === "+1");
    for (let i = 0; i < 5; i++) {
      await nativeEvent(plus.i, "click");
      await sleep(30);
    }
    await untilNode((n) => n.t === "Text" && n.p.font === "largeTitle" && n.p.text === "5");
    const { ops, ms } = await nativeRenderStats();
    if (!(await nativeTree()).closeButton) throw new Error("no close button");
    // Restart (the close button's menu): a new run, the view stays up, the count starts over.
    const counter = session.getSnapshot().runCounter;
    await call("test.ui", { action: "restart" });
    let hidden = false;
    await until(async () => {
      const t = await nativeTree();
      if (!t.visible) hidden = true;
      return session.getSnapshot().runCounter > counter && session.getSnapshot().uiOpen && !t.restarting &&
        findNodes(t.tree, (n) => n.t === "Text" && n.p.font === "largeTitle" && n.p.text === "0").length > 0;
    }, 30000);
    if (hidden) throw new Error("the app view went away while restarting");
    await call("test.ui", { action: "close" });
    await until(() => !session.getSnapshot().uiOpen);
    return { lastRender: { ops, ms } };
  });

  await step("ui_close_from_python", async () => {
    // close_button=False: no close button; the program ends itself with ui.close().
    await fs.writeText(
      "Tests/Close.py",
      'import ui\n\nui.run(lambda: ui.Screen("Quit", ui.Button("Quit", on_click=ui.close)), close_button=False)\n',
    );
    await runFile("Tests/Close.py");
    const quit = await untilNode((n) => n.t === "Button" && n.p.label === "Quit");
    if ((await nativeTree()).closeButton) throw new Error("close button shown");
    await nativeEvent(quit.i, "click");
    await until(() => !session.getSnapshot().uiOpen);
    await until(async () => !(await nativeTree()).visible);
    if (consoleText().includes("Traceback")) throw new Error(consoleText());
  });

  await step("ui_todo", async () => {
    // The full example: navigation, a text field, and saving into SQLite
    // while the app keeps running (the worker flushes files when idle).
    for (const f of ["todos.db", "todos.db-journal", "todos.json"]) if (await fs.exists(`Examples/${f}`)) await fs.remove(`Examples/${f}`);
    await runFile("Examples/Todo App.py");
    const inboxRow = (n: NativeNode) => n.t === "Row" && n.p.title === "Inbox";
    await nativeEvent((await untilNode(inboxRow)).i, "click");
    const stack = () => nativeTree().then((t) => findNodes(t.tree, (n) => n.t === "NavigationStack")[0]);
    const top = async () => (await stack())?.c?.at(-1);
    await until(async () => (await stack())?.c?.length === 2 && (await top())?.p.title === "Inbox");
    const field = findNodes((await top())!, (n) => n.t === "TextField" && n.p.placeholder === "New To-Do")[0];
    await nativeEvent(field.i, "change", ["Selftest to-do"]);
    await nativeEvent(field.i, "submit", ["Selftest to-do"]);
    await until(async () => findNodes((await top())!, (n) => n.t === "Row" && n.p.title === "Selftest to-do").length > 0);
    await nativeEvent((await top())!.i, "back");
    await untilNode((n) => inboxRow(n) && String(n.p.detail) === "2");
    // SQLite stores short text as is, so the title shows up in the file's bytes.
    const saved = async () =>
      (await fs.exists("Examples/todos.db")) &&
      new TextDecoder("latin1").decode(base64ToBytes(await fs.readBase64("Examples/todos.db"))).includes("Selftest to-do");
    // On disk while the app is still open: 0.5 s of quiet, then the next flush.
    const t0 = performance.now();
    for (let i = 0; i < 40 && !(await saved()); i++) await sleep(100);
    if (!(await saved())) throw new Error("todos.db not written back while the app runs");
    const savedMs = Math.round(performance.now() - t0);
    if (!session.getSnapshot().uiOpen) throw new Error("the app closed");
    await call("test.ui", { action: "close" });
    await until(() => !session.getSnapshot().uiOpen);
    await sleep(300);
    if (await fs.exists("Examples/todos.db-journal")) throw new Error("a journal was left behind");
    // A second run reads the database back.
    await runFile("Examples/Todo App.py");
    await untilNode((n) => inboxRow(n) && String(n.p.detail) === "2");
    await call("test.ui", { action: "close" });
    await until(() => !session.getSnapshot().uiOpen);
    await sleep(300);
    await fs.remove("Examples/todos.db");
    return { savedMs };
  });

  await step("ui_navigation", async () => {
    // Native navigation, dialogs and sheets (D30), driven through the host's renderer.
    const slow = location.hash.includes("slow") ? 2500 : 0;
    await fs.writeText("Tests/Navigation.py", navigationExample);
    await runFile("Tests/Navigation.py");
    const ada = await untilNode((n) => n.t === "Row" && n.p.title === "Ada Lovelace");
    await sleep(slow);
    await nativeEvent(ada.i, "click");
    const stack = () => nativeTree().then((t) => findNodes(t.tree, (n) => n.t === "NavigationStack")[0]);
    const top = async () => (await stack())?.c?.at(-1);
    await until(async () => (await stack())?.c?.length === 2 && (await top())?.p.title === "Ada Lovelace");
    await sleep(slow);
    const rename = findNodes((await top())!, (n) => n.t === "Button" && n.p.label === "Rename…")[0];
    await nativeEvent(rename.i, "click");
    await until(async () => (await nativeTree()).dialogs?.[0]?.kind === "prompt");
    await sleep(slow);
    await call("test.ui", { action: "dialog", value: "Ada L." });
    await until(async () => (await top())?.p.title === "Ada L.");
    await nativeEvent((await top())!.i, "back");
    await until(async () => (await stack())?.c?.length === 1);
    const add = await untilNode((n) => n.t === "Button" && n.p.a11y === "Add");
    await nativeEvent(add.i, "click");
    await until(async () => (await nativeTree()).sheets?.length === 1);
    const sheet = await untilNode((n) => n.t === "Sheet" && n.p.open === true);
    const [name] = findNodes(sheet, (n) => n.t === "TextField");
    await nativeEvent(name.i, "change", ["Margaret Hamilton"]);
    await sleep(slow);
    const save = findNodes(sheet, (n) => n.t === "Button" && n.p.label === "Save")[0];
    await until(async () => findNodes((await nativeTree()).tree, (n) => n.i === save.i && !n.p.disabled).length > 0);
    await nativeEvent(save.i, "click");
    await until(async () => (await nativeTree()).sheets?.length === 0);
    await untilNode((n) => n.t === "Row" && n.p.title === "Margaret Hamilton");
    await sleep(slow);
    await call("test.ui", { action: "close" });
    await until(() => !session.getSnapshot().uiOpen);
  });

  await step("linked_folder", async () => {
    // A folder outside Documents, linked like one picked from iCloud Drive
    // (the picker itself cannot be driven from here): browse, edit, run, write back.
    const loc = await call<{ name: string; path: string }>("test.link", { name: "Selftest Cloud" });
    const dir = `${loc.path}/app`;
    try {
      const listed = await locations.list();
      if (!listed.some((l) => l.path === loc.path && l.available)) throw new Error(`not listed: ${JSON.stringify(listed)}`);
      if ((await fs.list("")).some((e) => e.path === loc.path)) throw new Error("linked folder listed in Documents");
      await fs.writeText(`${dir}/helper.py`, "NAME = 'linked'\n");
      await fs.writeText(`${dir}/main.py`, "");
      await runFile(`${dir}/main.py`, "import os\nfrom helper import NAME\nopen('out.txt', 'w').write(NAME)\nos.makedirs('data', exist_ok=True)\nopen('data/x.txt', 'w').write('x')\nos.remove('helper.py')\nprint('hello from', NAME)\n");
      await until(idle);
      if (!consoleText().includes("hello from linked")) throw new Error(consoleText());
      for (let i = 0; i < 30 && !(await fs.exists(`${dir}/out.txt`)); i++) await sleep(100);
      const out = await fs.readText(`${dir}/out.txt`);
      if (out !== "linked") throw new Error(`out.txt: ${out}`);
      // It ran on a local copy (D35); new folders and deletions went back too.
      if ((await fs.readText(`${dir}/data/x.txt`)) !== "x") throw new Error("data/x.txt not synced back");
      if (await fs.exists(`${dir}/helper.py`)) throw new Error("helper.py not deleted in the linked folder");
      if (!(await fs.list(loc.path)).some((e) => e.name === "app" && e.dir)) throw new Error("app folder not listed");
      let refused = false;
      await fs.remove(loc.path).catch(() => (refused = true));
      if (!refused) throw new Error("deleting a linked folder's root was allowed");
      await fs.remove(dir);
    } finally {
      await locations.remove(loc.path);
    }
    if (await fs.exists(`${dir}/main.py`)) throw new Error("still reachable after removing the location");
    if ((await locations.list()).some((l) => l.path === loc.path)) throw new Error("still listed");
  });

  await step("processes_linked_folder", async () => {
    // Child processes share the root's copy of a linked folder (D35, D47):
    // they read what it wrote, and what they write goes back too.
    const loc = await call<{ name: string; path: string }>("test.link", { name: "Selftest Procs" });
    const dir = `${loc.path}/app`;
    try {
      await fs.writeText(`${dir}/main.py`, "");
      await runFile(
        `${dir}/main.py`,
        [
          "import multiprocessing as mp",
          "",
          "def child():",
          "    text = open('from_parent.txt').read()",
          "    open('from_child.txt', 'w').write(text.upper())",
          "",
          "if __name__ == '__main__':",
          "    open('from_parent.txt', 'w').write('shared')",
          "    p = mp.Process(target=child)",
          "    p.start(); p.join()",
          "    print('child said', open('from_child.txt').read(), p.exitcode)",
          "",
        ].join("\n"),
      );
      await until(idle, 60000);
      if (!consoleText().includes("child said SHARED 0")) throw new Error(consoleText().slice(-1500));
      for (let i = 0; i < 30 && !(await fs.exists(`${dir}/from_child.txt`)); i++) await sleep(100);
      if ((await fs.readText(`${dir}/from_child.txt`)) !== "SHARED") throw new Error("from_child.txt not synced back");
      await fs.remove(dir);
    } finally {
      await locations.remove(loc.path);
    }
  });

  await step("crash_recovery", async () => {
    // Recursion through C code runs out of the worker's native stack (D16):
    // the run crashes and shows where, as a RecursionError (D49).
    await fs.writeText("Tests/deep.py", "x = []\nfor _ in range(50000): x = [x]\nprint(len(repr(x)))\n");
    await runFile("Tests/deep.py");
    await until(idle);
    let trace = await until(() => lastTrace(), 5000).catch(() => undefined);
    let exc = trace?.exceptions[0];
    if (!exc || exc.type !== "RecursionError" || exc.frames.at(-1)?.line !== 3 || exc.frames.at(-1)?.context?.lines[0] !== "print(len(repr(x)))") {
      throw new Error(`repr: ${JSON.stringify(trace) ?? consoleText()}`);
    }
    if (Object.values(session.getSnapshot().runs).at(-1)?.status !== "crashed") throw new Error("not crashed");
    // Recursion through a C-implemented decorator: the repeated frame is folded.
    await fs.writeText("Tests/deep_cached.py", "import functools\n\n@functools.lru_cache(None)\ndef f(n):\n    return f(n - 1) + 1 if n else 0\n\nprint(f(5000))\n");
    await runFile("Tests/deep_cached.py");
    await until(idle);
    trace = await until(() => lastTrace()?.exceptions[0].frames.some((f) => f.name === "f") && lastTrace(), 5000).catch(() => undefined);
    exc = trace?.exceptions[0];
    const f = exc?.frames.find((x) => x.name === "f");
    if (!f || f.line !== 5 || !(f.repeat! > 10) || !trace!.text.includes("Previous line repeated")) throw new Error(`lru_cache: ${JSON.stringify(trace) ?? consoleText()}`);
    await fs.writeText("Tests/alive.py", "print('alive again')\n");
    await runFile("Tests/alive.py");
    await until(idle);
    if (!consoleText().includes("alive again")) throw new Error(consoleText());
    return { repeat: f.repeat };
  });

  await step("memory_budget", async () => {
    // The heaps of all Python workers share a budget (D50): past it, a
    // program gets MemoryError instead of iOS ending the page's process.
    const { memoryUse, setMemoryBudget } = await import("./python");
    const before = memoryUse();
    if (!before.budget) throw new Error("no budget from the host");
    setMemoryBudget(before.used + (300 << 20));
    try {
      await fs.writeText("Tests/memory.py", [
        "chunks = []",
        "try:",
        "    while True:",
        "        chunks.append(bytearray(16 << 20))",
        "except MemoryError:",
        "    print('stopped at', len(chunks) * 16, 'MB')",
        "chunks.clear()",
        "x = bytearray(64 << 20)",
        "print('still works')",
        "bytearray(1 << 30)",
        "",
      ].join("\n"));
      const { done } = await runFile("Tests/memory.py");
      await done;
      const out = consoleText();
      const stopped = Number(/stopped at (\d+) MB/.exec(out)?.[1]);
      if (!(stopped > 64 && stopped <= 300) || !out.includes("still works")) throw new Error(out.slice(-600));
      if (lastTrace()?.exceptions.at(-1)?.type !== "MemoryError" || !out.includes("Python programs can use about")) throw new Error(out.slice(-600));
      const used = memoryUse().used;
      if (used > before.used + (300 << 20)) throw new Error(`used ${Math.round(used / 2 ** 20)} MB`);
      return { stoppedMB: stopped, budgetMB: Math.round(before.budget / 2 ** 20), usedMB: Math.round(used / 2 ** 20) };
    } finally {
      setMemoryBudget(before.budget);
    }
  });

  // Only when asked for (only=memory_full), for a device: a program fills the
  // real budget, writing every page, and must get MemoryError before iOS ends
  // the page's process (D50). If iOS ends it, the result says webContentTerminated.
  if (only && /memory_full/.test(only)) {
    await step("memory_full", async () => {
      const { memoryUse, setMemoryBudget } = await import("./python");
      // &budget=<MB> tries another budget than the host's.
      const mb = Number(new URLSearchParams(location.hash.slice(1)).get("budget"));
      if (mb) setMemoryBudget(mb * 2 ** 20);
      const before = memoryUse();
      await fs.writeText("Tests/memory_full.py", [
        "import time",
        "chunks = []",
        "try:",
        "    while True:",
        "        b = bytearray(16 << 20)",
        "        b[::4096] = b'\\x01' * (len(b) // 4096)",
        "        chunks.append(b)",
        "except MemoryError:",
        "    print('stopped at', len(chunks) * 16, 'MB')",
        "time.sleep(3)",
        "print('survived')",
        "",
      ].join("\n"));
      const { done } = await runFile("Tests/memory_full.py");
      await done;
      const out = consoleText();
      if (!out.includes("survived")) throw new Error(out.slice(-600));
      return { stoppedMB: Number(/stopped at (\d+) MB/.exec(out)?.[1]), budgetMB: Math.round(before.budget / 2 ** 20), usedBeforeMB: Math.round(before.used / 2 ** 20) };
    });
  }

  // -- code intelligence and dependencies -------------------------------------------

  const diagnostics = () => editorCall<{ source: string; message: string; actions: string[] }[]>("diagnostics");
  const editorText = () => editorCall<string>("text");

  async function openWith(path: string, code: string) {
    await fs.writeText(path, code);
    await app.openFile(path);
    await until(async () => (await app.currentFile()) === path && (await app.editorPath()) === path);
    if ((await editorText()) !== code) await editorCall("setText", code);
  }

  await step("analysis_ready", async () => {
    const info = await analysis.init();
    return { ruff: info.ruff, ruffInitMs: Math.round(info.ruffMs), tyInitMs: Math.round(info.tyMs) };
  });

  await step("lint_and_types", async () => {
    await openWith("Tests/lint.py", 'import os\n\n\ndef add(a: int, b: int) -> int:\n    return a + b\n\n\nadd(1, "two")\nprint(undefined_name)\n');
    const t0 = performance.now();
    const ds = await until(async () => { const d = await diagnostics(); return d.length >= 3 && d; }, 20000);
    const sources = ds.map((d) => d.source.replace(" ", ":"));
    for (const w of ["ruff:F401", "ty:invalid-argument-type", "ty:unresolved-reference"]) if (!sources.includes(w)) throw new Error(`missing ${w}: ${sources}`);
    const f401Actions = ds.find((d) => d.source === "ruff F401")!.actions;
    return { firstCheckMs: Math.round(performance.now() - t0), sources, f401Actions };
  });

  await step("pyodide_imports_not_flagged", async () => {
    await openWith("Tests/np.py", "import numpy as np\nimport matplotlib.pyplot as plt\nprint(np.pi, plt)\n");
    await sleep(1500);
    const unresolved = (await diagnostics()).filter((d) => d.source.includes("unresolved-import"));
    if (unresolved.length) throw new Error(JSON.stringify(unresolved));
  });

  await step("completions", async () => {
    const t0 = performance.now();
    const items = await analysis.complete("Tests/c.py", "import math\nmath.sq", 2, 8);
    const names = items.map((i) => i.name);
    if (!names.includes("sqrt")) throw new Error(names.slice(0, 20).join(","));
    return { ms: Math.round(performance.now() - t0), first: names.slice(0, 5) };
  });

  await step("format", async () => {
    await openWith("Tests/fmt.py", "x=[1,2,\n3]\ndef f( a ):\n  return a\n");
    await app.format();
    const out = await editorText();
    if (out !== "x = [1, 2, 3]\n\n\ndef f(a):\n    return a\n") throw new Error(JSON.stringify(out));
  });

  await step("add_dependency_quickfix_and_run", async () => {
    await openWith("Tests/cow.py", 'import cowsay\n\ncowsay.cow("moo from PyPI")\n');
    const d = await until(async () => (await diagnostics()).find((x) => x.source.includes("unresolved-import")), 20000);
    if (!(await editorCall("applyFixNamed", "cowsay"))) throw new Error("no quick fix");
    const text = await editorText();
    if (!text.startsWith('# /// script\n# dependencies = [\n#     "cowsay",\n# ]\n# ///')) throw new Error(text);
    session.clear();
    const t0 = performance.now();
    await app.run();
    await until(idle, 60000);
    const out = consoleText();
    if (!out.includes("moo from PyPI")) throw new Error(out);
    return { action: d.actions, installRunMs: Math.round(performance.now() - t0), status: out.split("\n").filter((l) => l.startsWith("Install")) };
  });

  await step("dependencies_cached_rerun", async () => {
    session.clear();
    const t0 = performance.now();
    await app.run();
    await until(idle, 60000);
    if (!consoleText().includes("moo from PyPI")) throw new Error(consoleText());
    return { rerunMs: Math.round(performance.now() - t0) };
  });

  await step("requires_python", async () => {
    await openWith("Tests/old.py", '# /// script\n# requires-python = "<3.10"\n# ///\nprint("should not run")\n');
    session.clear();
    await app.run();
    await until(idle);
    const out = consoleText();
    if (!out.includes("requires Python <3.10") || out.includes("should not run")) throw new Error(out);
  });

  // -- Python versions and docs (D37) -----------------------------------------------

  const lastRun = () => Object.values(session.getSnapshot().runs).at(-1);

  await step("python_versions", async () => {
    await fs.mkdir("Tests/py").catch(() => {});
    await fs.remove("Tests/py/.python-version").catch(() => {});
    const code = "import sys\nprint('on', sys.version.split()[0])\n";
    await fs.writeText("Tests/py/v.py", code);
    let { done } = await runFile("Tests/py/v.py");
    await done;
    if (!consoleText().includes("on 3.14.2") || lastRun()?.python !== "3.14.2") throw new Error(`default: ${consoleText()} ${lastRun()?.python}`);
    // The folder pins 3.15, as the ⋯ menu writes it.
    await appCall("setFolderPython", "3.15");
    if ((await fs.readText("Tests/py/.python-version")).trim() !== "3.15") throw new Error("no .python-version");
    const native = await appCall("filePython");
    if (native.python !== "3.15" || native.pin !== "3.15") throw new Error(`native: ${JSON.stringify(native)}`);
    ({ done } = await runFile("Tests/py/v.py"));
    await done;
    if (!consoleText().includes("on 3.15.0rc1") || lastRun()?.python !== "3.15.0rc1") throw new Error(`pinned: ${consoleText()}`);
    // 3.15's packages come from its own CDN folder and cache.
    ({ done } = await runFile("Tests/py/v.py", "import numpy, sys\nprint('numpy', numpy.__version__, 'on', sys.version_info[:2])\n"));
    await done;
    if (!/numpy \S+ on \(3, 15\)/.test(consoleText())) throw new Error(`numpy on 3.15: ${consoleText()}`);
    await appCall("setFolderPython", null);
    if (await fs.exists("Tests/py/.python-version")) throw new Error(".python-version not removed");
    // requires-python picks a version: >=3.15 needs the preview, >=3.10 keeps the default.
    ({ done } = await runFile("Tests/py/v.py", '# /// script\n# requires-python = ">=3.15"\n# ///\n' + code));
    await done;
    if (!consoleText().includes("on 3.15.0rc1")) throw new Error(`requires >=3.15: ${consoleText()}`);
    ({ done } = await runFile("Tests/py/v.py", '# /// script\n# requires-python = ">=3.10"\n# ///\n' + code));
    await done;
    if (!consoleText().includes("on 3.14.2")) throw new Error(`requires >=3.10: ${consoleText()}`);
    // The default from Settings.
    await appCall("setDefaultPython", "3.15");
    await until(async () => (await appCall("filePython")).python === "3.15", 5000);
    ({ done } = await runFile("Tests/py/v.py", code));
    await done;
    const onDefault = consoleText();
    await appCall("setDefaultPython", "3.14");
    if (!onDefault.includes("on 3.15.0rc1")) throw new Error(`default 3.15: ${onDefault}`);
    await until(async () => (await appCall("filePython")).python === "3.14", 5000);
  });

  await step("docs_index", async () => {
    const search = (query: string, version = "3.14") => call<{ ref: string; title: string; link: string }[]>("docs.search", { query, version, limit: 8 });
    const loads = await search("json.loads");
    if (loads[0]?.ref !== "library/json.html#json.loads" || loads[0].link !== "docs:3.14/library/json.html#json.loads") throw new Error(JSON.stringify(loads.slice(0, 3)));
    const words = await search("template strings");
    if (!words.some((h) => h.ref.startsWith("library/string.templatelib.html"))) throw new Error(`words: ${JSON.stringify(words.map((h) => h.ref))}`);
    const page = await call<{ title: string; markdown: string } | null>("docs.read", { ref: "library/json.html#json.loads", version: "3.14" });
    if (!page?.markdown.includes("Deserialize") && !page?.markdown.includes("deserialize")) throw new Error(`read: ${page?.markdown.slice(0, 200)}`);
    const section = await call<{ markdown: string } | null>("docs.read", { ref: "library/json.html#basic-usage", version: "3.14" });
    if (!section?.markdown.includes("`json.dump(")) throw new Error(`section: ${section?.markdown.slice(0, 300)}`);
    const v315 = await search("json.loads", "3.15");
    if (v315[0]?.ref !== "library/json.html#json.loads") throw new Error(`3.15: ${JSON.stringify(v315.slice(0, 2))}`);
    return { results: words.length, sectionChars: section.markdown.length };
  });

  await step("docs_viewer", async () => {
    await appCall("showDocs", "3.14", "library/json.html#json.loads");
    let state = await until(async () => {
      const s = await appCall("docsState");
      return s.shown && s.ref === "library/json.html#json.loads" && /json/.test(s.title ?? "") ? s : null;
    }, 10000);
    const hits = await appCall<string[]>("docsSearch", "pathlib.Path.glob");
    if (hits[0] !== "library/pathlib.html#pathlib.Path.glob") throw new Error(`viewer search: ${JSON.stringify(hits)}`);
    // An agent's docs: link opens the viewer at the other version.
    await appCall("docsLink", "docs:3.15/library/os.html#os.listdir");
    state = await until(async () => {
      const s = await appCall("docsState");
      return s.version === "3.15" && s.ref === "library/os.html#os.listdir" ? s : null;
    }, 10000);
    await appCall("closeDocs");
    await until(async () => !(await appCall("docsState")).shown, 5000);
    return { title: state.title };
  });

  await step("help_opens_docs", async () => {
    await fs.writeText("Tests/py/h.py", "import json, pathlib\n");
    const { done } = await runFile("Tests/py/h.py");
    await done;
    const expectDocs = async (source: string, ref: string) => {
      await session.runConsole(source);
      await until(idle);
      await until(async () => (await appCall("docsState")).ref === ref, 8000).catch(async () => {
        throw new Error(`${source}: ${JSON.stringify(await appCall("docsState"))} ${consoleText().slice(-300)}`);
      });
    };
    await expectDocs("help(json.loads)", "library/json.html#json.loads");
    if (!consoleText().includes("Opened the Python 3.14 documentation")) throw new Error(consoleText());
    await expectDocs("help(pathlib.Path.glob)", "library/pathlib.html#pathlib.Path.glob");
    await expectDocs("help(str.split)", "builtins/stdtypes.html#str.split");
    await expectDocs("help('json')", "library/json.html#module-json");
    await appCall("closeDocs");
    // Not the standard library: pydoc's text, as before.
    await session.runConsole("class Mine:\n    'My own class.'\nhelp(Mine)");
    await until(idle);
    if (!consoleText().includes("My own class.") || (await appCall("docsState")).shown) throw new Error(`pydoc: ${consoleText().slice(-300)}`);
  });

  // -- Home Screen shortcuts and links (D38) ---------------------------------------

  await step("launch_shortcuts", async () => {
    await fs.mkdir("Tests/launch").catch(() => {});
    await fs.writeText("Tests/launch/hello.py", "print('launched', 6 * 7)\n");
    session.clear();
    if (!(await appCall("openURL", "terrarium://run?path=Tests/launch/hello.py"))) throw new Error("link not taken");
    await until(() => consoleText().includes("launched 42"), 20000);
    await until(idle);
    if ((await app.currentFile()) !== "Tests/launch/hello.py") throw new Error(`open: ${await app.currentFile()}`);
    // The Shortcuts action: a ui app opens full screen.
    await appCall("runIntent", "Examples/Counter App.py");
    await until(async () => (await nativeTree()).visible, 20000);
    if ((await app.currentFile()) !== "Examples/Counter App.py") throw new Error(`intent opened ${await app.currentFile()}`);
    // A second one while it runs: the first ends.
    session.clear();
    await appCall("runIntent", "Tests/launch/hello.py");
    await until(() => consoleText().includes("launched 42"), 20000);
    await until(async () => !(await nativeTree()).visible, 5000);
    const programs = await appCall<string[]>("programs");
    if (!programs.includes("Examples/Todo App.py") || !programs.includes("Tests/launch/hello.py")) throw new Error(`programs: ${programs.slice(0, 10)}`);
    await appCall("homeScreenSheet", "Examples/Todo App.py");
    await sleep(300);
    await appCall("closeSheet");
    return { programs: programs.length };
  });

  // -- device modules (D40) -----------------------------------------------------------

  const runOutput = async (path: string, code: string, answers: unknown[] = [], timeout = 60000) => {
    await fs.writeText(path, code);
    const { done } = await runFile(path);
    for (const answer of answers) {
      if (!(await appCall<boolean>("deviceAnswer", answer))) throw new Error(`no dialog to answer with ${JSON.stringify(answer)}: ${consoleText().slice(-400)}`);
    }
    await until(idle, timeout).catch(() => {
      throw new Error(`timed out: ${consoleText().slice(-600)}`);
    });
    await done.catch(() => {});
    return consoleText();
  };
  const expectLines = (out: string, lines: string[]) => {
    const missing = lines.filter((l) => !out.includes(l));
    if (missing.length) throw new Error(`missing ${JSON.stringify(missing)} in: ${out.slice(-900)}`);
  };

  await step("device_basics", async () => {
    await fs.mkdir("Tests/device").catch(() => {});
    const out = await runOutput("Tests/device/basics.py", [
      "import clipboard, keychain, haptics, motion, speech, sound, console, webbrowser",
      "clipboard.set('hello clip')",
      "print('clip', clipboard.get())",
      "keychain.set_password('svc', 'me', 'pw1')",
      "print('kc', keychain.get_password('svc', 'me'), ('svc', 'me') in keychain.get_services())",
      "keychain.delete_password('svc', 'me')",
      "print('kc2', keychain.get_password('svc', 'me'))",
      "haptics.impact('light'); haptics.notification('success'); haptics.selection()",
      "motion.start_updates(); print('motion', len(motion.get_attitude()), len(motion.get_magnetic_field())); motion.stop_updates()",
      "print('langs', len(speech.get_synthesis_languages()) > 0)",
      "speech.say('hi', 'en-US', 1.0); speech.stop()",
      "e = sound.play_effect('coin'); print('effect', e is not None); e.volume = 0.2; sound.stop_all_effects()",
      "for name in sound.EFFECTS: sound.play_effect(name, volume=0)",
      "console.set_color(1, 0, 0); print('red'); console.set_color()",
      "console.write_link('site', 'https://example.com'); print()",
      "print('browser', type(webbrowser.get()).__name__)",
    ].join("\n"));
    expectLines(out, ["clip hello clip", "kc pw1 True", "kc2 None", "motion 3 4", "langs True", "effect True", "red", "browser AppBrowser"]);
    if (!out.includes("\u001b[38;2;255;0;0m") || !out.includes("\u001b]8;;https://example.com")) throw new Error(`escapes: ${JSON.stringify(out.slice(-300))}`);
  });

  await step("device_dialogs", async () => {
    await fs.writeText("Tests/device/notes.txt", "some notes\n");
    const out = await runOutput("Tests/device/dialog_test.py", [
      "import console, dialogs",
      "print('alert', console.alert('T', 'm', 'A', 'B'))",
      "print('input', console.input_alert('Name'))",
      "print('login', console.login_alert('Log in'))",
      "print('list', dialogs.list_dialog('L', ['x', 'y', 'z']))",
      "print('multi', dialogs.list_dialog('M', ['x', 'y', 'z'], multiple=True))",
      "print('form', dialogs.form_dialog('F', [{'type': 'text', 'key': 'n', 'title': 'N'}, {'type': 'switch', 'key': 's', 'title': 'S'}, {'type': 'date', 'key': 'd', 'title': 'D'}]))",
      "print('date', dialogs.date_dialog('D'))",
      "print('duration', dialogs.duration_dialog('T'))",
      "print('text', dialogs.text_dialog('Edit', 'abc'))",
      "print('edit', dialogs.edit_list_dialog('E', ['a', 'b', 'c']))",
      "print('cancel', dialogs.list_dialog('L2', ['a']))",
      "console.quicklook('notes.txt')",
      "print('share', dialogs.share_text('hi'))",
      "try:",
      "    console.alert('X')",
      "except KeyboardInterrupt:",
      "    print('interrupted')",
      "console.hud_alert('Done', duration=0.25)",
      "print('end')",
    ].join("\n"), [2, ["Ada"], ["me", "pw"], [1], [0, 2], { n: "Bob", s: true, d: "2026-01-02T00:00:00" }, "2026-03-04T00:00:00", 90, "abcdef", [2, 0], null, null, null, null]);
    expectLines(out, [
      "alert 2", "input Ada", "login ('me', 'pw')", "list y", "multi ['x', 'z']",
      "form {'n': 'Bob', 's': True, 'd': datetime.datetime(2026, 1, 2, 0, 0)}", "date 2026-03-04 00:00:00", "duration 90.0",
      "text abcdef", "edit ['c', 'a']", "cancel None", "share None", "interrupted", "end",
    ]);
  });

  await step("device_stop_closes_dialog", async () => {
    await fs.writeText("Tests/device/wait.py", "import console\nconsole.alert('Waiting')\n");
    const { done } = await runFile("Tests/device/wait.py");
    await until(() => appCall<boolean>("deviceHasDialog"), 15000);
    session.stop();
    await until(idle, 10000);
    await done.catch(() => {});
    await until(async () => !(await appCall<boolean>("deviceHasDialog")), 5000);
    const run = Object.values(session.getSnapshot().runs).at(-1);
    if (run?.status !== "stopped") throw new Error(`${run?.status}: ${consoleText().slice(-300)}`);
  });

  await step("device_pim", async () => {
    const out = await runOutput("Tests/device/pim.py", [
      "print('start', flush=True)",
      "import contacts, reminders, notification, location, photos, sys",
      "print('imported', contacts.is_authorized(), flush=True)",
      "p = contacts.Person(); p.first_name = 'Terrarium'; p.last_name = 'Selftest'; p.email = [(contacts.WORK, 't@example.com')]",
      "contacts.add_person(p); contacts.save(); print('saved contact', flush=True)",
      "found = contacts.find('Selftest')",
      "print('contact', [x.full_name for x in found], found[0].email)",
      "contacts.remove_person(found[0]); contacts.save()",
      "print('contact2', len(contacts.find('Selftest')))",
      "r = reminders.Reminder(); r.title = 'Terrarium selftest'; r.save()",
      "print('rem', any(x.title == 'Terrarium selftest' for x in reminders.get_reminders(completed=False)))",
      "print('del', reminders.delete_reminder(r))",
      // The self-test can't answer the notification permission prompt, so it isn't asked.
      "try:",
      "    nid = notification.schedule('later', delay=600, title='Selftest')",
      "    print('notif', nid in notification.get_scheduled())",
      "    notification.cancel(nid)",
      "except PermissionError:",
      "    print('notif', 'not allowed', notification.get_scheduled() == [])",
      "location.start_updates()",
      "loc = location.get_location()",
      // The simulator is at the Eiffel Tower (run.sh); a device is wherever it is.
      "print('loc', bool(loc) and -90 <= loc['latitude'] <= 90, location.is_authorized())",
      "location.stop_updates()",
      "assets = photos.get_assets()",
      "print('photos', len(assets) > 0)",
      "if assets: print('image', assets[-1].get_image().size == (assets[-1].pixel_width, assets[-1].pixel_height))",
    ].join("\n"), [], 90000);
    expectLines(out, ["contact ['Terrarium Selftest'] [('_$!<Work>!$_', 't@example.com')]", "contact2 0", "rem True", "del True", "notif", "loc True True", "photos True", "image True"]);
  });

  // -- file management (D41) -------------------------------------------------------

  await step("file_management", async () => {
    await fs.mkdir("Tests/files/sub").catch(() => {});
    await fs.writeText("Tests/files/a.py", "print('a')\n");
    await app.openFile("Tests/files/a.py");
    // Move: the open tab follows.
    const moved = await appCall<string | null>("movePath", "Tests/files/a.py", "Tests/files/sub");
    if (moved !== "Tests/files/sub/a.py" || !(await fs.exists(moved)) || (await fs.exists("Tests/files/a.py"))) throw new Error(`move: ${moved}`);
    if ((await app.currentFile()) !== moved) throw new Error(`tab after move: ${await app.currentFile()}`);
    // Favorites follow it around.
    let favorites = await appCall<string[]>("toggleFavorite", moved);
    if (!favorites.includes(moved)) throw new Error(`favorite: ${favorites}`);
    // Delete goes to the Trash, and comes back.
    await appCall("deletePath", moved);
    if (await fs.exists(moved)) throw new Error("not deleted");
    favorites = await appCall<string[]>("favorites");
    if (favorites.includes(moved)) throw new Error("favorite kept after delete");
    let trash = await appCall<string[][]>("trashList");
    const entry = trash.find(([, original]) => original === moved);
    if (!entry) throw new Error(`trash: ${JSON.stringify(trash)}`);
    await appCall("trashRestore", entry[0]);
    if ((await fs.readText(moved)) !== "print('a')\n") throw new Error("not restored");
    // Restoring next to a file with the same name keeps both.
    await appCall("deletePath", moved);
    await fs.writeText(moved, "new\n");
    trash = await appCall<string[][]>("trashList");
    await appCall("trashRestore", trash.find(([, o]) => o === moved)![0]);
    if (!(await fs.exists("Tests/files/sub/a 2.py"))) throw new Error(`restore beside: ${JSON.stringify((await fs.list("Tests/files/sub")).map((e) => e.name))}`);
    // Delete for good from the Trash.
    await appCall("deletePath", "Tests/files/sub/a 2.py");
    trash = await appCall<string[][]>("trashList");
    await appCall("trashRemove", trash.find(([, o]) => o === "Tests/files/sub/a 2.py")![0]);
    if ((await appCall<string[][]>("trashList")).some(([, o]) => o === "Tests/files/sub/a 2.py")) throw new Error("still in the trash");
    // Templates.
    const created = await appCall<string>("newFromTemplate", "Tests/files", "hello", "script");
    if (created !== "Tests/files/hello.py" || !(await fs.readText(created)).includes("input(")) throw new Error(`template: ${created}`);
    const notes = await appCall<string>("newFromTemplate", "Tests/files", "notes", "markdown");
    if (notes !== "Tests/files/notes.md") throw new Error(`markdown template: ${notes}`);
    // Quick Look for files the editor doesn't show.
    await fs.writeBase64("Tests/files/dot.png", "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=");
    const shown = await appCall<string>("quickLook", "Tests/files/dot.png");
    if (!shown.includes("QLPreviewController")) throw new Error(`quick look: ${shown}`);
  });

  await step("device_modules_typed", async () => {
    // ty knows the device modules: no unresolved imports, and their signatures.
    const code = "import clipboard\nimport dialogs\nimport photos\n\nclipboard.set(1, 2)\nprint(dialogs.list_dialog('t', ['a']))\n";
    const problems = await analysis.check("Tests/device/typed.py", code);
    if (problems.some((p) => p.code === "unresolved-import")) throw new Error(JSON.stringify(problems));
    if (!problems.some((p) => p.source === "ty" && /argument/i.test(p.message))) throw new Error(`no argument error: ${JSON.stringify(problems)}`);
  });

  // The app's own modules in the docs (D42), and the example apps that use them.
  await step("app_docs", async () => {
    const hits = await call<{ ref: string }[]>("docs.search", { query: "photos.pick_image", version: "3.14", limit: 5 });
    if (hits[0]?.ref !== "terrarium/photos.html#photos.pick_image") throw new Error(JSON.stringify(hits));
    const ui = await call<{ ref: string }[]>("docs.search", { query: "ui.Button", version: "3.15", limit: 5 });
    if (ui[0]?.ref !== "terrarium/ui.html#ui.Button") throw new Error(`3.15: ${JSON.stringify(ui)}`);
    const page = await call<{ markdown: string } | null>("docs.read", { ref: "terrarium/sound.html#sound.Player", version: "3.14" });
    if (!page?.markdown.includes("play()") || !page.markdown.includes("finished_handler")) throw new Error(`read: ${page?.markdown.slice(0, 300)}`);
    const words = await call<{ ref: string }[]>("docs.search", { query: "record from the microphone", version: "3.14", limit: 8 });
    if (!words.some((h) => h.ref.startsWith("terrarium/sound.html"))) throw new Error(`words: ${JSON.stringify(words.map((h) => h.ref))}`);
    // help() opens the app's modules too.
    await fs.mkdir("Tests/device").catch(() => {});
    await fs.writeText("Tests/device/helpme.py", "import clipboard, sound\n");
    const { done } = await runFile("Tests/device/helpme.py");
    await done;
    await session.runConsole("help(clipboard.get)");
    await until(idle);
    await until(async () => (await appCall("docsState")).ref === "terrarium/clipboard.html#clipboard.get", 8000);
    await session.runConsole("help(sound.Player)");
    await until(idle);
    await until(async () => (await appCall("docsState")).ref === "terrarium/sound.html#sound.Player", 8000);
    await appCall("closeDocs");
    // Show Info on a device module links its page.
    const text = "import clipboard\nclipboard.set('x')\n";
    await openWith("Tests/device/info.py", text);
    const target = await appCall("docsTarget", "Tests/device/info.py", text, 2, 12);
    if (target?.ref !== "terrarium/clipboard.html#clipboard.set") throw new Error(`show info: ${JSON.stringify(target)}`);
  });

  await step("device_example_apps", async () => {
    const opened: Record<string, number> = {};
    for (const name of ["Photo Booth.py", "Level.py", "Birthdays.py"]) {
      const { done } = await runFile(`Examples/${name}`);
      const tree = await until(async () => {
        const t = await nativeTree();
        return t.visible ? t : null;
      }, 30000).catch(() => {
        throw new Error(`${name} did not open: ${consoleText().slice(-500)}`);
      });
      opened[name] = findNodes(tree.tree, () => true).length;
      if (/Traceback/.test(consoleText())) throw new Error(`${name}: ${consoleText().slice(-500)}`);
      session.closeUI();
      await until(async () => !(await nativeTree()).visible, 5000).catch(() => {
        throw new Error(`${name} did not close`);
      });
      await done.catch(() => {});
    }
    return opened;
  });

  // -- the examples ---------------------------------------------------------------------

  const NEW_EXAMPLES = [
    "Async Data.py", "Async.py", "Bounce.py", "Brick Breaker.py", "Clipboard Tools.py", "Debug Me.py", "Draw a Digit.py",
    "Drum Machine.py", "Game of Life.py", "Journal.py", "Mandelbrot.py", "Navigation.py", "Paint.py", "Piano.py",
    "Pomodoro.py", "Settings.py", "Tabs.py", "Turtle Fractals.py", "Voice Memos.py", "Weather.py",
    "Adventure/world.py",
  ];

  /** Run an example app and wait for it to show; the text of its tree. */
  async function openApp(name: string, timeout = 60000) {
    const { done } = await runFile(`Examples/${name}`);
    await until(async () => (await nativeTree()).visible, timeout).catch(() => {
      throw new Error(`${name} did not open: ${consoleText().slice(-500)}`);
    });
    return { done };
  }
  async function closeApp(name: string, done: Promise<unknown>) {
    if (/Traceback|Error/.test(consoleText())) throw new Error(`${name}: ${consoleText().slice(-800)}`);
    session.closeUI();
    await until(async () => !(await nativeTree()).visible, 5000).catch(() => {
      throw new Error(`${name} did not close`);
    });
    await done.catch(() => {});
  }
  const texts = async () => findNodes((await nativeTree()).tree, (n) => n.t === "Text" || n.t === "Label").map((n) => String(n.p.text ?? ""));
  const untilText = (pred: (s: string) => boolean, timeout = 15000) =>
    until(async () => (await texts()).find(pred), timeout).catch(async () => {
      throw new Error(`no such text in ${JSON.stringify(await texts()).slice(0, 600)}; console: ${consoleText().slice(-400)}`);
    });
  const canvases = async () => findNodes((await nativeTree()).tree, (n) => n.t === "Canvas");
  const pointer = (id: number, event: string, x: number, y: number, touch = 1) =>
    nativeEvent(id, event, [{ x, y, id: touch, buttons: event === "pointer_up" ? 0 : 1 }]);

  await step("examples_lint_clean", async () => {
    // What the editor shows for each new example: nothing (Types.py on purpose has five).
    const found: Record<string, string[]> = {};
    for (const name of NEW_EXAMPLES) {
      const path = `Examples/${name}`;
      let problems;
      try {
        problems = await analysis.check(path, await fs.readText(path));
      } catch (e) {
        found[name] = [String(e)];
        continue;
      }
      const real = problems.filter((p) => p.code !== "unresolved-import");
      if (real.length) found[name] = real.map((p) => `${p.start.line}: ${p.source} ${p.code} ${p.message}`);
    }
    if (Object.keys(found).length) throw new Error(JSON.stringify(found));
    const types = (await analysis.check("Examples/Types.py", await fs.readText("Examples/Types.py"))).map((p) => p.code).sort();
    const want = ["B006", "F401", "invalid-argument-type", "invalid-argument-type", "invalid-return-type"];
    if (JSON.stringify(types) !== JSON.stringify(want)) found["Types.py"] = types;
    if (Object.keys(found).length) throw new Error(JSON.stringify(found));
  });

  await step("examples_games", async () => {
    const result: Record<string, unknown> = {};
    // Brick Breaker: a tap launches the ball, and the game loop runs.
    let { done } = await openApp("Brick Breaker.py");
    let [canvas] = await canvases();
    await pointer(canvas.i, "pointer_down", 180, 500);
    await pointer(canvas.i, "pointer_up", 180, 500);
    await sleep(1500);
    await closeApp("Brick Breaker", done);
    // Game of Life: Play advances the generations.
    ({ done } = await openApp("Game of Life.py"));
    const play = await untilNode((n) => n.t === "Button" && n.p.label === "Play");
    await nativeEvent(play.i, "click");
    result.life = await untilText((s) => /^Generation ([3-9]|\d\d)/.test(s));
    [canvas] = await canvases();
    await pointer(canvas.i, "pointer_down", 5, 5);
    await closeApp("Game of Life", done);
    // Mandelbrot: a picture, a zoom, and the same on all cores.
    ({ done } = await openApp("Mandelbrot.py"));
    result.mandelbrot = await untilText((s) => s.includes("s on 1 process"), 60000);
    [canvas] = await canvases();
    await pointer(canvas.i, "pointer_down", 120, 180);
    result.zoomed = await untilText((s) => s.startsWith("4x zoom"), 60000);
    const cores = await untilNode((n) => n.t === "Toggle" && n.p.label === "Use all cores");
    await nativeEvent(cores.i, "change", [true]);
    result.parallel = await untilText((s) => s.startsWith("4x zoom") && s.includes("processes"), 90000);
    await closeApp("Mandelbrot", done);
    // Draw a Digit: a vertical stroke is a 1.
    ({ done } = await openApp("Draw a Digit.py"));
    await untilText((s) => s.startsWith("Ready."), 90000);
    [canvas] = await canvases();
    await pointer(canvas.i, "pointer_down", 140, 40);
    for (let y = 60; y <= 240; y += 20) await pointer(canvas.i, "pointer_move", 140, y);
    await pointer(canvas.i, "pointer_up", 140, 240);
    await untilText((s) => s.endsWith("votes"), 15000);
    const guess = (await texts()).find((s) => /^\d$/.test(s));
    if (guess !== "1") throw new Error(`guessed ${guess}: ${JSON.stringify(await texts())}`);
    result.digit = guess;
    await closeApp("Draw a Digit", done);
    // Piano: a key plays its note.
    ({ done } = await openApp("Piano.py"));
    [canvas] = await canvases();
    await pointer(canvas.i, "pointer_down", 10, 200);
    result.piano = await untilText((s) => s.startsWith("C4"));
    await pointer(canvas.i, "pointer_up", 10, 200);
    await closeApp("Piano", done);
    // Drum Machine: it plays.
    ({ done } = await openApp("Drum Machine.py"));
    const drums = await untilNode((n) => n.t === "Button" && n.p.label === "Play");
    await nativeEvent(drums.i, "click");
    await untilNode((n) => n.t === "Button" && n.p.label === "Stop");
    await sleep(1000);
    await closeApp("Drum Machine", done);
    // The canvas examples from uikit.
    for (const name of ["Bounce.py", "Paint.py"]) {
      ({ done } = await openApp(name));
      [canvas] = await canvases();
      await pointer(canvas.i, "pointer_down", 100, 100);
      await pointer(canvas.i, "pointer_move", 150, 150);
      await pointer(canvas.i, "pointer_up", 150, 150);
      await sleep(500);
      await closeApp(name, done);
    }
    return result;
  });

  await step("examples_apps", async () => {
    const result: Record<string, unknown> = {};
    // Weather: the simulator's location, then a search.
    let { done } = await openApp("Weather.py");
    result.weather = await untilText((s) => s.startsWith("Feels like"), 60000);
    await closeApp("Weather", done);
    // Journal: the first entry, a new one, the database file.
    for (const f of ["journal.db", "journal.db-journal"]) if (await fs.exists(`Examples/${f}`)) await fs.remove(`Examples/${f}`);
    ({ done } = await openApp("Journal.py"));
    await untilNode((n) => n.t === "Row" && String(n.p.title).startsWith("Started a journal"));
    result.journal = await untilText((s) => s.endsWith("day streak"));
    await closeApp("Journal", done);
    if (!(await fs.exists("Examples/journal.db"))) throw new Error("no journal.db");
    await fs.remove("Examples/journal.db");
    // Pomodoro: start and pause.
    ({ done } = await openApp("Pomodoro.py"));
    const start = await untilNode((n) => n.t === "Button" && n.p.label === "Start");
    await nativeEvent(start.i, "click");
    const pause = await untilNode((n) => n.t === "Button" && n.p.label === "Pause");
    await sleep(1200);
    await nativeEvent(pause.i, "click");
    await untilNode((n) => n.t === "Button" && n.p.label === "Start");
    await closeApp("Pomodoro", done);
    if (await fs.exists("Examples/pomodoro.json")) await fs.remove("Examples/pomodoro.json");
    // The rest open and close.
    for (const name of ["Voice Memos.py", "Navigation.py", "Tabs.py", "Settings.py", "Async Data.py"]) {
      ({ done } = await openApp(name));
      await sleep(800);
      await closeApp(name, done);
    }
    if (await fs.exists("Examples/Recordings")) await fs.remove("Examples/Recordings");
    return result;
  });

  await step("examples_console", async () => {
    const result: Record<string, unknown> = {};
    // asyncio with httpx.
    let { done } = await runFile("Examples/Async.py");
    await done;
    expectLines(consoleText(), ["One after another:", "All at once:", "As they arrive:", "within 10 ms"]);
    result.async = consoleText().match(/All at once:.*/)?.[0];
    // Debug Me: fails on its second check.
    ({ done } = await runFile("Examples/Debug Me.py"));
    await done;
    expectLines(consoleText(), ["find(13) = 5 \u2713", "find(7) = -1 \u2717 (should be 3)", "AssertionError"]);
    // Types: two of its mistakes bite.
    ({ done } = await runFile("Examples/Types.py"));
    await done;
    expectLines(consoleText(), ["Average rating: 4.35", "['classic: Dune', 'cyberpunk: Neuromancer']", "TypeError"]);
    // Clipboard Tools: sort the lines on the clipboard.
    await fs.mkdir("Tests").catch(() => {});
    await fs.mkdir("Tests/device").catch(() => {});
    await runOutput("Tests/device/clip.py", "import clipboard\nclipboard.set('pear\\nApple\\nfig')\n");
    ({ done } = await runFile("Examples/Clipboard Tools.py"));
    if (!(await until(() => appCall<boolean>("deviceHasDialog"), 15000).then(() => appCall<boolean>("deviceAnswer", [4])))) throw new Error(`no dialog: ${consoleText()}`);
    await until(idle, 30000);
    expectLines(consoleText(), ["Sort lines:\nApple\nfig\npear"]);
    // Adventure: imports a sibling module and reads JSON; the walkthrough wins.
    ({ done } = await runFile("Examples/Adventure/Adventure.py"));
    for (const command of ["e", "take can", "w", "s", "take net", "n", "w", "use net", "use can", "e", "n", "use can"]) {
      await until(() => session.getSnapshot().awaitingInput, 15000).catch(() => {
        throw new Error(`no prompt for ${command}: ${consoleText().slice(-500)}`);
      });
      session.submitInput(command);
      await sleep(50);
    }
    await done;
    expectLines(consoleText(), ["GLASSHOUSE", "You saved the moon orchid in 10 moves"]);
    // Turtle Fractals: draws, and keeps running for taps until Stop.
    const scenes = turtleScenes.size;
    await runFile("Examples/Turtle Fractals.py");
    await until(() => turtleScenes.size > scenes && (lastScene()?.items.size ?? 0) > 100, 60000);
    await until(() => lastScene()?.listening.pointer, 60000); // waiting for taps
    if (idle()) throw new Error(`ended: ${consoleText().slice(-400)}`);
    session.stop();
    await until(idle, 10000);
    if (/Traceback/.test(consoleText())) throw new Error(consoleText().slice(-600));
    result.fractal = lastScene()?.items.size;
    return result;
  });

  await step("examples_start_here", async () => {
    const path = "Examples/Start Here.md";
    await app.openFile(path);
    await until(async () => (await editorCall<any>("markdownInfo"))?.path === path, 10000);
    await editorCall("previewFollow", "Brick%20Breaker.py");
    await until(async () => (await app.currentFile()) === "Examples/Brick Breaker.py", 5000);
    await app.openFile(path);
    await until(async () => (await editorCall<any>("markdownInfo"))?.path === path, 10000);
    await editorCall("previewFollow", "Adventure/README.md");
    await until(async () => (await app.currentFile()) === "Examples/Adventure/README.md", 5000);
    // Every link to a file points at an example that is there.
    const text = await fs.readText(path);
    const missing = [];
    for (const [, target] of text.matchAll(/\]\(([^):]+)\)/g)) {
      if (!(await fs.exists(`Examples/${decodeURIComponent(target)}`))) missing.push(target);
    }
    if (missing.length) throw new Error(`missing: ${missing}`);
  });

  await step("editor_themes", async () => {
    await app.openFile("Examples/Hello.py");
    const themes = await editorCall<{ id: string }[]>("themes");
    if (themes[0]?.id !== "terrarium" || themes.length < 4) throw new Error(`themes: ${JSON.stringify(themes.map((t) => t.id))}`);
    let state = await editorCall<{ theme: string; bg: string; dark: boolean }>("themeState");
    if (state.theme !== "terrarium") throw new Error(`default: ${JSON.stringify(state)}`);
    await appCall("setTheme", "solarized");
    await appCall("setAppearance", "dark");
    state = await until(async () => {
      const s = await editorCall<{ theme: string; bg: string; dark: boolean }>("themeState");
      return s.theme === "solarized" && s.dark ? s : null;
    }, 5000);
    if (state.bg !== "#002b36") throw new Error(`solarized dark: ${JSON.stringify(state)}`);
    await appCall("setAppearance", "light");
    state = await until(async () => {
      const s = await editorCall<{ theme: string; bg: string; dark: boolean }>("themeState");
      return !s.dark ? s : null;
    }, 5000);
    if (state.bg !== "#fdf6e3") throw new Error(`solarized light: ${JSON.stringify(state)}`);
    await appCall("setAppearance", "system");
    await appCall("setTheme", "terrarium");
    return { themes: themes.length };
  });

  await step("show_info_docs", async () => {
    const text = "import json\nimport pathlib\njson.loads('1')\npathlib.Path('.').glob('*')\n";
    await openWith("Tests/py/info.py", text);
    const loads = await appCall("docsTarget", "Tests/py/info.py", text, 3, 8);
    if (loads?.ref !== "library/json.html#json.loads") throw new Error(`json.loads: ${JSON.stringify(loads)}`);
    const glob = await appCall("docsTarget", "Tests/py/info.py", text, 4, 20);
    if (glob?.ref !== "library/pathlib.html#pathlib.Path.glob") throw new Error(`glob: ${JSON.stringify(glob)}`);
    const module = await appCall("docsTarget", "Tests/py/info.py", text, 1, 9);
    if (module?.ref !== "library/json.html#module-json") throw new Error(`module: ${JSON.stringify(module)}`);
  });

  // -- debugger (D23) --------------------------------------------------------------

  await fs.mkdir("Tests").catch(() => {});
  const stopped = (prev = -1) => () => {
    const d = session.getSnapshot().debug;
    return d && d.stopId !== prev ? d : null;
  };

  await step("debugger_breakpoint_step_inspect", async () => {
    const code = "def greet(name):\n    message = f'Hello {name}'\n    return message\n\n\nfor who in ['Ada', 'Guido']:\n    print(greet(who))\n";
    await fs.writeText("Tests/debug.py", code);
    breakpoints.set("Tests/debug.py", [{ line: 3, enabled: true }]);
    const t0 = performance.now();
    await runFile("Tests/debug.py");
    let d = await until(stopped());
    const stopMs = Math.round(performance.now() - t0);
    const where = `${d.frames[0].name}:${d.frames[0].line}/${d.frames[1]?.name}:${d.frames[1]?.line}`;
    if (where !== "greet:3/<module>:7") throw new Error(`stopped at ${where}`);
    const message = d.scopes[0].variables.find((v) => v.name === "message")?.value;
    if (message !== "'Hello Ada'") throw new Error(`message = ${message}`);
    const evaluated = await session.debugEvaluate("name.upper()");
    if (evaluated.value?.value !== "'ADA'") throw new Error(JSON.stringify(evaluated));
    await session.debugConsole("message = 'Hi Ada'"); // the program sees the change
    session.resume("next");
    d = await until(stopped(d.stopId));
    if (d.frames[0].name !== "<module>") throw new Error(`next went to ${d.frames[0].name}:${d.frames[0].line}`);
    breakpoints.clear("Tests/debug.py"); // sent to the paused program
    session.resume("continue");
    await until(idle);
    const out = consoleText();
    if (!out.includes("Hi Ada") || !out.includes("Hello Guido")) throw new Error(out);
    return { stopMs };
  });

  await step("debugger_pause_and_stop", async () => {
    await fs.writeText("Tests/loop.py", "import time\nn = 0\nwhile True:\n    n += 1\n    if n % 1000 == 0:\n        time.sleep(0.05)\n");
    await runFile("Tests/loop.py");
    await until(() => session.getSnapshot().status === "running");
    await sleep(800);
    const t0 = performance.now();
    session.pause();
    const d = await until(stopped());
    const pauseMs = Math.round(performance.now() - t0);
    if (d.reason !== "pause" || d.frames[0].file !== "Tests/loop.py") throw new Error(JSON.stringify(d.frames));
    session.stop();
    await until(idle);
    const run = Object.values(session.getSnapshot().runs).at(-1);
    if (run?.status !== "stopped") throw new Error(`run ${run?.status}: ${consoleText()}`);
    return { pauseMs, line: d.frames[0].line };
  });

  await step("debugger_breakpoint_while_running", async () => {
    await fs.writeText("Tests/late.py", "import time\ntotal = 0\nfor i in range(400):\n    total += i\n    time.sleep(0.01)\nprint('total', total)\n");
    await runFile("Tests/late.py");
    await until(() => session.getSnapshot().status === "running");
    await sleep(500);
    breakpoints.set("Tests/late.py", [{ line: 4, enabled: true }]);
    const d = await until(stopped(), 5000);
    breakpoints.clear("Tests/late.py");
    session.resume("continue");
    await until(idle);
    if (!consoleText().includes("total 79800")) throw new Error(consoleText());
    return { line: d.frames[0].line, i: d.scopes[0].variables.find((v) => v.name === "i")?.value };
  });

  await step("debugger_inspect_error", async () => {
    await fs.writeText("Tests/avg.py", "def average(xs):\n    total = sum(xs)\n    return total / len(xs)\n\nprint(average([]))\n");
    const { done } = await runFile("Tests/avg.py");
    await done;
    await until(idle);
    if (!session.canInspect) throw new Error("cannot inspect");
    void session.inspectError();
    const d = await until(stopped());
    if (!d.postMortem || !d.exception?.startsWith("ZeroDivisionError") || d.frames[0].name !== "average") throw new Error(JSON.stringify(d));
    const xs = d.scopes[0].variables.find((v) => v.name === "xs")?.value;
    session.resume("continue");
    await until(() => !session.getSnapshot().debug && idle() && session.canInspect);
    // "Inspect Here" on the traceback's outer frame (D45): the debugger starts there.
    const outer = lastTrace()?.exceptions.at(-1)?.frames.find((f) => f.name === "<module>");
    if (outer?.debug !== 1) throw new Error(JSON.stringify(lastTrace()));
    void session.inspectError(outer.debug);
    const here = await until(stopped());
    const selected = here.frames[here.selected];
    if (here.selected !== 1 || selected.name !== "<module>" || selected.line !== 5) throw new Error(JSON.stringify(here));
    session.resume("continue");
    await until(() => !session.getSnapshot().debug && idle());
    return { xs };
  });

  await step("breakpoint_builtin", async () => {
    await fs.writeText("Tests/bp.py", "x = 41\nbreakpoint()\nx += 1\nprint('x is', x)\n");
    await runFile("Tests/bp.py");
    const d = await until(stopped());
    if (d.reason !== "breakpoint()" || d.frames[0].line !== 2) throw new Error(JSON.stringify(d.frames));
    session.resume("continue");
    await until(idle);
    if (!consoleText().includes("x is 42")) throw new Error(consoleText());
  });

  // -- navigation: traceback links, go to definition, tabs, split view --------------

  const editorInfo = () => editorCall<{ path: string | null; readOnly: boolean; line: number; lineText: string }>("info");

  await step("traceback_link", async () => {
    await fs.mkdir("Tests").catch(() => {});
    await fs.mkdir("Tests/nav").catch(() => {});
    await fs.writeText("Tests/nav/helper.py", "def average(xs):\n    total = sum(xs)\n    return total / len(xs)\n");
    await fs.writeText("Tests/nav/main.py", "from helper import average\n\nprint(average([1, 2]))\nprint(average([]))\n");
    const { done } = await runFile("Tests/nav/main.py");
    await done;
    await until(idle);
    const links = await app.tapTraceback('File "helper.py", line 3');
    if (!links) throw new Error("no link");
    await until(async () => { const i = await editorInfo(); return i.path === "Tests/nav/helper.py" && i.line === 3; });
    // The same from the traceback as data (D45): the frame's place.
    await app.openFile("Tests/nav/main.py");
    const target = await app.tapTraceFrame("average");
    if (target !== "Tests/nav/helper.py") throw new Error(`frame opened ${target}`);
    await until(async () => { const i = await editorInfo(); return i.path === "Tests/nav/helper.py" && i.line === 3; });
    return { links };
  });

  await step("go_to_definition", async () => {
    await app.openFile("Tests/nav/main.py");
    await until(async () => (await app.editorPath()) === "Tests/nav/main.py");
    await editorCall("setCursor", 3, 1 + "print(".length + 2); // in "average"
    const t0 = performance.now();
    const asked = await app.goToDefinition();
    try {
      await until(async () => { const i = await editorInfo(); return i.path === "Tests/nav/helper.py" && i.line === 1; }, 5000);
    } catch {
      throw new Error(`went to ${JSON.stringify(await editorInfo())} (${JSON.stringify(asked)})`);
    }
    const projectMs = Math.round(performance.now() - t0);
    await app.openFile("Tests/nav/main.py");
    await until(async () => (await app.editorPath()) === "Tests/nav/main.py");
    await editorCall("setCursor", 3, 3); // print
    await app.goToDefinition();
    await until(async () => (await app.editorPath())?.endsWith("builtins.pyi"));
    const info = await editorInfo();
    if (!info.readOnly || !info.lineText.startsWith("def print(")) throw new Error(`not at def print: ${JSON.stringify(info)}`);
    await app.closeTab((await app.currentFile())!);
    return { projectMs };
  });

  await step("tabs", async () => {
    const pane = async () => {
      const [panes, current] = [await app.panes(), await app.currentFile()];
      return panes.find((p) => p.active === current) ?? panes[0];
    };
    const tabs = (await pane()).tabs;
    if (!tabs.includes("Tests/nav/main.py") || !tabs.includes("Tests/nav/helper.py")) throw new Error(JSON.stringify(tabs));
    if (tabs.some((t) => t.startsWith("ext:"))) throw new Error("closed tab still open");
    await app.closeTab("Tests/nav/helper.py");
    await until(async () => !(await pane()).tabs.includes("Tests/nav/helper.py"));
    return { open: (await pane()).tabs.length };
  });

  await step("split_view", async () => {
    if (!(await app.wide())) return { skipped: "iPhone" };
    await app.openFile("Tests/nav/main.py");
    await app.setSplit(true);
    await until(async () => (await app.panes()).length === 2);
    await app.openFile("Tests/nav/helper.py"); // opens in the focused (right) pane
    await until(async () => (await app.panes())[1]?.active === "Tests/nav/helper.py");
    await app.openLocation("Tests/nav/main.py");
    await app.setSplit(false);
    await until(async () => (await app.panes()).length === 1);
  });

  // Folding an iPhone Duo (or rotating, or iPad multitasking) goes from the
  // split view to the stack: the file on screen stays on screen (D58).
  await step("fold_handoff", async () => {
    const wasWide = await app.wide();
    try {
      await app.setWide(true);
      await app.openFile("Tests/nav/main.py");
      await app.setSplit(true);
      await until(async () => (await app.panes()).length === 2);
      await app.openFile("Tests/nav/helper.py"); // the right pane
      await until(async () => (await app.panes())[1]?.active === "Tests/nav/helper.py");
      await app.setWide(false); // folded
      await until(async () => (await app.currentFile()) === "Tests/nav/helper.py" && (await app.editorShown()));
      await until(async () => (await app.panes())[0]?.active === "Tests/nav/helper.py");
      await app.setWide(true); // open again: the split view is back
      await until(async () => (await app.panes()).length === 2);
    } finally {
      await app.setSplit(false);
      await app.setWide(wasWide);
    }
  });

  // The wide workspace's other half shows what the user picks (D59): the agent
  // and the docs open there instead of in sheets, a ui app runs there (or in
  // the main half) instead of over everything.
  await step("halves", async () => {
    if (!(await app.wide())) return { skipped: "iPhone" };
    const halves = () => appCall<any>("halves");
    const sidebar = (await halves()).sidebar;
    await fs.mkdir("Tests").catch(() => {});
    try {
      await appCall("setHalves", "editor", "agent", true);
      await appCall("openAgent", "Tests");
      await until(async () => (await halves()).agentInPanel);
      if ((await appCall<any>("agentState")).sheet) throw new Error("the agent opened a sheet too");

      // Only ever one agent: a sheet from the narrow layout (a folded iPhone
      // Duo) or with the half hidden goes when the half shows the agent.
      await appCall("setHalves", "editor", "agent", false);
      await appCall("openAgent", "Tests");
      await until(async () => (await appCall<any>("agentState")).sheet);
      await appCall("setDocked", true);
      await until(async () => !(await appCall<any>("agentState")).sheet && (await halves()).agentInPanel);
      await appCall("setWide", false); // folded: the agent button opens the sheet again
      await appCall("openAgent", "Tests");
      await until(async () => (await appCall<any>("agentState")).sheet);
      await appCall("setWide", true); // and unfolding closes it
      await until(async () => !(await appCall<any>("agentState")).sheet && (await halves()).agentInPanel);

      await appCall("setHalves", "editor", "docs", true);
      await appCall("showDocs", "3.14", "library/json.html#json.loads");
      await until(async () => { const d = await appCall<any>("docsState"); return d.inPanel && d.ref === "library/json.html#json.loads"; }, 8000);

      await appCall("setHalves", "editor", "app", true);
      await runFile("Examples/Counter App.py");
      await until(() => session.getSnapshot().uiOpen);
      await until(async () => (await nativeTree()).visible);
      let h = await halves();
      if (!h.appInHalf || h.overlay) throw new Error(`app not in the half: ${JSON.stringify(h)}`);
      const plus = await untilNode((n) => n.t === "Button" && n.p.label === "+1");
      await nativeEvent(plus.i, "click");
      await untilNode((n) => n.t === "Text" && n.p.font === "largeTitle" && n.p.text === "1");

      // Full screen and back (the half's header, the close button's menu).
      await appCall("setAppFullScreen", true);
      h = await halves();
      if (h.appInHalf || !h.overlay || !h.fullScreen) throw new Error(`full screen: ${JSON.stringify(h)}`);
      await appCall("setAppFullScreen", false);
      if (!(await halves()).appInHalf) throw new Error("not back in the half");

      await appCall("swapAppHalf"); // the app to the main half, the docs back in the other
      h = await halves();
      if (h.main !== "app" || h.panel !== "docs" || !h.appInHalf) throw new Error(`swap: ${JSON.stringify(h)}`);
      await appCall("setHalves", "app", "console", false); // the other half hidden: the app stays in the main half
      if (!(await halves()).appInHalf) throw new Error("hiding the other half moved the app");
      await call("test.ui", { action: "close" });
      await until(() => !session.getSnapshot().uiOpen);

      // An app that asks for the whole screen gets it, also with a half set to apps.
      await appCall("setHalves", "editor", "app", true);
      await fs.writeText("Tests/FullScreen.py", 'import ui\n\nui.run(lambda: ui.Screen("Big", ui.Text("big")), full_screen=True)\n');
      await runFile("Tests/FullScreen.py");
      await until(async () => { const s = await halves(); return s.overlay && s.fullScreen && !s.appInHalf; });
      await call("test.ui", { action: "close" });
      await until(() => !session.getSnapshot().uiOpen);

      // The other half first: left of the main half (or above); the files make room.
      await appCall("setHalves", "app", "docs", true, true);
      await until(async () => {
        const h = await halves();
        return h.first && !h.sidebar && h.panelSlot && h.mainSlot && h.panelSlot[0] <= h.mainSlot[0];
      });
    } finally {
      await appCall("setHalves", "editor", "console", true);
      await appCall("setSidebar", sidebar);
    }
  });

  // -- HTTP through the host's proxy (D25) -------------------------------------------

  await step("http", async () => {
    await fs.mkdir("Tests").catch(() => {});
    await fs.writeText("Tests/webcheck.py", [
      "import requests, urllib.request",
      "r = requests.get('https://httpbin.org/get', params={'q': 'x'}, headers={'User-Agent': 'terrarium-test/1'}, timeout=20)",
      "print('get', r.status_code, r.json()['args'], r.json()['headers']['User-Agent'])",
      "r = requests.post('https://httpbin.org/post', json={'a': 1}, timeout=20)",
      "print('post', r.status_code, r.json()['json'])",
      "print('urllib', urllib.request.urlopen('https://httpbin.org/status/201').status)",
      "import httpx",
      "print('httpx', httpx.get('https://httpbin.org/status/202').status_code)",
      "from pyodide.http import pyfetch",
      "print('pyfetch', (await pyfetch('https://httpbin.org/status/203')).status)",
      // A blocking XHR goes through the fetch relay (Q25), with what XHR does.
      "import js, time",
      "time.sleep(1)",
      "x = js.XMLHttpRequest.new()",
      "x.open('POST', 'https://httpbin.org/post?a=1', False)",
      "x.setRequestHeader('X-Test', 'yes')",
      "x.send('body text')",
      "d = __import__('json').loads(x.responseText)",
      "print('relayed', x.status, x.readyState, d['data'], d['headers']['X-Test'], d['args'], js._terrariumRelayedRequests > 1)",
      "try:",
      "    requests.get('https://does-not-exist.invalid/', timeout=5)",
      "except requests.ConnectionError:",
      "    print('connection error ok')",
      "",
    ].join("\n"));
    const t0 = performance.now();
    const { done } = await runFile("Tests/webcheck.py");
    await done;
    await until(idle, 60000);
    const out = consoleText();
    for (const want of ["get 200 {'q': 'x'} terrarium-test/1", "post 200 {'a': 1}", "urllib 201", "httpx 202", "pyfetch 203", "relayed 200 4 body text yes {'a': '1'} True", "connection error ok"]) {
      if (!out.includes(want)) throw new Error(out.slice(-600));
    }
    return { ms: Math.round(performance.now() - t0) };
  });

  // -- typing through iOS text input into the native console fields ------------------

  const typeNative = (text: string) => call<string>("test.type", { text });

  // -- notebooks (D44) ---------------------------------------------------------------

  const nbInfo = () => editorCall<any>("notebookInfo");
  const ipynb = (cells: { type?: "code" | "markdown"; source: string }[]) =>
    JSON.stringify({
      cells: cells.map((c, i) => ({
        cell_type: c.type ?? "code", id: `cell${i}`, metadata: {}, source: c.source,
        ...((c.type ?? "code") === "code" ? { outputs: [], execution_count: null } : {}),
      })),
      metadata: {}, nbformat: 4, nbformat_minor: 5,
    });
  async function openNotebook(path: string, cells: number) {
    await app.openFile(path);
    return until(async () => (await app.editorPath()) === path && (await nbInfo())?.cells?.length === cells && nbInfo(), 10000);
  }
  const cellDone = (index: number, timeout = 60000) =>
    until(async () => {
      const info = await nbInfo();
      const c = info?.cells?.[index];
      return c && c.status === "idle" && c.outputs.length && info.cells.every((x: any) => x.status === "idle") ? info : null;
    }, timeout);
  const expect = (cond: unknown, what: string, data: unknown) => {
    if (!cond) throw new Error(`${what}: ${JSON.stringify(data).slice(0, 1500)}`);
  };

  await step("notebook_run_all", async () => {
    await fs.mkdir("Tests").catch(() => {});
    await fs.mkdir("Tests/nb").catch(() => {});
    const path = "Tests/nb/test.ipynb";
    await fs.writeText(path, ipynb([
      { source: "x = 41\nx + 1" },
      { type: "markdown", source: "# Title\nSome *text*." },
      { source: "import sys\nprint('hi')\nprint('oops', file=sys.stderr)" },
      { source: "from IPython.display import HTML, display\ndisplay(HTML('<b>bold</b>'))\n%time sum(range(10))" },
      { source: "1/0" },
      { source: "x * 2" },
    ]));
    await openNotebook(path, 6);
    await editorCall("notebookCommand", "runAll");
    const info = await cellDone(4);
    const [c0, , c2, c3, c4, c5] = info.cells;
    expect(c0.count === 1 && c0.outputs[0]?.type === "execute_result" && c0.outputs[0].text === "42", "value", c0);
    expect(c2.outputs.some((o: any) => o.name === "stdout" && o.text === "hi\n") && c2.outputs.some((o: any) => o.name === "stderr" && o.text.includes("oops")), "streams", c2);
    expect(c3.outputs[0]?.mimes?.includes("text/html") && c3.outputs.some((o: any) => o.type === "stream" && o.text.includes("Wall time")) && c3.outputs.some((o: any) => o.type === "execute_result" && o.text === "45"), "display, %time", c3);
    expect(c4.outputs[0]?.type === "error" && c4.outputs[0].ename === "ZeroDivisionError", "error", c4);
    // The error as data, drawn with its source (D45); its frame's place is the cell.
    expect(c4.outputs[0].trace?.length === 1 && c4.outputs[0].trace[0] === `ZeroDivisionError: <cell ${c4.count}>:1`, "error as data", c4);
    const drawn = await until(async () => (await editorCall<any[]>("traceProbe")).find((t) => t.type === "ZeroDivisionError"), 5000);
    expect(drawn.message === "division by zero" && drawn.frames === 1 && drawn.open[0] === "module level" && drawn.span === "1/0" && drawn.links === 1, "drawn traceback", drawn);
    await editorCall("traceTap", 0);
    await until(async () => (await editorInfo()).lineText === "1/0", 3000).catch(async () => {
      throw new Error(`tap on the frame: ${JSON.stringify(await editorInfo())}`);
    });
    expect(c5.count === null && !c5.outputs.length, "Run All stops at an error", c5);
    expect(info.kernel === "idle" && /^3\./.test(info.python ?? ""), "kernel", info);
    // The outputs are in the file, as Jupyter writes them.
    const saved = await until(async () => {
      const nb = JSON.parse(await fs.readText(path));
      return nb.cells[4].outputs?.length ? nb : null;
    }, 5000);
    expect(saved.cells.map((c: any) => c.id).join() === "cell0,cell1,cell2,cell3,cell4,cell5", "ids kept", saved.cells);
    expect(saved.cells[0].outputs[0].data["text/plain"].join("") === "42" && saved.cells[0].execution_count === 1, "saved value", saved.cells[0]);
    expect(saved.cells[1].source.join("") === "# Title\nSome *text*." && saved.nbformat_minor === 5, "saved markdown", saved.cells[1]);
    // The kernel keeps its variables between cells...
    await editorCall("notebookRun", 5);
    const again = await cellDone(5);
    expect(again.cells[5].outputs[0]?.text === "82" && again.cells[5].count === 5, "kernel state", again.cells[5]);
    // ...until it restarts.
    session.restartKernel(path);
    await until(async () => (await nbInfo()).kernel === "dead", 5000);
    await editorCall("notebookRun", 5);
    const fresh = await until(async () => {
      const i = await nbInfo();
      return i.cells[5].outputs[0]?.type === "error" && i.cells[5].status === "idle" ? i : null;
    }, 30000);
    expect(fresh.cells[5].outputs[0].ename === "NameError" && fresh.cells[5].count === 1, "restarted", fresh.cells[5]);
  });

  await step("notebook_input_and_plot", async () => {
    const path = "Tests/nb/input.ipynb";
    await fs.writeText(path, ipynb([
      { source: "name = input('Name? ')\nprint('Hi', name)" },
      // IPython (our shim) first: matplotlib then talks to its shell.
      { source: "from IPython.display import display\nimport matplotlib.pyplot as plt\nplt.plot([1, 3, 2])\nplt.title('t');" },
    ]));
    await openNotebook(path, 2);
    await editorCall("notebookRun", 0);
    const title = await appCall<string | null>("notebookAnswer", "Ada");
    const info = await cellDone(0);
    expect(title === "Name?" && info.cells[0].outputs.map((o: any) => o.text).join("") === "Name? Ada\nHi Ada\n", "input()", { title, cell: info.cells[0] });
    await editorCall("notebookRun", 1);
    const plot = await cellDone(1, 90000);
    expect(plot.cells[1].outputs.some((o: any) => o.type === "display_data" && o.mimes.includes("image/png")), "figure", plot.cells[1]);
  });

  // HTML outputs with scripts run in a sandboxed frame, which can't reach the host (D44).
  await step("notebook_html_sandbox", async () => {
    const path = "Tests/nb/html.ipynb";
    const script = [
      "<div>probe</div><script>",
      "const report = (s) => parent.postMessage({ nbProbe: s }, '*');",
      "try { window.webkit.messageHandlers.bridge.postMessage({ op: 'echo', value: 'hi' }).then((v) => report('reached: ' + v), (e) => report('refused: ' + e.message)); }",
      "catch (e) { report('no bridge: ' + e.message); }",
      "try { report('parent: ' + parent.document.title); } catch (e) { report('no parent'); }",
      "</script>",
    ].join("\n");
    await fs.writeText(path, ipynb([{ source: `from IPython.display import HTML\nHTML(${JSON.stringify(script)})` }]));
    await openNotebook(path, 1);
    await editorCall("notebookRun", 0);
    await cellDone(0);
    const probes = await until(async () => {
      const p = await editorCall<string[]>("frameProbes");
      return p.length >= 2 ? p : null;
    }, 10000);
    expect(probes.includes("no parent") && probes.some((p) => p.startsWith("refused") || p.startsWith("no bridge")) && !probes.some((p) => p.startsWith("reached")), "sandbox", probes);
    return { probes };
  });

  await step("notebook_py_cells", async () => {
    const path = "Tests/nb/cells.py";
    await fs.writeText(path, "# %%\na = 2\n\n# %% [markdown]\n# Notes\n\n# %%\nprint(a * 21)\n");
    await openNotebook(path, 3);
    const pane = await until(() => appCall<any>("notebookPane"), 5000).catch(() => {
      throw new Error("the host doesn't know the notebook");
    });
    expect(pane.kind === "py" && pane.cells === 3, "the host knows", pane);
    await editorCall("notebookCommand", "runAll");
    const info = await cellDone(2);
    expect(info.kind === "py" && info.cells[1].type === "markdown" && info.cells[2].outputs[0]?.text === "42\n", "cells in a .py", info);
    // Run still runs the file as a script (and ends the kernel).
    session.clear();
    await app.run();
    await until(() => consoleText().includes("42"), 30000).catch(() => {
      throw new Error(`the script's output: ${consoleText().slice(-300)}`);
    });
    await until(idle);
    await until(async () => (await nbInfo()).kernel === "dead", 5000).catch(async () => {
      throw new Error(`kernel: ${JSON.stringify(await nbInfo()).slice(0, 300)}`);
    });
  });

  await step("notebook_edit_and_analysis", async () => {
    const path = "Tests/nb/edit.ipynb";
    await fs.writeText(path, ipynb([
      { source: "import os\n%matplotlib inline\nvalue = 1\nvalue" },
      { source: "import json\nimport asyncio\nawait asyncio.sleep(0)\njson.dumps(value)" },
    ]));
    await openNotebook(path, 2);
    // ruff and ty see the code cells: the unused import, not what fits a notebook.
    const diagnostics = await until(async () => {
      const d = await editorCall<{ source: string; message: string }[]>("diagnostics");
      return d.length ? d : null;
    }, 20000);
    const sources = diagnostics.map((d) => d.source);
    expect(sources.includes("ruff F401") && diagnostics.length === 1, "diagnostics", diagnostics);
    // Cells: add, move, delete; a marker line can't be deleted.
    await editorCall("setCursor", 2, 1);
    await editorCall("notebookCommand", "insertMarkdown");
    let info = await until(async () => ((await nbInfo()).cells.length === 3 ? nbInfo() : null), 3000);
    expect(info.cells[1].type === "markdown" && info.active === 1, "inserted", info);
    await editorCall("insert", "## Hello");
    await editorCall("notebookCommand", "moveDown");
    info = await nbInfo();
    expect(info.cells.map((c: any) => c.type).join() === "code,code,markdown" && info.cells[2].source === "## Hello" && info.active === 2, "moved", info);
    await editorCall("notebookCommand", "deleteCell");
    info = await nbInfo();
    expect(info.cells.length === 2 && info.cells.every((c: any) => c.type === "code"), "deleted", info);
    await editorCall("setCursor", 7, 1); // the start of the second cell
    const before = await editorCall<string>("text");
    const after = await editorCall<string>("backspace");
    expect(before === after, "Backspace at a cell's start", { before: before.slice(0, 300), after: after.slice(0, 300) });
    // Its JSON, and back.
    expect((await editorCall("setView", "source")).ok, "source view", null);
    const json = (await editorCall<{ text: string }>("info")).text;
    expect(JSON.parse(json).cells.length === 2 && (await appCall("notebookPane"))?.view === "source", "JSON", json.slice(0, 200));
    expect((await editorCall("setView", "notebook")).ok && (await nbInfo()).cells.length === 2, "notebook view", null);
    // The template.
    const created = await appCall<string>("newFromTemplate", "Tests/nb", "fresh", "notebook");
    const fresh = await openNotebook(created, 2);
    expect(created === "Tests/nb/fresh.ipynb" && fresh.cells[0].type === "markdown", "template", fresh);
  });

  await step("examples_notebook", async () => {
    // Earthquakes: live data, pandas and plots; Run All without an error.
    const path = "Examples/Earthquakes.ipynb";
    const before = await fs.readText(path);
    const info = await openNotebook(path, 11);
    await editorCall("notebookCommand", "runAll");
    const ran = await cellDone(9, 180000);
    const code = ran.cells.filter((c: any) => c.type === "code");
    const errors = code.flatMap((c: any) => c.outputs.filter((o: any) => o.type === "error"));
    if (errors.length || code.some((c: any) => !c.outputs.length)) throw new Error(JSON.stringify(code.map((c: any) => c.outputs.map((o: any) => o.type))));
    const b = ran.cells[9].outputs.find((o: any) => o.type === "stream")?.text;
    // Leave the example as it was shipped (without outputs).
    await appCall("closeTab", path).catch(() => {});
    await fs.writeText(path, before);
    return { cells: info.cells.length, b };
  });

  // -- Markdown files (D46) ------------------------------------------------------------

  const mdInfo = () => editorCall<any>("markdownInfo");
  const filler = (n: number) => Array.from({ length: n }, (_, i) => `Paragraph ${i + 1} of the filler.`).join("\n\n");

  await step("markdown_preview", async () => {
    await fs.mkdir("Tests/md/docs").catch(() => {});
    await fs.mkdir("Tests/md/img").catch(() => {});
    await fs.writeBase64("Tests/md/img/dot.png", "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=");
    await fs.writeText("Tests/md/code.py", "a = 1\nb = 2\nc = 3\n");
    await fs.writeText("Tests/md/docs/guide.md", `# Guide\n\n${filler(40)}\n\n## Second part\n\nHere.\n`);
    const text = [
      "# Project notes",
      "",
      "Some *text*: [the code](code.py#L3), [the guide](docs/guide.md#second-part), [below](#details-here), [json](docs:3.14/library/json.html#json.loads).",
      "",
      "![dot](img/dot.png)",
      "",
      "```python",
      "def hello():",
      "    return 42",
      "```",
      "",
      "| a | b |",
      "|---|--:|",
      "| 1 | 2 |",
      "",
      "- [x] done",
      "- [ ] open",
      "",
      "<script>window.__mdScript = 1</script>",
      "<img src=\"x\" onerror=\"window.__mdHandler = 1\">",
      "",
      filler(40),
      "",
      "## Details here",
      "",
      "The end.",
      "",
      filler(20),
      "",
    ].join("\n");
    const lines = text.split("\n");
    const details = lines.indexOf("## Details here") + 1;
    const path = "Tests/md/README.md";
    await fs.writeText(path, text);
    await app.openFile(path);
    await until(async () => (await app.editorPath()) === path);

    // A file with text opens as its preview, drawn safely.
    let info = await until(async () => {
      const i = await mdInfo();
      return i.path === path && i.blocks.length ? i : null;
    }, 10000);
    expect(info.view === "preview" && info.visible && info.editorHidden, "opens as a preview", info);
    expect((await appCall("markdownView")) === "preview", "the host knows", await appCall("markdownView"));
    expect(info.headings.join() === "project-notes,details-here", "heading anchors", info.headings);
    const dot = info.images.find((i: any) => i.path === "Tests/md/img/dot.png");
    expect(dot?.loaded && dot.src.startsWith("data:image/png"), "image next to the file", info.images);
    expect(info.highlighted > 2 && info.tables === 1 && info.tasks === 2, "code, table, tasks", info);
    expect(info.scripts === 0 && info.handlers === 0, "sanitized", info);
    expect(info.blocks.find((b: any) => b.tag === "h2")?.line === details, "source lines", info.blocks.slice(-4));

    // Go to: headings, and lines reveal in the preview.
    const outline = await editorCall<any>("outline");
    expect(outline.symbols.map((s: any) => `${s.kind}:${s.depth}:${s.name}`).join() === "h1:0:Project notes,h2:1:Details here", "outline", outline);
    await editorCall("reveal", details, 1);
    info = await until(async () => {
      const i = await mdInfo();
      return i.topLine === details ? i : null;
    }, 3000).catch(async () => {
      throw new Error(`reveal: ${JSON.stringify(await mdInfo()).slice(0, 300)}`);
    });
    await editorCall("reveal", 1, 1);
    await until(async () => (await mdInfo()).scrollTop === 0, 3000);
    await editorCall("previewFollow", "#details-here");
    await until(async () => (await mdInfo()).topLine === details, 3000).catch(async () => {
      throw new Error(`anchor: ${JSON.stringify(await mdInfo()).slice(0, 300)}`);
    });

    // The source starts where the preview was; edits show in the preview.
    await appCall("toggleMarkdown");
    info = await until(async () => {
      const i = await mdInfo();
      return i.view === "source" && !i.editorHidden && Math.abs(i.sourceTop - details) <= 2 ? i : null;
    }, 3000).catch(async () => {
      throw new Error(`source view: ${JSON.stringify(await mdInfo()).slice(0, 300)}`);
    });
    expect((await appCall("markdownView")) === "source", "the host knows the source", null);
    await editorCall("setText", `${text}\n## Added\n`);
    await appCall("toggleMarkdown");
    info = await until(async () => {
      const i = await mdInfo();
      return i.view === "preview" && i.headings.includes("added") ? i : null;
    }, 3000);
    await until(async () => (await fs.readText(path)).includes("## Added"), 3000);
    await editorCall("setText", `${text}\n## Live\n`);
    await until(async () => (await mdInfo()).headings.includes("live"), 3000);

    // Nothing to run; find works in the preview.
    session.clear();
    await app.run();
    await sleep(300);
    expect(idle() && !consoleText(), "Run does nothing", consoleText());
    const found = await appCall<boolean>("findInPreview");
    expect(found, "find bar", found);
    return { blocks: info.blocks.length, find: found };
  });

  await step("markdown_links", async () => {
    const path = "Tests/md/README.md";
    // Another file at a line.
    await app.openFile(path);
    await until(async () => (await mdInfo()).path === path);
    await editorCall("previewFollow", "code.py#L3");
    await until(async () => (await app.currentFile()) === "Tests/md/code.py" && (await editorCall<any>("info")).line === 3, 5000).catch(async () => {
      throw new Error(`code link: ${await app.currentFile()} ${JSON.stringify(await editorCall<any>("info")).slice(0, 200)}`);
    });
    // A Markdown file at a heading.
    await app.openFile(path);
    await until(async () => (await mdInfo()).path === path);
    await editorCall("previewFollow", "docs/guide.md#second-part");
    const guide = await until(async () => {
      if ((await app.currentFile()) !== "Tests/md/docs/guide.md") return null;
      const i = await mdInfo();
      return i.path === "Tests/md/docs/guide.md" && i.topLine > 40 ? i : null;
    }, 5000).catch(async () => {
      throw new Error(`guide link: ${await app.currentFile()} ${JSON.stringify(await mdInfo()).slice(0, 300)}`);
    });
    // Back up a folder, and the Python docs.
    await editorCall("previewFollow", "../README.md");
    await until(async () => (await app.currentFile()) === path, 5000);
    await editorCall("previewFollow", "docs:3.14/library/json.html#json.loads");
    const docs = await until(async () => {
      const s = await appCall<any>("docsState");
      return s.shown && s.ref ? s : null;
    }, 10000);
    await appCall("closeDocs");
    // Not there: the file stays.
    await editorCall("previewFollow", "missing.md");
    await sleep(300);
    expect((await app.currentFile()) === path, "missing link", await app.currentFile());
    // A new note opens to write in.
    const fresh = await appCall<string>("newFromTemplate", "Tests/md", "fresh", "markdown");
    await app.openFile(fresh);
    const info = await until(async () => {
      const i = await mdInfo();
      return i.view && (await app.editorPath()) === fresh ? i : null;
    }, 5000);
    expect(info.view === "source" && !info.editorHidden, "a new note", info);
    return { guideTop: guide.topLine, docs: docs.ref };
  });

  await step("typing_console", async () => {
    await fs.writeText("Tests/typing.py", "x = 1\n");
    const { done } = await runFile("Tests/typing.py");
    await done;
    await until(idle);
    await app.showPane("console");
    await app.focusField("console");
    await sleep(600);
    const responder = await typeNative("x + 41");
    await sleep(300);
    const value = await app.fieldValue("console");
    if (value !== "x + 41") throw new Error(`typed "x + 41", field has ${JSON.stringify(value)} (${responder})`);
    await app.submitField("console");
    await until(() => consoleText().includes("42"));
  });

  type KeyBar = { shown: boolean } | string;
  const keyBar = (keys: string[]) => call<KeyBar>("test.keybar", { keys });

  await step("keybar_console", async () => {
    // The code keys above the keyboard work in the native >>> field too.
    await app.showPane("console");
    await app.focusField("console");
    await sleep(600);
    try {
      await typeNative("len");
      const tapped = await keyBar(["("]);
      if (typeof tapped === "string") throw new Error(tapped);
      await typeNative("[1, 2");
      await keyBar(["]"]);
      await sleep(200);
      const value = await app.fieldValue("console");
      if (value !== "len([1, 2])") throw new Error(`field has ${JSON.stringify(value)}`);
      await app.submitField("console");
      await until(() => consoleText().includes("len([1, 2])2"));
      // Touch and hold: the alternate, and not the key's own text.
      await app.clearField("console");
      await app.focusField("console");
      await sleep(600);
      const held = await keyBar(["⇥"]);
      if (typeof held === "string") throw new Error(held);
      await typeNative("x");
      await keyBar(["hold:⇥"]); // dedent, not another indent
      await sleep(200);
      const holdValue = await app.fieldValue("console");
      if (holdValue !== "x") throw new Error(`after ⇥ x and holding ⇥: ${JSON.stringify(holdValue)}`);
      return { shown: tapped.shown };
    } finally {
      await app.clearField("console");
    }
  });

  await step("keybar_only_with_software_keyboard", async () => {
    // The bar shows only with the software keyboard: not with a hardware
    // keyboard, and not after the software keyboard's own hide key (iPad),
    // which keeps the field focused.
    await app.showPane("console");
    await app.focusField("console");
    await sleep(1000);
    const before = await keyBar([]);
    if (typeof before === "string") throw new Error(before);
    if (!before.shown) {
      await app.blurFields();
      return { hardwareKeyboard: true };
    }
    if (!(await app.wide())) {
      await app.blurFields();
      return { shown: true, skipped: "no hide key on iPhone" };
    }
    const hidden = await call<unknown>("test.hideKeyboard", {});
    if (hidden !== true) throw new Error(String(hidden));
    await sleep(1200);
    const after = await keyBar([]);
    await app.blurFields();
    if (typeof after === "string" || after.shown) throw new Error(`after hiding: ${JSON.stringify(after)}`);
    return { collapsedAfterHide: true };
  });

  await step("editor_keyboard_from_native", async () => {
    // Focus without a tap in the page (a native command, a problem in the
    // list): the keyboard comes up with the key bar and plain traits (D56).
    const path = "Examples/Hello.py";
    await app.openFile(path);
    await until(async () => (await app.currentFile()) === path && (await app.editorPath()) === path);
    await sleep(800);
    await editorCall("focus");
    try {
      const state = await until(async () => {
        const s = await call<{ firstResponder: boolean; bar?: boolean; traits?: string } | string>("test.editorKeyboard", {});
        return typeof s !== "string" && s.firstResponder ? s : null;
      }, 5000).catch(async () => { throw new Error(`no keyboard: ${JSON.stringify(await call("test.editorKeyboard", {}))}`); });
      // UITextAutocapitalizationType.none = 0, the others' .no = 1.
      if (state.bar === undefined) throw new Error(`no key bar on the content view: ${JSON.stringify(state)}`);
      if (state.traits !== undefined && state.traits !== "autocap=0 autocorrect=1 spell=1 quotes=1 dashes=1") throw new Error(`traits: ${state.traits}`);
      return state;
    } finally {
      await editorCall("blur");
      await app.blurFields();
      await sleep(600);
    }
  });

  await step("typing_plain_traits", async () => {
    await app.showPane("console");
    await app.focusField("console");
    await sleep(800);
    const notes = await typeNative("");
    // UITextAutocapitalizationType.none = 0, UITextAutocorrectionType.no = 1, UITextSmartQuotesType.no = 1
    if (!/autocap=0 autocorrect=1 quotes=1/.test(notes)) throw new Error(notes);
    await app.blurFields();
    return { notes };
  });

  await step("typing_input", async () => {
    await runFile("Examples/Hello.py");
    await until(() => session.getSnapshot().awaitingInput);
    await sleep(800);
    const responderInput = await typeNative("Armin");
    await sleep(300);
    const value = await app.fieldValue("input");
    if (value !== "Armin") throw new Error(`typed "Armin", field has ${JSON.stringify(value)} (${responderInput})`);
    await app.submitField("input");
    await until(idle);
    if (!consoleText().includes("Hello, Armin!")) throw new Error(consoleText());
  });

  await step("typing_debugger_console", async () => {
    await fs.writeText("Tests/typing2.py", "def f(a):\n    b = a * 2\n    return b\n\nprint(f(21))\n");
    breakpoints.set("Tests/typing2.py", [{ line: 3, enabled: true }]);
    await runFile("Tests/typing2.py");
    await until(stopped());
    await app.showPane("console");
    await app.focusField("console");
    await sleep(600);
    await typeNative("b + 1");
    await sleep(300);
    const value = await app.fieldValue("console");
    if (value !== "b + 1") throw new Error(`typed "b + 1", field has ${JSON.stringify(value)}`);
    await app.submitField("console");
    await until(() => consoleText().includes("43"));
    breakpoints.clear("Tests/typing2.py");
    session.resume("continue");
    await until(idle);
  });

  // The coding agent (D34) with a scripted model: every tool against a real
  // project folder, the edited file open in the editor, the native transcript.
  await step("agent", async () => {
    const { agent } = await import("./agent/service");
    const { fauxAssistantMessage, fauxText, fauxToolCall } = await import("@earendil-works/pi-ai/providers/faux");
    const dir = "Tests/agent";
    await fs.mkdir(dir);
    await fs.writeText(`${dir}/greet.py`, 'def greet(name):\n    return "Hello " + name\n\n\nif __name__ == "__main__":\n    print(greet("world"))\n');
    await fs.remove(`${dir}/out.txt`).catch(() => {});
    await fs.remove(`${dir}/data`).catch(() => {});
    await app.openFile(`${dir}/greet.py`);
    await appCall("openAgent", dir);
    await until(async () => (await agent.state()).project === dir, 30000);
    const faux = agent.useFaux();
    await agent.newConversation(dir);
    await agent.setModel("selftest", "faux-1");
    const tool = (name: string, args: Parameters<typeof fauxToolCall>[1], id: string) =>
      fauxAssistantMessage([fauxToolCall(name, args, { id })], { stopReason: "toolUse" });
    let firstPrompt = "";
    faux.setResponses([
      (context) => {
        const first = context.messages.find((m) => m.role === "user");
        firstPrompt = typeof first?.content === "string" ? first.content : JSON.stringify(first?.content);
        return tool("ls", {}, "ls");
      },
      tool("read", { path: "greet.py" }, "read"),
      tool("edit", { path: "greet.py", edits: [{ oldText: '"Hello " + name', newText: 'f"Hello, {name}!"' }] }, "edit"),
      tool("write", { path: "data/notes.py", content: "import os\nx=1\n" }, "write"),
      tool("run_python", { code: "from greet import greet\nopen('out.txt', 'w').write(greet('agent'))\nprint(greet('agent'))" }, "run"),
      tool("grep", { pattern: "Hello", glob: "*.py" }, "grep"),
      tool("find", { pattern: "*.txt" }, "find"),
      tool("check", { paths: ["data/notes.py"] }, "check"),
      tool("format", { paths: ["data/notes.py"] }, "format"),
      tool("read", { path: "../secret.txt" }, "outside"),
      fauxAssistantMessage([fauxText("Done: greet() now uses an f-string.")]),
    ]);
    await agent.submit("Make greet friendlier", await appCall("agentIDEState"));
    const state = await until(async () => {
      const s = await agent.state();
      return !s.busy && s.items.at(-1)?.text.startsWith("Done") ? s : null;
    }, 120000);
    const tools = Object.fromEntries(state.items.filter((i) => i.kind === "tool").map((i) => [i.id, i]));
    const expect = (cond: unknown, what: string) => {
      if (!cond) throw new Error(`${what}: ${JSON.stringify(state.items.map((i) => [i.id, i.status, (i.output ?? i.text).slice(0, 160)]))}`);
    };
    expect(Object.values(tools).every((t) => (t.id === "outside" ? t.status === "error" : t.status === "done")), "tool statuses");
    expect(tools.ls.output?.includes("greet.py"), "ls");
    expect(tools.write.output?.includes("F401"), "lint feedback after write");
    expect(tools.run.output?.includes("Hello, agent!"), "run_python output");
    expect(tools.grep.output?.includes("greet.py:2:"), "grep");
    expect(tools.find.output?.includes("out.txt"), "find sees run_python's file");
    expect(tools.check.output?.includes("F401"), "check");
    expect(tools.format.output?.includes("1 file reformatted") && tools.format.diff, "format");
    expect(tools.edit.diff, "edit diff");
    expect(firstPrompt.includes("<ide>") && firstPrompt.includes("Active file: greet.py") && firstPrompt.endsWith("Make greet friendlier"), `IDE context in the prompt (${firstPrompt.slice(0, 300)})`);
    const user = state.items.find((i) => i.kind === "user");
    expect(user?.text === "Make greet friendlier" && user.path === "greet.py", "the transcript shows the message and its file");
    const greet = await fs.readText(`${dir}/greet.py`);
    if (!greet.includes('f"Hello, {name}!"')) throw new Error(`greet.py: ${greet}`);
    const out = await fs.readText(`${dir}/out.txt`);
    if (out !== "Hello, agent!") throw new Error(`out.txt: ${out}`);
    const notes = await fs.readText(`${dir}/data/notes.py`);
    if (notes !== "import os\n\nx = 1\n") throw new Error(`notes.py: ${JSON.stringify(notes)}`);
    // The open editor shows the agent's edit.
    await until(async () => String(await editorCall("text")).includes('f"Hello, {name}!"'), 5000);
    // The native view has the same transcript.
    const native = await until(async () => {
      const s = await appCall("agentState");
      return s.items === state.items.length && !s.busy ? s : null;
    }, 5000);
    await appCall("closeSheet");
    return { items: state.items.length, tools: native.tools.length, model: native.model };
  });

  // The IDE tools (D36) in the same conversation: the context is not repeated
  // when it did not change, ide_* act on the editor, and the user moving to
  // another file mid-turn reaches the model at the next step.
  await step("agent-ide", async () => {
    const { agent } = await import("./agent/service");
    const { fauxAssistantMessage, fauxText, fauxToolCall } = await import("@earendil-works/pi-ai/providers/faux");
    const dir = "Tests/agent";
    const faux = agent.useFaux();
    await fs.writeText(`${dir}/messy.py`, "import os\nx=1\n");
    await app.openFile(`${dir}/greet.py`);
    await appCall("openAgent", dir);
    await until(async () => (await appCall("agentState")).sheet);
    const tool = (name: string, args: Parameters<typeof fauxToolCall>[1], id: string) =>
      fauxAssistantMessage([fauxToolCall(name, args, { id })], { stopReason: "toolUse" });
    const lastUser = (messages: any[]) => {
      const m = [...messages].reverse().find((x) => x.role === "user");
      return typeof m?.content === "string" ? m.content : JSON.stringify(m?.content ?? "");
    };
    let prompt = "";
    let afterMove = "";
    let detent = "";
    faux.setResponses([
      (context) => {
        prompt = lastUser(context.messages);
        return tool("ide_state", {}, "state");
      },
      tool("ide_open", { path: "messy.py", line: 1, end_line: 2 }, "open"),
      async () => {
        detent = await appCall("agentDetent");
        return tool("ide_lint", {}, "lint");
      },
      tool("ide_format", {}, "format"),
      async () => {
        // The user goes back to greet.py while the agent works.
        await app.openFile(`${dir}/greet.py`);
        await sleep(1500);
        return tool("ls", {}, "ls");
      },
      (context) => {
        afterMove = lastUser(context.messages);
        return tool("ide_close", { path: "messy.py" }, "close");
      },
      tool("ide_open", { path: "nope.py" }, "missing"),
      fauxAssistantMessage([fauxText("Done in the IDE.")]),
    ]);
    await agent.submit("Tidy messy.py", await appCall("agentIDEState"));
    const state = await until(async () => {
      const s = await agent.state();
      return !s.busy && s.items.at(-1)?.text.startsWith("Done in the IDE") ? s : null;
    }, 60000);
    const tools = Object.fromEntries(state.items.filter((i) => i.kind === "tool").map((i) => [i.id, i]));
    const expect = (cond: unknown, what: string) => {
      if (!cond) throw new Error(`${what}: ${JSON.stringify(state.items.slice(-12).map((i) => [i.id, i.kind, i.status, (i.output ?? i.text).slice(0, 160)]))}`);
    };
    expect(!prompt.includes("<ide>") && prompt === "Tidy messy.py", `no IDE context when nothing changed (${prompt.slice(0, 200)})`);
    expect(tools.state.ide && tools.state.output?.includes("Active file: greet.py"), "ide_state");
    expect(tools.open.output?.startsWith("Opened messy.py at lines 1-2"), "ide_open");
    expect((await app.wide()) || detent === "medium", `the sheet makes room on iPhone (${detent})`);
    expect(tools.lint.output?.includes("F401"), "ide_lint");
    expect(tools.format.output?.startsWith("Formatted messy.py in the editor"), "ide_format");
    expect(afterMove.includes("<ide>") && afterMove.includes("Active file: greet.py"), `the move reaches the model (${afterMove.slice(0, 300)})`);
    expect(state.items.some((i) => i.kind === "context" && i.path === "greet.py"), "the move shows in the transcript");
    expect(tools.close.status === "done" && !(await app.panes()).some((p) => p.tabs.includes(`${dir}/messy.py`)), "ide_close");
    expect(tools.missing.status === "error" && tools.missing.output?.includes("No such file"), "ide_open of a missing file");
    const messy = await fs.readText(`${dir}/messy.py`);
    if (messy !== "import os\n\nx = 1\n") throw new Error(`messy.py: ${JSON.stringify(messy)}`);
    return { tools: Object.keys(tools).length };
  });

  // Several conversations per project (D36): a new one, one that keeps running
  // in the background (its IDE tools do nothing there), unread, archive, rename,
  // and a renamed folder.
  await step("agent-conversations", async () => {
    const { agent } = await import("./agent/service");
    const { fauxAssistantMessage, fauxText, fauxToolCall } = await import("@earendil-works/pi-ai/providers/faux");
    const dir = "Tests/agent";
    const faux = agent.useFaux();
    const tool = (name: string, args: Parameters<typeof fauxToolCall>[1], id: string) =>
      fauxAssistantMessage([fauxToolCall(name, args, { id })], { stopReason: "toolUse" });
    const first = (await agent.state()).conversationId!;
    await agent.newConversation(dir);
    await agent.setModel("selftest", "faux-1");
    const second = (await agent.state()).conversationId!;
    if (second === first) throw new Error("no new conversation");
    faux.setResponses([
      tool("run_python", { code: "import time\ntime.sleep(2)\nprint('slept')" }, "sleep"),
      tool("ide_open", { path: "greet.py" }, "open"),
      fauxAssistantMessage([fauxText("Background done.")]),
    ]);
    await agent.submit("Wait, then open greet.py", null);
    await until(async () => (await agent.state()).busy);
    await agent.switchTo(first);
    const back = await until(async () => {
      const s = await agent.state();
      const c = s.conversations.find((x) => x.id === second);
      return c && !c.running && c.unread ? s : null;
    }, 60000);
    if (back.conversationId !== first) throw new Error("switched away");
    await agent.switchTo(second);
    const s2 = await agent.state();
    const open = s2.items.find((i) => i.id === "open");
    if (open?.status !== "error" || !open.output?.includes("not looking at this conversation")) throw new Error(`background ide_open: ${JSON.stringify(open)}`);
    if (s2.conversations.find((x) => x.id === second)?.unread) throw new Error("still unread on screen");
    const titles = s2.conversations.map((c) => c.title);
    if (!titles.includes("Make greet friendlier") || !titles.includes("Wait, then open greet.py")) throw new Error(`titles: ${JSON.stringify(titles)}`);
    // Archiving the one on screen shows the latest other one; it can come back.
    await agent.archive(second, true);
    let s = await agent.state();
    if (s.conversationId !== first || !s.conversations.find((x) => x.id === second)?.archived) throw new Error(`archive: ${JSON.stringify(s.conversations)}`);
    await agent.archive(second, false);
    await agent.rename(first, "Greeting work");
    s = await agent.state();
    if (s.conversations.find((x) => x.id === first)?.title !== "Greeting work") throw new Error("rename");
    // A renamed folder: the conversations follow.
    await agent.renamed(dir, `${dir}-moved`);
    s = await agent.state();
    const moved = s.project === `${dir}-moved` && s.root === `${dir}-moved` && s.conversations.every((c) => c.project === `${dir}-moved`);
    await agent.renamed(`${dir}-moved`, dir);
    if (!moved) throw new Error(`renamed: ${JSON.stringify({ project: s.project, root: s.root })}`);
    const native = await until(async () => {
      const n = await appCall("agentState");
      return n.conversations >= 2 ? n : null;
    }, 5000);
    await appCall("closeSheet");
    return { conversations: s.conversations.length, native: native.conversations };
  });

  // The docs tools (D37): search, read, and show the user.
  await step("agent-docs", async () => {
    const { agent } = await import("./agent/service");
    const { fauxAssistantMessage, fauxText, fauxToolCall } = await import("@earendil-works/pi-ai/providers/faux");
    const dir = "Tests/agentdocs";
    await fs.mkdir(dir).catch(() => {});
    await fs.writeText(`${dir}/main.py`, "print('hi')\n");
    await app.openFile(`${dir}/main.py`);
    await appCall("openAgent", dir);
    await until(async () => (await agent.state()).project === dir, 30000);
    const faux = agent.useFaux();
    await agent.newConversation(dir);
    await agent.setModel("selftest", "faux-1");
    const tool = (name: string, args: Parameters<typeof fauxToolCall>[1], id: string) =>
      fauxAssistantMessage([fauxToolCall(name, args, { id })], { stopReason: "toolUse" });
    faux.setResponses([
      tool("docs_search", { query: "json.loads" }, "search"),
      tool("docs_read", { ref: "library/json.html#json.loads" }, "read"),
      tool("docs_search", { query: "template strings", version: "3.15" }, "search315"),
      tool("ide_show_docs", { ref: "library/json.html#json.loads" }, "show"),
      fauxAssistantMessage([fauxText("Done: see [json.loads](docs:3.14/library/json.html#json.loads).")]),
    ]);
    await agent.submit("How do I parse JSON?", await appCall("agentIDEState"));
    const state = await until(async () => {
      const s = await agent.state();
      return !s.busy && s.items.at(-1)?.text.startsWith("Done") ? s : null;
    }, 60000);
    const tools = Object.fromEntries(state.items.filter((i) => i.kind === "tool").map((i) => [i.id, i]));
    const expect = (cond: unknown, what: string) => {
      if (!cond) throw new Error(`${what}: ${JSON.stringify(state.items.map((i) => [i.id, i.status, (i.output ?? i.text).slice(0, 200)]))}`);
    };
    expect(Object.values(tools).every((t) => t.status === "done"), "tool statuses");
    expect(tools.search.output?.includes("ref: library/json.html#json.loads") && tools.search.output.includes("Python 3.14"), "docs_search");
    expect(tools.read.output?.includes("docs:3.14/library/json.html#json.loads") && /deserialize/i.test(tools.read.output), "docs_read");
    expect(tools.search315.output?.includes("Python 3.15") && tools.search315.output.includes("string.templatelib"), "docs_search 3.15");
    expect(tools.show.output?.includes("Showing the Python 3.14 docs"), "ide_show_docs");
    await until(async () => {
      const docs = await appCall("docsState");
      return docs.shown && docs.ref === "library/json.html#json.loads" && /json/.test(docs.title ?? "");
    }, 8000).catch(async () => {
      throw new Error(`viewer: ${JSON.stringify(await appCall("docsState"))}`);
    });
    await appCall("closeDocs");
    await until(async () => !(await appCall("docsState")).shown, 5000);
    await appCall("closeSheet");
  });

  // Last: iOS ends the engine's process (D50). The host reloads the page, which
  // gets the console back and finishes the self-test (above).
  if (!only || new RegExp(only).test("engine_recovery")) {
    await fs.writeText("Tests/recover.py", "import time\nprint('before the end')\ntime.sleep(60)\n");
    const { done } = await runFile("Tests/recover.py");
    done.catch(() => {});
    await until(() => consoleText().includes("before the end"), 30000);
    await appCall("stashResults", JSON.stringify(r));
    if (await appCall<boolean>("killEngine")) return; // this page ends here
    r.engine_recovery = { ok: false, error: "WKWebView has no _killWebContentProcess" };
    session.stop();
  }

  await fs.remove("Tests").catch(() => {});
  await call("result", JSON.stringify(r, null, 2));
}
