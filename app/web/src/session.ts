// The running Python session: one worker at a time, the console transcript
// (grouped into runs), pending input(), the >>> console and UI apps. React
// subscribes via useSyncExternalStore. Output is batched per animation frame.
import { basename, call, dirname, fs, haptic, join } from "./host";
import { breakpoints } from "./debug/breakpoints";
import type { CellRequest, KernelEvent, Output } from "./notebook/types";
import { memoryUse, PyWorker, SIGNAL, WorkerPool, type Stream } from "./python";
import { chooseFor, onDefaultPython, runtimeFor } from "./runtimes";
import { crashTrace, parseTrace, type Trace } from "./trace";
import { TurtleScene, turtleScenes } from "./turtle";

/** "turtle": a turtle screen; the line's text is the key of its scene (D29). */
export type LineKind = Stream | "input" | "prompt" | "run" | "turtle";

export interface Line {
  id: number;
  runId: number;
  kind: LineKind;
  text: string;
  /** A traceback as data (D45); `text` is its classic form. Never merged with other output. */
  trace?: Trace;
}

export type RunStatus = "running" | "ok" | "error" | "stopped" | "crashed";

export interface Run {
  id: number;
  file: string | null; // null: console input
  dir: string; // the folder the interpreter runs in (resolves traceback paths)
  python: string | null; // the runtime's full version ("3.14.2"), once chosen (D37)
  startedAt: number;
  endedAt: number | null;
  status: RunStatus;
}

export type Status = "idle" | "starting" | "running";

// -- debugger (D23) -------------------------------------------------------------------

export interface DebugFrame {
  name: string; // qualified function name, "<module>" for module level
  file: string; // app path
  line: number;
}

export interface DebugVariable {
  name: string;
  value: string; // reprlib-limited repr
  type: string;
  ref: number; // > 0: has children, fetch with session.debugVariables(ref)
}

export interface DebugScope {
  name: string;
  variables: DebugVariable[];
}

export interface DebugState {
  stopId: number; // changes on every stop; variable refs are only valid until the next
  /** Transcript lines from this id on were written while paused (>>> evaluations); the console shows them below the paused block. */
  firstLineId: number;
  reason: "breakpoint" | "step" | "pause" | "breakpoint()" | "exception" | string;
  postMortem: boolean;
  exception: string | null;
  frames: DebugFrame[];
  selected: number;
  scopes: DebugScope[];
}

export type DebugCommand =
  | { op: "continue" | "next" | "stepIn" | "stepOut" }
  | { op: "scopes"; frame: number }
  | { op: "variables"; ref: number }
  | { op: "evaluate"; expr: string; frame: number; context: "hover" | "repl" }
  | { op: "setBreakpoints"; breakpoints: Record<string, number[]> };

export interface SessionState {
  lines: Line[];
  runs: Record<number, Run>;
  status: Status;
  awaitingInput: boolean;
  uiOpen: boolean;
  runningFile: string | null;
  bootMs: number | null;
  /** Bumped when a run starts so the console can open itself. */
  runCounter: number;
  /** The program is stopped in the debugger. */
  debug: DebugState | null;
  /** Pause was requested and the program has not stopped yet. */
  pausing: boolean;
  /** The interpreter is a notebook's kernel (D44); `cell` is the count of the cell running. */
  kernel: { path: string; python: string; count: number; cell: number | null } | null;
}

/** A notebook cell's error output. */
const errorOutput = (ename: string, evalue: string, traceback?: string[], trace?: Trace): Output => ({
  output_type: "error", ename, evalue, traceback: traceback ?? [`${ename}: ${evalue}`], ...(trace ? { trace } : {}),
});

const MAX_CHARS = 400_000;
const PROJECT_ROOT = "/home/pyodide/project";

/** Apply carriage returns: text after a \r overwrites the current line. */
function applyCR(text: string): string {
  if (!text.includes("\r")) return text;
  return text
    .replace(/\r\n/g, "\n")
    .split("\n")
    .map((line) => (line.includes("\r") ? line.slice(line.lastIndexOf("\r") + 1) : line))
    .join("\n");
}

export class Session {
  private state: SessionState = {
    lines: [], runs: {}, status: "idle", awaitingInput: false, uiOpen: false, runningFile: null, bootMs: null, runCounter: 0,
    debug: null, pausing: false, kernel: null,
  };
  private listeners = new Set<() => void>();
  private pool = new WorkerPool();
  private worker: PyWorker | null = null;
  private workerDir = "";
  private workerSerial = 0; // scene keys are "<worker>:<screen>"
  private nextId = 1;
  private currentRun = 0;
  private stopRequested = false;
  private inputResolver: ((text: string | null) => void) | null = null;
  private uiListener: ((json: string | null) => void) | null = null;
  private pendingOutput: { kind: LineKind; text: string; runId: number; trace?: Trace }[] = [];
  private flushScheduled = false;
  // The worker blocks in the debugger until debugNext is called with a command.
  private debugNext: ((command: DebugCommand) => void) | null = null;
  private debugResult: ((message: any) => void) | null = null;
  private debugQueue: Promise<unknown> = Promise.resolve();
  private stopCounter = 0;
  // Notebook kernels (D44): the worker belongs to one notebook while `kernel` is set.
  private kernel: { path: string; python: string; count: number } | null = null;
  private cell: { path: string; id: string; count: number; failed: boolean; tail: string; run: number | null } | null = null;
  private cellQueue: { path: string; id: string; code: string; source: string }[] = [];
  private cellLoop: Promise<void> | null = null;
  private cellLoopPath: string | null = null;
  private kernelEvents = new Map<string, KernelEvent[]>();
  private eventsScheduled = false;
  /** The self-test listens to what goes to the editors. */
  onKernelEvents: ((path: string, events: KernelEvent[]) => void) | null = null;

  constructor() {
    this.pool.spareReady.then((info) => this.set({ bootMs: info.bootMs }), () => {});
    onDefaultPython((python) => {
      this.pool.setDefault(python);
      this.pool.spareReady.then((info) => this.set({ bootMs: info.bootMs }), () => {});
    });
    breakpoints.subscribe(() => this.syncBreakpoints());
  }

  /** The app goes to the background, where it may be killed: what the
   * program queued goes to disk (the host calls this). */
  async syncInBackground() {
    if (this.worker && !this.worker.dead && !this.state.debug) await this.worker.syncFiles();
  }

  subscribe = (fn: () => void) => {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  };

  getSnapshot = () => this.state;

  private set(patch: Partial<SessionState>) {
    this.state = { ...this.state, ...patch };
    for (const fn of this.listeners) fn();
  }

  // -- console transcript -----------------------------------------------------------

  /** Queue output; it is merged into the transcript once per frame. */
  append(kind: LineKind, text: string, runId = this.currentRun, trace?: Trace) {
    this.pendingOutput.push({ kind, text, runId, trace });
    if (this.flushScheduled) return;
    this.flushScheduled = true;
    const flush = () => {
      this.flushScheduled = false;
      this.flushOutput();
    };
    setTimeout(flush, 16);
  }

  /** Apply queued output now (also used before state changes that depend on it). */
  flushOutput() {
    if (!this.pendingOutput.length) return;
    let lines = this.state.lines.slice();
    for (const { kind, text, runId, trace } of this.pendingOutput) {
      const last = lines.at(-1);
      const mergeable = (kind === "stdout" || kind === "stderr" || kind === "system") && !trace;
      // Output while paused must not merge into a line from before the stop:
      // the console shows the two on different sides of the paused block.
      const boundary = this.state.debug?.firstLineId ?? 0;
      if (mergeable && last && last.kind === kind && !last.trace && last.runId === runId && last.id >= boundary) {
        lines[lines.length - 1] = { ...last, text: applyCR(last.text + text) };
      } else if (trace) {
        lines.push({ id: this.nextId++, runId, kind, text, trace });
      } else {
        lines.push({ id: this.nextId++, runId, kind, text: mergeable ? applyCR(text) : text });
      }
    }
    this.pendingOutput = [];
    const size = (l: Line) => (l.kind === "image" || l.kind === "turtle" ? 2000 : l.text.length);
    let total = 0;
    for (const l of lines) total += size(l);
    let drop = 0;
    while (total > MAX_CHARS && drop < lines.length - 1) {
      total -= size(lines[drop]);
      drop++;
    }
    if (drop) lines = lines.slice(drop);
    this.set({ lines });
    if (drop) this.pruneScenes();
  }

  /** Forget turtle scenes that are no longer in the transcript. */
  private pruneScenes() {
    const shown = new Set(this.state.lines.filter((l) => l.kind === "turtle").map((l) => l.text));
    for (const [key, scene] of turtleScenes) {
      if (!shown.has(key) && !scene.live) turtleScenes.delete(key);
    }
  }

  /**
   * The page was reloaded because iOS ended its process (D50), usually for
   * using too much memory: the console as the host still had it. Its programs
   * are gone; a run that was going on is marked crashed and says why. Only
   * into a session that has nothing yet.
   */
  restore(snapshot: { lines: Line[]; runs: Record<string, Run> }) {
    if (this.state.lines.length || this.state.status !== "idle" || this.worker) return false;
    const now = Date.now();
    const runs: Record<number, Run> = {};
    const ended: number[] = [];
    for (const run of Object.values(snapshot.runs ?? {})) {
      if (run.status === "running") ended.push(run.id);
      runs[run.id] = run.status === "running" ? { ...run, status: "crashed", endedAt: now } : run;
    }
    const lines = (snapshot.lines ?? []).filter((l) => runs[l.runId]);
    const ids = [...lines.map((l) => l.id), ...Object.keys(runs).map(Number)];
    this.nextId = Math.max(this.nextId, ...ids.map((id) => id + 1));
    this.currentRun = Math.max(0, ...Object.keys(runs).map(Number));
    // Turtle screens keep their drawings (the host has them); new ones get new keys.
    for (const l of lines) if (l.kind === "turtle") this.workerSerial = Math.max(this.workerSerial, Number(l.text.split(":")[0]) || 0);
    this.set({ lines, runs });
    for (const id of ended) {
      this.append("stderr", "Python was stopped: iOS ended the process it runs in, most likely because the program used too much memory.\n", id);
    }
    this.flushOutput();
    return true;
  }

  clear() {
    this.pendingOutput = [];
    const running = this.state.status !== "idle" ? this.state.runs[this.currentRun] : null;
    this.set({ lines: running ? [{ id: this.nextId++, runId: running.id, kind: "run", text: "" }] : [], runs: running ? { [running.id]: running } : {} });
    this.pruneScenes();
  }

  private startRun(file: string | null) {
    this.flushOutput();
    const dir = file ? dirname(file) : this.workerDir;
    const run: Run = { id: this.nextId++, file, dir, python: null, startedAt: Date.now(), endedAt: null, status: "running" };
    this.currentRun = run.id;
    this.stopRequested = false;
    this.set({ runs: { ...this.state.runs, [run.id]: run }, runCounter: this.state.runCounter + 1 });
    this.append("run", "", run.id);
    return run;
  }

  private setRunPython(python: string) {
    const run = this.state.runs[this.currentRun];
    if (run) this.set({ runs: { ...this.state.runs, [run.id]: { ...run, python: runtimeFor(python).version } } });
  }

  private endRun(status: RunStatus) {
    this.flushOutput();
    const run = this.state.runs[this.currentRun];
    if (!run) return;
    this.set({ runs: { ...this.state.runs, [run.id]: { ...run, status, endedAt: Date.now() } } });
  }

  // -- running ------------------------------------------------------------------------

  /** Run a saved file: its folder is the program's cwd, used in place (D35). */
  async runFile(path: string, code: string) {
    this.closeWorker();
    const dir = dirname(path);
    this.startRun(path);
    this.set({ status: "starting", runningFile: path });
    try {
      const choice = await chooseFor(dir, code);
      if (!choice.ok) throw new Error(`Python version: ${choice.error}`);
      this.setRunPython(choice.python);
      const worker = await this.takeWorker(dir, choice.python);
      // What the last program started on the device (sensors, sounds) stops (D40).
      await call("device.reset").catch(() => {});
      this.set({ status: "running" });
      const result = await worker.run(code, { filename: basename(path), cwd: PROJECT_ROOT, breakpoints: breakpoints.forRun(dir) });
      await this.finishRun(result);
    } catch (e) {
      this.append("stderr", `${(e as Error).message ?? e}\n`);
      this.endRun("error");
      this.set({ status: "idle" });
    }
  }

  /** Run console input in the current session (a fresh one if there is none). */
  async runConsole(source: string) {
    if (!source.trim() || this.state.status !== "idle") return;
    this.flushOutput();
    // Console input continues the previous run's block when that program is still loaded.
    const reuse = this.worker && !this.worker.dead;
    if (!reuse || !this.state.runs[this.currentRun]) this.startRun(null);
    this.append("prompt", source);
    let worker = this.worker!;
    if (reuse) {
      this.setRunPython(worker.python);
    } else {
      const choice = await chooseFor(this.workerDir);
      const python = choice.ok ? choice.python : undefined;
      worker = await this.takeWorker(this.workerDir, python);
      this.setRunPython(worker.python);
    }
    this.setScenesActive(true);
    this.set({ status: "running" });
    const result = await worker.run(source, { repl: true, cwd: PROJECT_ROOT });
    await this.finishRun(result, true);
  }

  private async takeWorker(dir: string, python?: string) {
    const worker = await this.pool.take(python);
    try {
      await worker.attach(dir);
    } catch (e) {
      worker.terminate("closed");
      throw new Error(`Could not open the folder: ${(e as Error).message ?? e}`);
    }
    this.worker = worker;
    this.workerDir = dir;
    const serial = ++this.workerSerial;
    worker.onOutput = (stream, text) => this.output(stream, text);
    worker.onDisplay = (json) => this.display(json);
    worker.onInput = () =>
      this.cell ? this.cellInput() : new Promise((resolve) => {
        this.flushOutput();
        this.inputResolver = resolve;
        this.set({ awaitingInput: true });
      });
    worker.onUIRender = (json) => {
      // A closed program may still send a message before it is killed.
      if (this.worker !== worker) return;
      this.set({ uiOpen: true });
      this.uiListener?.(json);
    };
    worker.onCrash = (error, dump) => this.crashed(error, dump);
    worker.onDebug = (message) => this.onDebugMessage(worker, message);
    worker.onTurtle = (batches) => {
      for (const json of batches) {
        const { id, ops } = JSON.parse(json) as { id: number; ops: any[] };
        const key = `${serial}:${id}`;
        let scene = turtleScenes.get(key);
        if (!scene) {
          scene = new TurtleScene(key);
          turtleScenes.set(key, scene);
          this.cellConsoleRun();
          this.append("turtle", key);
        }
        scene.apply(ops);
      }
    };
    worker.onTurtleCall = async (request: { id: number; wait?: number; prompt?: { title: string; text: string; default: string } }) => {
      if (request.prompt) {
        const { title, text, default: value } = request.prompt;
        this.flushOutput();
        return window.prompt([title, text].filter(Boolean).join("\n\n"), value);
      }
      const scene = turtleScenes.get(`${serial}:${request.id}`);
      return scene ? scene.take(request.wait ?? 0) : [];
    };
    return worker;
  }

  /**
   * The interpreter failed (D16). Out of native stack, with the Python stack
   * the worker found then, it is shown as a RecursionError where the program
   * was (D49); the program can't catch it, and the next run gets a new
   * interpreter.
   */
  private crashed(error: string, dump?: string) {
    const runId = this.currentRun;
    const dir = this.workerDir;
    if (!dump || !/call stack/i.test(error)) return this.append("stderr", `Python crashed: ${error}\n`, runId);
    const exception = { type: "RecursionError", message: "maximum recursion depth exceeded (Python ran out of stack space and was restarted)" };
    const sources = (file: string) => fs.readText(join(dir, file)).then((text) => text.split("\n"));
    void crashTrace(dump, exception, sources).then(
      (trace) => this.append("stderr", trace ? `${trace.text}\n` : `Python crashed: ${error}\n`, runId, trace),
      () => this.append("stderr", `Python crashed: ${error}\n`, runId),
    );
  }

  /** Whether the worker's turtle screens take events (only while code runs). */
  private setScenesActive(active: boolean) {
    const prefix = `${this.workerSerial}:`;
    for (const [key, scene] of turtleScenes) if (key.startsWith(prefix)) scene.setActive(active);
  }

  /** The worker's turtle screens take no more events. */
  private endScenes() {
    const prefix = `${this.workerSerial}:`;
    for (const [key, scene] of turtleScenes) if (key.startsWith(prefix)) scene.end();
    this.pruneScenes();
  }

  // -- debugger -----------------------------------------------------------------------

  private onDebugMessage(worker: PyWorker, message: any): Promise<DebugCommand> {
    if (message.event === "breakpoints") {
      return Promise.resolve({ op: "setBreakpoints", breakpoints: breakpoints.forRun(this.workerDir) });
    }
    if (message.event === "stopped") {
      this.flushOutput();
      this.set({
        pausing: false,
        debug: {
          stopId: ++this.stopCounter,
          firstLineId: this.nextId,
          reason: message.reason,
          postMortem: !!message.postMortem,
          exception: message.exception ?? null,
          frames: (message.frames as { name: string; file: string; line: number }[]).map((f) => ({ ...f, file: join(this.workerDir, f.file) })),
          selected: typeof message.selected === "number" ? message.selected : 0,
          scopes: message.scopes ?? [],
        },
      });
      if (!message.postMortem) haptic();
    } else if (message.event === "result") {
      const resolve = this.debugResult;
      this.debugResult = null;
      resolve?.(message);
    }
    return new Promise((resolve) => {
      // A late message from a replaced worker must not take over.
      if (this.worker !== worker) return resolve({ op: "continue" });
      this.debugNext = resolve;
    });
  }

  /** Ask the paused program something; answers come back in order. */
  debugRequest(command: DebugCommand): Promise<any> {
    const result = this.debugQueue.then(
      () =>
        new Promise((resolve) => {
          // Checks the pending command, not state.debug: resume() hides the
          // paused UI right away, but requests queued before it still go first.
          const next = this.debugNext;
          if (!next) return resolve({ error: "The program is not paused." });
          this.debugNext = null;
          this.debugResult = resolve;
          next(command);
        }),
    );
    this.debugQueue = result.catch(() => {});
    return result;
  }

  /** Continue or step. */
  resume(op: "continue" | "next" | "stepIn" | "stepOut") {
    if (!this.state.debug) return;
    this.set({ debug: null });
    void this.debugQueue.then(() => {
      const next = this.debugNext;
      this.debugNext = null;
      next?.({ op });
    });
  }

  async selectFrame(index: number) {
    const debug = this.state.debug;
    if (!debug || index === debug.selected || index < 0 || index >= debug.frames.length) return;
    this.set({ debug: { ...debug, selected: index, scopes: [] } });
    const result = await this.debugRequest({ op: "scopes", frame: index });
    const now = this.state.debug;
    if (now && now.stopId === debug.stopId && now.selected === index) this.set({ debug: { ...now, scopes: result.scopes ?? [] } });
  }

  async debugVariables(ref: number): Promise<DebugVariable[]> {
    const result = await this.debugRequest({ op: "variables", ref });
    return result.variables ?? [];
  }

  /** The value of a name tapped in the editor. */
  async debugEvaluate(expr: string): Promise<{ value?: DebugVariable; error?: string }> {
    return this.debugRequest({ op: "evaluate", expr, frame: this.state.debug?.selected ?? 0, context: "hover" });
  }

  /** >>> input while paused runs in the selected frame. */
  async debugConsole(source: string) {
    const debug = this.state.debug;
    if (!debug || !source.trim()) return;
    this.append("prompt", source);
    await this.debugRequest({ op: "evaluate", expr: source, frame: debug.selected, context: "repl" });
    // Assignments show up in the variables.
    const scopes = await this.debugRequest({ op: "scopes", frame: debug.selected });
    const now = this.state.debug;
    if (now && now.stopId === debug.stopId && scopes.scopes) this.set({ debug: { ...now, scopes: scopes.scopes } });
  }

  /** Stop at the next line of user code. */
  pause() {
    if (this.state.status !== "running" || this.state.debug || this.state.awaitingInput) return;
    if (this.worker?.signal(SIGNAL.pause)) this.set({ pausing: true });
  }

  get canInspect() {
    return !!this.worker && !this.worker.dead && !this.worker.running && this.state.status === "idle" && !this.state.debug;
  }

  /** Open the debugger on the frames of the last uncaught exception, at
   * `frame` of its stack (innermost first; a traceback's "debug" index). */
  async inspectError(frame = 0) {
    const worker = this.worker;
    if (!worker || !this.canInspect) return;
    this.flushOutput();
    const result = await worker.run(`import _terrarium_debug\n_terrarium_debug.post_mortem(${Math.max(0, Math.floor(frame) || 0)})`, { repl: true, cwd: PROJECT_ROOT });
    if (this.worker !== worker) return;
    this.set({ debug: null });
    if (!result.ok && result.error) this.appendError(result);
  }

  /** A failed run's traceback: as data when the runtime described it (D45). */
  private appendError(result: { error?: string; trace?: string }) {
    const trace = parseTrace(result.trace);
    this.append("stderr", (trace?.text ?? cleanTraceback(result.error ?? "")) + "\n", this.currentRun, trace);
    // Out of the memory Python may use here (D50): say how much that is.
    const { budget } = memoryUse();
    const last = trace?.exceptions.at(-1)?.type ?? /(\w+Error)\b[^\n]*\s*$/.exec(result.error ?? "")?.[1];
    if (last === "MemoryError" && budget) {
      const gb = budget / 2 ** 30;
      const size = gb >= 1 ? `${gb.toFixed(1)} GB` : `${Math.round(budget / 2 ** 20)} MB`;
      this.append("system", `Python programs can use about ${size} of memory on this device.\n`);
    }
  }

  /** Breakpoints changed: tell a program that is running (or paused). */
  private syncBreakpoints() {
    const worker = this.worker;
    if (!worker || worker.dead) return;
    if (this.debugNext && !this.state.debug?.postMortem) {
      void this.debugRequest({ op: "setBreakpoints", breakpoints: breakpoints.forRun(this.workerDir) });
    } else if (this.state.status === "running" || this.state.uiOpen) {
      worker.signal(SIGNAL.breakpoints);
    }
  }

  private endDebug() {
    this.debugNext = null;
    const resolve = this.debugResult;
    this.debugResult = null;
    resolve?.({ error: "The program ended." });
    if (this.state.debug || this.state.pausing) this.set({ debug: null, pausing: false });
  }

  private async finishRun(
    result: { ok: boolean; error?: string; trace?: string; killed?: boolean },
    fromConsole = false,
  ) {
    this.inputResolver = null;
    this.setScenesActive(false);
    let status: RunStatus = "ok";
    if (!result.ok && result.error) {
      const interrupted = /KeyboardInterrupt\s*$/.test(result.error.trim()) || (result.killed && this.stopRequested);
      if (interrupted && this.stopRequested) {
        status = "stopped";
        this.dropInterruptTraceback();
      } else if (result.killed && /crashed/i.test(result.error)) {
        status = "crashed";
      } else {
        status = "error";
        this.appendError(result);
      }
    }
    if (fromConsole) {
      // A failing console line does not change how the program itself ended.
      if (status === "crashed") this.endRun("crashed");
      else if (this.state.runs[this.currentRun]?.status === "running") this.endRun("ok");
    } else {
      this.endRun(status);
    }
    this.set({ status: "idle", awaitingInput: false, pausing: false });
    // Dialogs and the spinner a program left go with it (a ui app keeps them).
    if (!this.state.uiOpen) void call("device.ended").catch(() => {});
    if (this.state.debug && !this.state.uiOpen) this.endDebug();
    if (status === "error" || status === "crashed") haptic();
    // A linked folder's copy goes back now; the host tells the views what changed.
    await this.worker?.syncFiles();
  }

  /** Pyodide prints the KeyboardInterrupt traceback when input() is interrupted; a stop is not an error. */
  private dropInterruptTraceback() {
    this.flushOutput();
    const lines = this.state.lines;
    const i = lines.findLastIndex((l) => l.runId === this.currentRun && l.kind === "stderr");
    if (i >= 0 && /KeyboardInterrupt\s*$/.test(lines[i].text)) {
      const text = lines[i].text.replace(/Traceback \(most recent call last\):[\s\S]*KeyboardInterrupt\s*$/, "");
      this.set({ lines: text ? lines.with(i, { ...lines[i], text }) : lines.filter((_, j) => j !== i) });
    }
  }

  submitInput(text: string) {
    const resolve = this.inputResolver;
    if (!resolve) return;
    this.inputResolver = null;
    this.append("input", text + "\n");
    this.flushOutput();
    this.set({ awaitingInput: false });
    resolve(text + "\n");
  }

  stop() {
    const debug = this.state.debug;
    if (debug?.postMortem) return this.resume("continue"); // just ends the inspection
    this.stopRequested = true;
    this.cancelCells();
    if (this.worker?.running) {
      this.worker.stop(); // also interrupts a paused debugger (its call is pending)
      this.endDebug();
    } else if (debug) {
      // Paused in a UI app's callback after the script returned: end the app.
      this.endDebug();
      this.closeUI();
    }
  }

  private closeWorker(keepAlive = false) {
    void call("device.ended").catch(() => {});
    if (this.kernel) {
      this.emit(this.kernel.path, { type: "kernel", state: "dead" });
      this.kernel = null;
      this.set({ kernel: null });
    }
    if (this.worker && !this.worker.dead && !keepAlive) this.worker.terminate("closed");
    if (this.worker) this.endScenes();
    this.endDebug();
    this.worker = null;
    this.set({ uiOpen: false, awaitingInput: false });
    this.uiListener?.(null);
  }

  // -- notebooks (D44) ----------------------------------------------------------------

  /** Output of the program: a running cell's goes to its notebook, the rest to the console. */
  private output(stream: Stream, text: string) {
    const cell = this.cell;
    if (!cell) return this.append(stream, text);
    if (stream === "image") {
      this.cellOutput({ output_type: "display_data", data: { "image/png": text, "text/plain": "<Figure>" }, metadata: {} });
    } else if (stream === "system") {
      this.cellOutput({ output_type: "status", text: text.replace(/\n$/, "") });
    } else {
      if (stream === "stdout") cell.tail = (cell.tail + text).split("\n").at(-1)!.slice(-300);
      this.cellOutput({ output_type: "stream", name: stream, text });
    }
  }

  private cellOutput(output: Output) {
    const cell = this.cell;
    if (cell) this.emit(cell.path, { type: "output", cell: cell.id, output });
  }

  /** A rich output (display(), a cell's value, its error), as JSON from _terrarium_notebook. */
  private display(json: string) {
    let msg: any;
    try {
      msg = JSON.parse(json);
    } catch {
      return;
    }
    const cell = this.cell;
    if (!cell) {
      // A program's display() (or a kernel's after its cell ended): the console.
      if (msg.type === "error" || msg.type === "exception") {
        const trace = msg.trace?.exceptions?.length ? (msg.trace as Trace) : undefined;
        return this.append("stderr", (trace?.text ?? (msg.traceback ?? []).join("\n")) + "\n", this.currentRun, trace);
      }
      const data = msg.data ?? {};
      if (typeof data["image/png"] === "string") this.append("image", data["image/png"].replace(/\s/g, ""));
      else if (data["text/plain"] != null) this.append("stdout", `${data["text/plain"]}\n`);
      return;
    }
    switch (msg.type) {
      case "display_data":
        this.cellOutput({ output_type: "display_data", data: msg.data ?? {}, metadata: msg.metadata ?? {}, transient: msg.transient ?? {} });
        break;
      case "execute_result":
        this.cellOutput({ output_type: "execute_result", data: msg.data ?? {}, metadata: msg.metadata ?? {}, execution_count: cell.count });
        break;
      case "update_display_data":
        if (msg.transient?.display_id) {
          this.emit(cell.path, { type: "update", displayId: msg.transient.display_id, data: msg.data ?? {}, metadata: msg.metadata ?? {} });
        }
        break;
      case "clear_output":
        this.emit(cell.path, { type: "clear", cell: cell.id, wait: !!msg.wait });
        break;
      case "error":
        cell.failed = true;
        this.cellOutput(errorOutput(msg.ename ?? "Error", msg.evalue ?? "", msg.traceback, msg.trace));
        break;
      case "exception": // the runtime caught it (a turtle event handler): shown, the cell goes on
        this.cellOutput(errorOutput(msg.ename ?? "Error", msg.evalue ?? "", msg.traceback, msg.trace));
        break;
    }
  }

  /** input() in a cell: a native prompt (the console is not on screen). */
  private async cellInput(): Promise<string | null> {
    const cell = this.cell!;
    this.flushEvents();
    const text = await call<string | null>("notebook.input", { path: cell.path, prompt: cell.tail.trim() }).catch(() => null);
    if (this.cell !== cell || text === null || text === undefined) return null; // EOFError
    this.cellOutput({ output_type: "stream", name: "stdout", text: `${text}\n` });
    cell.tail = "";
    return `${text}\n`;
  }

  /** Turtle screens are drawn in the console: a cell that draws gets a run there. */
  private cellConsoleRun() {
    const cell = this.cell;
    if (!cell || cell.run !== null) return;
    cell.run = this.startRun(cell.path).id;
    this.cellOutput({ output_type: "status", text: "Turtle graphics are in the console." });
  }

  /** Events for a notebook's editors, sent at most once a frame (stream text merged). */
  private emit(path: string, event: KernelEvent) {
    let list = this.kernelEvents.get(path);
    if (!list) this.kernelEvents.set(path, (list = []));
    const last = list.at(-1);
    if (
      event.type === "output" && event.output.output_type === "stream" && last?.type === "output" && last.cell === event.cell &&
      last.output.output_type === "stream" && last.output.name === event.output.name
    ) {
      list[list.length - 1] = { ...last, output: { ...last.output, text: last.output.text + event.output.text } };
    } else {
      list.push(event);
    }
    if (this.eventsScheduled) return;
    this.eventsScheduled = true;
    setTimeout(() => this.flushEvents(), 16);
  }

  private flushEvents() {
    this.eventsScheduled = false;
    for (const [path, events] of this.kernelEvents) {
      void call("notebook.events", { path, events }).catch(() => {});
      this.onKernelEvents?.(path, events);
    }
    this.kernelEvents.clear();
  }

  /** Run cells of a notebook one after the other in its kernel (started if needed).
   * False if something else is running. `source` is the whole notebook's code
   * (its dependencies and Python version, read when the kernel starts). */
  runCells(path: string, cells: CellRequest[], source: string): boolean {
    if (this.state.status !== "idle" && this.cellLoopPath !== path) return false;
    for (const c of cells) {
      this.cellQueue.push({ path, id: c.id, code: c.code, source });
      this.emit(path, { type: "queued", cell: c.id });
    }
    if (!this.cellLoop) {
      this.cellLoopPath = path;
      this.cellLoop = this.drainCells().finally(() => {
        this.cellLoop = null;
        this.cellLoopPath = null;
      });
    }
    return true;
  }

  private async drainCells() {
    while (this.cellQueue.length) {
      const next = this.cellQueue.shift()!;
      const status = await this.runCell(next);
      // An error stops "Run All", as in Jupyter.
      if (status !== "ok") this.cancelCells();
    }
  }

  private cancelCells() {
    for (const c of this.cellQueue) this.emit(c.path, { type: "done", cell: c.id, status: "cancelled" });
    this.cellQueue = [];
  }

  /** End the notebook's kernel: its variables are gone, the next cell starts a new one. */
  restartKernel(path?: string) {
    if (!this.kernel || (path && this.kernel.path !== path)) return;
    this.cancelCells();
    this.stopRequested = true;
    this.closeWorker();
  }

  private kernelSnapshot() {
    const k = this.kernel;
    return k ? { path: k.path, python: k.python, count: k.count, cell: this.cell?.count ?? null } : null;
  }

  private async runCell({ path, id, code, source }: { path: string; id: string; code: string; source: string }): Promise<"ok" | "error" | "stopped"> {
    this.flushOutput();
    this.stopRequested = false;
    let fresh = false;
    if (!this.worker || this.worker.dead || this.kernel?.path !== path || this.state.uiOpen) {
      this.closeWorker(); // what ran before ends, like with Run
      this.set({ status: "starting", runningFile: path, kernel: { path, python: "", count: 0, cell: null } });
      this.emit(path, { type: "kernel", state: "starting" });
      try {
        const choice = await chooseFor(dirname(path), source);
        if (!choice.ok) throw new Error(`Python version: ${choice.error}`);
        await this.takeWorker(dirname(path), choice.python);
        await call("device.reset").catch(() => {});
        this.kernel = { path, python: runtimeFor(choice.python).version, count: 0 };
        fresh = true;
      } catch (e) {
        this.emit(path, { type: "output", cell: id, output: errorOutput("Error", String((e as Error).message ?? e)) });
        this.emit(path, { type: "done", cell: id, status: "error" });
        this.emit(path, { type: "kernel", state: "dead" });
        this.set({ status: "idle", runningFile: null, kernel: null });
        return "error";
      }
    }
    const worker = this.worker!;
    const kernel = this.kernel!;
    const cell = { path, id, count: ++kernel.count, failed: false, tail: "", run: null as number | null };
    this.cell = cell;
    this.setScenesActive(true);
    this.set({ status: "running", runningFile: path, kernel: this.kernelSnapshot() });
    this.emit(path, { type: "kernel", state: "busy", python: kernel.python });
    this.emit(path, { type: "start", cell: id, count: cell.count });
    const result = await worker.run(code, { filename: basename(path), cwd: PROJECT_ROOT, cell: { count: cell.count, prepare: fresh ? source : null } });
    this.flushOutput();
    this.cell = null;
    this.setScenesActive(false);
    let status: "ok" | "error" | "stopped" = cell.failed ? (this.stopRequested ? "stopped" : "error") : "ok";
    if (!result.ok) {
      const error = result.error ?? "";
      if (result.killed) {
        status = this.stopRequested ? "stopped" : "error";
        const message = /crashed/i.test(error) ? error : "The kernel was restarted; its variables are gone.";
        this.emit(path, { type: "output", cell: id, output: errorOutput(this.stopRequested ? "KernelRestarted" : "Crash", message, [message]) });
      } else if (/KeyboardInterrupt\s*$/.test(error.trim())) {
        status = "stopped";
        if (!cell.failed) this.emit(path, { type: "output", cell: id, output: errorOutput("KeyboardInterrupt", "") });
      } else {
        status = "error";
        const trace = parseTrace(result.trace);
        const text = trace?.text ?? cleanTraceback(error);
        const last = text.split("\n").at(-1) ?? "";
        const exc = trace?.exceptions.at(-1);
        this.emit(path, { type: "output", cell: id, output: errorOutput(exc?.type ?? (last.split(":")[0] || "Error"), exc?.message ?? last.split(": ").slice(1).join(": "), text.split("\n"), trace) });
        if (fresh) this.closeWorker(); // its dependencies did not install: the next cell tries again
      }
    }
    if (cell.run !== null && this.state.runs[cell.run]) {
      this.currentRun = cell.run;
      this.endRun(status === "ok" ? "ok" : status === "stopped" ? "stopped" : "error");
    }
    this.emit(path, { type: "done", cell: id, status });
    if (this.kernel && this.worker === worker && !worker.dead) this.emit(path, { type: "kernel", state: "idle", python: kernel.python });
    else if (this.kernel?.path === path && worker.dead) this.closeWorker();
    this.set({ status: "idle", awaitingInput: false, pausing: false, kernel: this.kernelSnapshot() });
    if (!this.state.uiOpen) void call("device.ended").catch(() => {});
    if (status === "error") haptic();
    await worker.syncFiles();
    return status;
  }

  // -- UI apps ------------------------------------------------------------------------

  /** The UI view registers here. Its renderer asks the program for a full
   * snapshot itself, so nothing needs replaying. */
  attachUI(fn: (json: string | null) => void) {
    this.uiListener = fn;
    return () => {
      if (this.uiListener === fn) this.uiListener = null;
    };
  }

  sendUIEvent(id: string, args: string) {
    this.worker?.sendUIEvent(id, args);
  }

  closeUI() {
    // Closing the app view ends the program, like Pythonista's close button.
    this.stopRequested = true;
    if (this.state.runs[this.currentRun]?.status === "running") this.endRun("stopped");
    const worker = this.worker;
    if (!worker || worker.dead || worker.running || this.state.debug) {
      this.closeWorker();
      return;
    }
    // Close the view right away, but let the program's queued writes (e.g.
    // saved data) reach the disk before it is killed.
    this.closeWorker(true);
    void worker.syncFiles().finally(() => worker.terminate("closed"));
  }
}

/** Drop Pyodide's own frames from a traceback. */
export function cleanTraceback(text: string): string {
  const dep = /_terrarium\.DependencyError: ([\s\S]*)$/.exec(text.trim());
  if (dep) return `Dependency error: ${dep[1]}`;
  // Project files are shown relative to the program's folder (its cwd).
  const lines = text.replace(/\n+$/, "").replaceAll(`File "${PROJECT_ROOT}/`, 'File "').split("\n");
  const out: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.startsWith('  File "') && (line.includes("/_pyodide/") || line.includes("_terrarium.py") || line.includes('"<dependencies>"'))) {
      while (i + 1 < lines.length && lines[i + 1].startsWith("    ")) i++;
      continue;
    }
    out.push(line);
  }
  return out.join("\n");
}

export const session = new Session();
