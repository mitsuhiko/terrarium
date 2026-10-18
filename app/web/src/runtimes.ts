// The Python versions the app bundles (D37, app/runtimes.json) and which one
// a program runs on. The rules follow uv's, so a project behaves the same
// with `uv run` on a desktop:
//
// 1. the program's `requires-python` (PEP 723 block, else pyproject.toml in
//    its folder) limits the candidates; none left is an error
// 2. a `.python-version` file (the folder or one above it) picks one of them
// 3. else the default from Settings, if it is a candidate
// 4. else the newest candidate; a prerelease (3.15) only when nothing else fits
import { parse as parseToml } from "smol-toml";
import config from "../../runtimes.json";
import { dirname, fs, isLocationRoot, join } from "./host";

export interface Runtime {
  python: string; // "3.14"
  version: string; // "3.14.2"
  pyodide: string; // "314.0.7"
  prerelease?: boolean;
}

export const RUNTIMES: Runtime[] = config.runtimes.map(({ python, version, pyodide, prerelease }) => ({ python, version, pyodide, prerelease }));

let defaultPython = config.default;
const defaultListeners = new Set<(python: string) => void>();

export function getDefaultPython() {
  return defaultPython;
}

/** The host sends the default from Settings. */
export function setDefaultPython(python: string) {
  if (!RUNTIMES.some((r) => r.python === python) || python === defaultPython) return;
  defaultPython = python;
  for (const fn of defaultListeners) fn(python);
}

export function onDefaultPython(fn: (python: string) => void) {
  defaultListeners.add(fn);
}

export const runtimeFor = (python: string) => RUNTIMES.find((r) => r.python === python) ?? RUNTIMES[0];
export const label = (python: string) => `Python ${python}${runtimeFor(python).prerelease ? " (preview)" : ""}`;

// -- PEP 440 specifiers (the part requires-python uses) ------------------------------

function release(version: string): number[] {
  const m = /^\s*v?(\d+(?:\.\d+)*)/.exec(version);
  return m ? m[1].split(".").map(Number) : [];
}

function compare(a: number[], b: number[]): number {
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const d = (a[i] ?? 0) - (b[i] ?? 0);
    if (d) return Math.sign(d);
  }
  return 0;
}

/**
 * Whether a runtime's version satisfies a specifier set like ">=3.10,<3.15".
 * Compares release numbers only: 3.15.0rc1 counts as 3.15.0, which is what
 * `requires-python = ">=3.15"` means.
 */
export function satisfies(version: string, specifiers: string): boolean {
  const v = release(version);
  for (const raw of specifiers.split(",")) {
    const spec = raw.trim();
    if (!spec) continue;
    const m = /^(~=|===|==|!=|<=|>=|<|>)\s*(.+)$/.exec(spec);
    if (!m) throw new Error(`invalid version specifier "${spec}"`);
    const [, op, target] = m;
    const wildcard = target.endsWith(".*");
    const t = release(wildcard ? target.slice(0, -2) : target);
    if (!t.length) throw new Error(`invalid version specifier "${spec}"`);
    const prefix = (n: number) => compare(v.slice(0, n), t.slice(0, n)) === 0;
    const c = compare(v, t);
    const ok =
      op === "==" || op === "===" ? (wildcard ? prefix(t.length) : c === 0)
      : op === "!=" ? (wildcard ? !prefix(t.length) : c !== 0)
      : op === ">=" ? c >= 0
      : op === "<=" ? c <= 0
      : op === ">" ? c > 0
      : op === "<" ? c < 0
      : /* ~= */ c >= 0 && prefix(t.length - 1);
    if (!ok) return false;
  }
  return true;
}

// -- choosing a runtime ------------------------------------------------------------------

const SCRIPT_BLOCK = /^# \/\/\/ (?<type>[a-zA-Z0-9-]+)$\n(?<content>(^#(| .*)$\n)+)^# \/\/\/$/gm;

/** requires-python from a PEP 723 `script` block, or null. */
export function scriptRequiresPython(source: string): string | null {
  for (const m of (source.endsWith("\n") ? source : source + "\n").matchAll(SCRIPT_BLOCK)) {
    if (m.groups!.type !== "script") continue;
    const toml = m.groups!.content
      .split("\n")
      .map((line) => (line.startsWith("# ") ? line.slice(2) : line.slice(1)))
      .join("\n");
    try {
      const value = (parseToml(toml) as Record<string, unknown>)["requires-python"];
      return typeof value === "string" ? value : null;
    } catch {
      return null; // the run reports a broken block (_terrarium.py)
    }
  }
  return null;
}

export interface FolderPython {
  /** The `.python-version` that applies and where it is. */
  pin: { version: string; path: string } | null;
  /** requires-python from pyproject.toml in the folder. */
  requires: string | null;
}

const folderCache = new Map<string, { at: number; info: Promise<FolderPython> }>();

/** What a folder says about its Python (cached briefly; `forgetFolders` drops it). */
export function folderPython(dir: string): Promise<FolderPython> {
  const cached = folderCache.get(dir);
  if (cached && Date.now() - cached.at < 5000) return cached.info;
  const info = readFolder(dir);
  folderCache.set(dir, { at: Date.now(), info });
  return info;
}

export function forgetFolders() {
  folderCache.clear();
}

async function readText(path: string): Promise<string | null> {
  try {
    return (await fs.exists(path)) ? await fs.readText(path) : null;
  } catch {
    return null;
  }
}

async function readFolder(dir: string): Promise<FolderPython> {
  let pin: FolderPython["pin"] = null;
  for (let d = dir; ; d = dirname(d)) {
    const path = join(d, ".python-version");
    const text = await readText(path);
    const version = text?.split("\n").map((l) => l.trim()).find((l) => l && !l.startsWith("#"));
    if (version) {
      pin = { version, path };
      break;
    }
    if (!d || isLocationRoot(d)) break;
  }
  let requires: string | null = null;
  const pyproject = await readText(join(dir, "pyproject.toml"));
  if (pyproject) {
    try {
      const project = (parseToml(pyproject) as any).project;
      if (typeof project?.["requires-python"] === "string") requires = project["requires-python"];
    } catch {
      // reported by the run
    }
  }
  return { pin, requires };
}

export type Choice = { ok: true; python: string; reason: string } | { ok: false; error: string };

/** Pick the runtime for a program (its folder and source; no source for the >>> console). */
export function choose(folder: FolderPython, source?: string): Choice {
  const fromScript = source ? scriptRequiresPython(source) : null;
  const requires = fromScript ?? folder.requires;
  const origin = fromScript ? "script metadata" : "pyproject.toml";
  let candidates = RUNTIMES;
  if (requires) {
    try {
      candidates = RUNTIMES.filter((r) => satisfies(r.version, requires));
    } catch (e) {
      return { ok: false, error: `${(e as Error).message} in requires-python (${origin})` };
    }
    if (!candidates.length) {
      return { ok: false, error: `this program requires Python ${requires} (${origin}), but the app has ${RUNTIMES.map((r) => r.version).join(" and ")}` };
    }
  }
  if (folder.pin) {
    const wanted = release(folder.pin.version);
    const pinned = RUNTIMES.find((r) => compare(release(r.version).slice(0, wanted.length), wanted) === 0);
    if (!pinned) {
      return { ok: false, error: `${folder.pin.path} asks for Python ${folder.pin.version}, but the app has ${RUNTIMES.map((r) => r.python).join(" and ")}` };
    }
    if (candidates.includes(pinned)) return { ok: true, python: pinned.python, reason: folder.pin.path };
  }
  const fallback = candidates.find((r) => r.python === defaultPython);
  if (fallback) return { ok: true, python: fallback.python, reason: requires ? `${origin}, default` : "default" };
  const newest = [...candidates].sort((a, b) => compare(release(b.version), release(a.version)));
  const pick = newest.find((r) => !r.prerelease) ?? newest[0];
  return { ok: true, python: pick.python, reason: origin };
}

/** The runtime for a file (or a folder, for the console). */
export async function chooseFor(dir: string, source?: string): Promise<Choice> {
  return choose(await folderPython(dir), source);
}
