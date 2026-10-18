// Runs the spike's tests in Node: each process is a worker_threads worker
// with its own Pyodide. Fast to iterate on; the iOS run is ../run.sh.
//
//   node node/run.mjs [t_basic,t_pool,...]
//   PYODIDE=315.0.0-alpha.2 WARM=4 node node/run.mjs
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { Worker } from "node:worker_threads";
import { runTests } from "../web/harness.js";
import { Manager, PRELOAD } from "../web/procs-manager.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const web = path.join(here, "..", "web");
const version = process.env.PYODIDE ?? "314.0.7";
const pyodideDir = path.resolve(here, `../../../app/vendor/pyodide-${version}`) + "/";
const pkgs = path.resolve(here, `../build/pkgs-${version}`) + "/";

const read = (p) => fs.readFileSync(p, "utf8");
const boot = {
  moduleURL: pathToFileURL(pyodideDir + "pyodide.mjs").href,
  indexURL: pyodideDir,
  packageBaseUrl: fs.existsSync(pkgs) ? pkgs : undefined,
  runtime: { "_terrarium_procs.py": read(path.join(web, "_terrarium_procs.py")) },
  preload: process.env.PRELOAD === "0" ? [] : PRELOAD,
};

const manager = new Manager({
  createWorker() {
    const w = new Worker(new URL("../web/worker.js", import.meta.url));
    const handle = { post: (m) => w.postMessage(m), terminate: () => w.terminate(), onmessage: null };
    w.on("message", (m) => handle.onmessage?.(m));
    w.on("error", (e) => handle.onmessage?.({ type: "fatal", error: String(e?.stack ?? e) }));
    return handle;
  },
  boot,
  cpuCount: os.availableParallelism(),
  warm: Number(process.env.WARM ?? 2),
  log: (line) => process.stderr.write(line + "\n"),
});
for (const name of fs.readdirSync(path.join(web, "tests"))) {
  if (name.endsWith(".py")) manager.files[`/home/pyodide/project/${name}`] = read(path.join(web, "tests", name));
}

const result = await runTests(manager, {
  only: process.argv[2],
  log: (l) => process.stderr.write(l + "\n"),
  memory: () => process.memoryUsage().rss,
});
result.environment = { runtime: "node " + process.version, pyodide: version, cpuCount: os.availableParallelism(), warm: manager.warm, preload: boot.preload.length > 0 };
console.log(JSON.stringify(result, null, 2));
manager.shutdown();
process.exit(result.failures.length ? 1 : 0);
