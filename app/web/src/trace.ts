// Tracebacks as data (D45), from _terrarium_traceback.py: the console (native)
// and notebook outputs (editor/trace.ts) draw them instead of the text.

export interface TraceFrame {
  /** "omitted": frames left out of a very long stack (`count` of them). */
  kind: "app" | "library" | "omitted";
  file?: string; // relative to the program's folder for project files, "json/decoder.py" for the library, "<cell 3>"
  name?: string | null; // qualified function name; null for a SyntaxError's place
  line?: number;
  endLine?: number; // the span ends on a later line
  col?: number; // span start on `line` (characters, 0-based, in the dedented context lines)
  endCol?: number; // span end on `endLine ?? line` (exclusive)
  context?: { start: number; lines: string[] }; // source lines from `start` on, dedented
  repeat?: number; // the same frame again this many times (recursion)
  count?: number; // "omitted" frames
  debug?: number; // the frame's index in the debugger's post-mortem stack (the run's uncaught exception)
}

export interface TraceException {
  type: string;
  message: string;
  notes?: string[];
  /** How the exception before this one led to it. */
  chain?: "cause" | "context";
  frames: TraceFrame[]; // most recent call last
  syntax?: TraceFrame; // a SyntaxError's place
  group?: TraceException[][]; // an ExceptionGroup's members, each a chain
  groupMore?: number;
}

export interface Trace {
  /** The classic traceback (copy, the agent, the self-test). */
  text: string;
  exceptions: TraceException[]; // oldest first, as Python prints them
}

export function parseTrace(json: string | undefined | null): Trace | undefined {
  if (!json) return undefined;
  try {
    const trace = JSON.parse(json) as Trace;
    return Array.isArray(trace?.exceptions) && trace.exceptions.length ? trace : undefined;
  } catch {
    return undefined;
  }
}

export const CHAIN_TEXT = {
  cause: "The above exception was the direct cause of the following exception:",
  context: "During handling of the above exception, another exception occurred:",
};

const PROJECT = "/home/pyodide/project";
const LIBRARY = /^\/lib\/python3\d*(?:\.zip)?\/(?:site-packages\/)?|^.*\/site-packages\//;

/**
 * A traceback for an interpreter that crashed (D16): Pyodide prints the
 * Python stack when it fails ("Stack (most recent call first):", at most 100
 * frames, no exception). `sources` gives an app file's lines for context.
 * Undefined if the dump has no Python frames.
 */
export async function crashTrace(
  dump: string,
  exception: { type: string; message: string },
  sources: (file: string) => Promise<string[] | null>,
): Promise<Trace | undefined> {
  const entries: TraceFrame[] = [];
  const cache = new Map<string, Promise<string[] | null>>();
  let truncated = false;
  for (const line of dump.split("\n")) {
    if (/^\s+\.\.\.\s*$/.test(line)) truncated = true;
    const m = /^\s+File "(.+)", line (\d+) in (.+?)\s*$/.exec(line);
    if (!m) continue;
    const [, path, lineText, name] = m;
    if (path.startsWith("/lib/terrarium/") || path.includes("/_pyodide/") || path === "<dependencies>") continue;
    const absolute = path.startsWith("/") ? path : `${PROJECT}/${path}`;
    const app = path.startsWith("<") ? /^<(console|cell)/.test(path) : absolute.startsWith(`${PROJECT}/`) && !absolute.includes("/site-packages/");
    const file = absolute.startsWith(`${PROJECT}/`) && !path.startsWith("<") ? absolute.slice(PROJECT.length + 1) : path.replace(LIBRARY, "");
    entries.unshift({ kind: app ? "app" : "library", file, name, line: Number(lineText) });
  }
  if (!entries.length) return undefined;
  // What runs the program (Pyodide's event loop) is no part of its traceback.
  const first = entries.findIndex((f) => f.kind === "app");
  if (first > 0) entries.splice(0, first);
  // Recursion: the same frame again and again is shown once.
  let frames: TraceFrame[] = [];
  for (const f of entries) {
    const prev = frames.at(-1);
    if (prev && prev.file === f.file && prev.line === f.line && prev.name === f.name) prev.repeat = (prev.repeat ?? 0) + 1;
    else frames.push(f);
  }
  // As _terrarium_traceback.py: the first 20 and the last 40 of a long stack.
  if (frames.length > 60) frames = [...frames.slice(0, 20), { kind: "omitted", count: frames.length - 60 }, ...frames.slice(-40)];
  for (const f of frames) {
    if (f.kind !== "app" || !f.file || f.file.startsWith("<") || !f.line) continue;
    if (!cache.has(f.file)) cache.set(f.file, sources(f.file).catch(() => null));
    const lines = await cache.get(f.file)!;
    const text = lines?.[f.line! - 1];
    if (text?.trim()) f.context = { start: f.line!, lines: [text.trim()] };
  }
  const out = ["Traceback (most recent call last):"];
  if (truncated) out.push("  ...");
  for (const f of frames) {
    if (f.kind === "omitted") {
      out.push(`  [${f.count} more frames]`);
      continue;
    }
    out.push(`  File "${f.file}", line ${f.line}, in ${f.name}`);
    if (f.context) out.push(`    ${f.context.lines[0]}`);
    if (f.repeat) out.push(`  [Previous line repeated ${f.repeat} more time${f.repeat === 1 ? "" : "s"}]`);
  }
  out.push(`${exception.type}: ${exception.message}`);
  return { text: out.join("\n"), exceptions: [{ type: exception.type, message: exception.message, frames }] };
}
