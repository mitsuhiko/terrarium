// The agent's tools (D34): pi-durable's read, write and edit over the project
// (env.ts), plus ls, find and grep (there is no shell), run_python, and
// check / format with ruff and ty. write and edit report new ruff/ty
// problems of a Python file right in their result.
import { Type } from "@earendil-works/pi-ai";
import { defineExtension, defineTool, type ToolExecutionResult, type ToolRegistration } from "@earendil-works/pi-durable";
import { createEditTool, createReadTool, createWriteTool } from "@earendil-works/pi-durable/tools";
import { createTwoFilesPatch } from "diff";
import { analysis } from "../analysis/api";
import type { Problem } from "../analysis/protocol";
import { base64ToBytes, bytesToBase64 } from "../host";
import { PyWorker } from "../python";
import { chooseFor, runtimeFor } from "../runtimes";
import { cleanTraceback } from "../session";
import { parseTrace } from "../trace";
import type { ProjectEnv } from "./env";

const PROJECT_ROOT = "/home/pyodide/project";
const decoder = new TextDecoder();
const MAX_OUTPUT = 24_000;

function projectEnv(api: { env: unknown }): ProjectEnv {
  if (!api.env) throw new Error("No project is open");
  return api.env as ProjectEnv;
}

const text = (t: string) => [{ type: "text" as const, text: t }];
const dirOf = (p: string) => (p.lastIndexOf("/") > 0 ? p.slice(0, p.lastIndexOf("/")) : "/");
const baseOf = (p: string) => p.slice(p.lastIndexOf("/") + 1);
const isHidden = (p: string) => p.split("/").some((part) => part.startsWith(".") || part === "__pycache__");

/** "*.py", "tests/**" -> RegExp over project paths without the leading "/". */
function globToRegExp(glob: string): RegExp {
  let re = "";
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "*") {
      if (glob[i + 1] === "*") {
        re += ".*";
        i++;
        if (glob[i + 1] === "/") i++;
      } else re += "[^/]*";
    } else if (c === "?") re += "[^/]";
    else re += c.replace(/[.+^${}()|[\]\\]/g, "\\$&");
  }
  // A pattern without "/" matches the file name anywhere.
  return glob.includes("/") ? new RegExp(`^${re}$`) : new RegExp(`(^|/)${re}$`);
}

function formatProblems(path: string, problems: Problem[], limit = 20): string {
  const lines = problems
    .slice(0, limit)
    .map((p) => `${path}:${p.start.line}:${p.start.column}: ${p.severity} [${p.source} ${p.code}] ${p.message}${p.fix ? " (fix available)" : ""}`);
  if (problems.length > limit) lines.push(`… and ${problems.length - limit} more`);
  return lines.join("\n");
}

async function checkText(env: ProjectEnv, path: string, source: string): Promise<Problem[]> {
  try {
    return await analysis.check(env.appPath(path), source);
  } catch {
    return []; // analysis not ready: no feedback rather than a failed write
  }
}

/** write/edit: after a .py file changes, append the problems ruff and ty see in it. */
function withLint<T extends ToolRegistration<any, any>>(tool: T): T {
  return {
    ...tool,
    async execute(args: any, api: any, context: any) {
      const result: ToolExecutionResult = await tool.execute(args, api, context);
      const env = projectEnv(api);
      const resolved = env.resolve(String(args?.path ?? ""));
      if (result.isError || !resolved.ok || !resolved.value.endsWith(".py")) return result;
      const source = await env.readTextFile(resolved.value, context);
      if (!source.ok) return result;
      const problems = await checkText(env, resolved.value, source.value);
      if (!problems.length) return result;
      const note = `\n\nruff/ty report ${problems.length} problem${problems.length === 1 ? "" : "s"} in ${resolved.value}:\n${formatProblems(resolved.value, problems)}`;
      return { ...result, output: [...(result.output ?? []), ...text(note)] };
    },
  } as T;
}

// -- ls, find, grep -----------------------------------------------------------------

const lsTool = defineTool({
  name: "ls",
  description: "List a directory of the project (default: its root). Directories end with '/'.",
  parameters: Type.Object({ path: Type.Optional(Type.String({ description: "Directory, relative to the project root" })) }),
  async execute(args, api, context) {
    const env = projectEnv(api);
    const r = await env.listDir(args.path ?? "/", context);
    if (!r.ok) throw r.error;
    const lines = r.value
      .filter((e) => !isHidden(e.name))
      .map((e) => (e.kind === "directory" ? `${e.name}/` : `${e.name}  (${e.size} bytes)`));
    return { output: text(lines.length ? lines.join("\n") : "(empty)") };
  },
});

async function walk(env: ProjectEnv, dir: string, context: any, out: { path: string; dir: boolean }[], max: number) {
  const r = await env.listDir(dir, context);
  if (!r.ok) throw r.error;
  for (const e of r.value) {
    if (out.length >= max) return;
    if (isHidden(e.name)) continue;
    out.push({ path: e.path, dir: e.kind === "directory" });
    if (e.kind === "directory") await walk(env, e.path, context, out, max);
  }
}

const findTool = defineTool({
  name: "find",
  description: "Find files in the project by glob pattern (e.g. '*.py', 'data/**/*.csv'). Without a pattern, lists every file.",
  parameters: Type.Object({
    pattern: Type.Optional(Type.String({ description: "Glob; without '/' it matches file names anywhere" })),
    path: Type.Optional(Type.String({ description: "Directory to search in (default: the project root)" })),
  }),
  async execute(args, api, context) {
    const env = projectEnv(api);
    const root = env.resolve(args.path ?? "/");
    if (!root.ok) throw root.error;
    const entries: { path: string; dir: boolean }[] = [];
    await walk(env, root.value, context, entries, 5000);
    const re = args.pattern ? globToRegExp(args.pattern) : null;
    const files = entries.filter((e) => !e.dir && (!re || re.test(e.path.slice(1)))).map((e) => e.path.slice(1));
    const shown = files.slice(0, 500);
    return { output: text(shown.length ? shown.join("\n") + (files.length > shown.length ? `\n… ${files.length - shown.length} more` : "") : "No files found") };
  },
});

const grepTool = defineTool({
  name: "grep",
  description: "Search the project's text files with a regular expression. Shows path:line: text for each match.",
  parameters: Type.Object({
    pattern: Type.String({ description: "JavaScript regular expression" }),
    path: Type.Optional(Type.String({ description: "Directory or file to search (default: the project root)" })),
    glob: Type.Optional(Type.String({ description: "Only files matching this glob, e.g. '*.py'" })),
    ignore_case: Type.Optional(Type.Boolean()),
  }),
  async execute(args, api) {
    const env = projectEnv(api);
    const re = new RegExp(args.pattern, args.ignore_case ? "i" : "");
    const only = args.glob ? globToRegExp(args.glob) : null;
    const start = env.resolve(args.path ?? "/");
    if (!start.ok) throw start.error;
    const files = await env.tree(start.value).catch(async () => {
      // A single file.
      const one = await env.readBinaryFile(start.value, {} as any);
      if (!one.ok) throw one.error;
      return [{ path: start.value, data: bytesToBase64(one.value) }];
    });
    const out: string[] = [];
    let matches = 0;
    for (const f of files) {
      if (isHidden(f.path) || (only && !only.test(f.path.slice(1)))) continue;
      const bytes = base64ToBytes(f.data);
      if (bytes.length > 2_000_000 || bytes.subarray(0, 8000).includes(0)) continue; // binary or huge
      const lines = decoder.decode(bytes).split("\n");
      for (let i = 0; i < lines.length; i++) {
        if (!re.test(lines[i])) continue;
        matches++;
        if (out.length < 200) out.push(`${f.path.slice(1)}:${i + 1}: ${lines[i].slice(0, 300)}`);
      }
    }
    if (matches > out.length) out.push(`… ${matches - out.length} more matches`);
    return { output: text(out.length ? out.join("\n") : "No matches") };
  },
});

// -- run_python ---------------------------------------------------------------------

const runPythonTool = defineTool({
  name: "run_python",
  description:
    "Run Python (Pyodide: CPython in WebAssembly) in a fresh interpreter, with the project folder as the working directory. " +
    "The Python version is the one the program would get from the Run button (requires-python, .python-version, else the default). " +
    "Files the program writes go straight into the project. Dependencies: a PEP 723 `# /// script` block in the code or file. " +
    "Returns stdout/stderr, the traceback on failure, and matplotlib figures shown with plt.show() as images. " +
    "input() gets end-of-file; ui apps and turtle windows cannot be shown here.",
  parameters: Type.Object({
    code: Type.Optional(Type.String({ description: "Python source to run (in the project root)" })),
    path: Type.Optional(Type.String({ description: "A project file to run instead, like the Run button (its folder is the working directory)" })),
    timeout_seconds: Type.Optional(Type.Number({ description: "Stop the program after this long (default 60)" })),
  }),
  async execute(args, api, context) {
    const env = projectEnv(api);
    if (!args.code && !args.path) throw new Error("Pass `code` or `path`.");
    let code = args.code ?? "";
    let dir = "/";
    let filename = "<agent>";
    if (args.path) {
      const p = env.resolve(args.path);
      if (!p.ok) throw p.error;
      const source = await env.readTextFile(p.value, context);
      if (!source.ok) throw source.error;
      code = source.value;
      dir = dirOf(p.value);
      filename = baseOf(p.value);
    }
    const choice = await chooseFor(env.appPath(dir), code);
    if (!choice.ok) return { output: text(`Python version: ${choice.error}`), isError: true };
    const worker = new PyWorker(choice.python);
    worker.allowDevice = false; // no dialogs, contacts or photos behind the user's back (D40)
    let output = "";
    const images: string[] = [];
    let note = "";
    worker.onOutput = (stream, chunk) => {
      if (stream === "image") {
        if (images.length < 4) images.push(chunk);
        return;
      }
      output += chunk;
      if (output.length > MAX_OUTPUT * 2) output = output.slice(-MAX_OUTPUT);
      api.output(chunk);
    };
    // Exceptions the runtime caught (a turtle event handler) come as data (D45): their text.
    worker.onDisplay = (json) => {
      try {
        const msg = JSON.parse(json);
        if (msg.type === "exception" && typeof msg.trace?.text === "string") worker.onOutput("stderr", `${msg.trace.text}\n`);
      } catch {
        // not for the agent
      }
    };
    worker.onInput = async () => {
      note ||= "input() was called; the agent's runs have no input, so it got end-of-file.\n";
      return null;
    };
    worker.onUIRender = () => {
      note ||= "The program opened a ui app, which cannot be shown to the agent; it was stopped.\n";
      worker.stop();
    };
    worker.onTurtle = () => {
      note ||= "The program draws with turtle, which the agent cannot see.\n";
    };
    worker.onTurtleCall = async () => [];
    const timeout = Math.max(1, Math.min(args.timeout_seconds ?? 60, 600));
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      worker.stop();
    }, timeout * 1000);
    const onAbort = () => worker.stop(500);
    context.abortSignal?.addEventListener("abort", onAbort);
    try {
      await worker.ready;
      // The folder itself (D35); a linked folder through a local copy.
      await worker.attach(env.appPath(dir));
      const result = await worker.run(code, { filename, cwd: PROJECT_ROOT });
      const prefix = env.project ? `${env.project}/` : "";
      const written = (await worker.release())
        .filter((p) => !p.split("/").includes("__pycache__"))
        .map((p) => `/${p.startsWith(prefix) ? p.slice(prefix.length) : p}`);
      if (written.length) env.notifyWrites(written.map((p) => env.appPath(p)));
      let report = output.length > MAX_OUTPUT ? `…\n${output.slice(-MAX_OUTPUT)}` : output;
      if (report && !report.endsWith("\n")) report += "\n";
      report += note;
      if (timedOut) report += `Stopped after ${timeout} s.\n`;
      else if (!result.ok && result.error) report += (parseTrace(result.trace)?.text ?? cleanTraceback(result.error)) + "\n";
      if (written.length) report += `Files written: ${written.map((p) => p.slice(1)).join(", ")}\n`;
      report += result.ok ? `Finished in ${Math.round(result.ms)} ms` : timedOut ? "" : "The program failed";
      report += ` (Python ${runtimeFor(choice.python).version}).`;
      return {
        output: [...text(report.trim() || "(no output)"), ...images.map((data) => ({ type: "image" as const, data, mimeType: "image/png" }))],
        isError: !result.ok,
      };
    } finally {
      clearTimeout(timer);
      context.abortSignal?.removeEventListener("abort", onAbort);
      worker.terminate("done");
    }
  },
});

// -- check, format ------------------------------------------------------------------

async function pythonFiles(env: ProjectEnv, paths: string[] | undefined): Promise<{ path: string; text: string }[]> {
  if (paths?.length) {
    const out = [];
    for (const p of paths) {
      const r = env.resolve(p);
      if (!r.ok) throw r.error;
      const source = await env.readTextFile(r.value, {} as any);
      if (!source.ok) throw source.error;
      out.push({ path: r.value, text: source.value });
    }
    return out;
  }
  const tree = await env.tree("/");
  return tree
    .filter((f) => f.path.endsWith(".py") && !isHidden(f.path))
    .slice(0, 200)
    .map((f) => ({ path: f.path, text: decoder.decode(base64ToBytes(f.data)) }));
}

const checkTool = defineTool({
  name: "check",
  description: "Check Python files with ruff (lint) and ty (types). Without paths, checks every .py file in the project.",
  parameters: Type.Object({ paths: Type.Optional(Type.Array(Type.String())) }),
  async execute(args, api) {
    const env = projectEnv(api);
    const files = await pythonFiles(env, args.paths);
    const reports: string[] = [];
    let total = 0;
    for (const f of files) {
      const problems = await analysis.check(env.appPath(f.path), f.text);
      total += problems.length;
      if (problems.length) reports.push(formatProblems(f.path.slice(1), problems, 30));
    }
    const summary = `${files.length} file${files.length === 1 ? "" : "s"} checked, ${total} problem${total === 1 ? "" : "s"}.`;
    return { output: text(reports.length ? `${reports.join("\n")}\n\n${summary}` : summary) };
  },
});

const formatTool = defineTool({
  name: "format",
  description: "Format Python files with ruff format and save them. Without paths, formats every .py file in the project.",
  parameters: Type.Object({
    paths: Type.Optional(Type.Array(Type.String())),
    check_only: Type.Optional(Type.Boolean({ description: "Only report which files would change" })),
  }),
  async execute(args, api, context) {
    const env = projectEnv(api);
    const files = await pythonFiles(env, args.paths);
    const changed: string[] = [];
    let patch = "";
    for (const f of files) {
      let formatted: string;
      try {
        formatted = await analysis.format(f.text);
      } catch (e) {
        return { output: text(`Could not format ${f.path.slice(1)}: ${(e as Error).message ?? e}`), isError: true };
      }
      if (formatted === f.text) continue;
      changed.push(f.path.slice(1));
      patch += createTwoFilesPatch(f.path.slice(1), f.path.slice(1), f.text, formatted, "", "", { context: 2 });
      if (!args.check_only) {
        const w = await env.writeFile(f.path, formatted, context);
        if (!w.ok) throw w.error;
      }
    }
    const verb = args.check_only ? "would be reformatted" : "reformatted";
    return {
      output: text(changed.length ? `${changed.length} file${changed.length === 1 ? "" : "s"} ${verb}: ${changed.join(", ")}` : "Already formatted."),
      details: { patch },
    };
  },
});

export const ProjectTools = defineExtension({
  name: "terrarium-tools",
  tools: [createReadTool(), withLint(createWriteTool()), withLint(createEditTool()), lsTool, findTool, grepTool, runPythonTool, checkTool, formatTool],
});
