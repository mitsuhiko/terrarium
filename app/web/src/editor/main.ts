// Editor page entry (D31): one CodeMirror pane in its own web view. The host
// drives it through window.__editor and gets events through the bridge.
// Analysis requests go through the host to the engine page.
import { METHODS, setAnalysis, type AnalysisApi } from "../analysis/api";
import { call } from "../host";
import { settings } from "../settings";
import { editorEvent, PaneEditor } from "./editor";
import "./editor.css";
import { installThemes, THEMES } from "./themes";

installThemes();

const remote = Object.fromEntries(METHODS.map((m) => [m, (...args: unknown[]) => call("analysis", { method: m, args })])) as unknown as AnalysisApi;
setAnalysis(remote);

const editor = new PaneEditor(document.getElementById("editor")!, document.getElementById("problem-bar")!, document.getElementById("preview")!);

type Api = Record<string, (...args: any[]) => unknown>;
const api: Api = {
  open: (path: string | null, text: string, readOnly: boolean) => editor.open(path, text, readOnly),
  has: (path: string) => editor.has(path),
  path: () => editor.path,
  text: (path?: string) => editor.text(path),
  flush: () => editor.flush(),
  setBreakpoints: (list) => editor.setBreakpoints(list),
  setPaused: (paused: boolean, errorStyle: boolean) => editor.setPaused(paused, errorStyle),
  setDebugLine: (line: number | null, fraction: number) => editor.setDebugLine(line, fraction),
  reveal: (line: number, column?: number, fraction?: number) => editor.reveal(line, column, fraction),
  revealRange: (from: number, to: number, fraction?: number) => editor.revealRange(from, to, fraction),
  insert: (text: string, offset?: number) => editor.insert(text, offset),
  command: (name) => editor.command(name),
  key: (action: string) => editor.key(action),
  applyRemote: (path: string, changes: string, notebook?: boolean) => editor.applyRemote(path, changes, !!notebook),
  // notebooks (D44)
  notebookEvents: (path: string, events: any[]) => editor.notebookEvents(path, events),
  notebookCommand: (name: string) => editor.notebookCommand(name),
  notebookInfo: () => editor.notebookInfo(),
  setView: (mode: "notebook" | "preview" | "source") => editor.setView(mode),
  // Markdown (D46)
  revealAnchor: (anchor: string) => editor.revealAnchor(anchor),
  markdownInfo: () => editor.markdownInfo(),
  previewFollow: (href: string) => editor.previewFollow(href),
  notebookRun: (index: number) => editor.notebookRun(index),
  backspace: () => editor.backspace(),
  frameProbes: () => (window as any).__nbProbes ?? [],
  // Tracebacks drawn in the outputs (D45): what shows, and a tap on a frame's place.
  traceProbe: () =>
    [...document.querySelectorAll<HTMLElement>(".nb-trace")].map((t) => ({
      type: t.querySelector(".tb-head .tb-type")?.textContent ?? null,
      message: t.querySelector(".tb-head .tb-msg")?.textContent ?? null,
      frames: t.querySelectorAll(".tb-frame").length,
      open: [...t.querySelectorAll<HTMLDetailsElement>(".tb-frame[open]")].map((d) => d.querySelector(".tb-name")?.textContent ?? ""),
      span: t.querySelector(".tb-span")?.textContent ?? null,
      links: t.querySelectorAll(".tb-loc.link").length,
    })),
  traceTap: (index: number) => {
    const link = document.querySelectorAll<HTMLElement>(".nb-trace")[index]?.querySelector<HTMLElement>(".tb-loc.link");
    link?.click();
    return !!link;
  },
  replaceText: (path: string, text: string) => editor.replaceText(path, text),
  renamePath: (from: string, to: string) => editor.renamePath(from, to),
  forget: (path: string) => editor.forget(path),
  cursor: () => editor.cursor(),
  format: () => editor.format(),
  outline: () => editor.outline(),
  problems: () => editor.problems(),
  applyFix: (index: number, action: number) => editor.applyFix(index, action),
  selectProblem: (index: number) => editor.selectProblem(index),
  relint: () => editor.relint(),
  focus: () => editor.focus(),
  blur: () => editor.blur(),
  settings: (s: { fontSize: number; wrap: boolean; theme?: string }) => settings.update(s),
  themes: () => THEMES,
  setInsets: (bottom: number) => document.documentElement.style.setProperty("--bottom-inset", `${bottom}px`),
  // self-test
  setText: (text: string) => editor.setText(text),
  diagnostics: () => editor.diagnostics(),
  applyFixNamed: (name: string) => editor.applyFixNamed(name),
  setCursor: (line: number, column: number) => editor.setCursor(line, column),
  info: () => editor.info(),
  themeState: () => {
    const style = getComputedStyle(document.documentElement);
    return { theme: document.documentElement.dataset.theme, bg: style.getPropertyValue("--editor-bg").trim(), dark: matchMedia("(prefers-color-scheme: dark)").matches };
  },
};

(window as any).__editor = {
  call: async (method: string, args: unknown[] = []) => {
    const fn = api[method];
    if (!fn) throw new Error(`unknown editor method ${method}`);
    const result = await fn(...args);
    return result === undefined ? null : result;
  },
};
(window as any).__terrariumKey = (action: string) => editor.key(action);
(window as any).__editorView = editor.view; // debugging aid

void editorEvent("ready");
