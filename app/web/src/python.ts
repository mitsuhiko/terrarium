// Page-side controller for Python workers (D6, D11, D13, D16): warm pool,
// output streaming, stdin, interrupt with escalation, host calls, UI messages,
// and the project folder the program works in (HostFS, D35).
import { call } from "./host";
import { ProcessTree } from "./processes";
import { RUNTIME_FILES } from "./runtimeModules";
import { getDefaultPython, runtimeFor } from "./runtimes";

const encoder = new TextEncoder();
const CHANNEL_BYTES = 8 + 1024 * 1024;
const RELAY_BYTES = 16 + 1024 * 1024;

/**
 * Memory (D50): iOS ends the web content process when it uses too much (about
 * 1.9 GB on a 6 GB iPhone 14 Pro), without a MemoryError. So the heaps of all
 * Python workers of the page share a budget, set by the host: a heap that would
 * grow past it doesn't, and the program gets a MemoryError. Shared with every
 * worker: [0] pages in use, [1] the budget in pages (0: none), then one slot per
 * worker with its own pages (given back when it ends).
 */
const MEMORY_SLOTS = 128;
const PAGE = 65536;
const memory = self.crossOriginIsolated && typeof SharedArrayBuffer === "function" ? new Int32Array(new SharedArrayBuffer(4 * (2 + MEMORY_SLOTS))) : null;
const freeSlots = Array.from({ length: MEMORY_SLOTS }, (_, i) => MEMORY_SLOTS + 1 - i);

export function setMemoryBudget(bytes: number) {
  if (memory) Atomics.store(memory, 1, Math.max(0, Math.floor(bytes / PAGE)));
}

/** The heaps of all workers and the budget, in bytes (budget 0: none). */
export function memoryUse() {
  return { used: memory ? Atomics.load(memory, 0) * PAGE : 0, budget: memory ? Atomics.load(memory, 1) * PAGE : 0 };
}

/** The page's fetch relay (Q25): makes HostFS's requests for blocked workers,
 * so they don't use synchronous XHRs, which WebKit sometimes answers about a
 * second late after a worker slept. `?fs=xhr` turns it off. */
let relay: Worker | null | undefined;
function fetchRelay(): Worker | null {
  if (relay === undefined) {
    const usable = typeof (Atomics as any).waitAsync === "function" && new URLSearchParams(location.search).get("fs") !== "xhr";
    relay = usable ? new Worker("/runtime/fetch-relay.js") : null;
  }
  return relay;
}

export type Stream = "stdout" | "stderr" | "system" | "image";

export interface RunOptions {
  filename?: string;
  cwd?: string; // directory inside the interpreter's file system (the mounted folder, see attach)
  repl?: boolean; // run as console input (shows the value of a final expression)
  /** Run as a notebook cell (D44); `prepare` is the notebook's source when the kernel is new (its dependencies). */
  cell?: { count: number; prepare?: string | null };
  breakpoints?: Record<string, number[]>; // project-relative path -> lines (D23)
}

/** Signals delivered through the interrupt buffer (see _terrarium_debug.py). */
export const SIGNAL = { interrupt: 2, pause: 10, breakpoints: 12 } as const;

export interface RunResult {
  ok: boolean;
  error?: string;
  /** The uncaught exception as data (D45): JSON from _terrarium_traceback. */
  trace?: string;
  ms: number;
  killed?: boolean;
}

export interface WorkerInfo {
  bootMs: number;
  version: string;
  jspi: string;
  gcTrampoline: boolean;
  isolated: boolean;
}

function workerOptions(python: string) {
  const params = new URLSearchParams(location.search);
  return {
    // Each bundled Python (D37) has its own core and package cache.
    indexURL: new URL(`/pyodide/${python}/`, location.href).href,
    packageBaseUrl: new URL(`/pkgs/${python}/`, location.href).href,
    jspi: params.get("jspi") !== "0",
    gcTrampoline: params.get("gc") !== "0",
    warm: params.get("warm") !== "0", // D49: _terrarium_warmup
    pythonFiles: Object.fromEntries(RUNTIME_FILES.map((f) => [f, new URL(`/runtime/python/${f}`, location.href).href])),
  };
}

export class PyWorker {
  readonly ready: Promise<WorkerInfo>;
  /** The runtime ("3.14"). */
  readonly python: string;
  /** Whether the program may use the device modules (D40): not in the agent's runs. */
  allowDevice = true;
  dead = false;
  onOutput: (stream: Stream, text: string) => void = () => {};
  onInput: () => Promise<string | null> = async () => null;
  onUIRender: (json: string) => void = () => {};
  /** A rich output, an error of a cell, display() (JSON, D44). */
  onDisplay: (json: string) => void = () => {};
  /** The interpreter failed (D16); `dump` is the Python stack then (D49). */
  onCrash: (error: string, dump?: string) => void = () => {};
  /** A debugger message; the returned promise is the next command (D23). */
  onDebug: (message: any) => Promise<unknown> = async () => ({ op: "continue" });
  /** Turtle graphics ops: JSON strings of {id, ops} (D29). */
  onTurtle: (batches: string[]) => void = () => {};
  /** A blocking turtle call: events for a screen, or a dialog. */
  onTurtleCall: (request: any) => Promise<unknown> = async () => [];
  /** The processes of the program this worker runs (D47); set on first run (the
   * root) or by the tree that started this worker as a child. */
  procs: ProcessTree | null = null;
  /** As a child process: its pid (0 for a root). */
  processPid = 0;
  /** The app path of the attached folder. */
  attachedPath: string | null = null;

  private worker: Worker;
  private interrupt: Int32Array | null;
  private channel: SharedArrayBuffer | null;
  private relayChannel: SharedArrayBuffer | null = null;
  private memorySlot = -1;
  private syncPending = false;
  private syncSeq = 0; // the blocking call being answered (a late answer to an interrupted one is dropped)
  private current: ((r: RunResult) => void) | null = null;
  private stopTimer: ReturnType<typeof setInterval> | null = null;
  private resolveReady!: (info: WorkerInfo) => void;
  private rejectReady!: (err: Error) => void;

  /** `preload`: modules to import while waiting (spares for child processes). */
  constructor(python = getDefaultPython(), options: { preload?: string[] } = {}) {
    this.python = runtimeFor(python).python;
    this.worker = new Worker("/runtime/py-worker.js", { type: "module" });
    const isolated = self.crossOriginIsolated && typeof SharedArrayBuffer === "function";
    this.interrupt = isolated ? new Int32Array(new SharedArrayBuffer(4)) : null;
    this.channel = isolated ? new SharedArrayBuffer(CHANNEL_BYTES) : null;
    const relay = isolated ? fetchRelay() : null;
    if (relay) {
      this.relayChannel = new SharedArrayBuffer(RELAY_BYTES);
      relay.postMessage({ type: "attach", channel: this.relayChannel });
    }
    this.ready = new Promise((resolve, reject) => {
      this.resolveReady = resolve;
      this.rejectReady = reject;
    });
    this.ready.catch(() => {});
    this.worker.onmessage = (e) => this.handle(e.data);
    this.worker.onerror = (e) => this.rejectReady(new Error(e.message));
    if (memory && freeSlots.length) this.memorySlot = freeSlots.pop()!;
    this.worker.postMessage({
      type: "boot", interrupt: this.interrupt?.buffer ?? null, channel: this.channel, relay: this.relayChannel, preload: options.preload,
      memory: this.memorySlot >= 0 ? { buffer: memory!.buffer, slot: this.memorySlot } : null, ...workerOptions(this.python),
    });
  }

  get running() {
    return this.current !== null;
  }

  private handle(msg: any) {
    switch (msg.type) {
      case "ready":
        this.resolveReady(msg);
        break;
      case "boot-failed":
        this.rejectReady(new Error(msg.error));
        break;
      case "output":
        this.onOutput(msg.stream, msg.text);
        break;
      case "ui-render":
        this.onUIRender(msg.tree);
        break;
      case "display":
        this.onDisplay(msg.json);
        break;
      case "turtle":
        this.onTurtle(msg.batches);
        break;
      case "call":
        void this.handleCall(msg);
        break;
      case "done":
        this.finish(msg);
        break;
      case "share":
      case "spawn":
      case "kill":
      case "abandon":
      case "process-started":
      case "process-exit":
        this.procs?.onMessage(this, msg);
        break;
      case "synced":
        this.syncs.get(msg.id)?.();
        this.syncs.delete(msg.id);
        break;
      case "worker-error": {
        // The interpreter is unusable afterwards; only report it as a crash
        // while something is running (a late error must not rewrite a run).
        const hint = /call stack/i.test(msg.error) ? " (recursion too deep)" : "";
        if (this.current) {
          this.onCrash(`${msg.error}${hint}`, msg.dump);
          this.terminate(`Python crashed: ${msg.error}${hint}`);
        } else {
          this.dead = true;
          this.worker.terminate();
          this.detachRelay();
          this.releaseMemory();
          this.unmount();
          if (this.processPid) this.onCrash(`${msg.error}${hint}`, msg.dump);
          this.procs?.workerGone(this, true);
        }
        break;
      }
    }
  }

  private async handleCall(msg: any) {
    if (msg.op === "chunk") return this.replyChunk(msg.value.offset);
    let reply: { value?: unknown; error?: string };
    const seq = msg.sync ? ++this.syncSeq : 0;
    try {
      if (msg.sync) this.syncPending = true;
      let value: unknown;
      if (msg.op === "stdin") value = await this.onInput();
      else if (msg.op === "debug") value = await this.onDebug(msg.value);
      else if (msg.op === "turtle") value = await this.onTurtleCall(msg.value);
      else if (msg.op === "host") {
        if (String(msg.value.op).startsWith("device.") && !this.allowDevice) {
          throw new Error("PermissionError: the device modules (clipboard, photos, contacts, ...) are not available when the agent runs code; run the program yourself");
        }
        value = await call(msg.value.op, msg.value.value);
      }
      else throw new Error(`unknown call ${msg.op}`);
      reply = { value };
    } catch (e) {
      reply = { error: String((e as Error).message ?? e) };
    }
    if (msg.sync) {
      if (this.syncPending && seq === this.syncSeq) this.replySync(reply);
    } else {
      this.worker.postMessage({ type: "call-reply", id: msg.id, ...reply });
    }
  }

  /** A reply too big for the channel (an image, D40) goes in pieces the worker asks for. */
  private bigReply: Uint8Array | null = null;

  private replySync(reply: unknown) {
    this.syncPending = false;
    let bytes = encoder.encode(JSON.stringify(reply));
    if (bytes.length > CHANNEL_BYTES - 8) {
      this.bigReply = bytes;
      bytes = encoder.encode(JSON.stringify({ $size: bytes.length }));
    }
    this.writeChannel(bytes);
  }

  private replyChunk(offset: number) {
    const all = this.bigReply ?? new Uint8Array(0);
    const part = all.subarray(offset, offset + CHANNEL_BYTES - 8);
    if (offset + part.length >= all.length) this.bigReply = null;
    this.writeChannel(part);
  }

  private writeChannel(bytes: Uint8Array) {
    const ints = new Int32Array(this.channel!, 0, 2);
    new Uint8Array(this.channel!, 8).set(bytes);
    ints[1] = bytes.length;
    Atomics.store(ints, 0, 1);
    Atomics.notify(ints, 0);
  }

  private mountToken: string | null = null;
  private unmounted: Promise<string[]> | null = null;

  /** Use a project folder (an app path) as the program's files: the host
   * mounts it (a linked folder via a local copy), and the next run sees it at
   * its cwd. */
  async attach(path: string, share?: string) {
    // `share`: another worker's mount of the folder, whose staged copy of a
    // linked folder this one uses too (child processes, D47).
    const { token } = await call<{ token: string; staged: boolean }>("hostfs.mount", { path, ...(share ? { share } : {}) });
    this.mountToken = token;
    this.attachedPath = path;
  }

  /** This worker's mount, for child processes to share. */
  get mountTokenForSharing() {
    return this.mountToken ?? undefined;
  }

  /** Start as a child process of `procs` (D47): its task, in the shared folder. */
  startProcess(init: Record<string, unknown>) {
    this.worker.postMessage({ type: "process", mount: this.mountToken, ...init });
  }

  run(code: string, options: RunOptions = {}): Promise<RunResult> {
    if (this.current) throw new Error("already running");
    if (this.interrupt) Atomics.store(this.interrupt, 0, 0);
    this.procs ??= new ProcessTree(this);
    this.procs.runStarted(options.cwd);
    const procs = this.procs.root === this ? this.procs.init() : undefined;
    return new Promise((resolve) => {
      this.current = resolve;
      this.worker.postMessage({ type: "run", code, mount: this.mountToken, ...options, procs });
    });
  }

  /** Deliver a signal to the program (Pause, breakpoint updates). */
  signal(signal: number) {
    if (!this.interrupt || this.dead) return false;
    Atomics.store(this.interrupt, 0, signal);
    Atomics.notify(this.interrupt, 0);
    return true;
  }

  private syncs = new Map<number, () => void>();
  private nextSync = 0;

  /** The program's queued writes reach the host, and a linked folder's copy
   * goes back to it. Resolves with the files changed since the last sync (app
   * paths); the host also tells the app's views about them. */
  async syncFiles(timeoutMs = 1000): Promise<string[]> {
    if (!this.dead) {
      const id = this.nextSync++;
      await new Promise<void>((resolve) => {
        const timer = setTimeout(() => {
          this.syncs.delete(id);
          resolve();
        }, timeoutMs);
        this.syncs.set(id, () => {
          clearTimeout(timer);
          resolve();
        });
        this.worker.postMessage({ type: "sync", id });
      });
    }
    if (!this.mountToken) return [];
    return call<string[]>("hostfs.sync", { token: this.mountToken }).catch(() => []);
  }

  /** Flush, end the worker and unmount its folder: every file the program
   * changed while it was mounted (app paths). */
  async release(): Promise<string[]> {
    await this.syncFiles();
    this.terminate("done");
    return this.unmounted ?? [];
  }

  sendUIEvent(id: string, args: string) {
    this.worker.postMessage({ type: "ui-event", id, args });
  }

  private finish(result: RunResult) {
    if (this.stopTimer) clearInterval(this.stopTimer);
    this.stopTimer = null;
    const done = this.current;
    this.current = null;
    done?.(result);
  }

  /** KeyboardInterrupt, re-asserted until the run ends; kill after killAfterMs (D11). */
  stop(killAfterMs = 1500) {
    // The program's child processes get SIGINT too (D47), after it.
    const tree = this.procs?.root === this ? this.procs : null;
    if (!this.current) {
      tree?.stop();
      return;
    }
    if (!this.interrupt) {
      this.terminate("killed");
      return;
    }
    const assert = () => {
      Atomics.store(this.interrupt!, 0, 2);
      Atomics.notify(this.interrupt!, 0);
      if (this.syncPending) this.replySync({ interrupted: true });
    };
    assert();
    tree?.stop();
    if (this.stopTimer) return;
    const started = performance.now();
    this.stopTimer = setInterval(() => {
      if (performance.now() - started > killAfterMs) this.terminate("Killed: the program did not respond to Stop");
      else assert();
    }, 50);
  }

  terminate(reason = "terminated") {
    this.dead = true;
    this.worker.terminate();
    this.detachRelay();
    this.releaseMemory();
    this.unmount();
    this.procs?.workerGone(this);
    this.finish({ ok: false, error: reason, ms: 0, killed: true });
  }

  /** The ended worker's heap no longer counts against the budget. */
  private releaseMemory() {
    if (this.memorySlot < 0 || !memory) return;
    Atomics.sub(memory, 0, Atomics.exchange(memory, this.memorySlot, 0));
    freeSlots.push(this.memorySlot);
    this.memorySlot = -1;
  }

  private detachRelay() {
    if (this.relayChannel) relay?.postMessage({ type: "detach", channel: this.relayChannel });
    this.relayChannel = null;
  }

  private unmount() {
    // Writes still queued in the worker are lost, as in a crash.
    if (this.mountToken && !this.unmounted) {
      this.unmounted = call<string[]>("hostfs.unmount", { token: this.mountToken }).catch(() => []);
    }
  }
}

/**
 * Keeps a booted worker in reserve so a fresh run starts instantly: one for
 * the default Python, and one for the last other Python a program used.
 */
export class WorkerPool {
  private spares = new Map<string, PyWorker>();

  constructor() {
    this.spare(getDefaultPython());
  }

  /** The default runtime's spare (its boot time is shown in Settings). */
  get spareReady() {
    return this.spare(getDefaultPython()).ready;
  }

  private spare(python: string) {
    let worker = this.spares.get(python);
    if (!worker || worker.dead) {
      worker = new PyWorker(python);
      this.spares.set(python, worker);
    }
    return worker;
  }

  /** Only the default's spare and the one for `keep` stay. */
  private trim(keep: string) {
    for (const [python, worker] of this.spares) {
      if (python !== keep && python !== getDefaultPython()) {
        worker.terminate("unused");
        this.spares.delete(python);
      }
    }
  }

  /** The default changed (Settings). */
  setDefault(python: string) {
    this.spare(python);
    this.trim(python);
  }

  async take(python = getDefaultPython()): Promise<PyWorker> {
    const worker = this.spare(python);
    this.spares.delete(python);
    this.spare(python);
    this.trim(python);
    await worker.ready;
    return worker;
  }
}
