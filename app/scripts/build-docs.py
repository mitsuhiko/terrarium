#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12,<3.14"
# dependencies = ["beautifulsoup4==4.13.4", "lxml==6.0.0", "markdownify==1.1.0", "markdown==3.8", "pygments==2.19.1"]
# ///
"""Build the Python documentation the app bundles (D37), one set per runtime
in runtimes.json, into vendor/docs-<python>/:

- app/docs/*.md (D42): the app's own modules (ui, turtle in the app, the
  device modules), rendered into terrarium/ in the same HTML as Sphinx's
  (sections, API entries as dl.py with their names as ids), so the viewer
  shows them in the same style and the index treats them like the rest.

- html/: the official HTML archive (pinned by its sha256), pruned (C API,
  old What's New pages, the general index, Sphinx's search) and patched for
  the app's viewer: no site header, sidebar or theme switcher, our
  stylesheet, links to pruned pages go to docs.python.org.
- docs.sqlite: the same pages as Markdown chunks (one per section, API entry
  and glossary term) with an FTS5 index and a symbol table, for the agent's
  docs_search / docs_read and the viewer's search.

Does nothing when the output matches the pinned archive and this script.
`--update-pins` downloads the current archives and pins them.
"""

import argparse
import hashlib
import json
import re
import shutil
import sqlite3
import sys
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath

from bs4 import BeautifulSoup, NavigableString, Tag
from markdownify import MarkdownConverter

APP = Path(__file__).resolve().parent.parent
VENDOR = APP / "vendor"
RUNTIMES = APP / "runtimes.json"
APP_DOCS = APP / "docs"
APP_DOCS_DIR = "terrarium"  # where they go in the HTML tree
SCRIPT_HASH = hashlib.sha256(
    Path(__file__).read_bytes() + b"".join(p.read_bytes() for p in sorted(APP_DOCS.glob("*.md")))
).hexdigest()[:16]

PRUNE_DIRS = ["_sources", "c-api", "extending"]
PRUNE_GLOBS = [
    "genindex*.html", "searchindex.js", "search.html", "404.html", "improve-page*.html", "download.html",
    "objects.inv", "_rediraffe_redirected.json", "whatsnew/changelog.html", "whatsnew/2.*.html",
    "_static/opensearch.xml", "_static/searchtools.js", "_static/rtd_switcher.js", "_static/search-focus.js",
    "_static/themetoggle.js", "_static/menu.js", "_static/language_data.js", "_static/changelog_search.js",
    "_static/glossary_search.js", "_static/glossary.json", "_static/sidebar.js",
]
KEEP_SCRIPTS = {"documentation_options.js", "doctools.js", "sphinx_highlight.js", "copybutton.js"}
MAX_IMAGE = 1_000_000  # bigger images (animated GIFs) load from docs.python.org
NOT_INDEXED = {"index.html", "contents.html", "py-modindex.html", "copyright.html", "license.html", "about.html", "bugs.html"}
OBJECT_KINDS = {
    "function", "class", "method", "classmethod", "staticmethod", "attribute", "property", "data",
    "exception", "decorator", "module", "type", "opcode", "pdbcommand", "envvar", "cmdoption",
}

CSS = """\
/* Terrarium: the docs in the app's viewer (scripts/build-docs.py). */
:root { color-scheme: light dark; -webkit-text-size-adjust: 100%; }
html { scroll-padding-top: 8px !important; }
body { margin: 0 !important; }
div.mobile-nav, div.sphinxsidebar, div.inline-search, .theme-selector-label { display: none !important; }
div.documentwrapper { float: none; width: 100%; }
div.bodywrapper { margin: 0 !important; }
div.body { min-width: 0 !important; max-width: 52em; margin: 0 auto; padding: 4px 16px 32px !important; }
div.related { margin: 0 !important; padding: 8px 16px !important; line-height: 1.4 !important; font-size: 0.8rem; }
div.related h3 { display: none; }
div.related ul { margin: 0; padding: 0; white-space: normal !important; }
div.related li { display: inline !important; float: none !important; white-space: normal !important; }
div.footer { font-size: 0.7rem; padding: 16px; margin: 0 !important; }
pre { overflow-x: auto; -webkit-overflow-scrolling: touch; }
dt:target, :target > dt, span.highlighted { background-color: rgba(255, 210, 0, 0.3) !important; }
@media (max-width: 700px) {
  div.body dl.field-list { display: block; }
  div.body dl.field-list > dt { background: none; padding: 0; margin: 12px 0 4px; }
  div.body dl.field-list > dd { margin-inline-start: 0; }
  div.body dd { margin-inline-start: 12px; }
}
"""


# -- fetching and pruning ---------------------------------------------------------


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def fetch(runtime: dict, update_pins: bool) -> Path:
    docs = runtime["docs"]
    cache = VENDOR / "docs-archives"
    cache.mkdir(parents=True, exist_ok=True)
    pinned = cache / f"python-{runtime['python']}-docs-html-{docs['sha256'][:12]}.zip"
    if pinned.exists() and not update_pins:
        return pinned
    print(f"downloading {docs['url']}", file=sys.stderr)
    tmp = cache / "download.tmp"
    with urllib.request.urlopen(docs["url"]) as response, tmp.open("wb") as f:
        shutil.copyfileobj(response, f)
    digest = sha256(tmp)
    if digest != docs["sha256"]:
        if not update_pins:
            tmp.unlink()
            sys.exit(
                f"error: {docs['url']} changed upstream (sha256 {digest}, pinned {docs['sha256']}).\n"
                "The archives are rebuilt in place; run scripts/build-docs.py --update-pins to pin the new one."
            )
        docs["sha256"] = digest
        pins = json.loads(RUNTIMES.read_text())
        for r in pins["runtimes"]:
            if r["python"] == runtime["python"]:
                r["docs"]["sha256"] = digest
        RUNTIMES.write_text(json.dumps(pins, indent=2) + "\n")
        print(f"pinned {runtime['python']} docs at {digest}", file=sys.stderr)
    target = cache / f"python-{runtime['python']}-docs-html-{digest[:12]}.zip"
    tmp.rename(target)
    return target


def prune(root: Path, python: str) -> None:
    for d in PRUNE_DIRS:
        shutil.rmtree(root / d, ignore_errors=True)
    for pattern in PRUNE_GLOBS:
        for p in root.glob(pattern):
            p.unlink()
    # What's New: this version and the two before it.
    minor = int(python.split(".")[1])
    for p in (root / "whatsnew").glob("3.*.html"):
        if int(p.stem.split(".")[1]) < minor - 2:
            p.unlink()
    for p in (root / "_images").glob("*"):
        if p.is_file() and p.stat().st_size > MAX_IMAGE:
            p.unlink()


# App Review rejects apps that contain the itms-services URL scheme (guideline
# 2.5.2, D57); urllib.parse's page names it in its list of schemes and in a
# note about exactly this. Both go, and nothing in the output may name it.
ITMS = "itms-services"


def app_store_compliance(root: Path) -> None:
    page = root / "library" / "urllib.parse.html"
    if page.exists():
        html = page.read_text(encoding="utf-8")
        html = re.sub(r'<code class="[^"]*"><span class="pre">itms-services</span></code>,\s*', "", html)
        html = re.sub(r'<div class="impl-detail compound">\s*<p>(?:(?!</div>).)*?itms-services.*?</div>\s*', "", html, flags=re.S)
        page.write_text(html, encoding="utf-8")
    for p in root.rglob("*"):
        if p.is_file() and ITMS.encode() in p.read_bytes():
            sys.exit(f"error: {p.relative_to(root)} names {ITMS}; App Review rejects that (D57), extend app_store_compliance")


# -- HTML for the viewer -----------------------------------------------------------


def patch(soup: BeautifulSoup, rel: PurePosixPath, root: Path, python: str) -> None:
    up = "../" * (len(rel.parts) - 1)
    for sel in ["div.mobile-nav", "div.sphinxsidebar", "link[rel=search]", "link[rel=index]"]:
        for el in soup.select(sel):
            el.decompose()
    related = soup.select("div.related")
    for el in related[1:]:
        el.decompose()
    if related:
        top = related[0]
        for li in top.select("li.right, li.switchers, li.root-icon"):
            li.decompose()
        for li in top.select("li"):
            a = li.find("a")
            if a is None or (a.get("href") or "").startswith("https://www.python.org"):
                li.decompose()
    for script in soup.find_all("script"):
        src = script.get("src")
        if not src or PurePosixPath(src.split("?")[0]).name not in KEEP_SCRIPTS:
            script.decompose()
    # Links: root-relative ones become relative, pruned pages go online.
    for tag, attr in (("a", "href"), ("img", "src"), ("link", "href")):
        for el in soup.find_all(tag):
            value = el.get(attr)
            if not value or value.startswith("#") or re.match(r"^[a-z][a-z0-9+.-]*:", value):
                continue
            path, _, fragment = value.partition("#")
            path = path.split("?")[0]
            if path.startswith("/"):
                target = PurePosixPath(path.lstrip("/"))
            else:
                target = PurePosixPath(*_normalize(rel.parent.parts + PurePosixPath(path).parts))
            if not (root / target).exists():
                if tag == "link":
                    el.decompose()
                    continue
                el[attr] = f"https://docs.python.org/{python}/{target}" + (f"#{fragment}" if fragment else "")
            elif path.startswith("/"):
                el[attr] = up + str(target) + (f"#{fragment}" if fragment else "")
    head = soup.head
    if head is not None:
        head.append(soup.new_tag("meta", attrs={"name": "color-scheme", "content": "light dark"}))
        head.append(soup.new_tag("link", attrs={"rel": "stylesheet", "href": f"{up}_static/terrarium.css"}))


def _normalize(parts: tuple[str, ...]) -> list[str]:
    out: list[str] = []
    for p in parts:
        if p == "..":
            if out:
                out.pop()
        elif p not in (".", ""):
            out.append(p)
    return out


# -- Markdown chunks for search ----------------------------------------------------


class Markdown(MarkdownConverter):
    def convert_pre(self, el, text, parent_tags):
        code = el.get_text()
        if not code.strip():
            return ""
        lang = ""
        for node in (el.parent, el.parent.parent if el.parent else None):
            for cls in (node.get("class", []) if isinstance(node, Tag) else []):
                if cls.startswith("highlight-"):
                    lang = cls.removeprefix("highlight-")
        lang = {"python3": "python", "pycon": "pycon", "default": "python", "py": "python", "none": "", "text": ""}.get(lang, lang)
        return f"\n\n```{lang}\n{code.rstrip()}\n```\n\n"

    def convert_p(self, el, text, parent_tags):
        if "admonition-title" in el.get("class", []):
            return f"\n\n**{text.strip()}:**\n\n"
        return super().convert_p(el, text, parent_tags)


def markdown(html: str) -> str:
    md = Markdown(
        heading_style="ATX", bullets="-", strip=["a", "img"], escape_underscores=False, escape_asterisks=False,
        escape_misc=False,
    ).convert(html)
    return re.sub(r"\n{3,}", "\n\n", md).strip()


def clean_text(el: Tag) -> str:
    for junk in el.select("a.headerlink, a.reference.internal > span.viewcode-link, .viewcode-link"):
        junk.decompose()
    return re.sub(r"\s+", " ", el.get_text()).strip().rstrip("¶").strip()


def object_kind(dl: Tag) -> str | None:
    classes = dl.get("class", [])
    if dl.name != "dl" or "py" not in classes and "std" not in classes:
        return None
    for c in classes:
        if c in OBJECT_KINDS:
            return c
    return None


class Indexer:
    def __init__(self, db: sqlite3.Connection):
        self.db = db
        self.ord = 0
        self.page = 0

    def index(self, soup: BeautifulSoup, rel: str) -> None:
        body = soup.select_one('div.body[role="main"]') or soup.select_one("div.body")
        if body is None:
            return
        title = soup.title.get_text() if soup.title else rel
        title = re.split(r"\s+\u2014\s+Python [\d.a-z]+ documentation", title)[0].strip()
        self.page = self.db.execute("INSERT INTO pages(path, title) VALUES (?, ?)", (rel, title)).lastrowid
        self.ord = 0
        sections = body.find_all("section", recursive=False)
        if not sections:
            self.chunk("section", "", title, [], 0, lambda: self.content(body, [title], 0))
        for sec in sections:
            self.section(sec, [], 0)

    def chunk(self, kind, anchor, title, crumbs, depth, fill, symbols=()):
        start = self.ord
        self.ord += 1
        cid = self.db.execute(
            "INSERT INTO chunks(page, ord, end_ord, depth, kind, anchor, title, symbol, breadcrumb, body) VALUES (?,?,?,?,?,?,?,?,?,'')",
            (self.page, start, start, depth, kind, anchor, title, " ".join(s for s, _ in symbols), " › ".join(crumbs)),
        ).lastrowid
        for name, skind in symbols:
            self.db.execute("INSERT INTO symbols(name, lower, chunk, kind) VALUES (?,?,?,?)", (name, name.lower(), cid, skind))
        body = fill()
        self.db.execute("UPDATE chunks SET body = ?, end_ord = ? WHERE id = ?", (body, self.ord - 1, cid))

    def section(self, sec: Tag, crumbs: list[str], depth: int) -> None:
        heading = sec.find(re.compile(r"^h[1-6]$"), recursive=False)
        title = clean_text(heading) if heading else ""
        ids = [sec.get("id", "")] + [s.get("id") for s in sec.find_all("span", recursive=False) if s.get("id")]
        modules = [i.removeprefix("module-") for i in ids if i and i.startswith("module-")]
        kind = "module" if modules else "section"
        anchor = sec.get("id", "")
        self.chunk(kind, anchor, title, crumbs, depth, lambda: self.content(sec, crumbs + [title], depth, skip=heading),
                   symbols=[(m, "module") for m in modules])

    def obj(self, dl: Tag, kind: str, crumbs: list[str], depth: int) -> None:
        # One entry: one or more signatures (dt) and the description (dd).
        dts = dl.find_all("dt", recursive=False)
        dd = dl.find("dd", recursive=False)
        ids = [dt.get("id") for dt in dts if dt.get("id")]
        if not ids:
            return
        signature = " | ".join(clean_text(dt) for dt in dts)
        name = ids[0]
        self.chunk(kind, name, signature, crumbs, depth,
                   lambda: self.content(dd, crumbs + [name], depth) if dd else "",
                   symbols=[(i, kind) for i in dict.fromkeys(ids)])

    def glossary(self, dl: Tag, crumbs: list[str], depth: int) -> None:
        for dt in dl.find_all("dt", recursive=False):
            dd = dt.find_next_sibling("dd")
            term = clean_text(dt)
            self.chunk("term", dt.get("id", ""), term, crumbs, depth, lambda dd=dd: markdown(dd.decode_contents()) if dd else "")

    def content(self, node: Tag, crumbs: list[str], depth: int, skip: Tag | None = None) -> str:
        """Markdown of node's own content; sections and API entries inside it become chunks of their own."""
        parts: list[str] = []
        for child in node.children:
            if child is skip:
                continue
            if isinstance(child, NavigableString):
                if child.strip():
                    parts.append(str(child))
                continue
            if not isinstance(child, Tag):
                continue
            kind = object_kind(child)
            if child.name == "section":
                self.section(child, crumbs, depth + 1)
            elif kind:
                self.obj(child, kind, crumbs, depth + 1)
            elif child.name == "dl" and "glossary" in child.get("class", []):
                self.glossary(child, crumbs, depth + 1)
            else:
                parts.append(str(child))
        return markdown("".join(parts))


SCHEMA = """
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE pages(id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, title TEXT NOT NULL);
CREATE TABLE chunks(
  id INTEGER PRIMARY KEY, page INTEGER NOT NULL, ord INTEGER NOT NULL, end_ord INTEGER NOT NULL,
  depth INTEGER NOT NULL, kind TEXT NOT NULL, anchor TEXT NOT NULL, title TEXT NOT NULL,
  symbol TEXT NOT NULL, breadcrumb TEXT NOT NULL, body TEXT NOT NULL
);
CREATE INDEX chunks_page ON chunks(page, ord);
CREATE INDEX chunks_anchor ON chunks(anchor);
CREATE TABLE symbols(name TEXT NOT NULL, lower TEXT NOT NULL, chunk INTEGER NOT NULL, kind TEXT NOT NULL);
CREATE INDEX symbols_name ON symbols(name);
CREATE INDEX symbols_lower ON symbols(lower);
CREATE VIRTUAL TABLE chunks_fts USING fts5(
  title, symbol, breadcrumb, body, content='chunks', content_rowid='id', tokenize='porter unicode61'
);
"""


# -- the app's own docs (D42) -------------------------------------------------------

_HEADING = re.compile(r"^(#{1,4})\s+(.*?)\s*$")
_API = re.compile(r"^(class\s+)?([A-Za-z_]\w*(?:\.\w+)+)(\(.*\))?$")


def _slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower().replace("`", "")).strip("-") or "section"


def _highlight(code: str, lang: str) -> str:
    from pygments import highlight
    from pygments.formatters import HtmlFormatter
    from pygments.lexers import get_lexer_by_name

    try:
        lexer = get_lexer_by_name(lang or "python3")
    except Exception:
        lexer = get_lexer_by_name("text")
    body = highlight(code, lexer, HtmlFormatter(nowrap=True))
    return f'<div class="highlight-{lang or "python3"} notranslate"><div class="highlight"><pre><span></span>{body}</pre></div></div>'


def _md(text: str) -> str:
    """Markdown as Sphinx would render it: literals, highlighted code, docutils tables."""
    import markdown as mdlib

    blocks: list[str] = []

    def stash(m):
        blocks.append(_highlight(m.group(2), m.group(1).strip()))
        return f"\n\nTERRARIUMCODE{len(blocks) - 1}\n\n"

    text = re.sub(r"^```(\w*)\n(.*?)^```\s*$", stash, text, flags=re.M | re.S)
    out = mdlib.markdown(text, extensions=["tables"])
    out = re.sub(r"<code>(.*?)</code>", r'<code class="docutils literal notranslate"><span class="pre">\1</span></code>', out, flags=re.S)
    out = out.replace("<table>", '<table class="docutils align-default">')
    for i, block in enumerate(blocks):
        out = out.replace(f"<p>TERRARIUMCODE{i}</p>", block)
    return out


def _inline(text: str) -> str:
    out = _md(text)
    return re.sub(r"^<p>(.*)</p>$", r"\1", out.strip(), flags=re.S)


def _parse(source: str) -> list[dict]:
    """Headings and the text under them, as a tree (by heading level)."""
    root: list[dict] = []
    stack: list[dict] = []
    body: list[str] = []
    current: dict | None = None
    in_code = False

    def flush():
        if current is not None:
            current["body"] = "\n".join(body).strip()
        body.clear()

    for line in source.split("\n"):
        if line.startswith("```"):
            in_code = not in_code
        m = None if in_code else _HEADING.match(line)
        if not m:
            body.append(line)
            continue
        flush()
        node = {"level": len(m.group(1)), "title": m.group(2), "children": []}
        while stack and stack[-1]["level"] >= node["level"]:
            stack.pop()
        (stack[-1]["children"] if stack else root).append(node)
        stack.append(node)
        current = node
    flush()
    return root


def _render(node: dict, page_module: str | None, parent_class: str | None = None, depth: int = 1) -> str:
    title = node["title"]
    m = _API.match(title)
    if m and depth > 1:
        is_class, name, params = bool(m.group(1)), m.group(2), m.group(3)
        if is_class:
            kind = "class"
        elif parent_class and name.startswith(parent_class + "."):
            kind = "method" if params is not None else "attribute"
        else:
            kind = "function" if params is not None else "data"
        prename, _, short = name.rpartition(".")
        sig = ""
        if is_class:
            sig += '<em class="property"><span class="pre">class</span><span class="w"> </span></em>'
        if kind in ("function", "class", "data"):
            sig += f'<span class="sig-prename descclassname"><span class="pre">{prename}.</span></span>'
        sig += f'<span class="sig-name descname"><span class="pre">{short}</span></span>'
        if params is not None:
            inner = params[1:-1].replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            sig += f'<span class="sig-paren">(</span><em class="sig-param">{inner}</em><span class="sig-paren">)</span>'
        children = "".join(_render(c, page_module, name if is_class else parent_class, depth + 1) for c in node["children"])
        return (
            f'<dl class="py {kind}"><dt class="sig sig-object py" id="{name}">{sig}'
            f'<a class="headerlink" href="#{name}" title="Link to this definition">¶</a></dt>'
            f'<dd>{_md(node["body"])}{children}</dd></dl>\n'
        )
    anchor = f"module-{page_module}" if depth == 1 and page_module else _slug(title)
    level = min(depth, 6)
    children = "".join(_render(c, page_module, parent_class, depth + 1) for c in node["children"])
    return (
        f'<section id="{anchor}"><h{level}>{_inline(title)}<a class="headerlink" href="#{anchor}" '
        f'title="Link to this heading">¶</a></h{level}>\n{_md(node["body"])}{children}</section>\n'
    )


def render_app_docs(root: Path, release: str) -> int:
    """app/docs/*.md -> <root>/terrarium/*.html, in the archive's page layout."""
    out = root / APP_DOCS_DIR
    out.mkdir(exist_ok=True)
    sources = sorted(APP_DOCS.glob("*.md"))
    for src in sources:
        stem = src.stem
        tree = _parse(src.read_text())
        title = re.sub(r"[`*]", "", tree[0]["title"]) if tree else stem
        # turtle's page is about the app; the module itself is the standard library's.
        module = None if stem in ("index", "turtle", "notebooks") else stem
        content = "".join(_render(n, module) for n in tree)
        crumbs = f'<li><a href="../index.html">{release} Documentation</a> &#187;</li>\n'
        if stem != "index":
            crumbs += '<li class="nav-item"><a href="index.html">Terrarium Modules</a> &#187;</li>\n'
        crumbs += f'<li class="nav-item nav-item-this"><a href="">{title}</a></li>'
        page = f"""<!DOCTYPE html>
<html lang="en" data-content_root="../">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>{title} &#8212; Python {release} documentation</title>
<link rel="stylesheet" type="text/css" href="../_static/pygments.css" />
<link rel="stylesheet" type="text/css" href="../_static/classic.css" />
<link rel="stylesheet" type="text/css" href="../_static/pydoctheme.css" />
<link id="pygments_dark_css" media="(prefers-color-scheme: dark)" rel="stylesheet" type="text/css" href="../_static/pygments_dark.css" />
<link rel="stylesheet" href="../_static/pydoctheme_dark.css" media="(prefers-color-scheme: dark)" id="pydoctheme_dark_css" />
</head>
<body>
<div class="related" role="navigation" aria-label="Related"><h3>Navigation</h3><ul>{crumbs}</ul></div>
<div class="document"><div class="documentwrapper"><div class="bodywrapper"><div class="body" role="main">
{content}
</div></div></div></div>
<div class="footer">The Terrarium modules' documentation is part of the app.</div>
</body>
</html>
"""
        (out / f"{stem}.html").write_text(page, encoding="utf-8")
    return len(sources)


def link_app_docs(soup: BeautifulSoup) -> None:
    """The docs' start page links the app's modules first."""
    ul = soup.select_one("div.contentstable ul")
    if ul is None:
        return
    li = BeautifulSoup(
        f'<li class="biglink"><a class="biglink" href="{APP_DOCS_DIR}/index.html">Terrarium modules</a><br/>'
        '<span class="linkdescr">ui apps, turtle, and the device: clipboard, dialogs, photos, location, sound, ...</span></li>',
        "html.parser",
    )
    ul.insert(0, li)


# -- build --------------------------------------------------------------------------


def build(runtime: dict, update_pins: bool, force: bool) -> None:
    python = runtime["python"]
    out = VENDOR / f"docs-{python}"
    stamp = f"{runtime['docs']['sha256']} {SCRIPT_HASH}\n"
    if not force and not update_pins and (out / ".stamp").exists() and (out / ".stamp").read_text() == stamp:
        return
    archive = fetch(runtime, update_pins)
    stamp = f"{runtime['docs']['sha256']} {SCRIPT_HASH}\n"
    work = VENDOR / f"docs-{python}.tmp"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    with zipfile.ZipFile(archive) as z:
        z.extractall(work / "raw")
    (root,) = [p for p in (work / "raw").iterdir() if p.is_dir()]
    prune(root, python)
    app_store_compliance(root)
    release = next(
        (m.group(1) for m in [re.search(r"Python ([\d.a-z]+) documentation", (root / "index.html").read_text())] if m), python
    )
    render_app_docs(root, release)

    db = sqlite3.connect(work / "docs.sqlite")
    db.executescript(SCHEMA)
    indexer = Indexer(db)
    release = python
    pages = sorted(root.rglob("*.html"))
    for page in pages:
        rel = PurePosixPath(page.relative_to(root).as_posix())
        soup = BeautifulSoup(page.read_bytes(), "lxml")
        if soup.title and (m := re.search(r"Python ([\d.a-z]+) documentation", soup.title.get_text())):
            release = m.group(1)
        if str(rel) not in NOT_INDEXED:
            indexer.index(BeautifulSoup(page.read_bytes(), "lxml"), str(rel))
        if str(rel) == "index.html":
            link_app_docs(soup)
        patch(soup, rel, root, python)
        page.write_text(str(soup), encoding="utf-8")
    (root / "_static" / "terrarium.css").write_text(CSS)
    db.executemany("INSERT INTO meta(key, value) VALUES (?, ?)", [
        ("python", python), ("release", release), ("archive_sha256", runtime["docs"]["sha256"]), ("source", runtime["docs"]["url"]),
    ])
    db.execute("INSERT INTO chunks_fts(chunks_fts) VALUES ('rebuild')")
    db.execute("INSERT INTO chunks_fts(chunks_fts) VALUES ('optimize')")
    db.commit()
    chunks = db.execute("SELECT count(*) FROM chunks").fetchone()[0]
    symbols = db.execute("SELECT count(*) FROM symbols").fetchone()[0]
    db.execute("VACUUM")
    db.close()
    if ITMS.encode() in (work / "docs.sqlite").read_bytes():
        sys.exit(f"error: docs.sqlite names {ITMS} (D57)")

    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    root.rename(out / "html")
    (work / "docs.sqlite").rename(out / "docs.sqlite")
    shutil.rmtree(work)
    (out / ".stamp").write_text(stamp)
    size = sum(p.stat().st_size for p in (out / "html").rglob("*") if p.is_file())
    print(
        f"built docs {release} into {out.relative_to(APP)}: {len(pages)} pages, {size / 1e6:.0f} MB HTML, "
        f"{chunks} chunks, {symbols} symbols, {(out / 'docs.sqlite').stat().st_size / 1e6:.0f} MB index",
        file=sys.stderr,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--update-pins", action="store_true", help="download the current archives and pin them")
    parser.add_argument("--force", action="store_true", help="rebuild even when up to date")
    args = parser.parse_args()
    for runtime in json.loads(RUNTIMES.read_text())["runtimes"]:
        build(runtime, args.update_pins, args.force)


if __name__ == "__main__":
    main()
