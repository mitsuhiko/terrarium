// Notebooks in the editor (D44): one CodeMirror document, cells marked by
// marker lines (see notebook/ipynb.ts). A state field keeps each cell's id,
// type, outputs and count, and follows the markers through edits;
// decorations draw cell headers (.ipynb) or run buttons (# %% in .py),
// outputs below the cells, and Markdown cells rendered while the cursor is
// elsewhere. In a .ipynb the marker lines are hidden and protected: cells are
// added, moved and deleted with the headers' buttons.
import { invertedEffects } from "@codemirror/commands";
import {
  type ChangeSpec, EditorState, type Extension, Facet, MapMode, Prec, RangeSet, RangeSetBuilder, RangeValue, StateEffect,
  StateField, type Text, Transaction, type TransactionSpec,
} from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, keymap, WidgetType } from "@codemirror/view";
import {
  analysisText, type CellInfo, type CellType, markerLine, markerType, newCell, type NotebookKind, type NotebookMeta, serializeIpynb,
} from "../notebook/ipynb";
import type { CellRequest, KernelEvent, KernelState, Output } from "../notebook/types";
import { renderMarkdown, renderOutput, type RenderContext } from "./outputs";
import { takeFocus } from "./focus";

export interface NotebookHooks {
  run(cells: CellRequest[], source: string): void;
  stop(): void;
  restart(): void;
  openURL(url: string): void;
  /** A project file of a traceback (D45), relative to the notebook's folder. */
  openLocation(file: string, line: number): void;
  /** Jump to a line of the document (a cell's line in a traceback): select, scroll, flash. */
  reveal(line: number): void;
}

export const notebookHooks = Facet.define<NotebookHooks, NotebookHooks | null>({ combine: (v) => v[0] ?? null });
const notebookKind = Facet.define<NotebookKind, NotebookKind>({ combine: (v) => v[0] ?? "py" });

export interface Cell {
  info: CellInfo;
  /** The marker line (none for the code before the first marker in a .py). */
  marker: { from: number; to: number } | null;
  /** The source: from the line after the marker to the end of its last line. */
  from: number;
  to: number;
}

export interface NotebookData {
  kind: NotebookKind;
  cells: Cell[];
  meta: NotebookMeta | null;
  kernel: KernelState;
  python: string | null;
}

interface Marker {
  from: number;
  to: number;
  type: CellType;
}

function scan(doc: Text, kind: NotebookKind): Marker[] {
  const out: Marker[] = [];
  let pos = 0;
  for (const it = doc.iterLines(); !it.next().done; ) {
    const line = it.value;
    if (line.startsWith("#")) {
      const type = markerType(kind, line);
      if (type) out.push({ from: pos, to: pos + line.length, type });
    }
    pos += line.length + 1;
  }
  return out;
}

function layout(doc: Text, kind: NotebookKind, markers: Marker[], infoFor: (m: Marker | null) => CellInfo): Cell[] {
  const cells: Cell[] = [];
  if (!markers.length) {
    // A .py without markers is no notebook; a .ipynb always has one cell.
    return kind === "ipynb" ? [{ info: infoFor(null), marker: null, from: 0, to: doc.length }] : [];
  }
  const first = markers[0];
  if (first.from > 0 && (kind === "ipynb" || doc.sliceString(0, first.from - 1).trim())) {
    cells.push({ info: infoFor(null), marker: null, from: 0, to: first.from - 1 });
  }
  markers.forEach((m, i) => {
    const next = markers[i + 1];
    const to = Math.max(next ? next.from - 1 : doc.length, m.to);
    cells.push({ info: infoFor(m), marker: { from: m.from, to: m.to }, from: Math.min(m.to + 1, to), to });
  });
  return cells;
}

function withType(info: CellInfo, type: CellType): CellInfo {
  if (info.type === type) return info;
  return { ...info, type, outputs: type === "code" ? info.outputs : [], count: type === "code" ? info.count : null };
}

/** The cells after an edit: markers that moved keep their cell. */
function reconcile(data: NotebookData, tr: Transaction): NotebookData {
  const doc = tr.state.doc;
  const byPos = new Map<number, CellInfo>();
  let preamble: CellInfo | null = null;
  for (const c of data.cells) {
    if (!c.marker) {
      preamble = c.info;
      continue;
    }
    const pos = tr.changes.mapPos(c.marker.from, 1, MapMode.TrackDel);
    if (pos !== null && !byPos.has(pos)) byPos.set(pos, c.info);
  }
  const cells = layout(doc, data.kind, scan(doc, data.kind), (m) => {
    if (!m) return preamble ?? newCell("code");
    const info = byPos.get(m.from);
    return info ? withType(info, m.type) : newCell(m.type);
  });
  return { ...data, cells };
}

/** A notebook for a document (`infos` from a .ipynb, in order). */
export function notebookData(doc: Text, kind: NotebookKind, infos: CellInfo[] = [], meta: NotebookMeta | null = null): NotebookData {
  let i = 0;
  const cells = layout(doc, kind, scan(doc, kind), (m) => {
    const info = infos[i++];
    return info ? withType(info, m?.type ?? "code") : newCell(m?.type ?? "code");
  });
  return { kind, cells, meta, kernel: "none", python: null };
}

// -- effects ---------------------------------------------------------------------------

/** The cells' infos in their new order (after a structural edit in the same transaction). */
const cellsEffect = StateEffect.define<CellInfo[]>();
const patchEffect = StateEffect.define<{ ids: Set<string> | null; fn: (info: CellInfo) => CellInfo }>();
export const kernelEventsEffect = StateEffect.define<KernelEvent[]>();

const MAX_STREAM = 200_000;

function applyCR(text: string): string {
  if (!text.includes("\r")) return text;
  return text
    .replace(/\r\n/g, "\n")
    .split("\n")
    .map((line) => (line.includes("\r") ? line.slice(line.lastIndexOf("\r") + 1) : line))
    .join("\n");
}

function addOutput(info: CellInfo, output: Output): Output[] {
  const outputs = info.clearOnOutput ? [] : info.outputs.slice();
  const last = outputs.at(-1);
  if (output.output_type === "stream" && last?.output_type === "stream" && last.name === output.name) {
    let text = applyCR(last.text + output.text);
    if (text.length > MAX_STREAM) text = "…\n" + text.slice(-MAX_STREAM);
    outputs[outputs.length - 1] = { ...last, text };
  } else if (output.output_type === "stream") {
    outputs.push({ ...output, text: applyCR(output.text) });
  } else {
    outputs.push(output);
  }
  return outputs;
}

function applyEvents(data: NotebookData, events: KernelEvent[]): NotebookData {
  const cells = data.cells.slice();
  let { kernel, python } = data;
  const index = (id: string) => cells.findIndex((c) => c.info.id === id);
  const patch = (id: string, fn: (info: CellInfo) => CellInfo) => {
    const i = index(id);
    if (i >= 0) cells[i] = { ...cells[i], info: fn(cells[i].info) };
  };
  for (const ev of events) {
    switch (ev.type) {
      case "kernel":
        kernel = ev.state;
        if (ev.python) python = ev.python;
        if (ev.state === "dead") {
          for (let i = 0; i < cells.length; i++) {
            if (cells[i].info.status !== "idle") cells[i] = { ...cells[i], info: { ...cells[i].info, status: "idle" } };
          }
        }
        break;
      case "queued":
        patch(ev.cell, (info) => ({ ...info, status: "queued" }));
        break;
      case "start":
        patch(ev.cell, (info) => ({ ...info, status: "running", count: ev.count, outputs: [], clearOnOutput: false }));
        break;
      case "output":
        patch(ev.cell, (info) => ({ ...info, outputs: addOutput(info, ev.output), clearOnOutput: false }));
        break;
      case "clear":
        patch(ev.cell, (info) => (ev.wait ? { ...info, clearOnOutput: true } : { ...info, outputs: [], clearOnOutput: false }));
        break;
      case "update":
        for (let i = 0; i < cells.length; i++) {
          const info = cells[i].info;
          if (!info.outputs.some((o) => "transient" in o && o.transient?.display_id === ev.displayId)) continue;
          const outputs = info.outputs.map((o) =>
            o.output_type === "display_data" && o.transient?.display_id === ev.displayId ? { ...o, data: ev.data, metadata: ev.metadata } : o,
          );
          cells[i] = { ...cells[i], info: { ...info, outputs } };
        }
        break;
      case "done":
        patch(ev.cell, (info) => ({ ...info, status: "idle" }));
        break;
    }
  }
  return { ...data, cells, kernel, python };
}

export const notebookField = StateField.define<NotebookData>({
  create: (state) => notebookData(state.doc, state.facet(notebookKind)),
  update(data, tr) {
    if (tr.docChanged) data = reconcile(data, tr);
    for (const e of tr.effects) {
      if (e.is(cellsEffect)) {
        const infos = e.value;
        data = { ...data, cells: data.cells.map((c, i) => (infos[i] ? { ...c, info: withType(infos[i], c.info.type) } : c)) };
      } else if (e.is(patchEffect)) {
        const { ids, fn } = e.value;
        data = { ...data, cells: data.cells.map((c) => (!ids || ids.has(c.info.id) ? { ...c, info: fn(c.info) } : c)) };
      } else if (e.is(kernelEventsEffect)) {
        data = applyEvents(data, e.value);
      }
    }
    return data;
  },
});

// Undoing a structural edit puts the cells' infos back too.
const invertCells = invertedEffects.of((tr) => {
  if (!tr.effects.some((e) => e.is(cellsEffect))) return [];
  return [cellsEffect.of(tr.startState.field(notebookField).cells.map((c) => c.info))];
});

// -- reading ------------------------------------------------------------------------------

export const notebookOf = (state: EditorState) => state.field(notebookField, false) ?? null;

/** Whether the document is a notebook: a .ipynb, or a .py with `# %%` cells. */
export const hasCells = (state: EditorState) => (notebookOf(state)?.cells.length ?? 0) > 0;

export function cellIndexAt(data: NotebookData, pos: number): number {
  let found = -1;
  data.cells.forEach((c, i) => {
    if ((c.marker?.from ?? c.from) <= pos && pos <= c.to) found = i;
  });
  return found;
}

const sourceOf = (state: EditorState, cell: Cell) => state.sliceDoc(cell.from, cell.to);

/** The whole notebook's code, for its dependencies and Python version (read when a kernel starts). */
export function notebookSource(state: EditorState): string {
  const data = notebookOf(state);
  if (!data || data.kind === "py") return state.doc.toString();
  return data.cells.filter((c) => c.info.type === "code").map((c) => sourceOf(state, c)).join("\n");
}

/** The file's text: a .ipynb as JSON. */
export function serializeNotebook(state: EditorState): string {
  const data = notebookOf(state)!;
  return serializeIpynb(data.meta ?? { nbformat_minor: 5, metadata: {} }, data.cells.map((c) => ({ info: c.info, source: sourceOf(state, c) })));
}

/** What ruff and ty check: the document with non-Python blanked (positions unchanged). */
export function analysisSource(state: EditorState): string {
  const data = notebookOf(state);
  if (!data || data.kind !== "ipynb") return state.doc.toString();
  return analysisText(state.doc.toString(), data.cells.map((c) => ({ type: c.info.type, from: c.from, to: c.to })));
}

/** The cells as the self-test and the host see them. */
export function notebookSummary(state: EditorState) {
  const data = notebookOf(state);
  if (!data) return null;
  return {
    kind: data.kind,
    kernel: data.kernel,
    python: data.python,
    active: cellIndexAt(data, state.selection.main.head),
    cells: data.cells.map((c) => ({
      id: c.info.id, type: c.info.type, count: c.info.count, status: c.info.status, source: sourceOf(state, c),
      outputs: c.info.outputs.map((o) => {
        if (o.output_type === "stream") return { type: "stream", name: o.name, text: o.text };
        if (o.output_type === "error") {
          // The traceback as data (D45): "type: file:line ..." per exception.
          const trace = o.trace?.exceptions.map((e) => `${e.type}: ${e.frames.map((f) => `${f.file}:${f.line}`).join(" ")}`) ?? null;
          return { type: "error", ename: o.ename, evalue: o.evalue, trace };
        }
        if (o.output_type === "status") return { type: "status", text: o.text };
        return { type: o.output_type, mimes: Object.keys(o.data ?? {}), text: String(o.data?.["text/plain"] ?? "") };
      }),
    })),
  };
}

// -- commands --------------------------------------------------------------------------------

function activeIndex(state: EditorState) {
  const data = notebookOf(state);
  return data ? cellIndexAt(data, state.selection.main.head) : -1;
}

export function runCells(view: EditorView, indices: number[]) {
  const data = notebookOf(view.state);
  const hooks = view.state.facet(notebookHooks);
  if (!data || !hooks) return;
  // Code cells with code in them (not just comments, like the top of a .py).
  const cells = indices
    .map((i) => data.cells[i])
    .filter((c) => c && c.info.type === "code" && sourceOf(view.state, c).split("\n").some((l) => l.trim() && !l.trim().startsWith("#")));
  if (!cells.length) return;
  hooks.run(cells.map((c) => ({ id: c.info.id, code: sourceOf(view.state, c) })), notebookSource(view.state));
}

function focusCell(view: EditorView, index: number) {
  const cell = notebookOf(view.state)?.cells[index];
  if (!cell) return;
  view.dispatch({ selection: { anchor: cell.from }, scrollIntoView: true });
}

/** Run a cell (the one with the cursor); `advance` moves on, adding a cell at the end of a .ipynb. */
export function runCell(view: EditorView, index = activeIndex(view.state), advance = false): boolean {
  const data = notebookOf(view.state);
  if (!data?.cells.length) return false;
  if (index < 0) index = 0;
  runCells(view, [index]);
  if (advance) {
    if (index + 1 < data.cells.length) focusCell(view, index + 1);
    else if (data.kind === "ipynb") insertCell(view, index, "code");
    else view.contentDOM.blur(); // a rendered Markdown cell shows
  }
  return true;
}

export const runAll = (view: EditorView) => runCells(view, notebookOf(view.state)?.cells.map((_, i) => i) ?? []);
export const runAbove = (view: EditorView, index = activeIndex(view.state)) => runCells(view, [...Array(Math.max(0, index)).keys()]);
export function runBelow(view: EditorView, index = activeIndex(view.state)) {
  const n = notebookOf(view.state)?.cells.length ?? 0;
  runCells(view, [...Array(n).keys()].filter((i) => i >= Math.max(0, index)));
}

const infosOf = (data: NotebookData) => data.cells.map((c) => c.info);

/** Add a cell after `after` (-1: at the top) and put the cursor in it. */
export function insertCell(view: EditorView, after = activeIndex(view.state), type: CellType = "code") {
  const data = notebookOf(view.state);
  if (!data) return;
  const marker = markerLine(data.kind, type);
  const infos = infosOf(data);
  let change: ChangeSpec;
  let cursor: number;
  if (!data.cells.length) {
    // A .py without cells: the first marker goes at the end.
    const end = view.state.doc.length;
    const insert = `${end && !view.state.doc.toString().endsWith("\n") ? "\n" : ""}${end ? "\n" : ""}${marker}\n`;
    view.dispatch({ changes: { from: end, insert }, selection: { anchor: end + insert.length }, scrollIntoView: true, userEvent: "cell.insert" });
    takeFocus(view);
    return;
  }
  if (after < 0) {
    const at = data.cells[0].marker?.from ?? 0;
    change = { from: at, insert: `${marker}\n\n` };
    cursor = at + marker.length + 1;
    infos.unshift(newCell(type));
  } else {
    const cell = data.cells[Math.min(after, data.cells.length - 1)];
    const insert = data.kind === "py" ? `\n\n${marker}\n` : `\n${marker}\n`;
    change = { from: cell.to, insert };
    cursor = cell.to + insert.length;
    infos.splice(Math.min(after, data.cells.length - 1) + 1, 0, newCell(type));
  }
  view.dispatch({ changes: change, selection: { anchor: cursor }, effects: cellsEffect.of(infos), scrollIntoView: true, userEvent: "cell.insert" });
  takeFocus(view);
}

export function deleteCell(view: EditorView, index = activeIndex(view.state)) {
  const data = notebookOf(view.state);
  if (!data || index < 0 || index >= data.cells.length) return;
  const cells = data.cells;
  const infos = infosOf(data);
  if (cells.length === 1 && data.kind === "ipynb") {
    // The last cell stays, empty.
    const c = cells[0];
    view.dispatch({
      changes: { from: c.from, to: c.to }, effects: cellsEffect.of([{ ...c.info, outputs: [], count: null }]), userEvent: "cell.delete",
    });
    return;
  }
  const c = cells[index];
  const from = index < cells.length - 1 ? (c.marker?.from ?? c.from) : index > 0 ? cells[index - 1].to : 0;
  const to = index < cells.length - 1 ? cells[index + 1].marker!.from : c.to;
  infos.splice(index, 1);
  const next = Math.min(index, cells.length - 2);
  view.dispatch({ changes: { from, to }, effects: cellsEffect.of(infos), userEvent: "cell.delete" });
  const cell = notebookOf(view.state)?.cells[next];
  if (cell) view.dispatch({ selection: { anchor: cell.from }, scrollIntoView: true });
}

export function moveCell(view: EditorView, index: number, delta: -1 | 1) {
  const data = notebookOf(view.state);
  if (!data) return;
  const j = index + delta;
  const a = data.cells[Math.min(index, j)];
  const b = data.cells[Math.max(index, j)];
  if (!a?.marker || !b?.marker) return;
  const doc = view.state.doc;
  const textA = doc.sliceString(a.marker.from, a.to);
  const textB = doc.sliceString(b.marker.from, b.to);
  const head = view.state.selection.main.head;
  const moved = data.cells[index];
  const offset = Math.max(0, head - moved.marker!.from);
  const start = delta < 0 ? a.marker.from : a.marker.from + textB.length + 1;
  const infos = infosOf(data);
  [infos[index], infos[j]] = [infos[j], infos[index]];
  view.dispatch({
    changes: { from: a.marker.from, to: b.to, insert: `${textB}\n${textA}` },
    selection: { anchor: start + Math.min(offset, (delta < 0 ? textB : textA).length) },
    effects: cellsEffect.of(infos), scrollIntoView: true, userEvent: "cell.move",
  });
}

export function setCellType(view: EditorView, index: number, type: CellType) {
  const data = notebookOf(view.state);
  const cell = data?.cells[index];
  if (!data || !cell?.marker || cell.info.type === type) return;
  const infos = infosOf(data);
  infos[index] = withType(cell.info, type);
  view.dispatch({
    changes: { from: cell.marker.from, to: cell.marker.to, insert: markerLine(data.kind, type) },
    effects: cellsEffect.of(infos), userEvent: "cell.type",
  });
}

export function clearOutputs(view: EditorView, index: number | null = null) {
  const data = notebookOf(view.state);
  if (!data) return;
  const ids = index === null ? null : new Set([data.cells[index]?.info.id].filter(Boolean) as string[]);
  view.dispatch({ effects: patchEffect.of({ ids, fn: (info) => ({ ...info, outputs: [], count: index === null ? null : info.count }) }) });
}

// -- protecting a .ipynb's marker lines --------------------------------------------------

/**
 * Typing and deleting must not break a marker line (or join it to a cell):
 * edits that touch one are cut down to the parts inside cells. Backspace at
 * the start of a cell does nothing, as in Jupyter.
 */
const protectMarkers = EditorState.transactionFilter.of((tr): Transaction | TransactionSpec | readonly TransactionSpec[] => {
  if (!tr.docChanged || !(tr.isUserEvent("input") || tr.isUserEvent("delete") || tr.isUserEvent("move"))) return tr;
  const data = notebookOf(tr.startState);
  if (!data || data.kind !== "ipynb") return tr;
  const guards = data.cells.filter((c) => c.marker).map((c) => ({
    from: Math.max(0, c.marker!.from - 1), to: c.marker!.to + 1, markerFrom: c.marker!.from, markerTo: c.marker!.to,
  }));
  let touched = false;
  const changes: { from: number; to: number; insert: string }[] = [];
  tr.changes.iterChanges((fromA, toA, _fromB, _toB, inserted) => {
    const text = inserted.toString();
    if (fromA === toA) {
      if (guards.some((g) => g.markerFrom <= fromA && fromA <= g.markerTo)) touched = true;
      else changes.push({ from: fromA, to: toA, insert: text });
      return;
    }
    let parts: [number, number][] = [[fromA, toA]];
    for (const g of guards) {
      parts = parts.flatMap(([a, b]): [number, number][] =>
        b <= g.from || a >= g.to ? [[a, b]] : ([[a, Math.min(b, g.from)], [Math.max(a, g.to), b]] as [number, number][]).filter(([x, y]) => y > x),
      );
    }
    if (parts.length !== 1 || parts[0][0] !== fromA || parts[0][1] !== toA) touched = true;
    parts.forEach(([a, b], k) => changes.push({ from: a, to: b, insert: k === 0 ? text : "" }));
  });
  if (!touched) return tr;
  if (!changes.length) return [];
  const first = changes[0];
  return { changes, selection: { anchor: first.from + first.insert.length }, scrollIntoView: true, userEvent: tr.annotation(Transaction.userEvent) };
});

class Atom extends RangeValue {}
const atom = new Atom();

/** The cursor steps over a .ipynb's hidden marker lines. */
const atomicMarkers = EditorView.atomicRanges.of((view) => {
  const data = notebookOf(view.state);
  if (!data || data.kind !== "ipynb") return RangeSet.empty;
  const b = new RangeSetBuilder<Atom>();
  for (const c of data.cells) {
    if (c.marker) b.add(Math.max(0, c.marker.from - 1), Math.min(view.state.doc.length, c.marker.to + 1), atom);
  }
  return b.finish();
});

// -- widgets ------------------------------------------------------------------------------

function button(label: string, title: string, onClick: () => void, className = ""): HTMLButtonElement {
  const b = document.createElement("button");
  b.className = `nb-button ${className}`;
  b.innerHTML = label;
  b.title = title;
  b.setAttribute("aria-label", title);
  b.addEventListener("mousedown", (e) => e.preventDefault());
  b.addEventListener("click", (e) => {
    e.preventDefault();
    e.stopPropagation();
    onClick();
  });
  return b;
}

const ICONS = {
  play: `<svg viewBox="0 0 16 16" width="13" height="13"><path d="M4 2.5v11l9.5-5.5z" fill="currentColor"/></svg>`,
  playAll: `<svg viewBox="0 0 20 16" width="17" height="13"><path d="M2 2.5v11l8-5.5zM10 2.5v11l8-5.5z" fill="currentColor"/></svg>`,
  stop: `<svg viewBox="0 0 16 16" width="12" height="12"><rect x="3" y="3" width="10" height="10" rx="1.5" fill="currentColor"/></svg>`,
  up: `<svg viewBox="0 0 16 16" width="14" height="14"><path d="M8 3 3 9h3.5v4h3V9H13z" fill="currentColor"/></svg>`,
  down: `<svg viewBox="0 0 16 16" width="14" height="14"><path d="M8 13 3 7h3.5V3h3v4H13z" fill="currentColor"/></svg>`,
  plus: `<svg viewBox="0 0 16 16" width="14" height="14"><path d="M7 2h2v5h5v2H9v5H7V9H2V7h5z" fill="currentColor"/></svg>`,
  trash: `<svg viewBox="0 0 16 16" width="14" height="14"><path d="M6 1.5h4l.5 1H14v1.5H2V2.5h3.5zM3.5 5h9l-.8 9.5H4.3z" fill="currentColor"/></svg>`,
  restart: `<svg viewBox="0 0 16 16" width="14" height="14"><path d="M8 2.5a5.5 5.5 0 1 0 5.4 6.5h-1.8A3.8 3.8 0 1 1 8 4.2V6.5l3.5-3L8 .5z" fill="currentColor"/></svg>`,
  clear: `<svg viewBox="0 0 16 16" width="14" height="14"><path d="M3.5 3.5l9 9m0-9-9 9" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>`,
};

const countLabel = (info: CellInfo) => (info.status === "running" ? "[*]" : info.status === "queued" ? "[…]" : `[${info.count ?? " "}]`);

function runButton(view: EditorView, info: CellInfo): HTMLButtonElement {
  const hooks = () => view.state.facet(notebookHooks);
  const running = info.status === "running";
  return button(
    running ? ICONS.stop : ICONS.play,
    running ? "Stop" : "Run Cell",
    () => {
      if (running) return hooks()?.stop();
      const i = notebookOf(view.state)?.cells.findIndex((c) => c.info.id === info.id) ?? -1;
      if (i >= 0) runCell(view, i);
    },
    `nb-run${running ? " running" : ""}`,
  );
}

const indexOf = (view: EditorView, id: string) => notebookOf(view.state)?.cells.findIndex((c) => c.info.id === id) ?? -1;

/** A .ipynb cell's header: run, its count; tools for the cell with the cursor. */
class HeaderWidget extends WidgetType {
  constructor(readonly info: CellInfo, readonly active: boolean, readonly first: boolean, readonly last: boolean) {
    super();
  }

  eq(other: HeaderWidget) {
    return other.info === this.info && other.active === this.active && other.first === this.first && other.last === this.last;
  }

  toDOM(view: EditorView) {
    const { info } = this;
    const el = document.createElement("div");
    el.className = `nb-header nb-${info.type}${this.active ? " active" : ""}${this.first ? " first" : ""}`;
    // A rendered Markdown cell needs no header: just room above it.
    if (info.type !== "code" && !this.active) {
      el.classList.add("quiet");
      return el;
    }
    if (info.type === "code") {
      el.append(runButton(view, info));
      const count = document.createElement("span");
      count.className = "nb-count";
      count.textContent = countLabel(info);
      el.append(count);
    } else {
      const label = document.createElement("span");
      label.className = "nb-label";
      label.textContent = info.type === "markdown" ? "Markdown" : "Raw";
      el.append(label);
    }
    const spacer = document.createElement("span");
    spacer.className = "nb-spacer";
    el.append(spacer);
    if (this.active) {
      const at = () => indexOf(view, info.id);
      const tools = document.createElement("span");
      tools.className = "nb-tools";
      const next: CellType = info.type === "code" ? "markdown" : "code";
      tools.append(
        button(next === "code" ? "Code" : "Markdown", next === "code" ? "Make Code Cell" : "Make Markdown Cell", () => setCellType(view, at(), next), "nb-text"),
        button(ICONS.up, "Move Up", () => moveCell(view, at(), -1), this.first ? "disabled" : ""),
        button(ICONS.down, "Move Down", () => moveCell(view, at(), 1), this.last ? "disabled" : ""),
        button(ICONS.plus, "Add Cell Below", () => insertCell(view, at(), "code")),
        button(ICONS.trash, "Delete Cell", () => deleteCell(view, at())),
      );
      el.append(tools);
    }
    return el;
  }

  ignoreEvent() {
    return true;
  }
}

/** A `# %%` line's run button and count, after the marker text. */
class ChipWidget extends WidgetType {
  constructor(readonly info: CellInfo) {
    super();
  }

  eq(other: ChipWidget) {
    return other.info.status === this.info.status && other.info.count === this.info.count && other.info.type === this.info.type && other.info.id === this.info.id;
  }

  toDOM(view: EditorView) {
    const el = document.createElement("span");
    el.className = "nb-chip";
    if (this.info.type !== "code") return el;
    el.append(runButton(view, this.info));
    if (this.info.count !== null || this.info.status !== "idle") {
      const count = document.createElement("span");
      count.className = "nb-count";
      count.textContent = countLabel(this.info);
      el.append(count);
    }
    return el;
  }

  ignoreEvent() {
    return true;
  }
}

const renderContext = (view: EditorView): RenderContext => ({
  openURL: (url) => view.state.facet(notebookHooks)?.openURL(url),
  resized: () => view.requestMeasure(),
  // Traceback frames (D45): a cell of this notebook ("<cell 3>", by its count) or a project file.
  canOpen: (frame) => {
    if (frame.kind !== "app" || !frame.file) return false;
    const count = cellCount(frame.file);
    if (count !== null) return !!cellByCount(view, count);
    return !frame.file.startsWith("<") && !frame.file.startsWith("/");
  },
  open: (frame) => {
    const count = cellCount(frame.file ?? "");
    if (count === null) return view.state.facet(notebookHooks)?.openLocation(frame.file!, frame.line ?? 1);
    const cell = cellByCount(view, count);
    if (!cell) return;
    const doc = view.state.doc;
    const first = doc.lineAt(cell.from).number;
    const last = doc.lineAt(Math.max(cell.from, cell.to)).number;
    view.state.facet(notebookHooks)?.reveal(Math.min(last, first + Math.max(0, (frame.line ?? 1) - 1)));
  },
});

const cellCount = (file: string) => {
  const m = /^<cell (\d+)>$/.exec(file);
  return m ? Number(m[1]) : null;
};

const cellByCount = (view: EditorView, count: number) =>
  notebookOf(view.state)?.cells.find((c) => c.info.type === "code" && c.info.count === count);

/** A Markdown cell, rendered; a tap edits it. */
class MarkdownWidget extends WidgetType {
  constructor(readonly id: string, readonly source: string, readonly attachments: Record<string, unknown> | undefined) {
    super();
  }

  eq(other: MarkdownWidget) {
    return other.id === this.id && other.source === this.source && other.attachments === this.attachments;
  }

  toDOM(view: EditorView) {
    const el = document.createElement("div");
    el.className = "nb-md-cell";
    if (this.source.trim()) el.append(renderMarkdown(this.source, renderContext(view), this.attachments));
    else {
      el.classList.add("empty");
      el.textContent = "Empty Markdown cell: tap to write";
    }
    el.addEventListener("click", (e) => {
      if (e.composedPath().some((n) => n instanceof HTMLAnchorElement)) return;
      const cell = notebookOf(view.state)?.cells.find((c) => c.info.id === this.id);
      if (!cell) return;
      view.dispatch({ selection: { anchor: cell.from }, scrollIntoView: true });
      view.focus();
    });
    return el;
  }

  ignoreEvent() {
    return true;
  }
}

/** A cell's outputs; redrawn in place, keeping outputs that did not change. */
class OutputsWidget extends WidgetType {
  constructor(readonly info: CellInfo) {
    super();
  }

  eq(other: OutputsWidget) {
    return other.info.outputs === this.info.outputs && other.info.status === this.info.status;
  }

  toDOM(view: EditorView) {
    const el = document.createElement("div");
    el.className = "nb-outputs";
    this.fill(el, view);
    return el;
  }

  updateDOM(dom: HTMLElement, view: EditorView) {
    this.fill(dom, view);
    return true;
  }

  private fill(el: HTMLElement, view: EditorView) {
    const cache: Map<Output, HTMLElement> = (el as any).__cache ?? new Map();
    const next = new Map<Output, HTMLElement>();
    const children: HTMLElement[] = [];
    for (const output of this.info.outputs) {
      const node = cache.get(output) ?? renderOutput(output, renderContext(view));
      next.set(output, node);
      children.push(node);
    }
    if (!this.info.outputs.length && this.info.status !== "idle") {
      const waiting = document.createElement("div");
      waiting.className = "nb-status";
      waiting.textContent = this.info.status === "running" ? "Running…" : "Waiting…";
      children.push(waiting);
    }
    (el as any).__cache = next;
    el.classList.toggle("running", this.info.status === "running");
    el.replaceChildren(...children);
    view.requestMeasure();
  }

  ignoreEvent() {
    return true;
  }
}

/** The top of a .ipynb: Run All, Restart, Clear, and the kernel. */
class ToolbarWidget extends WidgetType {
  constructor(readonly kernel: KernelState, readonly python: string | null, readonly running: boolean) {
    super();
  }

  eq(other: ToolbarWidget) {
    return other.kernel === this.kernel && other.python === this.python && other.running === this.running;
  }

  toDOM(view: EditorView) {
    const hooks = () => view.state.facet(notebookHooks);
    const el = document.createElement("div");
    el.className = "nb-toolbar";
    el.append(
      this.running
        ? button(`${ICONS.stop}<span>Stop</span>`, "Stop", () => hooks()?.stop(), "nb-pill stop")
        : button(`${ICONS.playAll}<span>Run All</span>`, "Run All", () => runAll(view), "nb-pill"),
      button(`${ICONS.restart}<span>Restart</span>`, "Restart Kernel", () => hooks()?.restart(), `nb-pill${this.kernel === "none" || this.kernel === "dead" ? " disabled" : ""}`),
      button(`${ICONS.clear}<span>Clear</span>`, "Clear Outputs", () => clearOutputs(view), "nb-pill"),
    );
    const state = document.createElement("span");
    state.className = `nb-kernel ${this.kernel}`;
    const name = this.python ? `Python ${this.python}` : "Python";
    state.textContent =
      this.kernel === "busy" ? `${name} · busy` : this.kernel === "idle" ? `${name} · idle` : this.kernel === "starting" ? "Starting…" : "No kernel";
    el.append(state);
    return el;
  }

  ignoreEvent() {
    return true;
  }
}

/** The end of a .ipynb: add a cell. */
class AddBarWidget extends WidgetType {
  eq() {
    return true;
  }

  toDOM(view: EditorView) {
    const el = document.createElement("div");
    el.className = "nb-addbar";
    const last = () => (notebookOf(view.state)?.cells.length ?? 1) - 1;
    el.append(
      button(`${ICONS.plus}<span>Code</span>`, "Add Code Cell", () => insertCell(view, last(), "code"), "nb-pill"),
      button(`${ICONS.plus}<span>Markdown</span>`, "Add Markdown Cell", () => insertCell(view, last(), "markdown"), "nb-pill"),
    );
    return el;
  }

  ignoreEvent() {
    return true;
  }
}

/** Markdown in a .py is comments: `# text`. */
function commentMarkdown(source: string): string | null {
  const lines = source.split("\n");
  if (!lines.every((l) => !l.trim() || /^\s*#/.test(l))) return null;
  return lines.map((l) => l.replace(/^\s*# ?/, "")).join("\n");
}

function buildDecorations(state: EditorState, data: NotebookData, active: number): DecorationSet {
  if (!data.cells.length) return Decoration.none;
  const b = new RangeSetBuilder<Decoration>();
  const ipynb = data.kind === "ipynb";
  const running = data.cells.some((c) => c.info.status !== "idle");
  if (ipynb) b.add(0, 0, Decoration.widget({ widget: new ToolbarWidget(data.kernel, data.python, running), block: true, side: -2 }));
  data.cells.forEach((cell, i) => {
    const { info } = cell;
    if (cell.marker) {
      if (ipynb) {
        const widget = new HeaderWidget(info, i === active, i === 0, i === data.cells.length - 1);
        b.add(cell.marker.from, cell.marker.to, Decoration.replace({ widget, block: true }));
      } else {
        b.add(cell.marker.from, cell.marker.from, Decoration.line({ class: `cm-nb-marker${i === active ? " active" : ""}` }));
        b.add(cell.marker.to, cell.marker.to, Decoration.widget({ widget: new ChipWidget(info), side: 1 }));
      }
    }
    const source = state.sliceDoc(cell.from, cell.to);
    const markdown = info.type === "markdown" && i !== active ? (ipynb ? source : commentMarkdown(source)) : null;
    if (markdown !== null && cell.to > cell.from) {
      b.add(cell.from, cell.to, Decoration.replace({ widget: new MarkdownWidget(info.id, markdown, info.attachments as Record<string, unknown> | undefined), block: true }));
    } else if (ipynb && cell.marker) {
      const empty = markdown !== null;
      for (let pos = cell.from; pos <= cell.to; ) {
        const line = state.doc.lineAt(pos);
        const classes = [`cm-nb-line`, `cm-nb-${info.type}`];
        if (line.from === cell.from) classes.push("cm-nb-first");
        if (line.to >= cell.to) classes.push("cm-nb-last");
        if (i === active) classes.push("cm-nb-active");
        if (empty) classes.push("cm-nb-empty-md");
        b.add(line.from, line.from, Decoration.line({ class: classes.join(" ") }));
        pos = line.to + 1;
      }
    }
    if (info.type === "code" && (info.outputs.length || info.status !== "idle")) {
      b.add(cell.to, cell.to, Decoration.widget({ widget: new OutputsWidget(info), block: true, side: 1 }));
    }
  });
  if (ipynb) b.add(state.doc.length, state.doc.length, Decoration.widget({ widget: new AddBarWidget(), block: true, side: 2 }));
  return b.finish();
}

/** Whether the editor has focus: only then is a cell "active" (its Markdown as source, its tools). */
const focusEffect = StateEffect.define<boolean>();
const focusField = StateField.define<boolean>({
  create: () => false,
  update(focused, tr) {
    for (const e of tr.effects) if (e.is(focusEffect)) focused = e.value;
    return focused;
  },
});
const focusTracker = EditorView.updateListener.of((u) => {
  if (!u.focusChanged) return;
  // Not while this update is going on.
  queueMicrotask(() => {
    const focused = u.view.hasFocus;
    if (u.view.state.field(focusField, false) !== focused) u.view.dispatch({ effects: focusEffect.of(focused) });
  });
});

const activeCell = (state: EditorState, data: NotebookData | null) =>
  data && state.field(focusField, false) ? cellIndexAt(data, state.selection.main.head) : -1;

const decorationField = StateField.define<{ deco: DecorationSet; data: NotebookData | null; active: number }>({
  create(state) {
    const data = notebookOf(state);
    const active = activeCell(state, data);
    return { deco: data ? buildDecorations(state, data, active) : Decoration.none, data, active };
  },
  update(value, tr) {
    const data = notebookOf(tr.state);
    const active = activeCell(tr.state, data);
    if (data === value.data && active === value.active) return value;
    return { deco: data ? buildDecorations(tr.state, data, active) : Decoration.none, data, active };
  },
  provide: (f) => EditorView.decorations.from(f, (v) => v.deco),
});

const cellKeys = Prec.high(
  keymap.of([
    { key: "Shift-Enter", run: (view) => hasCells(view.state) && runCell(view, undefined, true) },
    { key: "Mod-Enter", run: (view) => hasCells(view.state) && runCell(view) },
  ]),
);

/** Cells for a .py (with `# %%`) or a .ipynb (its parsed cells as `data`). */
export function notebookExtensions(kind: NotebookKind, hooks: NotebookHooks, init?: { infos: CellInfo[]; meta: NotebookMeta }): Extension[] {
  return [
    notebookKind.of(kind),
    notebookHooks.of(hooks),
    init ? notebookField.init((state) => notebookData(state.doc, kind, init.infos, init.meta)) : notebookField,
    focusField,
    focusTracker,
    decorationField,
    invertCells,
    cellKeys,
    ...(kind === "ipynb" ? [protectMarkers, atomicMarkers] : []),
  ];
}
