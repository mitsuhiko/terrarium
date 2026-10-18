// The agent's IDE tools and IDE context (D36). The project tools (tools.ts)
// work on files on disk and the user sees nothing happen; the `ide_*` tools
// change what is on the user's screen: open and close tabs, lint and format
// what is in the editor. They never return file contents (except the
// selection in ide_state), so the model cannot use them instead of `read`,
// and they only act for the conversation on screen.
//
// The IDE context (open tabs, active file, cursor, selection, a run that
// failed) reaches the model only when it changed since the model last saw it:
// with the user's message, or mid-turn as an entry placed at the next boundary.
import { Type } from "@earendil-works/pi-ai";
import { defineExtension, defineTool, type ToolExecutionResult } from "@earendil-works/pi-durable";
import { analysis } from "../analysis/api";
import { call } from "../host";
import { docsVersion } from "./docs";
import type { ProjectEnv } from "./env";

/** What the host reports (AppModel+Agent.swift `ideState`). Paths are app paths. */
export interface IDEState {
  panes: { tabs: string[]; active: string | null }[];
  focused: number;
  split: boolean;
  file: string | null;
  line: number | null;
  column: number | null;
  selection: { text: string; fromLine: number; toLine: number; truncated?: boolean } | null;
  /** The file a program is running from. */
  running: string | null;
  /** The end of the console output when the active file's last run failed. */
  error: string | null;
}

export const IDE_TOOLS = new Set(["ide_state", "ide_open", "ide_close", "ide_lint", "ide_format", "ide_show_docs"]);

/** Set by the service: which conversation is on screen, and what each one last saw. */
export const ideHooks = {
  active: null as number | null,
  /** IDE tools running now: what they change is theirs to report, not a change by the user. */
  inFlight: 0,
  /** The model now knows `state` (a tool's result showed it). */
  seen: async (_conversationId: number, _state: IDEState) => {},
};

/** A project path for an app path ("Examples/Hello.py" in project "Examples" -> "Hello.py"). */
export function projectPath(project: string, path: string): string | null {
  if (!project) return path.startsWith("@") || path.startsWith("ext:") ? null : path;
  return path.startsWith(project + "/") ? path.slice(project.length + 1) : null;
}

/** How the model sees a path: relative to the project, or marked as outside it. */
function shown(project: string, path: string): string {
  if (path.startsWith("ext:")) return `${path.slice(4)} (a library file, read-only)`;
  return projectPath(project, path) ?? `${path} (outside the project)`;
}

function hash(text: string): string {
  let h = 5381;
  for (let i = 0; i < text.length; i++) h = ((h << 5) + h + text.charCodeAt(i)) | 0;
  return (h >>> 0).toString(36);
}

/** What has to change for the model to be told again. */
export function contextKey(state: IDEState | null | undefined): string {
  if (!state) return "";
  const s = state.selection;
  return JSON.stringify({
    file: state.file,
    line: state.line,
    selection: s?.text ? [s.fromLine, s.toLine, hash(s.text)] : null,
    panes: state.panes.map((p) => [p.active, ...p.tabs]),
    running: state.running,
    error: state.error ? hash(state.error) : null,
  });
}

/** The IDE context as the model reads it. */
export function contextText(project: string, state: IDEState): string {
  const lines: string[] = [];
  if (state.file) {
    lines.push(`- Active file: ${shown(project, state.file)}${state.line ? `, cursor on line ${state.line}` : ""}.`);
  } else {
    lines.push("- No file is open in the editor.");
  }
  const s = state.selection;
  if (s?.text && state.file) {
    const range = s.fromLine === s.toLine ? `line ${s.fromLine}` : `lines ${s.fromLine}-${s.toLine}`;
    const cut = s.truncated ? " (cut short; read the file for the rest)" : "";
    lines.push(`- Selected, ${range}${cut}:\n\`\`\`\n${s.text}\n\`\`\``);
  }
  const panes = state.panes.filter((p) => p.tabs.length);
  panes.forEach((p, i) => {
    const tabs = p.tabs.map((t) => shown(project, t) + (t === p.active && t !== state.file ? " (shown)" : "")).join(", ");
    lines.push(`- Open tabs${panes.length > 1 ? ` in pane ${i + 1}${i === state.focused ? " (focused)" : ""}` : ""}: ${tabs}`);
  });
  if (state.running) lines.push(`- A program is running: ${shown(project, state.running)}.`);
  if (state.error && state.file) lines.push(`- The last run of ${shown(project, state.file)} failed:\n\`\`\`\n${state.error}\n\`\`\``);
  return lines.join("\n");
}

/** The block before a user's message or in a mid-turn entry. */
export function contextBlock(project: string, state: IDEState): string {
  return `<ide>\nThe user's IDE changed since you last saw it:\n${contextText(project, state)}\n</ide>`;
}

// -- the tools ------------------------------------------------------------------------

const PREFIX = "IDE tool: acts on what the user sees in their editor, not on files on disk (for those, use read, write and edit).";
const text = (t: string) => [{ type: "text" as const, text: t }];

function envOf(api: { env: unknown }): ProjectEnv {
  if (!api.env) throw new Error("No project is open");
  return api.env as ProjectEnv;
}

/** An IDE operation in the host; null when the conversation is not on screen. */
async function ide<T>(api: { conversationId: unknown }, method: string, args: Record<string, unknown> = {}): Promise<T> {
  if (ideHooks.active !== Number(api.conversationId)) {
    throw new Error("The user is not looking at this conversation, so IDE tools do nothing here. Use the project tools instead.");
  }
  ideHooks.inFlight++;
  try {
    return await call<T>("ide", { method, ...args });
  } finally {
    // The tool reports the new state right after; give it that long.
    setTimeout(() => ideHooks.inFlight--, 100);
  }
}

function appPathOf(env: ProjectEnv, path: string): string {
  const r = env.resolve(path);
  if (!r.ok) throw r.error;
  return env.appPath(r.value);
}

const fail = (message: string): ToolExecutionResult => ({ output: text(message), isError: true });

/** The file a lint/format call means: the given one, else the active file. */
async function target(api: any, path: string | undefined): Promise<{ appPath: string; shown: string }> {
  const env = envOf(api);
  if (path) return { appPath: appPathOf(env, path), shown: path.replace(/^\/+/, "") };
  const state = await ide<IDEState>(api, "state");
  if (!state.file) throw new Error("No file is open in the editor.");
  return { appPath: state.file, shown: shown(env.project, state.file) };
}

const stateTool = defineTool({
  name: "ide_state",
  description:
    `${PREFIX} Reports the user's IDE now: open tabs, the active file, the cursor line, the selected text and whether a program is running. ` +
    "Each user message already tells you when this changed (in an <ide> block); use this for a fresh look mid-task.",
  parameters: Type.Object({}),
  async execute(_args, api) {
    const env = envOf(api);
    const state = await ide<IDEState>(api, "state");
    await ideHooks.seen(Number(api.conversationId), state);
    return { output: text(contextText(env.project, state)) };
  },
});

const openTool = defineTool({
  name: "ide_open",
  description:
    `${PREFIX} Opens a project file in the user's editor (or switches to its tab) and scrolls to a line or a range of lines, highlighted, to show the user something. ` +
    "The result does not contain the file's text: to read a file, use read.",
  parameters: Type.Object({
    path: Type.String({ description: "Project file, relative to the project root" }),
    line: Type.Optional(Type.Number({ description: "First line to show" })),
    end_line: Type.Optional(Type.Number({ description: "Last line of the range to highlight" })),
    pane: Type.Optional(Type.Number({ description: "1 or 2: the editor pane, when the IDE is split (iPad)" })),
  }),
  async execute(args, api) {
    const env = envOf(api);
    const appPath = appPathOf(env, args.path);
    const r = await ide<{ message: string; state: IDEState }>(api, "open", {
      path: appPath,
      line: args.line ?? null,
      endLine: args.end_line ?? null,
      pane: args.pane ? args.pane - 1 : null,
    });
    await ideHooks.seen(Number(api.conversationId), r.state);
    return { output: text(r.message), details: { path: args.path.replace(/^\/+/, ""), line: args.line ?? null } };
  },
});

const closeTool = defineTool({
  name: "ide_close",
  description: `${PREFIX} Closes a file's tab in the user's editor. What the user typed is saved first; the file is not deleted.`,
  parameters: Type.Object({ path: Type.String({ description: "Project file, relative to the project root" }) }),
  async execute(args, api) {
    const env = envOf(api);
    const r = await ide<{ message: string; state: IDEState }>(api, "close", { path: appPathOf(env, args.path) });
    await ideHooks.seen(Number(api.conversationId), r.state);
    return { output: text(r.message) };
  },
});

const lintTool = defineTool({
  name: "ide_lint",
  description:
    `${PREFIX} Checks a file that is open in the user's editor with ruff and ty, using the editor's text (with what the user typed), and shows the problems there. ` +
    "Without a path: the active file. For files on disk, use check.",
  parameters: Type.Object({ path: Type.Optional(Type.String({ description: "An open file (default: the active one)" })) }),
  async execute(args, api) {
    const t = await target(api, args.path);
    const buffer = await ide<{ text: string } | null>(api, "buffer", { path: t.appPath });
    if (!buffer) return fail(`${t.shown} is not open in the editor. Use check for files on disk, or ide_open it first.`);
    const problems = await analysis.check(t.appPath, buffer.text);
    await ide(api, "relint", { path: t.appPath });
    if (!problems.length) return { output: text(`No problems in ${t.shown}.`) };
    const lines = problems
      .slice(0, 30)
      .map((p) => `${t.shown}:${p.start.line}:${p.start.column}: ${p.severity} [${p.source} ${p.code}] ${p.message}${p.fix ? " (fix available)" : ""}`);
    if (problems.length > 30) lines.push(`… and ${problems.length - 30} more`);
    return { output: text(`${problems.length} problem${problems.length === 1 ? "" : "s"} in ${t.shown}, shown in the editor:\n${lines.join("\n")}`) };
  },
});

const formatTool = defineTool({
  name: "ide_format",
  description:
    `${PREFIX} Formats a file that is open in the user's editor with ruff format, in the editor, so the user can undo it there. ` +
    "Without a path: the active file. For files that are not open, use format.",
  parameters: Type.Object({ path: Type.Optional(Type.String({ description: "An open file (default: the active one)" })) }),
  async execute(args, api) {
    const t = await target(api, args.path);
    const r = await ide<{ message: string }>(api, "format", { path: t.appPath, shown: t.shown });
    return { output: text(r.message) };
  },
});

const showDocsTool = defineTool({
  name: "ide_show_docs",
  description:
    "IDE tool: opens the Python documentation for the user, at a ref from docs_search (e.g. library/json.html#json.loads), " +
    "to show them where something is explained. The result does not contain the text: to read the docs yourself, use docs_read.",
  parameters: Type.Object({
    ref: Type.String({ description: "A ref from docs_search, or a page like library/json.html" }),
    version: Type.Optional(Type.String({ description: "Python version of the docs (default: the project's)" })),
  }),
  async execute(args, api) {
    const version = await docsVersion(api, args.version);
    const ref = args.ref.replace(/^docs:[\d.]+\//, "").replace(/^\/+/, "");
    const r = await ide<{ message: string }>(api, "docs", { ref, version });
    return { output: text(r.message), details: { ref, version } };
  },
});

export const IDETools = defineExtension({
  name: "terrarium-ide",
  tools: [stateTool, openTool, closeTool, lintTool, formatTool, showDocsTool],
});
