// One process = one Pyodide worker (spike). Runs in a browser worker or a
// Node worker thread.
//   boot:  load Pyodide (this is what the warm pool does ahead of time)
//   start: become process `pid`: shared objects, files, packages, install
//          _terrarium_procs, run the task, report the exit code
import "./sab-polyfill.js";
import { createProcs } from "./procs-worker.js";

const isNode = typeof process === "object" && !!process.versions?.node;
let post;
if (isNode) {
  const { parentPort } = process.getBuiltinModule("node:worker_threads");
  post = (msg) => parentPort.postMessage(msg);
  parentPort.on("message", (msg) => handle(msg));
} else {
  post = (msg) => self.postMessage(msg);
  self.onmessage = (e) => handle(e.data);
}

let py;
let boot;

async function handle(msg) {
  try {
    if (msg.type === "boot") await onBoot(msg);
    else if (msg.type === "start") await onStart(msg);
  } catch (e) {
    post({ type: "fatal", error: String(e?.stack ?? e) });
  }
}

async function onBoot(msg) {
  boot = msg;
  // As in the app (D13): hide the iOS user agent (wasm-gc trampoline), no JSPI.
  if (!isNode) {
    Object.defineProperty(navigator, "userAgent", { value: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)" });
    delete WebAssembly.Suspending;
    delete WebAssembly.promising;
  }
  const { loadPyodide } = await import(msg.moduleURL);
  py = await loadPyodide({
    indexURL: msg.indexURL,
    packageBaseUrl: msg.packageBaseUrl,
    env: { HOME: "/home/pyodide", PYTHONDONTWRITEBYTECODE: "1" },
  });
  py.FS.mkdirTree("/lib/terrarium");
  for (const [name, text] of Object.entries(msg.runtime)) py.FS.writeFile(`/lib/terrarium/${name}`, text);
  // Like forkserver's preload: a warm worker imports what a spawned child
  // will need anyway (the patches are applied at start, D: lazy hooks).
  let preloadMs = 0;
  if (msg.preload?.length) {
    const t = performance.now();
    py.runPython(msg.preload.map((m) => `import ${m}`).join("\n"));
    preloadMs = round(performance.now() - t);
  }
  post({ type: "booted", wasmBytes: py._module.HEAP8.length, preloadMs });
}

async function onStart(msg) {
  const t0 = performance.now();
  const { pid, ppid, task } = msg;
  const out = (stream) => ({ batched: (text) => post({ type: "output", stream, text: text + "\n" }) });
  py.setStdout(out("stdout"));
  py.setStderr(out("stderr"));
  py.setInterruptBuffer(new Int32Array(boot.interrupt));
  const objects = new Map(msg.objects);
  const procs = createProcs({ py, post, control: boot.control, interrupt: boot.interrupt, objects, pid, ppid, cpuCount: msg.cpuCount });
  py.registerJsModule("_procs", procs.api);
  for (const [path, text] of Object.entries(msg.files)) {
    py.FS.mkdirTree(path.slice(0, path.lastIndexOf("/")));
    py.FS.writeFile(path, text);
  }
  const t1 = performance.now();
  // Children load what their parent had loaded; the root what its imports
  // need (as the app does before a run).
  if (msg.packages?.length) await py.loadPackage(msg.packages, { messageCallback: () => {} });
  if (task.kind === "main") await py.loadPackagesFromImports(py.FS.readFile(task.path, { encoding: "utf8" }), { messageCallback: () => {} });
  const t2 = performance.now();
  py.runPython("import sys; sys.path.insert(0, '/lib/terrarium'); import _terrarium_procs; _terrarium_procs.install()");
  const t3 = performance.now();
  post({ type: "started", setupMs: round(t1 - t0 + (t3 - t2)), packagesMs: round(t2 - t1), installMs: round(t3 - t2) });
  const runTask = py.pyimport("_terrarium_procs").run_task;
  let code;
  try {
    code = runTask(JSON.stringify(task), msg.payload ?? undefined);
  } catch (e) {
    // Stop landed before run_task's own handler: killed by SIGINT.
    if (e?.type !== "KeyboardInterrupt") throw e;
    code = -2;
  }
  post({ type: "exit", code });
}

const round = (x) => Math.round(x * 10) / 10;
