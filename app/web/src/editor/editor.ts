// One editor pane (D31): CodeMirror 6 in its own web view, driven by the
// native host. One view, one cached EditorState per file (undo history and
// selection survive switching files). The host calls window.__editor; the
// page reports back with editorEvent().
import { autocompletion, closeBrackets, closeBracketsKeymap, completionKeymap } from "@codemirror/autocomplete";
import {
  defaultKeymap, deleteCharBackward, history, historyKeymap, indentLess, indentMore, indentWithTab, redo, toggleComment, undo,
} from "@codemirror/commands";
import { markdownKeymap, markdownLanguage, pasteURLAsLink } from "@codemirror/lang-markdown";
import { python, pythonLanguage } from "@codemirror/lang-python";
import {
  bracketMatching, ensureSyntaxTree, HighlightStyle, indentOnInput, indentUnit, Language, LanguageSupport, syntaxHighlighting,
} from "@codemirror/language";
import { type Diagnostic, forEachDiagnostic, forceLinting } from "@codemirror/lint";
import { highlightSelectionMatches, openSearchPanel, search, searchKeymap } from "@codemirror/search";
import {
  Annotation, ChangeSet, Compartment, EditorState, type Extension, Prec, RangeSetBuilder, StateEffect, StateField, Transaction,
} from "@codemirror/state";
import {
  Decoration, type DecorationSet, drawSelection, EditorView, highlightActiveLine, highlightActiveLineGutter,
  highlightSpecialChars, keymap, lineNumbers, ViewPlugin, type ViewUpdate,
} from "@codemirror/view";
import { tags as t } from "@lezer/highlight";
import { type MarkdownParser, parseCode } from "@lezer/markdown";
import { type AnalysisSource, analysisCompletions, analysisLinter, formatDocument, formatRanges } from "../analysis/codemirror";
import type { Breakpoint } from "../debug/breakpoints";
import {
  breakpointLines, debugExtensions, pausedCompartment, pausedExtension, setBreakpointsEffect, setDebugLineEffect,
} from "../debug/codemirror";
import { call } from "../host";
import { focusLog, takeFocus } from "./focus";
import { parseIpynb } from "../notebook/ipynb";
import type { KernelEvent } from "../notebook/types";
import { settings } from "../settings";
import { isMarkdownPath, MarkdownPreview, slug, worthPreviewing } from "./markdown";
import {
  analysisSource, clearOutputs, deleteCell, insertCell, kernelEventsEffect, moveCell, type NotebookHooks, notebookExtensions, notebookOf,
  notebookSummary, runAbove, runAll, runBelow, runCell, serializeNotebook, setCellType,
} from "./notebook";

export type EditorCommand = "undo" | "redo" | "indent" | "dedent" | "comment" | "left" | "right" | "up" | "down" | "search";

export const editorEvent = (type: string, value: Record<string, unknown> = {}) => call("editor.event", { type, ...value }).catch(() => {});

const rectOf = (r: DOMRect) => ({ x: r.left, y: r.top, width: r.width, height: r.height });

const wrapCompartment = new Compartment();
const readOnlyCompartment = new Compartment();
// Markdown is prose: it always wraps (D46), list items under their text.
const wrapping = (on: boolean, prose = false) =>
  prose ? [EditorView.lineWrapping, proseHanging] : on ? [EditorView.lineWrapping, codeHanging] : [];
const readOnlyExt = (on: boolean) => (on ? [EditorState.readOnly.of(true), EditorView.editable.of(false)] : []);

/** Marks transactions that mirror another pane's edits (not saved or re-sent). */
const remote = Annotation.define<boolean>();

// A short highlight on a line we jumped to.
const flashEffect = StateEffect.define<number | null>();
const flashField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(deco, tr) {
    deco = deco.map(tr.changes);
    for (const e of tr.effects) {
      if (!e.is(flashEffect)) continue;
      deco = e.value === null ? Decoration.none : Decoration.set([Decoration.line({ class: "cm-flash-line" }).range(e.value)]);
    }
    return deco;
  },
  provide: (f) => EditorView.decorations.from(f),
});

const highlight = HighlightStyle.define([
  { tag: [t.keyword, t.controlKeyword, t.definitionKeyword, t.operatorKeyword, t.moduleKeyword], color: "var(--syn-keyword)", fontWeight: "var(--syn-keyword-weight)" },
  { tag: [t.string, t.special(t.string)], color: "var(--syn-string)" },
  { tag: [t.number, t.bool, t.null], color: "var(--syn-number)" },
  { tag: [t.comment, t.lineComment], color: "var(--syn-comment)", fontStyle: "var(--syn-comment-style)" },
  { tag: [t.function(t.definition(t.variableName)), t.definition(t.className)], color: "var(--syn-def)" },
  { tag: [t.function(t.variableName), t.function(t.propertyName)], color: "var(--syn-call)" },
  { tag: [t.self, t.special(t.variableName)], color: "var(--syn-self)" },
  { tag: t.className, color: "var(--syn-class)" },
  { tag: t.meta, color: "var(--syn-meta)" },
  // Markdown (D46): the markup recedes, the text keeps its emphasis.
  { tag: t.heading, color: "var(--syn-def)", fontWeight: "bold" },
  { tag: t.strong, fontWeight: "bold" },
  { tag: t.emphasis, fontStyle: "italic" },
  { tag: t.strikethrough, textDecoration: "line-through" },
  { tag: [t.link, t.url], color: "var(--syn-call)" },
  { tag: t.monospace, color: "var(--syn-string)" },
  { tag: [t.processingInstruction, t.labelName, t.contentSeparator], color: "var(--syn-comment)" },
  { tag: t.quote, color: "var(--syn-comment)" },
  { tag: [t.tagName, t.angleBracket], color: "var(--syn-keyword)" },
  { tag: t.attributeName, color: "var(--syn-meta)" },
]);

const theme = EditorView.theme({
  "&": { height: "100%", fontSize: "var(--editor-font-size)", background: "var(--editor-bg)", color: "var(--editor-fg)" },
  "&.cm-focused": { outline: "none" },
  ".cm-scroller": { fontFamily: "var(--mono)", lineHeight: "1.5", overscrollBehavior: "contain" },
  ".cm-content": { caretColor: "var(--caret)", paddingBottom: "40vh" },
  ".cm-gutters": { background: "var(--editor-bg)", color: "var(--gutter)", border: "none" },
  ".cm-activeLine": { background: "var(--active-line)" },
  ".cm-activeLineGutter": { background: "transparent", color: "var(--gutter-active)" },
  "&.cm-focused .cm-cursor": { borderLeftColor: "var(--caret)", borderLeftWidth: "2px" },
  ".cm-selectionBackground, &.cm-focused .cm-selectionBackground, ::selection": { background: "var(--selection) !important" },
  ".cm-matchingBracket": { background: "var(--bracket-match)", outline: "none" },
  ".cm-tooltip": { border: "none", borderRadius: "10px", overflow: "hidden", boxShadow: "0 4px 20px rgba(0,0,0,.2)", background: "var(--cell-bg)" },
  ".cm-tooltip-autocomplete > ul > li": { padding: "6px 10px !important", fontFamily: "var(--mono)" },
  ".cm-panels": { background: "var(--grouped-bg)", color: "var(--label)" },
  ".cm-lintRange-error": { backgroundImage: "none", textDecoration: "underline wavy var(--red)", textDecorationSkipInk: "none", textUnderlineOffset: "3px" },
  ".cm-lintRange-warning": { backgroundImage: "none", textDecoration: "underline wavy #ff9500", textDecorationSkipInk: "none", textUnderlineOffset: "3px" },
  ".cm-lintRange-info": { backgroundImage: "none", textDecoration: "underline dotted var(--secondary)", textUnderlineOffset: "3px" },
});

const columns = (s: string) => s.replace(/\t/g, "    ").length;
/** Python: the line's own indentation + 4 columns. */
const pythonIndent = (text: string) => columns(/^[ \t]*/.exec(text)![0]) + 4;
/** Markdown: under the text of a list item or quote. */
const markdownIndent = (text: string) =>
  columns(/^[ \t]*(?:(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?|(?:>[ \t]?)+)?/.exec(text)![0]);

// Wrapped lines continue indented, which keeps wrapped Python readable on a phone.
const hangingIndent = (indentOf: (text: string) => number) => ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    constructor(view: EditorView) {
      this.decorations = this.build(view);
    }
    update(u: ViewUpdate) {
      if (u.docChanged || u.viewportChanged) this.decorations = this.build(u.view);
    }
    build(view: EditorView) {
      const builder = new RangeSetBuilder<Decoration>();
      for (const { from, to } of view.visibleRanges) {
        for (let pos = from; pos <= to; ) {
          const line = view.state.doc.lineAt(pos);
          const indent = indentOf(line.text);
          builder.add(line.from, line.from, Decoration.line({ attributes: { style: `padding-left:calc(${indent}ch + 6px);text-indent:-${indent}ch` } }));
          pos = line.to + 1;
        }
      }
      return builder.finish();
    }
  },
  { decorations: (v) => v.decorations },
);
const codeHanging = hangingIndent(pythonIndent);
const proseHanging = hangingIndent(markdownIndent);

const cursorMove = (view: EditorView, dir: "left" | "right" | "up" | "down") => {
  const sel = view.state.selection.main;
  let pos: number;
  if (dir === "left") pos = Math.max(0, sel.head - 1);
  else if (dir === "right") pos = Math.min(view.state.doc.length, sel.head + 1);
  else pos = view.moveVertically(sel, dir === "down").head;
  view.dispatch({ selection: { anchor: pos }, scrollIntoView: true });
};

/** A .ipynb shows as a notebook, or as its JSON (D44). */
const isNotebookPath = (path: string | null): path is string => !!path && path.endsWith(".ipynb");
type Mode = "python" | "notebook" | "json" | "markdown";
/** How a pane shows a file: a .ipynb as a notebook or its JSON, a Markdown file as a preview or its source. */
type View = "notebook" | "preview" | "source";

/**
 * Markdown with GFM, fenced Python highlighted as Python, and lists that
 * continue on Enter. Put together here rather than with lang-markdown's
 * markdown(), which brings HTML, CSS and JavaScript along (200 kB).
 */
const markdownSupport = new LanguageSupport(
  new Language(
    markdownLanguage.data,
    (markdownLanguage.parser as MarkdownParser).configure(
      parseCode({ codeParser: (info) => (/^(py|python3?|py3)$/i.test(info.trim()) ? pythonLanguage.parser : null) }),
    ),
    [],
    "markdown",
  ),
  [Prec.high(keymap.of(markdownKeymap)), pasteURLAsLink],
);

/** What the file holds: a notebook's JSON, else the text. */
const fileText = (state: EditorState) => (notebookOf(state)?.kind === "ipynb" ? serializeNotebook(state) : state.doc.toString());

const sameBreakpoints = (a: Breakpoint[], b: Breakpoint[]) =>
  a.length === b.length && a.every((bp, i) => bp.line === b[i].line && bp.enabled === b[i].enabled);

export interface Symbol {
  name: string;
  /** A Markdown heading's kind is its level: "h1" to "h6". */
  kind: "class" | "function" | "method" | `h${number}`;
  line: number;
  depth: number;
}

/** Classes and functions from the Python syntax tree, in document order. */
export function outline(state: EditorState): Symbol[] {
  const tree = ensureSyntaxTree(state, state.doc.length, 300);
  if (!tree) return [];
  const out: Symbol[] = [];
  const stack: { to: number; kind: "class" | "function" }[] = [];
  tree.iterate({
    enter(node) {
      if (node.name !== "ClassDefinition" && node.name !== "FunctionDefinition") return;
      while (stack.length && stack[stack.length - 1].to <= node.from) stack.pop();
      const nameNode = node.node.getChild("VariableName");
      if (!nameNode) return;
      const parent = stack[stack.length - 1];
      const kind = node.name === "ClassDefinition" ? "class" : parent?.kind === "class" ? "method" : "function";
      out.push({ name: state.sliceDoc(nameNode.from, nameNode.to), kind, line: state.doc.lineAt(node.from).number, depth: stack.length });
      stack.push({ to: node.to, kind: node.name === "ClassDefinition" ? "class" : "function" });
    },
  });
  return out;
}

/** A Markdown file's headings, indented by level. */
export function markdownOutline(state: EditorState): Symbol[] {
  const tree = ensureSyntaxTree(state, state.doc.length, 300);
  if (!tree) return [];
  const out: Symbol[] = [];
  tree.iterate({
    enter(node) {
      const m = /^(ATX|Setext)Heading(\d)$/.exec(node.name);
      if (!m) return;
      const line = state.doc.lineAt(node.from);
      const name = m[1] === "ATX" ? line.text.replace(/^\s*#+\s*/, "").replace(/\s+#+\s*$/, "") : line.text.trim();
      out.push({ name: name || "(untitled)", kind: `h${Number(m[2])}`, line: line.number, depth: Number(m[2]) });
      return false;
    },
  });
  const top = Math.min(...out.map((s) => s.depth));
  for (const s of out) s.depth -= top;
  return out;
}

interface Problem {
  d: Diagnostic;
  from: number;
  to: number;
}

export class PaneEditor {
  readonly view: EditorView;
  private states = new Map<string, EditorState>();
  private readOnly = new Map<string, boolean>();
  path: string | null = null;
  private breakpoints: Breakpoint[] = [];
  private paused = false;
  private pendingText: string | null = null;
  private saveTimer = 0;
  private updateFrame = 0;
  private problemBar: HTMLElement;
  private lastSummary = "";
  /** Notebooks shown as their JSON, Markdown files as a preview or their source. */
  private views = new Map<string, View>();
  private editorEl: HTMLElement;
  private preview: MarkdownPreview;
  /** Notebooks this pane ran cells of: it saves their outputs. */
  private runOwners = new Set<string>();
  private cachedSaves = new Map<string, number>();
  private lastNotebook = "";

  private hooks: NotebookHooks = {
    run: (cells, source) => {
      if (!this.path) return;
      this.runOwners.add(this.path);
      void editorEvent("runCells", { path: this.path, cells, source });
    },
    stop: () => void editorEvent("stop"),
    restart: () => void editorEvent("restartKernel", { path: this.path }),
    openURL: (url) => void editorEvent("openURL", { url }),
    openLocation: (file, line) => void editorEvent("openLocation", { path: this.path, file, line }),
    reveal: (line) => this.reveal(line),
  };

  constructor(parent: HTMLElement, problemBar: HTMLElement, preview: HTMLElement) {
    this.problemBar = problemBar;
    this.editorEl = parent;
    this.preview = new MarkdownPreview(preview, {
      openURL: (url) => void editorEvent("openURL", { url }),
      openPath: (path, fragment) => void editorEvent("openLink", { from: this.path, path, fragment }),
    }, highlight);
    this.view = new EditorView({ parent, state: this.makeState(null, "", false) });
    new ResizeObserver(() => this.view.requestMeasure()).observe(parent);
    settings.subscribe(() => {
      this.view.dispatch({ effects: wrapCompartment.reconfigure(wrapping(settings.getSnapshot().wrap, isMarkdownPath(this.path))) });
      this.view.requestMeasure();
    });
  }

  private makeState(path: string | null, text: string, readOnly: boolean): EditorState {
    if (isNotebookPath(path) && this.views.get(path) !== "source") {
      try {
        const nb = parseIpynb(text);
        return EditorState.create({ doc: nb.text, extensions: this.extensions(readOnly, "notebook", nb) });
      } catch (e) {
        // Not a notebook we can read: its JSON, and a word why.
        this.views.set(path, "source");
        void editorEvent("notebookError", { path, message: String((e as Error).message ?? e) });
      }
    }
    if (isMarkdownPath(path)) {
      // A file with something to read opens as its preview; a new one, to write in.
      if (!this.views.has(path)) this.views.set(path, worthPreviewing(text) ? "preview" : "source");
      return EditorState.create({ doc: text, extensions: this.extensions(readOnly, "markdown") });
    }
    return EditorState.create({ doc: text, extensions: this.extensions(readOnly, isNotebookPath(path) ? "json" : "python") });
  }

  /** How the file shows (null: it has only one way). */
  private viewOf(path: string | null): View | null {
    if (isNotebookPath(path)) return this.views.get(path) ?? "notebook";
    if (isMarkdownPath(path)) return this.views.get(path) ?? "preview";
    return null;
  }

  private previewing() {
    return isMarkdownPath(this.path) && this.viewOf(this.path) === "preview";
  }

  /** The preview or the editor, whichever the file shows as; `line`: the place to keep. */
  private syncPreview(line?: number) {
    const on = this.previewing();
    if (on) {
      this.view.contentDOM.blur();
      this.preview.show(this.path!, this.view.state.doc.toString(), line);
    } else {
      this.preview.hide();
    }
    this.preview.el.hidden = !on;
    this.editorEl.hidden = on;
    if (!on) {
      this.view.requestMeasure();
      if (line !== undefined) {
        const pos = this.view.state.doc.line(Math.max(1, Math.min(line, this.view.state.doc.lines))).from;
        requestAnimationFrame(() => this.view.dispatch({ effects: EditorView.scrollIntoView(pos, { y: "start", yMargin: 8 }) }));
      }
    }
    if (on) this.problemBar.hidden = true;
  }

  /** The first line on screen in the editor. */
  private sourceTopLine() {
    const view = this.view;
    const block = view.lineBlockAtHeight(view.scrollDOM.scrollTop - view.documentPadding.top + 4);
    return view.state.doc.lineAt(Math.min(block.from, view.state.doc.length)).number;
  }

  /** What ruff and ty check for the document on screen (D44: a notebook's code cells). */
  private analysisSourceOf = (state: EditorState): AnalysisSource | null => {
    const path = this.path;
    if (!path) return null;
    const data = notebookOf(state);
    const cells = data?.cells.filter((c) => c.info.type === "code").map((c) => ({ from: c.from, to: c.to }));
    if (isNotebookPath(path)) {
      if (data?.kind !== "ipynb") return null; // its JSON
      return { path: `${path}.py`, text: analysisSource(state), cells };
    }
    if (isMarkdownPath(path)) return null;
    return { path, text: state.doc.toString(), cells: data?.cells.length ? cells : undefined };
  };

  private extensions(readOnly: boolean, mode: Mode, notebook?: ReturnType<typeof parseIpynb>): Extension[] {
    const definition = () => void editorEvent("definition");
    const info = () => void editorEvent("info");
    const code = mode !== "json" && mode !== "markdown";
    return [
      readOnlyCompartment.of(readOnlyExt(readOnly)),
      flashField,
      code ? keymap.of([{ key: "F12", run: () => (definition(), true) }]) : [],
      EditorView.domEventHandlers({
        mousedown(e, view) {
          if (!code) return false;
          // ⌘-click: jump to the definition; ⌥-click: show info (as in Xcode).
          const action = e.metaKey || e.ctrlKey ? definition : e.altKey ? info : null;
          if (!action || e.button !== 0) return false;
          const pos = view.posAtCoords({ x: e.clientX, y: e.clientY });
          if (pos === null) return false;
          view.dispatch({ selection: { anchor: pos } });
          action();
          return true;
        },
      }),
      // A notebook has no line numbers (its lines are not the file's) and no breakpoints; Markdown no breakpoints.
      mode === "notebook"
        ? pausedCompartment.of([])
        : mode === "markdown"
        ? [pausedCompartment.of([]), lineNumbers(), highlightActiveLineGutter()]
        : [
            debugExtensions((line, rect) => {
              if (this.path) void editorEvent("longPress", { path: this.path, line, rect: rectOf(rect) });
            }),
            lineNumbers(),
            highlightActiveLineGutter(),
          ],
      highlightSpecialChars(),
      history(),
      drawSelection(),
      indentOnInput(),
      bracketMatching(),
      closeBrackets(),
      code ? [
        autocompletion({ activateOnTyping: true, icons: false, override: [analysisCompletions(this.analysisSourceOf)] }),
        analysisLinter(this.analysisSourceOf),
      ] : [],
      highlightActiveLine(),
      highlightSelectionMatches(),
      search({ top: true }),
      code ? python() : [],
      mode === "markdown" ? markdownSupport : [],
      mode === "python" ? notebookExtensions("py", this.hooks) : mode === "notebook" ? notebookExtensions("ipynb", this.hooks, notebook) : [],
      wrapCompartment.of(wrapping(settings.getSnapshot().wrap, mode === "markdown")),
      indentUnit.of("    "),
      EditorState.tabSize.of(4),
      syntaxHighlighting(highlight),
      theme,
      keymap.of([...closeBracketsKeymap, ...defaultKeymap, ...searchKeymap, ...historyKeymap, ...completionKeymap, indentWithTab]),
      EditorView.contentAttributes.of({ autocapitalize: "off", autocorrect: "off", spellcheck: "false", "aria-label": "Code editor" }),
      EditorView.updateListener.of((u) => {
        if (u.docChanged && !u.transactions.some((tr) => tr.annotation(remote))) this.localChange(u);
        // A preview follows edits from elsewhere (the other pane, the agent, a program).
        if (u.docChanged && this.previewing()) this.preview.update(u.state.doc.toString());
        else if (!u.docChanged && this.path && isNotebookPath(this.path) && notebookOf(u.startState) !== notebookOf(u.state)) {
          // Outputs and cleared outputs are part of a .ipynb (the pane that ran the cells saves them).
          const fromKernel = u.transactions.some((tr) => tr.effects.some((e) => e.is(kernelEventsEffect)));
          if (!fromKernel || this.runOwners.has(this.path)) this.saveLater(u.state);
        }
        if (u.focusChanged) {
          focusLog(`focusChanged ${u.view.hasFocus}`, u.view);
          if (!u.view.hasFocus) this.flush();
          void call("keyboard.mode", { mode: u.view.hasFocus ? "code" : "plain" }).catch(() => {});
          void editorEvent("focus", { focused: u.view.hasFocus });
        }
        // The host's notebook commands follow the file right away (no frame may come while the view moves).
        if (notebookOf(u.startState) !== notebookOf(u.state)) this.reportNotebook();
        cancelAnimationFrame(this.updateFrame);
        this.updateFrame = requestAnimationFrame(() => this.updated());
      }),
    ];
  }

  /** A local edit: mirrored into the other pane right away, saved a little later. */
  private localChange(u: ViewUpdate) {
    const path = this.path;
    if (!path) return;
    void editorEvent("changes", { path, changes: JSON.stringify(u.changes.toJSON()), notebook: notebookOf(u.state)?.kind === "ipynb" });
    this.saveLater(u.state);
    if (notebookOf(u.state)?.kind === "ipynb") return; // no breakpoints in a notebook
    const lines = breakpointLines(u.state);
    if (!sameBreakpoints(lines, this.breakpoints)) {
      this.breakpoints = lines;
      void editorEvent("breakpoints", { path, breakpoints: lines });
    }
  }

  private saveLater(state: EditorState) {
    this.pendingText = fileText(state);
    clearTimeout(this.saveTimer);
    this.saveTimer = window.setTimeout(() => this.flush(), 300);
  }

  /** Report unsaved text now; returns it (or null if there is none). */
  flush(): string | null {
    clearTimeout(this.saveTimer);
    const text = this.pendingText;
    this.pendingText = null;
    if (text !== null && this.path) void editorEvent("text", { path: this.path, text });
    return text;
  }

  // -- after updates: problems --------------------------------------------------------

  private problemList(): Problem[] {
    const out: Problem[] = [];
    forEachDiagnostic(this.view.state, (d, from, to) => out.push({ d, from, to }));
    return out;
  }

  private updated() {
    const state = this.view.state;
    this.reportNotebook();
    let errors = 0;
    let warnings = 0;
    let current: Problem | null = null;
    const head = state.selection.main.head;
    const line = state.doc.lineAt(head);
    for (const p of this.problemList()) {
      if (p.d.severity === "error") errors++;
      else if (p.d.severity === "warning") warnings++;
      const here = p.from <= head && head <= p.to;
      const sameLine = p.from <= line.to && p.to >= line.from;
      if (here || (!current && sameLine)) current = p;
    }
    const summary = JSON.stringify({ errors, warnings });
    if (summary !== this.lastSummary) {
      this.lastSummary = summary;
      void editorEvent("problems", { errors, warnings });
    }
    this.renderProblemBar(current, errors + warnings);
  }

  /** The diagnostic under the cursor with its quick fixes (touch has no hover). */
  private renderProblemBar(p: Problem | null, total: number) {
    const bar = this.problemBar;
    if (!p || this.paused || this.path?.startsWith("ext:") || this.previewing()) {
      bar.hidden = true;
      return;
    }
    bar.hidden = false;
    bar.className = `problem-bar ${p.d.severity}`;
    bar.replaceChildren();
    const text = document.createElement("div");
    text.className = "problem-text";
    const icon = document.createElement("span");
    icon.className = "problem-icon";
    icon.textContent = p.d.severity === "error" ? "⛔" : "⚠️";
    const message = document.createElement("span");
    message.className = "problem-message";
    message.textContent = `${p.d.message} `;
    const source = document.createElement("span");
    source.className = "problem-source";
    source.textContent = p.d.source ?? "";
    message.append(source);
    text.append(icon, message);
    const actions = document.createElement("div");
    actions.className = "problem-actions";
    for (const a of p.d.actions ?? []) {
      const b = document.createElement("button");
      b.textContent = a.name;
      b.onpointerdown = (e) => {
        e.preventDefault();
        a.apply(this.view, p.from, p.to);
      };
      actions.append(b);
    }
    if (total > 1) {
      const all = document.createElement("button");
      all.className = "secondary";
      all.textContent = `All ${total}`;
      all.onpointerdown = (e) => {
        e.preventDefault();
        void editorEvent("showProblems");
      };
      actions.append(all);
    }
    bar.append(text);
    if (actions.childElementCount) bar.append(actions);
  }

  /** The host offers notebook commands for files with cells. */
  private reportNotebook() {
    const path = this.path;
    const data = notebookOf(this.view.state);
    const view = this.viewOf(path);
    const summary = { path, kind: data?.cells.length ? data.kind : null, cells: data?.cells.length ?? 0, view };
    const key = JSON.stringify(summary);
    if (key === this.lastNotebook) return;
    this.lastNotebook = key;
    void editorEvent("notebook", summary);
  }

  // -- notebooks (D44) ---------------------------------------------------------------------

  /** What the kernel says about a notebook's cells (also for one that is not on screen). */
  notebookEvents(path: string, events: KernelEvent[]) {
    const spec = { effects: kernelEventsEffect.of(events) };
    if (path === this.path) {
      if (notebookOf(this.view.state)) this.view.dispatch(spec);
      return;
    }
    const cached = this.states.get(path);
    if (!cached || !notebookOf(cached)) return;
    const next = cached.update(spec).state;
    this.states.set(path, next);
    if (isNotebookPath(path) && this.runOwners.has(path)) {
      clearTimeout(this.cachedSaves.get(path));
      this.cachedSaves.set(path, window.setTimeout(() => {
        const state = this.states.get(path);
        if (state) void editorEvent("text", { path, text: fileText(state) });
      }, 500));
    }
  }

  notebookCommand(name: string): unknown {
    const view = this.view;
    if (name === "toggleView") {
      const other = isMarkdownPath(this.path) ? "preview" : "notebook";
      return this.setView(this.viewOf(this.path) === "source" ? other : "source");
    }
    if (!notebookOf(view.state)) return false;
    const active = () => {
      const data = notebookOf(view.state)!;
      return data.cells.findIndex((c) => (c.marker?.from ?? c.from) <= view.state.selection.main.head && view.state.selection.main.head <= c.to);
    };
    switch (name) {
      case "runCell": return runCell(view);
      case "runCellAdvance": return runCell(view, undefined, true);
      case "runAll": return runAll(view);
      case "runAbove": return runAbove(view);
      case "runBelow": return runBelow(view);
      case "insertCode": return insertCell(view, undefined, "code");
      case "insertMarkdown": return insertCell(view, undefined, "markdown");
      case "deleteCell": return deleteCell(view);
      case "moveUp": return moveCell(view, active(), -1);
      case "moveDown": return moveCell(view, active(), 1);
      case "toMarkdown": return setCellType(view, active(), "markdown");
      case "toCode": return setCellType(view, active(), "code");
      case "clearOutputs": return clearOutputs(view);
      default: return false;
    }
  }

  /** A .ipynb as a notebook or as its JSON; a Markdown file as its preview or its source (D46). */
  setView(mode: View): { ok: boolean; error?: string } {
    const path = this.path;
    if (isMarkdownPath(path)) {
      if (mode === "notebook") return { ok: false, error: "Not a notebook" };
      if (this.viewOf(path) === mode) return { ok: true };
      // The other view starts where this one is.
      const line = mode === "preview" ? this.sourceTopLine() : this.preview.topLine();
      if (mode === "preview") this.flush();
      this.views.set(path, mode);
      this.syncPreview(line);
      this.reportNotebook();
      return { ok: true };
    }
    if (mode === "preview") return { ok: false, error: "Not a Markdown file" };
    if (!isNotebookPath(path)) return { ok: false, error: "Not a notebook" };
    if ((this.views.get(path) ?? "notebook") === mode) return { ok: true };
    const text = fileText(this.view.state);
    if (mode === "notebook") {
      try {
        parseIpynb(text);
      } catch (e) {
        return { ok: false, error: String((e as Error).message ?? e) };
      }
    }
    this.flush();
    this.views.set(path, mode);
    this.view.setState(this.makeState(path, text, this.readOnly.get(path) ?? false));
    this.view.dispatch({ effects: pausedCompartment.reconfigure(this.pausedExt()) });
    this.reportNotebook();
    return { ok: true };
  }

  notebookInfo() {
    return { path: this.path, view: this.viewOf(this.path), ...notebookSummary(this.view.state) };
  }

  // -- the host's API ---------------------------------------------------------------------

  /** Show a file; `text` is used when there is no state for it yet. */
  open(path: string | null, text: string, readOnly: boolean) {
    const view = this.view;
    if (this.path === path) return;
    this.flush();
    if (this.path) this.states.set(this.path, view.state);
    this.path = path;
    if (path === null) {
      view.setState(this.makeState(null, "", false));
      this.syncPreview();
      this.updated();
      this.reportNotebook();
      return;
    }
    this.readOnly.set(path, readOnly);
    view.setState(this.states.get(path) ?? this.makeState(path, text, readOnly));
    this.syncPreview();
    view.dispatch({ effects: [setBreakpointsEffect.of(this.breakpoints), pausedCompartment.reconfigure(this.pausedExt())] });
    this.reportNotebook();
    requestAnimationFrame(() => view.requestMeasure());
    setTimeout(() => view.requestMeasure(), 450);
  }

  /** Whether a state for the file is cached (the host then needs no text). */
  has(path: string) {
    return this.path === path || this.states.has(path);
  }

  /** The file's text (a notebook's JSON). */
  text(path?: string) {
    if (!path || path === this.path) return fileText(this.view.state);
    const state = this.states.get(path);
    return state ? fileText(state) : null;
  }

  setBreakpoints(list: Breakpoint[]) {
    this.breakpoints = list;
    if (!sameBreakpoints(breakpointLines(this.view.state), list)) this.view.dispatch({ effects: setBreakpointsEffect.of(list) });
  }

  private pausedExt() {
    return this.paused
      ? pausedExtension((expr, rect) => void editorEvent("inspect", { expr, rect: rectOf(rect) }))
      : [];
  }

  setPaused(paused: boolean, errorStyle: boolean) {
    document.documentElement.classList.toggle("inspecting-error", errorStyle);
    if (paused === this.paused) return;
    this.paused = paused;
    if (paused) this.view.contentDOM.blur();
    this.view.dispatch({ effects: pausedCompartment.reconfigure(this.pausedExt()) });
    this.updated();
  }

  setDebugLine(line: number | null, visibleFraction: number) {
    const view = this.view;
    view.dispatch({ effects: setDebugLineEffect.of(line) });
    if (line === null || line > view.state.doc.lines) return;
    requestAnimationFrame(() => this.revealPos(view.state.doc.line(line).from, false, visibleFraction));
  }

  /** Bring a position into the part of the editor the console does not cover. */
  private revealPos(pos: number, always: boolean, visibleFraction = 0.85) {
    const view = this.view;
    const block = view.lineBlockAt(pos);
    const scroller = view.scrollDOM;
    const top = scroller.scrollTop;
    const visible = scroller.clientHeight * visibleFraction;
    if (always || block.top < top + 8 || block.bottom > top + visible - 8) {
      view.dispatch({ effects: EditorView.scrollIntoView(pos, { y: "start", yMargin: Math.round(visible * 0.3) }) });
    }
  }

  /** Scroll the first line that contains `text` to the top, without selecting it (screenshot launch hook); false if none. */
  scrollToText(text: string) {
    const view = this.view;
    const at = view.state.doc.toString().indexOf(text);
    if (at < 0) return false;
    view.dispatch({ effects: EditorView.scrollIntoView(view.state.doc.lineAt(at).from, { y: "start", yMargin: 8 }) });
    return true;
  }

  /** Jump to a line (traceback, definition, outline): select it, scroll, flash. */
  reveal(line: number, column = 1, visibleFraction = 0.85) {
    const view = this.view;
    const doc = view.state.doc;
    const l = doc.line(Math.max(1, Math.min(line, doc.lines)));
    const pos = Math.min(l.to, l.from + Math.max(0, column - 1));
    view.dispatch({ selection: { anchor: pos }, effects: flashEffect.of(l.from) });
    if (this.previewing()) void this.preview.rendered.then(() => this.preview.scrollToLine(l.number, true));
    else requestAnimationFrame(() => this.revealPos(pos, false, visibleFraction));
    setTimeout(() => view.dispatch({ effects: flashEffect.of(null) }), 1400);
  }

  /** Show a Markdown heading (a link's `#anchor`); false if there is none. */
  async revealAnchor(anchor: string) {
    if (!this.previewing()) {
      const name = anchor.toLowerCase();
      const heading = markdownOutline(this.view.state).find((s) => slug(s.name) === name || s.name.toLowerCase() === name);
      if (heading) this.reveal(heading.line);
      return !!heading;
    }
    await this.preview.rendered;
    return this.preview.scrollToAnchor(anchor);
  }

  /** Show a range of lines (the agent's ide_open): selected, scrolled to, the first one flashed. */
  revealRange(fromLine: number, toLine: number, visibleFraction = 0.85) {
    const view = this.view;
    const doc = view.state.doc;
    const from = doc.line(Math.max(1, Math.min(fromLine, doc.lines)));
    const to = doc.line(Math.max(from.number, Math.min(toLine, doc.lines)));
    view.dispatch({ selection: { anchor: from.from, head: to.to }, effects: flashEffect.of(from.from) });
    if (this.previewing()) void this.preview.rendered.then(() => this.preview.scrollToLine(from.number, true));
    else requestAnimationFrame(() => this.revealPos(from.from, false, visibleFraction));
    setTimeout(() => view.dispatch({ effects: flashEffect.of(null) }), 1400);
  }

  insert(text: string, cursorOffset = text.length) {
    const view = this.view;
    if (view.state.readOnly) return;
    const sel = view.state.selection.main;
    view.dispatch({
      changes: { from: sel.from, to: sel.to, insert: text },
      selection: { anchor: sel.from + cursorOffset },
      scrollIntoView: true,
      userEvent: "input.type",
    });
  }

  command(name: EditorCommand) {
    const view = this.view;
    const commands = { undo, redo, indent: indentMore, dedent: indentLess, comment: toggleComment, search: openSearchPanel };
    if (name in commands) commands[name as keyof typeof commands](view);
    else cursorMove(view, name as "left" | "right" | "up" | "down");
  }

  /** Keys from the native keyboard accessory. */
  key(action: string) {
    if (action === "dismiss") return this.view.contentDOM.blur();
    if (action === "definition") return void editorEvent("definition");
    if (action === "info") return void editorEvent("info");
    if (action.startsWith("insert:")) {
      const body = action.slice("insert:".length);
      const m = /^([\s\S]+):(\d+)$/.exec(body);
      return m ? this.insert(m[1], Number(m[2])) : this.insert(body);
    }
    this.command(action as EditorCommand);
  }

  applyRemote(path: string, changesJSON: string, notebook = false) {
    const changes = ChangeSet.fromJSON(JSON.parse(changesJSON));
    const spec = { changes, annotations: [remote.of(true), Transaction.addToHistory.of(false)] };
    // A notebook's edits only fit where it shows as a notebook too.
    const fits = (state: EditorState) => (notebookOf(state)?.kind === "ipynb") === notebook && state.doc.length === changes.length;
    if (path === this.path) {
      if (fits(this.view.state)) this.view.dispatch(spec);
    } else {
      const cached = this.states.get(path);
      if (cached && fits(cached)) this.states.set(path, cached.update(spec).state);
      else if (cached) this.states.delete(path);
    }
  }

  /** The file changed on disk (written by a program). */
  replaceText(path: string, text: string) {
    const view = this.view;
    if (path === this.path) {
      if (fileText(view.state) === text) return;
      if (notebookOf(view.state)?.kind === "ipynb") {
        // A notebook written by someone else (the agent): read it again.
        view.setState(this.makeState(path, text, this.readOnly.get(path) ?? false));
        view.dispatch({ effects: pausedCompartment.reconfigure(this.pausedExt()) });
      } else {
        view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text }, annotations: remote.of(true) });
      }
    } else {
      this.states.delete(path);
    }
  }

  renamePath(from: string, to: string) {
    const moved = (p: string) => (p === from || p.startsWith(from + "/") ? to + p.slice(from.length) : null);
    for (const [p, st] of [...this.states]) {
      const next = moved(p);
      if (next) {
        this.states.delete(p);
        this.states.set(next, st);
      }
    }
    for (const [p, v] of [...this.views]) {
      const next = moved(p);
      if (next) {
        this.views.delete(p);
        this.views.set(next, v);
      }
    }
    for (const p of [...this.runOwners]) {
      const next = moved(p);
      if (next) {
        this.runOwners.delete(p);
        this.runOwners.add(next);
      }
    }
    this.preview.rename(from, to);
    const current = this.path && moved(this.path);
    if (current) this.path = current;
  }

  forget(path: string) {
    for (const p of [...this.states.keys()]) if (p === path || p.startsWith(path + "/")) this.states.delete(p);
    for (const p of [...this.views.keys()]) if (p === path || p.startsWith(path + "/")) this.views.delete(p);
    if (path !== this.path) this.preview.forget(path);
  }

  /** Where the cursor is, for go to definition and show info. */
  cursor() {
    const state = this.view.state;
    const sel = state.selection.main;
    const pos = sel.empty ? sel.head : sel.from;
    const line = state.doc.lineAt(pos);
    const word = state.wordAt(pos);
    const a = this.view.coordsAtPos(word?.from ?? pos);
    const b = this.view.coordsAtPos(word?.to ?? pos, -1);
    const rect = a ? { x: a.left, y: a.top, width: Math.max(1, (b?.right ?? a.right) - a.left), height: a.bottom - a.top } : null;
    // What is selected, for the agent's context (capped: it goes into a prompt).
    const selection = sel.empty
      ? null
      : {
          text: state.sliceDoc(sel.from, Math.min(sel.to, sel.from + 4000)),
          fromLine: line.number,
          toLine: state.doc.lineAt(sel.to).number,
          truncated: sel.to - sel.from > 4000,
        };
    // A notebook's analysis sees its code cells as one Python file (D44).
    const source = this.analysisSourceOf(state);
    return {
      path: this.path, analysisPath: source?.path ?? this.path, text: source?.text ?? state.doc.toString(),
      line: line.number, column: pos - line.from + 1, rect, selection,
    };
  }

  async format(): Promise<boolean> {
    if (isMarkdownPath(this.path)) return false;
    const data = notebookOf(this.view.state);
    if (data?.kind === "ipynb") return formatRanges(this.view, data.cells.filter((c) => c.info.type === "code").map((c) => ({ from: c.from, to: c.to })));
    return formatDocument(this.view);
  }

  outline() {
    if (isMarkdownPath(this.path)) return { symbols: markdownOutline(this.view.state), lines: this.view.state.doc.lines };
    let state = this.view.state;
    if (notebookOf(state)?.kind === "ipynb") state = EditorState.create({ doc: analysisSource(state), extensions: python() });
    return { symbols: outline(state), lines: state.doc.lines };
  }

  problems() {
    const doc = this.view.state.doc;
    return this.problemList()
      .map((p, index) => ({
        index, message: p.d.message, source: p.d.source ?? "", severity: p.d.severity, line: doc.lineAt(p.from).number,
        actions: (p.d.actions ?? []).map((a) => a.name),
      }));
  }

  applyFix(index: number, action: number) {
    const p = this.problemList()[index];
    p?.d.actions?.[action]?.apply(this.view, p.from, p.to);
  }

  selectProblem(index: number) {
    const p = this.problemList()[index];
    if (!p) return;
    this.view.dispatch({ selection: { anchor: p.from, head: p.to }, effects: EditorView.scrollIntoView(p.from, { y: "center" }) });
    takeFocus(this.view);
  }

  relint() {
    forceLinting(this.view);
  }

  focus() {
    if (!this.previewing()) takeFocus(this.view);
  }

  blur() {
    this.view.contentDOM.blur();
  }

  // -- self-test helpers ------------------------------------------------------------------

  setText(text: string) {
    const view = this.view;
    view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text } });
  }

  diagnostics() {
    return this.problemList().map((p) => ({ source: p.d.source ?? "", message: p.d.message, actions: (p.d.actions ?? []).map((a) => a.name) }));
  }

  applyFixNamed(name: string) {
    for (const p of this.problemList()) {
      const action = p.d.actions?.find((a) => a.name.includes(name));
      if (action) {
        action.apply(this.view, p.from, p.to);
        return true;
      }
    }
    return false;
  }

  setCursor(line: number, column: number) {
    const doc = this.view.state.doc;
    const l = doc.line(Math.max(1, Math.min(line, doc.lines)));
    this.view.dispatch({ selection: { anchor: Math.min(l.to, l.from + column - 1) } });
  }

  /** What a Markdown file's preview shows, once it is drawn (self-test). */
  async markdownInfo() {
    await this.preview.rendered;
    return { view: this.viewOf(this.path), editorHidden: this.editorEl.hidden, sourceTop: this.sourceTopLine(), ...this.preview.probe() };
  }

  /** Tap a link in the preview (self-test). */
  previewFollow(href: string) {
    this.preview.follow(href);
  }

  /** Run a cell by its index (self-test). */
  notebookRun(index: number) {
    return runCell(this.view, index);
  }

  /** Backspace, as the keyboard would (self-test: marker lines are protected). */
  backspace() {
    deleteCharBackward(this.view);
    return fileText(this.view.state);
  }

  info() {
    const state = this.view.state;
    const line = state.doc.lineAt(state.selection.main.head);
    return { path: this.path, readOnly: state.readOnly, line: line.number, lineText: line.text, text: state.doc.toString() };
  }
}
