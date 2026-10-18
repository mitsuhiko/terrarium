// A minimal Python worker for the playground. It exposes the same `_uihost`
// module as app/web/public/runtime/py-worker.js (render + set_dispatcher), so
// ui.py runs here exactly as it would in the app.
let py = null;
let dispatcher = null;

function out(stream, text) {
  postMessage({ type: "output", stream, text });
}

async function boot({ indexURL, packageBaseUrl, uiUrl }) {
  const t0 = performance.now();
  const { loadPyodide } = await import(new URL("pyodide.mjs", indexURL).href);
  py = await loadPyodide({
    indexURL,
    packageBaseUrl,
    env: { MPLBACKEND: "agg" },
    stdout: (s) => out("stdout", s + "\n"),
    stderr: (s) => out("stderr", s + "\n"),
  });
  py.registerJsModule("_uihost", {
    render: (json) => postMessage({ type: "ui-render", tree: json }),
    set_dispatcher: (fn) => {
      dispatcher?.destroy?.();
      dispatcher = fn;
    },
  });
  py.FS.mkdirTree("/lib/terrarium");
  py.FS.writeFile("/lib/terrarium/ui.py", new Uint8Array(await (await fetch(uiUrl)).arrayBuffer()));
  py.runPython("import sys\nsys.path.append('/lib/terrarium')");
  postMessage({ type: "ready", bootMs: performance.now() - t0, version: py.version });
}

async function run({ code, filename }) {
  const t0 = performance.now();
  try {
    await py.loadPackagesFromImports(code, { messageCallback: () => {}, errorCallback: (m) => out("stderr", m + "\n") });
    await py.runPythonAsync(code, { filename });
    postMessage({ type: "done", ok: true, ms: performance.now() - t0 });
  } catch (e) {
    out("stderr", String(e.message ?? e) + "\n");
    postMessage({ type: "done", ok: false, ms: performance.now() - t0 });
  }
}

onmessage = async (e) => {
  const msg = e.data;
  if (msg.type === "boot") await boot(msg);
  else if (msg.type === "run") await run(msg);
  else if (msg.type === "ui-event") dispatcher?.(msg.id, msg.args);
  else if (msg.type === "eval") {
    // Selftest helper: evaluate Python and return repr.
    try {
      const v = await py.runPythonAsync(msg.code);
      postMessage({ type: "eval-result", id: msg.id, value: v?.toJs ? v.toJs() : v });
    } catch (err) {
      postMessage({ type: "eval-result", id: msg.id, error: String(err.message ?? err) });
    }
  }
};
