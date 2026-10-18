// The page: the process manager in WKWebView. Every process is a module
// worker with its own Pyodide. Runs the tests (harness.js) and reports JSON
// to the host. Options in the hash: tests=t_basic,t_pool&warm=2&preload=1
import { runTests } from "./harness.js";
import { Manager, PRELOAD } from "./procs-manager.js";

const post = (op, fields = {}) => window.webkit.messageHandlers.bridge.postMessage({ op, ...fields });
const log = (text) => post("log", { value: text });
const text = async (url) => {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url}: ${res.status}`);
  return res.text();
};

async function main() {
  const params = new URLSearchParams(location.hash.slice(1));
  const warm = Number(params.get("warm") ?? 2);
  const preload = params.get("preload") !== "0";
  const base = new URL("pyodide/", location.href).href;
  const manager = new Manager({
    createWorker() {
      const w = new Worker("worker.js", { type: "module" });
      const handle = { post: (m) => w.postMessage(m), terminate: () => w.terminate(), onmessage: null };
      w.onmessage = (e) => handle.onmessage?.(e.data);
      w.onerror = (e) => handle.onmessage?.({ type: "fatal", error: `${e.message} (${e.filename}:${e.lineno})` });
      return handle;
    },
    boot: {
      moduleURL: base + "pyodide.mjs",
      indexURL: base,
      packageBaseUrl: new URL("pkgs/", location.href).href,
      runtime: { "_terrarium_procs.py": await text("_terrarium_procs.py") },
      preload: preload ? PRELOAD : [],
    },
    cpuCount: navigator.hardwareConcurrency || 1,
    warm,
    log,
  });
  for (const name of JSON.parse(await text("tests/index.json"))) {
    manager.files[`/home/pyodide/project/${name}`] = await text(`tests/${name}`);
  }
  const result = await runTests(manager, { only: params.get("tests"), log });
  result.environment = {
    userAgent: navigator.userAgent,
    hardwareConcurrency: navigator.hardwareConcurrency,
    crossOriginIsolated: self.crossOriginIsolated,
    pyodide: params.get("pyodide"),
    warm,
    preload,
  };
  manager.shutdown();
  await post("result", { value: JSON.stringify(result, null, 2) });
  document.getElementById("out").textContent = JSON.stringify(result, null, 2);
}

main().catch(async (e) => {
  await post("result", { value: JSON.stringify({ error: String(e?.message ?? e), stack: String(e?.stack) }) });
});
