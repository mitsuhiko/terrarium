// Markdown files (D46): the preview a pane shows instead of the source. It
// is drawn in the page itself (not a shadow root, so the web view's find
// works in it), sanitized with DOMPurify. Each top-level block knows its
// source line, so the two views keep their place and "Go to" works in both.
// Links open in the app: other files (at a line or a heading), the Python
// docs, web pages outside. Images next to the file come through the host.
import { pythonLanguage } from "@codemirror/lang-python";
import { type Highlighter, highlightCode } from "@lezer/highlight";
import DOMPurify from "dompurify";
import { Marked, type TokensList } from "marked";
import { dirname, fs } from "../host";

export const isMarkdownPath = (path: string | null): path is string => !!path && /\.(md|markdown)$/i.test(path);

/** Whether there is anything to read: a new file (only headings) opens to write in. */
export const worthPreviewing = (text: string) => text.split("\n").some((l) => l.trim() && !/^\s*#/.test(l));

/**
 * A link's target as an app path: relative to `dir`, or with a leading `/` to
 * the root of the file's location (Documents, or a linked folder `@name`).
 * null when it climbs out of that root.
 */
export function resolvePath(dir: string, target: string): string | null {
  const root = dir.startsWith("@") ? dir.split("/")[0] : "";
  const parts = target.startsWith("/") ? (root ? [root] : []) : dir ? dir.split("/") : [];
  const floor = root ? 1 : 0;
  for (const seg of target.split("/")) {
    if (!seg || seg === ".") continue;
    if (seg === "..") {
      if (parts.length <= floor) return null;
      parts.pop();
    } else parts.push(seg);
  }
  return parts.length > floor ? parts.join("/") : null;
}

/** GitHub's heading anchors: lower case, punctuation dropped, spaces as dashes. */
export function slug(text: string): string {
  return text.trim().toLowerCase().replace(/[^\p{L}\p{M}\p{N}\p{Pc} -]/gu, "").replace(/ /g, "-");
}

const IMAGE_TYPES: Record<string, string> = {
  png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp", svg: "image/svg+xml",
  bmp: "image/bmp", ico: "image/x-icon", avif: "image/avif", heic: "image/heic", heif: "image/heif", tif: "image/tiff", tiff: "image/tiff",
};

const PYTHON_FENCES = new Set(["py", "python", "python3", "py3"]);
const hasScheme = (href: string) => /^[a-z][a-z\d+.-]*:/i.test(href);

export interface PreviewHost {
  openURL(url: string): void;
  /** Another file (an app path), with what followed `#` in the link. */
  openPath(path: string, fragment: string): void;
}

export class MarkdownPreview {
  readonly el: HTMLElement;
  private body: HTMLElement;
  private md = new Marked({ gfm: true, async: false });
  private images = new Map<string, Promise<string | null>>();
  private path: string | null = null;
  private text: string | null = null;
  private scrolls = new Map<string, number>();
  private timer = 0;
  private generation = 0;
  /** Done drawing (the self-test waits for it). */
  rendered: Promise<void> = Promise.resolve();

  constructor(el: HTMLElement, private host: PreviewHost, private highlighter: Highlighter) {
    this.el = el;
    this.body = document.createElement("article");
    this.body.className = "md-body";
    el.append(this.body);
    el.addEventListener("click", (e) => this.click(e));
  }

  /** Show a file's text; `line`: start there (the source view's place). */
  show(path: string, text: string, line?: number) {
    if (path !== this.path) {
      if (this.path) this.scrolls.set(this.path, this.el.scrollTop);
      this.path = path;
      this.text = null;
      this.images.clear(); // a file's images are read again when it is opened again
    }
    clearTimeout(this.timer);
    if (text === this.text) {
      if (line !== undefined) this.scrollToLine(line);
      return;
    }
    const scroll = line === undefined ? (this.scrolls.get(path) ?? this.el.scrollTop) : null;
    this.rendered = this.render(text).then(() => {
      if (line !== undefined) this.scrollToLine(line);
      else if (scroll !== null) this.el.scrollTop = scroll;
    });
  }

  /** The text changed (typed in the other pane, written by the agent): draw it again soon. */
  update(text: string) {
    clearTimeout(this.timer);
    this.timer = window.setTimeout(() => {
      const top = this.el.scrollTop;
      this.rendered = this.render(text).then(() => void (this.el.scrollTop = top));
    }, 120);
  }

  hide() {
    clearTimeout(this.timer);
    if (this.path) this.scrolls.set(this.path, this.el.scrollTop);
  }

  forget(path: string) {
    for (const p of [...this.scrolls.keys()]) if (p === path || p.startsWith(path + "/")) this.scrolls.delete(p);
    if (this.path && (this.path === path || this.path.startsWith(path + "/"))) {
      this.path = null;
      this.text = null;
    }
  }

  rename(from: string, to: string) {
    const moved = (p: string) => (p === from || p.startsWith(from + "/") ? to + p.slice(from.length) : null);
    for (const [p, top] of [...this.scrolls]) {
      const next = moved(p);
      if (next) {
        this.scrolls.delete(p);
        this.scrolls.set(next, top);
      }
    }
    if (this.path) this.path = moved(this.path) ?? this.path;
  }

  // -- drawing ------------------------------------------------------------------------------

  private async render(text: string) {
    const generation = ++this.generation;
    this.text = text;
    const dir = this.path ? dirname(this.path) : "";
    const tokens = this.md.lexer(text);
    // Each top-level block gets a marker with its first line, which moves
    // onto the element the block becomes once the whole is sanitized (an
    // HTML block may open in one token and close in another).
    let html = "";
    let line = 1;
    for (const token of tokens) {
      const at = line;
      line += newlines(token.raw);
      if (token.type === "space" || token.type === "def") continue;
      const one = Object.assign([token], { links: tokens.links }) as TokensList;
      html += `<span class="md-at" data-line="${at}"></span>${this.md.parser(one)}`;
    }
    const fragment = DOMPurify.sanitize(html, { RETURN_DOM_FRAGMENT: true, FORBID_TAGS: ["style", "form"], ADD_ATTR: ["target"] });
    for (const marker of fragment.querySelectorAll<HTMLElement>(".md-at")) {
      const next = marker.nextElementSibling as HTMLElement | null;
      if (next && !next.classList.contains("md-at") && !next.dataset.line) {
        next.dataset.line = marker.dataset.line;
        marker.remove();
      }
    }
    const seen = new Map<string, number>();
    for (const h of fragment.querySelectorAll<HTMLElement>("h1, h2, h3, h4, h5, h6")) {
      const base = slug(h.textContent ?? "");
      const n = seen.get(base) ?? 0;
      seen.set(base, n + 1);
      h.dataset.anchor = n ? `${base}-${n}` : base;
    }
    for (const code of fragment.querySelectorAll<HTMLElement>("pre > code")) {
      const lang = /\blanguage-(\S+)/.exec(code.className)?.[1]?.toLowerCase();
      if (lang && PYTHON_FENCES.has(lang)) this.highlight(code);
    }
    for (const table of fragment.querySelectorAll("table")) {
      const wrap = document.createElement("div");
      wrap.className = "md-table";
      table.replaceWith(wrap);
      wrap.append(table);
    }
    // Images next to the file: read through the host before the swap, so the page doesn't jump.
    const loads: Promise<void>[] = [];
    for (const img of fragment.querySelectorAll("img")) {
      const src = img.getAttribute("src") ?? "";
      if (!src || hasScheme(src) || src.startsWith("//")) continue;
      img.removeAttribute("src");
      const path = resolvePath(dir, decode(src.split(/[?#]/)[0]));
      if (!path) continue;
      img.dataset.path = path;
      loads.push(this.image(path).then((url) => {
        if (url) img.src = url;
        else img.classList.add("md-missing");
      }));
    }
    await Promise.all(loads);
    if (generation !== this.generation) return;
    if (!fragment.childNodes.length) {
      const empty = document.createElement("p");
      empty.className = "md-empty";
      empty.textContent = "Nothing to show yet: Edit to write.";
      fragment.append(empty);
    }
    this.body.replaceChildren(fragment);
  }

  private image(path: string): Promise<string | null> {
    let p = this.images.get(path);
    if (!p) {
      const type = IMAGE_TYPES[path.slice(path.lastIndexOf(".") + 1).toLowerCase()];
      p = type ? fs.readBase64(path).then((data) => `data:${type};base64,${data}`, () => null) : Promise.resolve(null);
      this.images.set(path, p);
    }
    return p;
  }

  private highlight(code: HTMLElement) {
    const text = code.textContent ?? "";
    const out = document.createDocumentFragment();
    highlightCode(text, pythonLanguage.parser.parse(text), this.highlighter, (t, classes) => {
      if (!classes) return void out.append(t);
      const span = document.createElement("span");
      span.className = classes;
      span.textContent = t;
      out.append(span);
    }, () => out.append("\n"));
    code.replaceChildren(out);
  }

  // -- places -------------------------------------------------------------------------------

  private blocks() {
    return [...this.body.querySelectorAll<HTMLElement>(":scope > [data-line]")];
  }

  private topOf(el: Element) {
    return el.getBoundingClientRect().top - this.el.getBoundingClientRect().top + this.el.scrollTop;
  }

  /** The source line of the first block on screen. */
  topLine(): number {
    const top = this.el.scrollTop;
    for (const b of this.blocks()) {
      if (this.topOf(b) + b.offsetHeight > top + 4) return Number(b.dataset.line);
    }
    return 1;
  }

  /** Scroll to the block that holds a source line. */
  scrollToLine(line: number, flash = false) {
    const blocks = this.blocks();
    let target: HTMLElement | null = null;
    for (const b of blocks) {
      if (Number(b.dataset.line) > line) break;
      target = b;
    }
    if (!target || target === blocks[0]) this.el.scrollTop = 0;
    else this.el.scrollTop = Math.max(0, this.topOf(target) - 12);
    if (!target) return;
    if (flash) this.flash(target);
  }

  /** Scroll to `#name`: a heading's anchor, or an element's id or name. */
  scrollToAnchor(name: string): boolean {
    const want = decode(name);
    const all = [...this.body.querySelectorAll<HTMLElement>("[data-anchor], [id], a[name]")];
    const el = all.find((e) => e.dataset.anchor === want || e.id === want || e.getAttribute("name") === want)
      ?? all.find((e) => e.dataset.anchor === slug(want));
    if (!el) return false;
    this.el.scrollTop = Math.max(0, this.topOf(el) - 12);
    this.flash(el);
    return true;
  }

  private flash(el: HTMLElement) {
    el.classList.remove("md-flash");
    void el.offsetWidth;
    el.classList.add("md-flash");
    setTimeout(() => el.classList.remove("md-flash"), 1400);
  }

  // -- links ------------------------------------------------------------------------------

  private click(e: MouseEvent) {
    const a = (e.target as Element).closest?.("a");
    if (!a || !this.el.contains(a)) return;
    e.preventDefault();
    this.follow(a.getAttribute("href") ?? "");
  }

  /** Where a link goes (also the self-test's way of tapping one). */
  follow(href: string) {
    if (!href) return;
    if (href.startsWith("#")) return void this.scrollToAnchor(href.slice(1));
    if (hasScheme(href)) {
      if (/^(https?|mailto|tel|docs|terrarium):/i.test(href)) this.host.openURL(href);
      return;
    }
    if (!this.path || href.startsWith("//")) return;
    const hash = href.indexOf("#");
    const target = (hash < 0 ? href : href.slice(0, hash)).split("?")[0];
    const fragment = hash < 0 ? "" : href.slice(hash + 1);
    const path = target ? resolvePath(dirname(this.path), decode(target)) : this.path;
    if (!path) return;
    if (path === this.path) return void (fragment && this.scrollToAnchor(fragment));
    this.host.openPath(path, fragment);
  }

  /** What is drawn (self-test). */
  probe() {
    const imgs = [...this.body.querySelectorAll("img")];
    return {
      path: this.path,
      visible: !this.el.hidden,
      blocks: this.blocks().map((b) => ({ tag: b.tagName.toLowerCase(), line: Number(b.dataset.line) })),
      headings: [...this.body.querySelectorAll<HTMLElement>("[data-anchor]")].map((h) => h.dataset.anchor),
      images: imgs.map((i) => ({ path: i.dataset.path ?? null, src: (i.getAttribute("src") ?? "").slice(0, 30), loaded: i.complete && i.naturalWidth > 0 })),
      highlighted: this.body.querySelectorAll("pre code span[class]").length,
      scripts: this.body.querySelectorAll("script, iframe").length,
      handlers: [...this.body.querySelectorAll("*")].filter((el) => [...el.attributes].some((a) => a.name.startsWith("on"))).length,
      tables: this.body.querySelectorAll(".md-table > table").length,
      tasks: this.body.querySelectorAll("input[type=checkbox]").length,
      topLine: this.topLine(),
      scrollTop: Math.round(this.el.scrollTop),
      text: (this.body.textContent ?? "").slice(0, 400),
    };
  }
}

function newlines(s: string) {
  let n = 0;
  for (let i = s.indexOf("\n"); i >= 0; i = s.indexOf("\n", i + 1)) n++;
  return n;
}

function decode(s: string) {
  try {
    return decodeURIComponent(s);
  } catch {
    return s;
  }
}
