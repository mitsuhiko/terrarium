// Code intelligence worker: ty (type checking, completions, hover) and ruff
// (lint, format), both as WebAssembly. Positions are 1-based line/column in
// UTF-16 code units, matching JS strings.
import initRuff, { type Diagnostic as RuffDiagnostic, PositionEncoding as RuffEncoding, Workspace as RuffWorkspace } from "@astral-sh/ruff-wasm-web";
import ruffWasmUrl from "@astral-sh/ruff-wasm-web/ruff_wasm_bg.wasm?url";
import initTy, { type FileHandle, Position, PositionEncoding, Severity, Workspace as TyWorkspace } from "ty_wasm";
import tyWasmUrl from "ty_wasm/ty_wasm_bg.wasm?url";
import { DEVICE_MODULES } from "../runtimeModules";
import type { AnalysisRequest, CompletionItem, DefinitionTarget, Problem } from "./protocol";

const ROOT = "/project";
const STARTED_AT = Date.now();
const STUBS = "/terrarium-stubs";
let ruff: RuffWorkspace;
let ty: TyWorkspace;
const handles = new Map<string, FileHandle>();
const stubHandles = new Map<string, FileHandle>();
let root: string | null = null;
const texts = new Map<string, string>();
let ready: Promise<{ ruff: string; tyMs: number; ruffMs: number }> | null = null;
let python = "3.14"; // the version ty and ruff check against (setPython)

function ruffWorkspace() {
  // Ruff's CLI defaults (pyflakes + the E4/E7/E9 errors) plus bugbear: real
  // mistakes, no style nagging. The playground defaults also enable isort etc.
  const defaults = RuffWorkspace.defaultSettings();
  return new RuffWorkspace(
    { ...defaults, "target-version": `py${python.replace(".", "")}`, lint: { ...defaults.lint, select: ["E4", "E7", "E9", "F", "B"] } },
    RuffEncoding.Utf16,
  );
}

async function init() {
  const t0 = performance.now();
  await initRuff({ module_or_path: ruffWasmUrl });
  const ruffMs = performance.now() - t0;
  ruff = ruffWorkspace();
  const t1 = performance.now();
  await initTy({ module_or_path: tyWasmUrl });
  ty = new TyWorkspace(ROOT, PositionEncoding.Utf16, { environment: { "python-version": python } });
  // Our runtime modules (ui, the device modules) become visible to ty through
  // an extra search path; the directory only exists once a file is in it.
  // turtle is left to typeshed, which knows it better.
  const files = ["ui.py", "_device.py", ...DEVICE_MODULES.map((m) => `${m}.py`)];
  const texts = await Promise.all(files.map((f) => fetch(`/runtime/python/${f}`).then((r) => (r.ok ? r.text() : null)).catch(() => null)));
  files.forEach((f, i) => {
    if (texts[i] !== null) stubHandles.set(`${STUBS}/${f}`, ty.openFile(`${STUBS}/${f}`, texts[i]!));
  });
  if (stubHandles.size) setRoot("");
  return { ruff: RuffWorkspace.version(), ruffMs, tyMs: performance.now() - t1 };
}

const tyPath = (path: string) => `${ROOT}/${path}`;

/** Open or update a file in ty's in-memory project. */
function sync(path: string, text: string) {
  if (texts.get(path) === text && handles.has(path)) return handles.get(path)!;
  let handle = handles.get(path);
  if (handle) ty.updateFile(handle, text);
  else {
    handle = ty.openFile(tyPath(path), text);
    handles.set(path, handle);
  }
  texts.set(path, text);
  return handle;
}

function check(path: string, text: string): Problem[] {
  const problems: Problem[] = [];
  const handle = sync(path, text);
  for (const d of ty.checkFile(handle)) {
    const range = d.toRange(ty);
    if (range) {
      const severity = d.severity();
      problems.push({
        source: "ty",
        code: d.id(),
        message: d.message(),
        severity: severity === Severity.Info ? "info" : severity === Severity.Warning ? "warning" : "error",
        start: { line: range.start.line, column: range.start.column },
        end: { line: range.end.line, column: range.end.column },
      });
      range.free();
    }
    d.free();
  }
  if (path.endsWith(".py")) {
    for (const d of ruff.check(text) as RuffDiagnostic[]) {
      if (d.code === "F821") continue; // ty reports undefined names (unresolved-reference)
      problems.push({
        source: "ruff",
        code: d.code ?? "syntax",
        message: d.message,
        severity: d.code ? "warning" : "error",
        start: { line: d.start_location.row, column: d.start_location.column },
        end: { line: d.end_location.row, column: d.end_location.column },
        fix: d.fix
          ? {
              message: d.fix.message ?? "Fix",
              edits: d.fix.edits.map((e: RuffDiagnostic["fix"] extends infer F ? F extends { edits: (infer E)[] } ? E : never : never) => ({
                start: { line: e.location.row, column: e.location.column },
                end: { line: e.end_location.row, column: e.end_location.column },
                text: e.content ?? "",
              })),
            }
          : undefined,
      });
    }
  }
  return problems;
}

/**
 * Programs run with their folder as cwd, so its modules import as top-level
 * ones: the folder is an extra search path. ty rejects paths that do not exist
 * in its file system yet, so it is applied once a file from it is open.
 */
let wantedRoot = "";
let appliedPaths = "";
function setRoot(dir: string) {
  wantedRoot = dir;
  applyRoot();
}
function applyRoot() {
  const extra = stubHandles.size ? [STUBS] : [];
  if (wantedRoot && [...handles.keys()].some((p) => p.startsWith(`${wantedRoot}/`))) extra.push(`${ROOT}/${wantedRoot}`);
  const key = `${python}\n${extra.join("\n")}`;
  if (key === appliedPaths) return;
  ty.updateOptions({ environment: { "python-version": python, "extra-paths": extra } });
  appliedPaths = key;
  root = wantedRoot;
}

function definition(path: string, text: string, line: number, column: number): DefinitionTarget[] {
  const handle = sync(path, text);
  const out: DefinitionTarget[] = [];
  for (const link of ty.gotoDefinition(handle, new Position(line, column))) {
    const range = link.selection_range ?? link.full_range;
    const target = link.path;
    const inProject = target.startsWith(`${ROOT}/`);
    out.push({
      path: inProject ? target.slice(ROOT.length + 1) : `ext:${target}`,
      external: !inProject,
      start: { line: range.start.line, column: range.start.column },
      end: { line: range.end.line, column: range.end.column },
    });
    link.free();
  }
  return out;
}

function source(path: string): string {
  const target = path.replace(/^ext:/, "");
  const stub = stubHandles.get(target);
  if (stub) return ty.sourceText(stub);
  const handle = ty.getVendoredFile(target.replace(/^vendored:\/\//, ""));
  try {
    return ty.sourceText(handle);
  } finally {
    handle.free();
  }
}

function complete(path: string, text: string, line: number, column: number): CompletionItem[] {
  const handle = sync(path, text);
  const position = new Position(line, column);
  const out = ty.completions(handle, position).map((c) => {
    const item = { name: c.name, kind: c.kind ?? null, detail: c.detail ?? null, insertText: c.insert_text ?? null, module: c.module_name ?? null };
    c.free();
    return item;
  });
  return out.slice(0, 200);
}

function hover(path: string, text: string, line: number, column: number): string | null {
  const handle = sync(path, text);
  const h = ty.hover(handle, new Position(line, column));
  if (!h) return null;
  const md = h.markdown;
  h.free();
  return md;
}

self.onmessage = async (e: MessageEvent<AnalysisRequest & { id: number }>) => {
  const { id, ...req } = e.data;
  try {
    ready ??= init();
    const info = await ready;
    let result: unknown;
    switch (req.type) {
      case "init":
        result = info;
        break;
      case "sync":
        for (const f of req.files) sync(f.path, f.text);
        applyRoot();
        result = null;
        break;
      case "check":
        result = check(req.path, req.text);
        break;
      case "complete":
        result = complete(req.path, req.text, req.line, req.column);
        break;
      case "hover":
        result = hover(req.path, req.text, req.line, req.column);
        break;
      case "format":
        result = ruff.format(req.text);
        break;
      case "definition":
        result = definition(req.path, req.text, req.line, req.column);
        break;
      case "source":
        result = source(req.path);
        break;
      case "state":
        result = { root, files: [...handles.keys()], startedAt: STARTED_AT };
        break;
      case "setRoot":
        setRoot(req.dir);
        result = null;
        break;
      case "setPython":
        if (req.python !== python) {
          python = req.python;
          ruff.free();
          ruff = ruffWorkspace();
          applyRoot();
        }
        result = null;
        break;
    }
    self.postMessage({ id, result });
  } catch (err) {
    self.postMessage({ id, error: String((err as Error)?.message ?? err) });
  }
};
