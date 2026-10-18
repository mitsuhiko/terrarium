"""Tracebacks as data (D45): the console and notebooks draw them, not just print them.

``describe(exc)`` returns the exception chain (oldest first, as Python prints
it) with each exception's frames (most recent call last), their spans
(character columns), a few lines of source around them and whether they are
the program's own ("app") or the standard library's and installed packages'
("library"). The runtime's frames (Pyodide, ``/lib/terrarium``) are dropped, as
in ``text``, the classic traceback that goes with it.

- ``last_json()``: the uncaught exception of the run that just failed
  (``sys.last_exc``), for the worker; ``mark()`` before a run.
- ``report(exc)``: an exception the runtime caught (a ui callback, a turtle
  event handler) goes to the page as an "exception" display message.
"""

import itertools
import json
import linecache
import os
import re
import sys
import traceback

PROJECT = "/home/pyodide/project"
RUNTIME = "/lib/terrarium/"
CONTEXT = 3  # lines before and after an app frame's line
MAX_SPAN_LINES = 8
MAX_LINE = 400  # characters of a source line
MAX_FRAMES = 60  # after repeats are folded: the first and the last ones stay
KEEP_FIRST = 20
MAX_CHAIN = 20
MAX_GROUP_WIDTH = 15
MAX_GROUP_DEPTH = 6


def hidden(filename):
    """The runtime's own frames: Pyodide's and ours."""
    return filename.startswith(RUNTIME) or "/_pyodide/" in filename or filename == "<dependencies>"


def kind(filename):
    if filename.startswith("<"):
        return "app" if filename.startswith(("<console", "<cell")) else "library"
    path = os.path.normpath(filename if os.path.isabs(filename) else os.path.join(PROJECT, filename))
    return "app" if path.startswith(PROJECT + "/") and "/site-packages/" not in path else "library"


_LIBRARY = re.compile(r"^/lib/python3\d*(?:\.zip)?/(?:site-packages/)?|^.*/site-packages/")


def display_name(filename):
    """Project files relative to the program's folder, the standard library and
    packages by their module path (json/decoder.py), the rest as they are."""
    if filename.startswith(PROJECT + "/"):
        return filename[len(PROJECT) + 1:]
    return _LIBRARY.sub("", filename)


def type_name(exc_type):
    name = getattr(exc_type, "__qualname__", None) or getattr(exc_type, "__name__", "Exception")
    module = getattr(exc_type, "__module__", None)
    return name if module in (None, "builtins", "__main__") else f"{module}.{name}"


def _safe_str(value):
    try:
        return str(value)
    except Exception:
        return "<exception str() failed>"


def _chars(line, offset):
    """A UTF-8 byte offset into a line as a character offset."""
    return len(line.encode("utf-8")[:offset].decode("utf-8", errors="replace"))


def _position(code, lasti):
    if lasti < 0:
        return None
    try:
        return next(itertools.islice(code.co_positions(), lasti // 2, None))
    except (StopIteration, ValueError):
        return None


def _source(filename, module_globals=None):
    if not filename.startswith("<"):
        linecache.checkcache(filename)
    try:
        return linecache.getlines(filename, module_globals)
    except Exception:
        return []


def _context(lines, first, last, around):
    """Lines first-around .. last+around (1-based), dedented; None without source."""
    if not lines or first > len(lines):
        return None
    start = max(1, first - around)
    end = min(len(lines), last + around)
    text = [lines[i - 1].rstrip("\r\n") for i in range(start, end + 1)]
    indents = [len(t) - len(t.lstrip()) for t in text if t.strip()]
    indent = min(indents) if indents else 0
    text = [t[indent:] if t.strip() else "" for t in text]
    text = [t if len(t) <= MAX_LINE else t[:MAX_LINE] + "…" for t in text]
    return {"start": start, "lines": text, "indent": indent}


def _frame(filename, name, lineno, pos, module_globals):
    """A frame (or a SyntaxError's place): pos is (end_lineno, col, end_col) in bytes, or None."""
    k = kind(filename)
    d = {"kind": k, "file": display_name(filename), "name": name, "line": lineno or 0}
    if not lineno:
        return d
    lines = _source(filename, module_globals)
    end_lineno = lineno
    col = end_col = None
    if pos is not None and lines and lineno <= len(lines):
        end_lineno, col, end_col = pos
        end_lineno = end_lineno or lineno
        if end_lineno < lineno or end_lineno > len(lines):
            end_lineno, col, end_col = lineno, None, None
        if col is not None:
            col = _chars(lines[lineno - 1].rstrip("\r\n"), col)
        if end_col is not None:
            end_col = _chars(lines[end_lineno - 1].rstrip("\r\n"), end_col)
    last = min(end_lineno, lineno + MAX_SPAN_LINES - 1)
    if last != end_lineno:  # the span is cut: up to the end of the last line shown
        end_col = None
    context = _context(lines, lineno, last, CONTEXT if k == "app" else 0)
    if context is not None:
        indent = context.pop("indent")
        d["context"] = context
        if end_lineno != lineno:
            d["endLine"] = last
        if col is not None:
            d["col"] = max(0, col - indent)
        if end_col is not None:
            d["endCol"] = max(0, end_col - indent)
    return d


def _frames(tb, debug=False):
    entries = []
    user = []
    if debug:
        try:
            from _terrarium_debug import debugger

            user = [id(t) for t in _walk(tb) if debugger.is_user(t.tb_frame)]
        except Exception:
            user = []
    index = {t: len(user) - 1 - i for i, t in enumerate(user)}  # post_mortem()'s stack is innermost first
    for t in _walk(tb):
        code = t.tb_frame.f_code
        filename = code.co_filename
        if hidden(filename):
            continue
        lineno = t.tb_lineno
        pos = _position(code, t.tb_lasti)
        if pos is not None and pos[0] != lineno:
            pos = None
        d = _frame(filename, getattr(code, "co_qualname", code.co_name), lineno, pos and pos[1:], t.tb_frame.f_globals)
        if id(t) in index:
            d["debug"] = index[id(t)]
        entries.append(d)
    # Recursion: the same frame again and again is shown once.
    folded = []
    for d in entries:
        prev = folded[-1] if folded else None
        if prev and (prev["file"], prev["line"], prev["name"], prev.get("col")) == (d["file"], d["line"], d["name"], d.get("col")):
            prev["repeat"] = prev.get("repeat", 0) + 1
        else:
            folded.append(d)
    if len(folded) > MAX_FRAMES:
        keep_last = MAX_FRAMES - KEEP_FIRST
        omitted = len(folded) - MAX_FRAMES
        folded = folded[:KEEP_FIRST] + [{"kind": "omitted", "count": omitted}] + folded[-keep_last:]
    return folded


def _walk(tb):
    seen = set()
    while tb is not None and id(tb) not in seen:
        seen.add(id(tb))
        yield tb
        tb = tb.tb_next


def _message(exc):
    """The message as Python shows it after "Type: " (with "Did you mean ...?")."""
    try:
        # The traceback is for "Did you mean ...?" (names in the failing frame); limit=0 skips the rest.
        te = traceback.TracebackException(type(exc), exc, exc.__traceback__, limit=0, lookup_lines=False, max_group_width=1, max_group_depth=1)
        message = getattr(te, "_str", None)
        if isinstance(message, str):
            return message
    except Exception:
        pass
    return _safe_str(exc)


def _matches(lines, exc):
    """The source we have is what was compiled (a cached copy can be stale)."""
    if not lines or exc.lineno > len(lines):
        return False
    return not exc.text or lines[exc.lineno - 1].strip() == exc.text.strip()


def _one(exc, depth, debug):
    d = {"type": type_name(type(exc)), "message": _message(exc), "frames": _frames(exc.__traceback__, debug)}
    notes = getattr(exc, "__notes__", None)
    if isinstance(notes, (list, tuple)) and notes:
        d["notes"] = [n if isinstance(n, str) else repr(n) for n in notes]
    if isinstance(exc, SyntaxError):
        d["message"] = _safe_str(exc.msg) if exc.msg is not None else "invalid syntax"
        if exc.filename and exc.lineno:
            end = exc.end_lineno or exc.lineno
            pos = None
            if exc.offset and exc.offset > 0:
                # SyntaxError offsets are 1-based characters: as bytes for _frame.
                lines = _source(exc.filename)
                if _matches(lines, exc) and end <= len(lines):
                    first, last = lines[exc.lineno - 1], lines[end - 1]
                    end_offset = exc.end_offset if exc.end_offset and exc.end_offset > 0 else exc.offset + 1
                    pos = (end, len(first[: exc.offset - 1].encode()), len(last[: end_offset - 1].encode()))
            frame = _frame(exc.filename, None, exc.lineno, pos, None) if _matches(_source(exc.filename), exc) else {
                "kind": kind(exc.filename), "file": display_name(exc.filename), "name": None, "line": exc.lineno}
            if "context" not in frame and exc.text:
                text = exc.text.rstrip("\r\n")
                stripped = text.lstrip()
                cut = len(text) - len(stripped)
                frame["context"] = {"start": exc.lineno, "lines": [stripped[:MAX_LINE]]}
                if exc.offset and exc.offset > 0 and end == exc.lineno:
                    frame["col"] = max(0, exc.offset - 1 - cut)
                    if exc.end_offset and exc.end_offset > exc.offset:
                        frame["endCol"] = max(0, exc.end_offset - 1 - cut)
            d["syntax"] = frame
    if isinstance(exc, BaseExceptionGroup) and depth < MAX_GROUP_DEPTH:
        members = list(exc.exceptions)
        d["group"] = [chain(e, depth + 1) for e in members[:MAX_GROUP_WIDTH]]
        if len(members) > MAX_GROUP_WIDTH:
            d["groupMore"] = len(members) - MAX_GROUP_WIDTH
    return d


def chain(exc, depth=0, debug=False):
    """The exception and the ones it came from, oldest first. A later one
    has "chain": how the one before it led to it ("cause" or "context")."""
    out = []
    seen = set()
    current = exc
    while current is not None and id(current) not in seen and len(out) < MAX_CHAIN:
        seen.add(id(current))
        d = _one(current, depth, debug and current is exc)
        out.append(d)
        if current.__cause__ is not None:
            d["chain"] = "cause"
            current = current.__cause__
        elif current.__context__ is not None and not current.__suppress_context__:
            d["chain"] = "context"
            current = current.__context__
        else:
            current = None
    out.reverse()
    return out


def _filter(te, seen):
    if te is None or id(te) in seen:
        return
    seen.add(id(te))
    if te.stack:
        te.stack = traceback.StackSummary.from_list([f for f in te.stack if not hidden(f.filename)])
    _filter(te.__cause__, seen)
    _filter(te.__context__, seen)
    for member in getattr(te, "exceptions", None) or ():
        _filter(member, seen)


def text(exc):
    """The classic traceback without the runtime's frames, project paths relative."""
    try:
        te = traceback.TracebackException.from_exception(exc)
        _filter(te, set())
        lines = "".join(te.format())
    except Exception:
        lines = "".join(traceback.format_exception_only(type(exc), exc))
    return lines.replace(f'File "{PROJECT}/', 'File "').rstrip("\n")


def describe(exc, debug=False):
    return {"text": text(exc), "exceptions": chain(exc, debug=debug)}


def to_json(exc, debug=False):
    try:
        return json.dumps(describe(exc, debug))
    except Exception:
        return ""


# -- the worker's side --------------------------------------------------------------------

_marked = None


def mark():
    """Before a run: the exception of an earlier run is not this run's."""
    global _marked
    _marked = getattr(sys, "last_exc", None)


def last_json():
    """The run's uncaught exception as JSON, "" if there is none (or it is not the program's)."""
    exc = getattr(sys, "last_exc", None)
    if exc is None or exc is _marked:
        return ""
    if type(exc).__name__ == "DependencyError" and type(exc).__module__ == "_terrarium":
        return ""
    return to_json(exc, debug=True)


def report(exc):
    """An exception the runtime caught: shown in the console (or the cell) as a traceback."""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.flush()
        except Exception:
            pass
    try:
        import _terrariumhost

        trace = describe(exc)
        last = trace["exceptions"][-1]
        _terrariumhost.display(json.dumps({
            "type": "exception", "ename": type(exc).__name__, "evalue": last["message"],
            "traceback": trace["text"].split("\n"), "trace": trace,
        }))
    except Exception:
        sys.stderr.write(text(exc) + "\n")
