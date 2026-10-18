// One Pyodide interpreter per worker (D6). The page talks to it with messages.
// Blocking calls back to the page (stdin, host.call_sync, time.sleep) use a
// SharedArrayBuffer channel and Atomics.wait (D13). Errors escaping Pyodide are
// reported as crashes (D16).
import "./sab-polyfill.js";
import { createHostFS } from "./hostfs.js";
import { createProcs } from "./procs-worker.js";
import { createRelayClient } from "./relay-client.js";

// HTTP for Python programs (D25): cross-origin XHR and fetch go through the
// host's /__http proxy, which makes the request natively (no CORS). requests
// (urllib3's Pyodide backend), urllib (pyodide-http) and pyfetch all use these.
// A synchronous XHR to the proxy goes through the fetch relay instead (Q25,
// D48): WebKit sometimes answers a worker's synchronous XHR a second late.
{
  const PROXY = new URL("/__http", location.href).href;
  // Headers scripts may not set; the proxy sets them for us.
  const FORBIDDEN = new Set(["user-agent", "cookie", "referer", "origin", "host", "connection", "accept-encoding", "content-length"]);
  const proxied = (url) => {
    try {
      const u = new URL(url, location.href);
      return (u.protocol === "http:" || u.protocol === "https:") && u.origin !== location.origin ? `${PROXY}?url=${encodeURIComponent(u.href)}` : null;
    } catch {
      return null;
    }
  };
  const networkError = (message) => new DOMException(`Network error: ${message}`, "NetworkError");

  const NativeXHR = self.XMLHttpRequest;
  const encoder = new TextEncoder();
  /** A request body as bytes, and the Content-Type it implies (as XHR does). */
  const bodyBytes = (body) => {
    if (body == null) return [null, null];
    if (typeof body === "string") return [encoder.encode(body), "text/plain;charset=UTF-8"];
    if (body instanceof URLSearchParams) return [encoder.encode(body.toString()), "application/x-www-form-urlencoded;charset=UTF-8"];
    if (body instanceof ArrayBuffer) return [new Uint8Array(body), null];
    if (ArrayBuffer.isView(body)) return [new Uint8Array(body.buffer, body.byteOffset, body.byteLength), null];
    if (body instanceof Blob) return [new Uint8Array(new FileReaderSync().readAsArrayBuffer(body)), body.type || null];
    return [encoder.encode(String(body)), "text/plain;charset=UTF-8"];
  };
  /** The charset of a Content-Type ("x-user-defined" keeps bytes as chars). */
  const charset = (type) => /;\s*charset="?([^";]+)/i.exec(type ?? "")?.[1] ?? "utf-8";

  self.XMLHttpRequest = class extends NativeXHR {
    open(method, url, async = true, ...rest) {
      this._via = proxied(url);
      this._hidden = {};
      this._sync = async === false;
      // Blocking and proxied: the fetch relay makes it (send below). The
      // native request stays unopened; the getters below answer instead.
      this._relay = this._via && this._sync && fetchSync ? { method: String(method).toUpperCase(), headers: {}, mime: null, done: null } : null;
      if (this._relay) return;
      return super.open(method, this._via ?? url, async, ...rest);
    }
    setRequestHeader(name, value) {
      if (this._via && FORBIDDEN.has(name.toLowerCase())) this._hidden[name] = value;
      else if (this._relay) this._relay.headers[name] = this._relay.headers[name] != null ? `${this._relay.headers[name]}, ${value}` : String(value);
      else super.setRequestHeader(name, value);
    }
    overrideMimeType(mime) {
      if (this._relay) this._relay.mime = mime;
      else super.overrideMimeType(mime);
    }
    send(body) {
      if (this._relay) return this._sendRelayed(body);
      if (this._via && Object.keys(this._hidden).length) super.setRequestHeader("X-Terrarium-Headers", JSON.stringify(this._hidden));
      super.send(body);
      const error = this._via && this._sync ? this.getResponseHeader("X-Terrarium-Error") : null;
      if (error) throw networkError(error);
    }
    _sendRelayed(body) {
      const relay = this._relay;
      const headers = { ...relay.headers };
      if (Object.keys(this._hidden).length) headers["X-Terrarium-Headers"] = JSON.stringify(this._hidden);
      const [bytes, type] = ["GET", "HEAD"].includes(relay.method) ? [null, null] : bodyBytes(body);
      if (type && !Object.keys(headers).some((h) => h.toLowerCase() === "content-type")) headers["Content-Type"] = type;
      let response;
      try {
        response = fetchSync(this._via, { method: relay.method, headers, body: bytes, timeout: this.timeout || 0 });
      } catch (e) {
        if (e.timeout) throw new DOMException("The request timed out", "TimeoutError");
        throw networkError(e.message.replace(/^Network error: /, ""));
      }
      if (response.headers["x-terrarium-error"]) throw networkError(response.headers["x-terrarium-error"]);
      relay.done = response;
      self._terrariumRelayedRequests = (self._terrariumRelayedRequests ?? 0) + 1; // for the self-test
      for (const type of ["readystatechange", "load", "loadend"]) this.dispatchEvent(new ProgressEvent(type));
    }
    _text() {
      const { done, mime } = this._relay;
      return new TextDecoder(charset(mime ?? done.headers["content-type"])).decode(done.body);
    }
    get readyState() {
      return this._relay ? (this._relay.done ? 4 : 1) : super.readyState;
    }
    get status() {
      return this._relay ? (this._relay.done?.status ?? 0) : super.status;
    }
    get statusText() {
      return this._relay ? (this._relay.done?.statusText ?? "") : super.statusText;
    }
    get response() {
      if (!this._relay) return super.response;
      const done = this._relay.done;
      if (!done) return this.responseType === "" || this.responseType === "text" ? "" : null;
      switch (this.responseType) {
        case "arraybuffer":
          return done.body.slice().buffer;
        case "blob":
          return new Blob([done.body], { type: this._relay.mime ?? done.headers["content-type"] ?? "" });
        case "json":
          try {
            return JSON.parse(this._text());
          } catch {
            return null;
          }
        case "document":
          return null;
        default:
          return this._text();
      }
    }
    get responseText() {
      if (!this._relay) return super.responseText;
      return this._relay.done ? this._text() : "";
    }
    get responseXML() {
      return this._relay ? null : super.responseXML;
    }
    getResponseHeader(name) {
      if (!this._relay) return super.getResponseHeader(name);
      return this._relay.done?.headers[String(name).toLowerCase()] ?? null;
    }
    getAllResponseHeaders() {
      if (!this._relay) return super.getAllResponseHeaders();
      const headers = this._relay.done?.headers ?? {};
      return Object.entries(headers).filter(([name]) => !name.startsWith("x-terrarium-")).map(([name, value]) => `${name}: ${value}\r\n`).join("");
    }
    get responseURL() {
      if (this._relay) return this._relay.done?.headers["x-terrarium-final-url"] ?? "";
      return (this._via && this.getResponseHeader("X-Terrarium-Final-Url")) || super.responseURL;
    }
  };

  const nativeFetch = self.fetch.bind(self);
  /** Header pairs as given (Request and Headers objects drop forbidden ones). */
  const rawHeaders = (h) => {
    if (!h) return [];
    if (h instanceof Map) return [...h];
    if (Array.isArray(h)) return h;
    if (typeof h.entries === "function" && !(h.constructor === Object)) return [...h.entries()];
    return Object.entries(h);
  };
  self.fetch = async (input, init) => {
    const request = new Request(input, init);
    const via = proxied(request.url);
    if (!via) return nativeFetch(request);
    const headers = new Headers(request.headers);
    const hidden = {};
    for (const [name, value] of rawHeaders(init?.headers)) if (FORBIDDEN.has(String(name).toLowerCase())) hidden[name] = String(value);
    if (Object.keys(hidden).length) headers.set("X-Terrarium-Headers", JSON.stringify(hidden));
    const body = ["GET", "HEAD"].includes(request.method) ? undefined : await request.arrayBuffer();
    const response = await nativeFetch(via, { method: request.method, headers, body, signal: request.signal, redirect: "follow" });
    const error = response.headers.get("X-Terrarium-Error");
    if (error) throw new TypeError(`Network error: ${error}`);
    const final = response.headers.get("X-Terrarium-Final-Url");
    if (final) Object.defineProperty(response, "url", { value: final });
    return response;
  };
}

const decoder = new TextDecoder();
let py;
let syncChannel; // Int32Array view: [state, length], payload from byte 8
let nextCallId = 0;
const pendingCalls = new Map();
let uiDispatcher = null;
let hostfs = null; // the project folder (D35); its write-behind queue is flushed by flushFiles()
let mounted = null; // {token, cwd}
let flushTimer = null;
let plumbing; // a private namespace for our own Python, so the program's globals stay clean
let interruptBuffer = null; // the SharedArrayBuffer behind Stop and the debugger's signals
let procs = null; // this interpreter as a process (D47): _procs and _terrarium_procs are installed
let fetchSync = null; // blocking requests through the page's fetch relay (Q25); null: synchronous XHR

// Turtle graphics (D29): ops from _terrarium_turtle.py, sent to the page at most
// every 16 ms, and always before the program blocks, sleeps or prints (so the
// console keeps the order) and when it ends.
let turtleBatches = [];
let turtleSentAt = 0;
function flushTurtle() {
  if (turtleBatches.length) {
    postMessage({ type: "turtle", batches: turtleBatches });
    turtleBatches = [];
  }
  turtleSentAt = performance.now();
}
let measureContext;
/** A 2D context for measuring text and parsing colors (null if unavailable). */
function context2d() {
  if (measureContext === undefined) {
    try {
      measureContext = new OffscreenCanvas(1, 1).getContext("2d");
    } catch {
      measureContext = null;
    }
  }
  return measureContext;
}

/** Run our own setup code without touching the program's namespace (__main__). */
function runPlumbing(code) {
  py.runPython(code, { globals: plumbing });
}
/** Send the program's queued file writes to the host (before it blocks or
 * sleeps, while it idles, when it ends). */
function flushFiles() {
  try {
    hostfs?.flush();
  } catch (e) {
    postMessage({ type: "output", stream: "stderr", text: `Could not save files: ${e.message ?? e}\n` });
  }
}

function syncCall(op, value) {
  if (!syncChannel) throw new Error(`blocking call '${op}' needs cross-origin isolation`);
  flushTurtle();
  flushFiles();
  const ints = new Int32Array(syncChannel, 0, 2);
  Atomics.store(ints, 0, 0);
  postMessage({ type: "call", sync: true, op, value });
  Atomics.wait(ints, 0, 0);
  const bytes = new Uint8Array(syncChannel, 8, ints[1]).slice();
  let reply = JSON.parse(decoder.decode(bytes));
  if (reply.$size !== undefined) {
    // Too big for the channel: fetch it in pieces.
    const all = new Uint8Array(reply.$size);
    for (let offset = 0; offset < all.length; ) {
      Atomics.store(ints, 0, 0);
      postMessage({ type: "call", sync: true, op: "chunk", value: { offset } });
      Atomics.wait(ints, 0, 0);
      const n = ints[1];
      if (!n) break;
      all.set(new Uint8Array(syncChannel, 8, n), offset);
      offset += n;
    }
    reply = JSON.parse(decoder.decode(all));
  }
  if (reply.interrupted) {
    py.checkInterrupt(); // raises KeyboardInterrupt if the page set the interrupt buffer
    return null;
  }
  if (reply.error) throw new Error(reply.error);
  return reply.value;
}

function asyncCall(op, value) {
  const id = nextCallId++;
  return new Promise((resolve, reject) => {
    pendingCalls.set(id, { resolve, reject });
    postMessage({ type: "call", sync: false, id, op, value });
  });
}

// When Pyodide fails (a native stack overflow, D16), it says so on the
// console and then prints the Python stack to stdout (_dump_traceback). That
// stack goes with the crash report (worker-error) instead of the console: the
// page shows it as a traceback (D49).
let fatal = null; // {dump} once Pyodide has failed
const consoleError = console.error.bind(console);
console.error = (...args) => {
  if (typeof args[0] === "string" && args[0].startsWith("Pyodide has suffered a fatal error")) fatal ??= { dump: "" };
  consoleError(...args);
};

/**
 * The Python stack of the thread state that was running when Pyodide failed,
 * in _dump_traceback's format (most recent call first). Pyodide's own dump
 * shows the main thread state, but a program runs in its task's (JSPI), so
 * walk that one with the C API. Null if that fails (a wasm trap is caught).
 */
function crashedStack() {
  const m = py._module;
  const allocated = [];
  const cString = (s) => {
    const bytes = new TextEncoder().encode(`${s}\0`);
    const p = m._malloc(bytes.length);
    m.HEAPU8.set(bytes, p);
    allocated.push(p);
    return p;
  };
  const jsString = (p) => {
    if (!p) return "?";
    const heap = m.HEAPU8;
    let end = p;
    while (heap[end]) end++;
    return decoder.decode(heap.subarray(p, end));
  };
  try {
    const names = { file: cString("co_filename"), name: cString("co_qualname") };
    const attr = (code, name) => {
      const value = m._PyObject_GetAttrString(code, name);
      if (!value) return "?";
      const text = jsString(m._PyUnicode_AsUTF8(value));
      m._Py_DecRef(value);
      return text;
    };
    const stack = (tstate) => {
      const lines = ["Stack (most recent call first):"];
      let frame = m._PyThreadState_GetFrame(tstate);
      for (let n = 0; frame && n < 20000; n++) {
        const code = m._PyFrame_GetCode(frame);
        lines.push(`  File "${attr(code, names.file)}", line ${m._PyFrame_GetLineNumber(frame)} in ${attr(code, names.name)}`);
        m._Py_DecRef(code);
        const back = m._PyFrame_GetBack(frame);
        m._Py_DecRef(frame);
        frame = back;
      }
      if (frame) lines.push("  ...");
      return lines;
    };
    // Every task has its own thread state: the deepest stack is the one that overflowed.
    let deepest = [];
    for (let t = m._PyInterpreterState_ThreadHead(m._PyInterpreterState_Main()); t; t = m._PyThreadState_Next(t)) {
      const lines = stack(t);
      if (lines.length > deepest.length) deepest = lines;
    }
    m._PyErr_Clear();
    return deepest.length > 1 ? deepest.join("\n") : null;
  } catch {
    return null;
  } finally {
    for (const p of allocated) m._free(p);
  }
}

function writer(stream) {
  return {
    write(buf) {
      if (fatal) {
        fatal.dump += decoder.decode(buf);
        return buf.length;
      }
      if (turtleBatches.length) flushTurtle();
      postMessage({ type: "output", stream, text: decoder.decode(buf) });
      return buf.length;
    },
  };
}

/**
 * Memory (D50): the heaps of all Python workers of the page share a budget
 * (python.ts). Growing this interpreter's heap past it fails, as if the
 * device had no more memory: malloc returns NULL and Python raises
 * MemoryError, instead of iOS ending the web content process.
 */
function limitMemory({ buffer, slot }) {
  const ints = new Int32Array(buffer);
  const grow = WebAssembly.Memory.prototype.grow;
  let heap = null; // the first memory that grows: Pyodide's
  WebAssembly.Memory.prototype.grow = function (delta) {
    if (heap === null) {
      heap = this;
      const pages = this.buffer.byteLength / 65536;
      Atomics.add(ints, 0, pages);
      Atomics.add(ints, slot, pages);
    }
    if (this !== heap || !(delta > 0)) return grow.call(this, delta);
    const budget = Atomics.load(ints, 1);
    if (budget && Atomics.add(ints, 0, delta) + delta > budget) {
      Atomics.sub(ints, 0, delta);
      throw new RangeError("WebAssembly.Memory.grow(): over the memory budget for Python");
    } else if (!budget) {
      Atomics.add(ints, 0, delta);
    }
    try {
      const old = grow.call(this, delta);
      Atomics.add(ints, slot, delta);
      return old;
    } catch (e) {
      Atomics.sub(ints, 0, delta);
      throw e;
    }
  };
}

async function boot({ interrupt, channel, relay, memory, jspi, gcTrampoline, warm, indexURL, packageBaseUrl, pythonFiles, preload }) {
  syncChannel = channel;
  interruptBuffer = interrupt;
  if (memory) limitMemory(memory);
  if (relay) fetchSync = createRelayClient(relay);
  // CPython's Emscripten build falls back to a JS call trampoline on iOS, which
  // makes JSPI impossible; hiding the iOS UA selects the wasm-gc trampoline (D13).
  if (gcTrampoline) {
    Object.defineProperty(navigator, "userAgent", { value: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)" });
  }
  if (!jspi) {
    delete WebAssembly.Suspending;
    delete WebAssembly.promising;
  }
  const interruptInts = interrupt ? new Int32Array(interrupt) : null;
  const t0 = performance.now();
  const { loadPyodide } = await import(new URL("pyodide.mjs", indexURL).href);
  py = await loadPyodide({
    indexURL,
    packageBaseUrl,
    // Bytecode would land in the user's folders (__pycache__), next to their files.
    env: { HOME: "/home/pyodide", MPLBACKEND: "agg", PYTHONDONTWRITEBYTECODE: "1" },
    stdout: (s) => (flushTurtle(), postMessage({ type: "output", stream: "stdout", text: s + "\n" })),
    stderr: (s) => (flushTurtle(), postMessage({ type: "output", stream: "stderr", text: s + "\n" })),
  });
  py.setStdout(writer("stdout"));
  py.setStderr(writer("stderr"));
  py._api.on_fatal = () => {
    const stack = crashedStack();
    if (stack && fatal) fatal.dump = stack;
  };
  py.setStdin({ stdin: () => (syncChannel ? syncCall("stdin", null) ?? undefined : undefined) });
  if (interruptInts) py.setInterruptBuffer(interruptInts);
  py.registerJsModule("host", {
    call: (op, value) => asyncCall("host", { op, value: value?.toJs?.() ?? value }),
    call_sync: (op, value) => syncCall("host", { op, value: value?.toJs?.() ?? value }),
    // Sleeps without burning CPU; any signal wakes it early. KeyboardInterrupt
    // (Stop) is then raised by CPython's own signal check right after we
    // return, not thrown through JavaScript (which WebKit reports as an
    // uncaught worker error). _terrarium_debug wraps this into time.sleep.
    sleep: (seconds) => {
      flushTurtle();
      flushFiles();
      Atomics.wait(interruptInts, 0, 0, Math.max(0, seconds * 1000));
      // Woken by Pause or a breakpoint update: run that handler now, before
      // the sleep loop waits again (CPython only polls the buffer now and then).
      const signal = Atomics.load(interruptInts, 0);
      if (signal !== 0 && signal !== 2) py.checkInterrupt();
    },
  });
  py.registerJsModule("_terrariumhost", {
    image: (b64) => postMessage({ type: "output", stream: "image", text: b64 }),
    // Rich outputs and errors of notebook cells, display() (D44): JSON.
    display: (json) => (flushTurtle(), postMessage({ type: "display", json })),
    status: (text) => postMessage({ type: "output", stream: "system", text: text + "\n" }),
    // The debugger's blocking round trip (_terrarium_debug.py); null when interrupted.
    debug: (json) => {
      const reply = syncCall("debug", JSON.parse(json));
      return reply == null ? null : JSON.stringify(reply);
    },
    turtle: (json) => {
      turtleBatches.push(json);
      if (performance.now() - turtleSentAt > 16) flushTurtle();
    },
    // Events (waiting up to `wait` ms for one) and dialogs; null when interrupted.
    // The device modules (clipboard, dialogs, photos, ..., D40): one blocking
    // call into the app per function. The mount token lets the host find the
    // program's files; null when interrupted (Stop).
    device: (json) => {
      const request = JSON.parse(json);
      request.value = { ...(request.value ?? {}), _mount: mounted?.token ?? null };
      const reply = syncCall("host", request);
      return reply == null ? undefined : JSON.stringify(reply); // undefined is None (null would be JsNull)
    },
    turtle_call: (json) => {
      const reply = syncCall("turtle", JSON.parse(json));
      return reply === undefined ? null : JSON.stringify(reply);
    },
    measure_text: (font, text) => {
      const ctx = context2d();
      if (!ctx) return null;
      ctx.font = font;
      return ctx.measureText(text).width;
    },
    /** A CSS color as the canvas normalizes it ("#rrggbb"), or null if it is none. */
    css_color: (name) => {
      const ctx = context2d();
      if (!ctx) return name;
      ctx.fillStyle = "#010203";
      ctx.fillStyle = name;
      const a = ctx.fillStyle;
      ctx.fillStyle = "#040506";
      ctx.fillStyle = name;
      return a === ctx.fillStyle ? a : null;
    },
  });
  py.registerJsModule("_uihost", {
    render: (json) => postMessage({ type: "ui-render", tree: json }),
    set_dispatcher: (fn) => {
      uiDispatcher?.destroy?.();
      uiDispatcher = fn;
    },
  });
  // Our runtime modules live outside the project dir.
  py.FS.mkdirTree("/lib/terrarium");
  for (const [name, url] of Object.entries(pythonFiles ?? {})) {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`failed to fetch ${url}: ${res.status}`);
    py.FS.writeFile(`/lib/terrarium/${name}`, new Uint8Array(await res.arrayBuffer()));
  }
  plumbing = py.runPython("dict()");
  runPlumbing("import sys\nsys.path.append('/lib/terrarium')");
  // Deeper recursion through C code before the native stack runs out (D49).
  if (warm) runPlumbing("import _terrarium_warmup\n_terrarium_warmup.run()\ndel _terrarium_warmup, sys.modules['_terrarium_warmup']");
  runPlumbing([
    "import _terrarium, _terrarium_debug, _terrarium_notebook, _terrarium_traceback",
    interruptInts ? "import host\n_terrarium_debug.install(host.sleep)\ndel host" : "_terrarium_debug.install()",
  ].join("\n"));
  // A spare for child processes imports what a spawned child needs anyway
  // (like forkserver's preload, D47).
  if (preload?.length) runPlumbing(preload.map((m) => `import ${m}`).join("\n"));
  postMessage({
    type: "ready", bootMs: performance.now() - t0, version: py.version,
    jspi: typeof WebAssembly.Suspending, gcTrampoline: !!gcTrampoline, isolated: !!syncChannel,
  });
}

/** Mount the project folder (a HostFS mount token) at cwd. */
function mount(token, cwd) {
  if (mounted?.token === token && mounted.cwd === cwd) return;
  if (mounted) {
    flushFiles();
    py.FS.chdir("/");
    py.FS.unmount(mounted.cwd);
  }
  py.FS.mkdirTree(cwd);
  hostfs = createHostFS(py, token, fetchSync);
  py.FS.mount(hostfs, {}, cwd);
  mounted = { token, cwd };
}

/**
 * While the program idles (the timer only fires between Python's tasks),
 * queued writes go to the host, so a UI app's data reaches the disk within a
 * quarter second. A killed worker loses at most that.
 */
function startFlushing() {
  flushTimer ??= setInterval(flushFiles, 250);
}

/**
 * Call one of our runtime modules directly (awaiting coroutines), so nothing
 * passes through the program's namespace (where the debugger and >>> see it).
 */
async function callRuntime(module, name, ...args) {
  const mod = py.pyimport(module);
  try {
    const result = mod[name](...args);
    const value = result && typeof result.then === "function" ? await result : result;
    value?.destroy?.();
  } finally {
    mod.destroy();
  }
}

/** What a notebook cell is as Python (its magics as calls), for finding its imports. */
function cellPython(code) {
  const nb = py.pyimport("_terrarium_notebook");
  try {
    return nb.transform_cell(code);
  } catch {
    return "";
  } finally {
    nb.destroy();
  }
}

/** Make this interpreter process `pid` of a tree (D47): pipes, locks, waits
 * and the patched os, multiprocessing and subprocess. Once per worker. */
function installProcs({ control, pid, ppid, cpuCount, objects }) {
  if (procs || !control || !interruptBuffer) return;
  procs = createProcs({
    py, post: (msg) => postMessage(msg), control, interrupt: interruptBuffer,
    objects: new Map(objects ?? []), pid, ppid, cpuCount,
  });
  py.registerJsModule("_procs", procs.api);
  runPlumbing("import _terrarium_procs\n_terrarium_procs.install()");
}

async function run({ code, filename, cwd, mount: token, repl, cell, indexURL, breakpoints, procs: procsInit }) {
  const t0 = performance.now();
  try {
    runPlumbing("_terrarium_traceback.mark()");
    if (token && cwd) {
      mount(token, cwd);
      startFlushing();
    }
    if (procsInit) installProcs(procsInit);
    if (cwd) {
      py.FS.mkdirTree(cwd);
      py.FS.chdir(cwd);
      runPlumbing(`import sys\nif ${JSON.stringify(cwd)} not in sys.path: sys.path.insert(0, ${JSON.stringify(cwd)})\nsys.argv = [${JSON.stringify(filename ?? "")}]`);
    }
    const index = indexURL ?? new URL("/pypi/simple", location.href).href;
    if (cell) {
      // A notebook kernel's first cell (D44): the notebook's dependencies first.
      if (cell.prepare != null) await callRuntime("_terrarium", "prepare_environment", cell.prepare, cwd ?? "/home/pyodide", index);
    } else if (!repl) {
      // Declared dependencies (PEP 723 or pyproject.toml) first, then
      // Pyodide packages that are imported but not declared.
      await callRuntime("_terrarium", "prepare_environment", code, cwd ?? "/home/pyodide", index);
    }
    // A cell's magics are no Python; IPython is our shim, not Pyodide's package.
    const python = (cell ? cellPython(code) : code).replace(/^[ \t]*(import|from)[ \t]+IPython\b.*$/gm, "");
    // urllib.request has no Pyodide backend of its own: pyodide-http adds one (sync XHR).
    if (/^\s*(import|from)\s[^\n#]*\burllib\b/m.test(python)) {
      await py.loadPackage("pyodide-http");
      runPlumbing("import pyodide_http\npyodide_http.patch_urllib()");
    }
    // The device modules hand over images as PIL images (D40): Pillow comes along.
    if (/^\s*(import|from)\s[^\n#]*\b(photos|clipboard|location)\b/m.test(python)) {
      await py.loadPackage("pillow").catch(() => {}); // not every Python has it (3.15)
    }
    await py.loadPackagesFromImports(python, {
      messageCallback: (m) => m.startsWith("Loading ") && postMessage({ type: "output", stream: "system", text: m.replace(/^Loading /, "Loading packages: ") + "\n" }),
      errorCallback: (m) => postMessage({ type: "output", stream: "stderr", text: m + "\n" }),
    });
    // urllib3 drops User-Agent because browsers forbid setting it; our proxy
    // sets it (the XHR/fetch shim passes it along), so let it through.
    if (/\b(requests|urllib3)\b/.test(python)) {
      runPlumbing("try:\n    import urllib3.contrib.emscripten.fetch as _f\n    _f.HEADERS_TO_IGNORE = ()\nexcept ImportError:\n    pass");
    }
    if (cell) {
      await callRuntime("_terrarium_notebook", "run_cell", code, cell.count, index);
    } else if (repl) {
      await callRuntime("_terrarium", "repl", code);
    } else {
      // The script's path: multiprocessing's children import it from there (D47).
      if (filename && cwd) runPlumbing(`import __main__\n__main__.__file__ = ${JSON.stringify(`${cwd}/${filename}`)}`);
      await callRuntime("_terrarium_debug", "start", JSON.stringify(breakpoints ?? {}));
      try {
        try {
          const result = await py.runPythonAsync(code, { filename: filename ?? "<main>" });
          result?.destroy?.();
          // A turtle program with event handlers keeps running, as in IDLE.
          runPlumbing("import sys\nif '_terrarium_turtle' in sys.modules: sys.modules['_terrarium_turtle'].finish()");
        } finally {
          // What the interpreter would do at exit: join child processes. A ui
          // app hasn't exited; its processes live as long as it does.
          if (procs && !uiDispatcher) runPlumbing("_terrarium_procs.program_finished()");
        }
      } finally {
        await callRuntime("_terrarium_debug", "finished");
      }
    }
    finishTurtle();
    flushFiles();
    postMessage({ type: "done", ok: true, ms: performance.now() - t0 });
  } catch (e) {
    // The interpreter itself failed (in our own code, before or after the
    // program's): a crash, not the program's error.
    if (fatal) return reportEscaped(String(e.message ?? e));
    finishTurtle();
    flushFiles();
    postMessage({ type: "done", ok: false, error: String(e.message ?? e), trace: lastTrace(), ms: performance.now() - t0 });
  }
}

/**
 * Run as a child process (D47): the parent's project folder, its packages,
 * then the task (multiprocessing's spawn, or a Python subprocess). Reports
 * the exit code (negative: the signal that ended it).
 */
async function runProcess({ task, payload, packages, mount: token, cwd, indexURL, ...init }) {
  let code = 1;
  try {
    if (token && cwd) {
      mount(token, cwd);
      startFlushing();
    }
    if (cwd) {
      py.FS.mkdirTree(cwd);
      py.FS.chdir(cwd);
    }
    if (packages?.length) await py.loadPackage(packages, { messageCallback: () => {}, errorCallback: () => {} });
    installProcs(init);
    if (task.pypi?.length) {
      const index = indexURL ?? new URL("/pypi/simple", location.href).href;
      await callRuntime("_terrarium_procs", "install_pypi", JSON.stringify(task.pypi), index);
    }
    postMessage({ type: "process-started" });
    const mod = py.pyimport("_terrarium_procs");
    try {
      code = mod.run_task(JSON.stringify(task), payload ?? undefined);
    } catch (e) {
      // Stop landed before run_task's own handler: ended by SIGINT.
      if (e?.type !== "KeyboardInterrupt") throw e;
      code = -2;
    } finally {
      mod.destroy();
    }
  } catch (e) {
    if (fatal) return reportEscaped(String(e.message ?? e));
    postMessage({ type: "output", stream: "stderr", text: `${e.message ?? e}\n` });
  }
  flushFiles();
  postMessage({ type: "process-exit", code });
}

/** The run's uncaught exception as data (D45): JSON, or undefined. */
function lastTrace() {
  try {
    return py.runPython("_terrarium_traceback.last_json()", { globals: plumbing }) || undefined;
  } catch {
    return undefined; // the interpreter is gone (a crash)
  }
}

/** Send what the program drew last (also when it failed). */
function finishTurtle() {
  try {
    runPlumbing("import sys\nif '_terrarium_turtle' in sys.modules: sys.modules['_terrarium_turtle'].flush_all()");
  } catch {
    // the interpreter is unusable; nothing to send
  }
  flushTurtle();
}

// Errors escaping Pyodide are crashes (D16), except KeyboardInterrupt: it is a
// BaseException, so asyncio re-raises it out of the event loop after Stop.
let crashReported = false;
function reportEscaped(error) {
  if (/KeyboardInterrupt\s*$/.test(error.trim())) return;
  if (crashReported) return;
  crashReported = true;
  postMessage({ type: "worker-error", error, dump: fatal?.dump || undefined });
}
addEventListener("error", (e) => {
  // A plain Event (not an ErrorEvent) has no message: say where it came from.
  const where = e.message ?? `${e.type} event from ${e.target?.constructor?.name ?? "?"}${e.filename ? ` (${e.filename}:${e.lineno})` : ""}`;
  reportEscaped(String(where));
});
// An unhandled rejection is a crash only if it says the interpreter broke (a
// wasm trap, a stack overflow, Pyodide's fatal error). Libraries leave other
// rejections behind: urllib3 starts a helper worker for streaming downloads,
// which WebKit refuses with an error Event that nobody handles.
const FATAL = /fatal error|unreachable|out of bounds|call stack|RuntimeError|Aborted/i;
addEventListener("unhandledrejection", (e) => {
  e.preventDefault();
  const reason = e.reason;
  const message = reason instanceof Error ? `${reason.name}: ${reason.message}` : String(reason?.message ?? reason);
  if (reason instanceof Error && FATAL.test(message)) reportEscaped(message);
  else console.warn("unhandled rejection (ignored):", reason);
});

onmessage = async (e) => {
  const msg = e.data;
  switch (msg.type) {
    case "boot":
      try {
        await boot(msg);
      } catch (err) {
        postMessage({ type: "boot-failed", error: String(err.stack ?? err) });
      }
      break;
    case "run":
      await run(msg);
      break;
    case "process":
      await runProcess(msg);
      break;
    case "ui-event":
      if (uiDispatcher) uiDispatcher(msg.id, msg.args);
      break;
    case "sync":
      // Before a UI app closes or the app goes to the background.
      flushFiles();
      postMessage({ type: "synced", id: msg.id });
      break;
    case "call-reply": {
      const pending = pendingCalls.get(msg.id);
      pendingCalls.delete(msg.id);
      if (msg.error) pending.reject(new Error(msg.error));
      else pending.resolve(msg.value);
      break;
    }
  }
};
