// Engine page entry (D31): a web view without UI that runs Python (Pyodide
// workers, D6) and code analysis (ruff + ty, D21) for the native app. The host
// sends commands through window.__engine.command and gets state and events
// through the bridge.
import { analysis, setAnalysis } from "../analysis/api";
import { analysis as client } from "../analysis/client";
import { versionedAnalysis } from "../analysis/versioned";
import { breakpoints } from "../debug/breakpoints";
import { seedExamples } from "../examples";
import { call } from "../host";
import { chooseFor, forgetFolders, label, runtimeFor, setDefaultPython } from "../runtimes";
import { setMemoryBudget } from "../python";
import { session } from "../session";
import { turtleScenes, turtleSync, type TurtleEvent } from "../turtle";
import { startStateSync } from "./state";

setAnalysis(versionedAnalysis);

// UI apps (D26) are drawn natively (D30); ops go to the host as they come.
session.attachUI((json) => void call("ui.render", { json }).catch(() => {}));
(window as any).__terrariumUI = {
  event: (id: string, args: string) => session.sendUIEvent(id, args),
  close: () => session.closeUI(),
};

// Turtle screens are drawn natively too; the scenes here keep the events.
turtleSync.ops = (scene, ops) => void call("turtle.ops", { key: scene.key, ops: JSON.stringify(ops) }).catch(() => {});
turtleSync.state = (scene) =>
  void call("turtle.state", { key: scene.key, live: scene.live, active: scene.active, pointer: scene.listening.pointer, keys: scene.listening.keys }).catch(() => {});

breakpoints.onChange = (data) => void call("breakpoints.changed", { data }).catch(() => {});

// The coding agent (D34) loads on first use; the bundle is large and most
// launches don't need it. It also starts a few seconds after launch to pick
// up a turn an earlier page left running.
const AGENT_METHODS = new Set([
  "open", "newConversation", "switchTo", "rename", "archive", "importConversations", "renamed", "setVisible", "ideChanged",
  "submit", "abort", "setModel", "accounts", "availableModels", "login", "cancelLogin", "logout", "state", "demo",
]);
const loadAgent = () => import("../agent/service").then((m) => m.agent);

type Command = (args: any) => unknown;
const commands: Record<string, Command> = {
  // Runs end much later; the host follows them through the session state.
  runFile: ({ path, code }) => void session.runFile(path, code),
  runConsole: ({ source }) => void session.runConsole(source),
  // Notebook cells (D44): false when another program is running.
  runCells: ({ path, cells, source }) => session.runCells(path, cells ?? [], source ?? ""),
  restartKernel: ({ path }) => session.restartKernel(path),
  submitInput: ({ text }) => session.submitInput(text),
  stop: () => session.stop(),
  pause: () => session.pause(),
  resume: ({ op }) => session.resume(op),
  selectFrame: ({ index }) => session.selectFrame(index),
  debugVariables: ({ ref }) => session.debugVariables(ref),
  debugEvaluate: ({ expr }) => session.debugEvaluate(expr),
  debugConsole: ({ source }) => session.debugConsole(source),
  inspectError: ({ frame }) => void session.inspectError(frame ?? 0),
  clear: () => session.clear(),
  closeUI: () => session.closeUI(),
  uiEvent: ({ id, args }) => session.sendUIEvent(id, args),
  background: () => session.syncInBackground(),
  // Memory (D50): what Python's heaps may use together, and the console of a
  // page iOS ended (the host kept it).
  setMemoryBudget: ({ bytes }) => setMemoryBudget(Number(bytes) || 0),
  restoreSession: ({ json }) => session.restore(JSON.parse(json)),
  setBreakpoints: ({ data }) => breakpoints.replaceAll(data ?? {}),
  // Python versions (D37): the default from Settings, and which one a file runs on.
  setDefaultPython: ({ python }) => setDefaultPython(python),
  pythonFor: async ({ path, code }: { path: string; code?: string }) => {
    forgetFolders();
    const dir = path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";
    const choice = await chooseFor(dir, code);
    if (!choice.ok) return { error: choice.error };
    return { python: choice.python, version: runtimeFor(choice.python).version, label: label(choice.python), reason: choice.reason };
  },
  analysis: ({ method, args }) => (analysis as any)[method](...(args ?? [])),
  turtle: ({ key, event }: { key: string; event: TurtleEvent }) => turtleScenes.get(key)?.push(event),
  agent: async ({ method, args }: { method: string; args?: unknown[] }) => {
    if (!AGENT_METHODS.has(method)) throw new Error(`unknown agent method ${method}`);
    const agent = await loadAgent();
    return (agent as any)[method](...(args ?? []));
  },
};

(window as any).__engine = {
  command: async (name: string, args: unknown) => {
    const fn = commands[name];
    if (!fn) throw new Error(`unknown engine command ${name}`);
    const result = await fn(args ?? {});
    return result === undefined ? null : result;
  },
};
(window as any).__session = session; // debugging aid

await seedExamples();
startStateSync();
void client.init().catch(() => {}); // start ruff + ty in the background
await call("engine.ready", {});
if (!location.hash.startsWith("#selftest")) {
  setTimeout(() => void loadAgent().then((agent) => agent.start()).catch((e) => call("log", `[agent] start failed: ${e}`)), 3000);
}

if (location.hash.startsWith("#selftest")) {
  const { selftest } = await import("../selftest");
  await selftest();
}
