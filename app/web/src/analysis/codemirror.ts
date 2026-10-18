// CodeMirror integration for the analysis worker: diagnostics (ty + ruff),
// completions (ty), quick fixes (ruff fixes, "add to dependencies").
import { type Completion, type CompletionContext, type CompletionResult } from "@codemirror/autocomplete";
import { localCompletionSource } from "@codemirror/lang-python";
import { type Action, type Diagnostic, linter } from "@codemirror/lint";
import type { EditorState, Extension, Text } from "@codemirror/state";
import type { EditorView } from "@codemirror/view";
import { parse as parseToml } from "smol-toml";
import { analysis } from "./api";
import { PUBLIC_MODULES } from "../runtimeModules";
import { RUNTIMES } from "../runtimes";
import type { LineCol, Problem } from "./protocol";

// -- positions ---------------------------------------------------------------------

export const toOffset = (doc: Text, p: LineCol) => {
  const line = doc.line(Math.min(Math.max(p.line, 1), doc.lines));
  return Math.min(line.from + Math.max(p.column - 1, 0), line.to);
};

const toLineCol = (doc: Text, pos: number): LineCol => {
  const line = doc.lineAt(pos);
  return { line: line.number, column: pos - line.from + 1 };
};

// -- PEP 723 script metadata --------------------------------------------------------

const BLOCK = /^# \/\/\/ script$\n((?:^#(?:| .*)$\n)+)^# \/\/\/$/m;

export const normalizeName = (name: string) => name.toLowerCase().replace(/[-_.]+/g, "-");
const requirementName = (req: string) => normalizeName(req.trim().split(/[\s<>=!~;[(@]/)[0] ?? "");

/** Dependency names declared in the script's `# /// script` block. */
export function declaredDependencies(source: string): string[] {
  const m = BLOCK.exec(source);
  if (!m) return [];
  const toml = m[1].split("\n").map((l) => (l.startsWith("# ") ? l.slice(2) : l.slice(1))).join("\n");
  try {
    const data = parseToml(toml) as { dependencies?: string[] };
    return (data.dependencies ?? []).map(requirementName).filter(Boolean);
  } catch {
    return [];
  }
}

/** Edit that adds `requirement` to the script block (creating the block if needed). */
export function addDependencyEdit(source: string, requirement: string): { from: number; to: number; insert: string } {
  const m = BLOCK.exec(source);
  if (!m) {
    // After a shebang/encoding line, if any.
    let at = 0;
    while (/^#!|^# -\*-|^# (?:vim:|coding[:=])/.test(source.slice(at, source.indexOf("\n", at) + 1 || undefined))) {
      at = source.indexOf("\n", at) + 1;
    }
    return { from: at, to: at, insert: `# /// script\n# dependencies = [\n#     "${requirement}",\n# ]\n# ///\n\n` };
  }
  const blockStart = m.index;
  const body = m[1];
  const bodyStart = blockStart + m[0].indexOf(body);
  const multi = /^# dependencies = \[\n((?:^#.*\n)*?)^# \]\n/m.exec(body);
  if (multi) {
    const close = bodyStart + multi.index + multi[0].length - "# ]\n".length;
    return { from: close, to: close, insert: `#     "${requirement}",\n` };
  }
  const inline = /^# dependencies = \[(.*)\]$/m.exec(body);
  if (inline) {
    const existing = inline[1].trim().replace(/,\s*$/, "");
    const items = existing ? `${existing}, "${requirement}"` : `"${requirement}"`;
    const from = bodyStart + inline.index;
    return { from, to: from + inline[0].length, insert: `# dependencies = [${items}]` };
  }
  return { from: bodyStart + body.length, to: bodyStart + body.length, insert: `# dependencies = [\n#     "${requirement}",\n# ]\n` };
}

// -- modules Pyodide can provide -------------------------------------------------

let pyodideModules: Set<string> | null = null;
export async function loadPyodideModules() {
  if (pyodideModules) return pyodideModules;
  // Any bundled Python's packages (D37): the editor doesn't know which one runs the file.
  const modules = new Set<string>();
  for (const { python } of RUNTIMES) {
    const lock = await (await fetch(`/pyodide/${python}/pyodide-lock.json`)).json();
    for (const pkg of Object.values<{ imports?: string[] }>(lock.packages)) for (const i of pkg.imports ?? []) modules.add(i);
  }
  pyodideModules = modules;
  return modules;
}

// Modules the runtime provides that ty cannot see.
const RUNTIME_MODULES = new Set(["js", "pyodide", "pyodide_js", "micropip", "host", "_terrarium", "_terrariumhost", "_uihost", "IPython", ...PUBLIC_MODULES]);

// Import names that differ from the distribution name for common packages.
const DIST_FOR_IMPORT: Record<string, string> = {
  bs4: "beautifulsoup4", PIL: "pillow", yaml: "pyyaml", sklearn: "scikit-learn", cv2: "opencv-python",
  dateutil: "python-dateutil", attr: "attrs", dotenv: "python-dotenv",
};

// -- linter -----------------------------------------------------------------------------

function fixAction(problem: Problem): Action | null {
  if (!problem.fix) return null;
  return {
    name: problem.fix.message.replace(/\.$/, ""),
    apply(view) {
      const doc = view.state.doc;
      view.dispatch({
        changes: problem.fix!.edits.map((e) => ({ from: toOffset(doc, e.start), to: toOffset(doc, e.end), insert: e.text })),
        userEvent: "quickfix",
      });
    },
  };
}

function addDependencyAction(module: string): Action {
  const dist = DIST_FOR_IMPORT[module] ?? module.replace(/_/g, "-");
  return {
    name: `Add “${dist}” to dependencies`,
    apply(view) {
      view.dispatch({ changes: addDependencyEdit(view.state.doc.toString(), dist), userEvent: "quickfix" });
    },
  };
}

/**
 * What the analysis sees of a document: its path for ty and ruff (a notebook's
 * ends in .py) and its text, with positions as in the editor. `cells` (a
 * notebook) turns off what does not apply to cells.
 */
export interface AnalysisSource {
  path: string;
  text: string;
  cells?: { from: number; to: number }[];
}

/** Rules that don't fit notebooks (D44): imports in later cells, a cell's
 * final expression (it is shown), top-level await, Jupyter's display(). */
function irrelevantInCells(p: Problem, doc: Text, cells: { from: number; to: number }[]): boolean {
  if (p.code === "E402" || p.code === "E703") return true; // a ";" hides a cell's value
  if (/`await`.*outside|outside of an? (async|asynchronous)/i.test(p.message) || p.code === "F704") return true;
  if (p.source === "ty" && p.code === "unresolved-reference" && /`(display|get_ipython)`/.test(p.message)) return true;
  if (p.code === "B018") {
    const end = toOffset(doc, p.end);
    const cell = cells.find((c) => c.from <= end && end <= c.to);
    if (!cell) return false;
    // Only the cell's last line of code.
    const rest = doc.sliceString(doc.lineAt(end).to, cell.to);
    return rest.split("\n").every((l) => !l.trim() || l.trim().startsWith("#"));
  }
  return false;
}

export function analysisLinter(getSource: (state: EditorState) => AnalysisSource | null): Extension {
  return linter(
    async (view: EditorView): Promise<Diagnostic[]> => {
      const source = getSource(view.state);
      if (!source?.path.endsWith(".py") || source.path.startsWith("ext:")) return []; // library files are read-only
      const { path, text } = source;
      const doc = view.state.doc;
      let problems: Problem[];
      try {
        [problems] = await Promise.all([analysis.check(path, text), loadPyodideModules()]);
      } catch {
        return [];
      }
      if (view.state.doc !== doc) return []; // stale; a newer run is coming
      const declared = new Set(declaredDependencies(text));
      const out: Diagnostic[] = [];
      for (const p of problems) {
        if (source.cells && irrelevantInCells(p, doc, source.cells)) continue;
        const actions: Action[] = [];
        if (p.code === "unresolved-import") {
          const module = /`([\w.]+)`/.exec(p.message)?.[1]?.split(".")[0];
          if (module && (pyodideModules!.has(module) || RUNTIME_MODULES.has(module))) continue; // provided at run time
          if (module && declared.has(normalizeName(DIST_FOR_IMPORT[module] ?? module))) continue; // installed on run
          if (module) actions.push(addDependencyAction(module));
        }
        const fix = fixAction(p);
        if (fix) actions.push(fix);
        const from = toOffset(doc, p.start);
        const to = Math.max(from, toOffset(doc, p.end));
        out.push({ from, to, severity: p.severity, source: p.source === "ruff" ? `ruff ${p.code}` : `ty ${p.code}`, message: p.message, actions });
      }
      return out;
    },
    { delay: 400 },
  );
}

// -- completions --------------------------------------------------------------------------

const KIND_TO_TYPE: Record<number, string> = {
  1: "method", 2: "function", 3: "class", 4: "property", 5: "variable", 6: "class", 7: "interface",
  8: "namespace", 9: "property", 10: "property", 12: "enum", 13: "keyword", 14: "text", 21: "constant",
};

export function analysisCompletions(getSource: (state: EditorState) => AnalysisSource | null) {
  return async (ctx: CompletionContext): Promise<CompletionResult | null> => {
    const word = ctx.matchBefore(/\w*/);
    const afterDot = ctx.state.sliceDoc(Math.max(0, (word?.from ?? ctx.pos) - 1), word?.from ?? ctx.pos) === ".";
    if (!ctx.explicit && !afterDot && (!word || word.to - word.from < 2)) return null;
    const source = getSource(ctx.state);
    if (!source) return null;
    try {
      const { line, column } = toLineCol(ctx.state.doc, ctx.pos);
      const items = await analysis.complete(source.path, source.text, line, column);
      if (ctx.aborted) return null;
      const options: Completion[] = items.map((i, rank) => ({
        label: i.name,
        type: i.kind != null ? KIND_TO_TYPE[i.kind] : undefined,
        detail: i.detail ?? (i.module ? `from ${i.module}` : undefined),
        apply: i.insertText ?? i.name,
        boost: -rank / 1000,
      }));
      return { from: word?.from ?? ctx.pos, options, validFor: /^\w*$/ };
    } catch {
      return localCompletionSource(ctx);
    }
  };
}

/** Formatting of a notebook's code cells, each on its own (cells with magics stay). */
export async function formatRanges(view: EditorView, ranges: { from: number; to: number }[]) {
  const doc = view.state.doc;
  const changes: { from: number; to: number; insert: string }[] = [];
  for (const r of ranges) {
    const text = doc.sliceString(r.from, r.to);
    if (!text.trim() || /^\s*(%|!(?!=))/m.test(text)) continue;
    let formatted: string;
    try {
      formatted = (await analysis.format(text)).replace(/\n+$/, "");
    } catch {
      continue; // a syntax error: left as it is
    }
    if (formatted !== text) changes.push({ from: r.from, to: r.to, insert: formatted });
  }
  if (view.state.doc !== doc || !changes.length) return false;
  view.dispatch({ changes, userEvent: "format" });
  return true;
}

/** Whole-document formatting with ruff. */
export async function formatDocument(view: EditorView) {
  const text = view.state.doc.toString();
  const formatted = await analysis.format(text);
  if (formatted === text || view.state.doc.toString() !== text) return false;
  view.dispatch({ changes: { from: 0, to: text.length, insert: formatted }, userEvent: "format" });
  return true;
}

export type { EditorState };
