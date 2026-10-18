"""Notebook cells (D44): a kernel in the program's interpreter.

- ``run_cell(source, count)``: run a cell in ``__main__`` like Jupyter does: the
  value of a final expression is shown (not after a ``;``), top-level ``await``
  works, figures are shown at the end, errors become an error output.
- the display protocol: ``display()``, ``_repr_html_`` and friends, and an
  ``IPython`` module with ``IPython.display`` (HTML, Markdown, Image, ...), so
  notebooks written for Jupyter work. Also in scripts: there ``display()``
  prints, and shows images in the console.
- magics: ``%pip``, ``%time``, ``%timeit``, ``%cd``, ``%run``, ``%%html``,
  ``%%writefile``, ``obj?`` and a few more; ``!cmd`` explains that there is no
  shell.

Outputs go to the page as JSON through ``_terrariumhost.display``.
"""

import ast
import base64
import builtins
import importlib.abc
import importlib.util
import inspect
import json
import linecache
import os
import re
import sys
import time
import uuid

import _terrariumhost


class UsageError(Exception):
    """A magic was used wrongly (shown without a traceback, as in IPython)."""


# -- sending outputs ---------------------------------------------------------------


def _flush_streams():
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.flush()
        except Exception:
            pass


def _send(message):
    # What the cell printed so far comes first.
    _flush_streams()
    _terrariumhost.display(json.dumps(message, default=str))


def publish_display_data(data, metadata=None, source=None, *, transient=None, **kwargs):
    _send({"type": "display_data", "data": data, "metadata": metadata or {}, "transient": transient or {}})


# -- formatting: the richest representations an object has ------------------------

_REPRS = [
    ("text/html", "_repr_html_"),
    ("text/markdown", "_repr_markdown_"),
    ("image/svg+xml", "_repr_svg_"),
    ("image/png", "_repr_png_"),
    ("image/jpeg", "_repr_jpeg_"),
    ("text/latex", "_repr_latex_"),
    ("application/json", "_repr_json_"),
    ("application/javascript", "_repr_javascript_"),
]


def _method(obj, name):
    """A _repr_*_ method of obj's type (bound), not one __getattr__ invents."""
    if inspect.isclass(obj):
        return None
    try:
        method = getattr(type(obj), name, None)
    except Exception:
        return None
    if method is None or not callable(method):
        return None
    return method.__get__(obj, type(obj)) if hasattr(method, "__get__") else None


def _plain(obj):
    if type(obj) in (dict, list, tuple, set, frozenset):
        import pprint

        try:
            return pprint.pformat(obj, width=80, sort_dicts=False)
        except Exception:
            pass
    return repr(obj)


def _is_figure(obj):
    t = type(obj)
    return t.__name__ == "Figure" and t.__module__.startswith("matplotlib.")


def _figure_png(fig):
    import io

    buf = io.BytesIO()
    fig.savefig(buf, format="png", dpi=144, bbox_inches="tight")
    try:
        import matplotlib.pyplot as plt

        plt.close(fig)  # not shown a second time at the end of the cell
    except Exception:
        pass
    return base64.b64encode(buf.getvalue()).decode("ascii")


def format_display_data(obj, include=None, exclude=None):
    """(data, metadata) for obj, like IPython's DisplayFormatter."""
    data, metadata = {}, {}
    if _is_figure(obj):
        data["image/png"] = _figure_png(obj)
        metadata["image/png"] = {"width": int(obj.get_figwidth() * 72), "height": int(obj.get_figheight() * 72)}
    method = _method(obj, "_repr_mimebundle_")
    if method is not None:
        try:
            try:
                result = method(include=include, exclude=exclude)
            except TypeError:
                result = method()
            if isinstance(result, tuple):
                result, md = result
                metadata.update(md or {})
            if result:
                data.update(result)
        except Exception:
            pass
    for mime, name in _REPRS:
        if mime in data:
            continue
        method = _method(obj, name)
        if method is None:
            continue
        try:
            value = method()
        except NotImplementedError:
            continue
        except Exception as e:
            print(f"Error in {type(obj).__name__}.{name}(): {e!r}", file=sys.stderr)
            continue
        if value is None:
            continue
        if isinstance(value, tuple) and len(value) == 2 and isinstance(value[1], dict):
            value, md = value
            metadata[mime] = md
        if mime in ("image/png", "image/jpeg") and isinstance(value, (bytes, bytearray)):
            value = base64.b64encode(value).decode("ascii")
        data[mime] = value
    if "text/plain" not in data:
        data["text/plain"] = _plain(obj)
    if include:
        data = {k: v for k, v in data.items() if k in include}
    if exclude:
        data = {k: v for k, v in data.items() if k not in exclude}
    return data, metadata


# -- display() ------------------------------------------------------------------------


class DisplayHandle:
    """Updates what display(..., display_id=True) showed."""

    def __init__(self, display_id=None):
        self.display_id = display_id or uuid.uuid4().hex

    def __repr__(self):
        return f"<DisplayHandle display_id={self.display_id}>"

    def display(self, obj, **kwargs):
        display(obj, display_id=self.display_id, **kwargs)

    def update(self, obj, **kwargs):
        update_display(obj, display_id=self.display_id, **kwargs)


def display(*objs, include=None, exclude=None, metadata=None, transient=None, display_id=None, raw=False, clear=False, **kwargs):
    """Show objects with their richest representation (IPython's display)."""
    if clear:
        clear_output(wait=True)
    if display_id is True:
        display_id = uuid.uuid4().hex
    transient = dict(transient or {})
    if display_id:
        transient["display_id"] = display_id
    for obj in objs:
        if raw:
            data, md = obj, dict(metadata or {})
        else:
            data, md = format_display_data(obj, include, exclude)
            if metadata:
                md.update(metadata)
        if data:
            _send({"type": "display_data", "data": data, "metadata": md, "transient": transient})
    if display_id:
        return DisplayHandle(display_id)
    return None


def update_display(obj, *, display_id, **kwargs):
    data, md = format_display_data(obj)
    _send({"type": "update_display_data", "data": data, "metadata": md, "transient": {"display_id": display_id}})


def clear_output(wait=False):
    _send({"type": "clear_output", "wait": bool(wait)})


# -- IPython.display's classes ----------------------------------------------------------


class DisplayObject:
    _read_flags = "r"

    def __init__(self, data=None, url=None, filename=None, metadata=None):
        if isinstance(data, str) and data.startswith(("http://", "https://")) and url is None and filename is None:
            url, data = data, None
        self.data = data
        self.url = url
        self.filename = filename
        self.metadata = metadata or {}
        if filename is not None and data is None:
            with open(filename, self._read_flags) as f:
                self.data = f.read()
        elif url is not None and data is None and self._read_flags == "r":
            # Fetched like Jupyter does (through the app's HTTP, D25).
            try:
                import urllib.request

                with urllib.request.urlopen(url) as r:
                    self.data = r.read().decode("utf-8", "replace")
            except Exception:
                self.data = None

    def __repr__(self):
        return f"<IPython.core.display.{type(self).__name__} object>"


class TextDisplayObject(DisplayObject):
    def __init__(self, data=None, url=None, filename=None, metadata=None):
        if isinstance(data, (list, tuple)):
            data = "".join(data)
        super().__init__(data, url, filename, metadata)


class HTML(TextDisplayObject):
    def _repr_html_(self):
        return self.data


class Markdown(TextDisplayObject):
    def _repr_markdown_(self):
        return self.data


class SVG(TextDisplayObject):
    def _repr_svg_(self):
        return self.data


class Latex(TextDisplayObject):
    def _repr_latex_(self):
        return self.data


class Math(TextDisplayObject):
    def _repr_latex_(self):
        s = (self.data or "").strip("$")
        return f"$\\displaystyle {s}$"


class Pretty(TextDisplayObject):
    def __repr__(self):
        return self.data or ""


class Code(TextDisplayObject):
    def __init__(self, data=None, url=None, filename=None, language=None):
        super().__init__(data, url, filename)
        self.language = language

    def __repr__(self):
        return self.data or ""

    def _repr_html_(self):
        import html

        return f"<pre><code>{html.escape(self.data or '')}</code></pre>"


class Javascript(TextDisplayObject):
    def __repr__(self):
        return "<Javascript output: not shown in Terrarium>"


class JSON(DisplayObject):
    def __init__(self, data=None, url=None, filename=None, expanded=False, metadata=None, root="root", **kwargs):
        if isinstance(data, str) and url is None and filename is None:
            data = json.loads(data)
        super().__init__(data, url, filename, metadata)
        if isinstance(self.data, str):
            self.data = json.loads(self.data)

    def _repr_json_(self):
        return self.data


class Image(DisplayObject):
    _read_flags = "rb"

    def __init__(self, data=None, url=None, filename=None, format=None, embed=None, width=None, height=None,
                 retina=False, unconfined=False, metadata=None, alt=None):
        if isinstance(data, str) and url is None and filename is None:
            if data.startswith(("http://", "https://")):
                url, data = data, None
            elif os.path.exists(data):
                filename, data = data, None
        source = (filename or url or "").lower()
        if format is None:
            if source.endswith((".jpg", ".jpeg")):
                format = "jpeg"
            elif source.endswith(".png"):
                format = "png"
            elif source.endswith(".gif"):
                format = "gif"
        if embed is None:
            embed = url is None or filename is not None or data is not None
        self.embed = embed
        self.width, self.height, self.alt = width, height, alt
        super().__init__(data, url, filename, metadata)
        if self.embed and self.data is None and url is not None:
            import urllib.request

            with urllib.request.urlopen(url) as r:
                self.data = r.read()
        if format is None and isinstance(self.data, (bytes, bytearray)):
            format = "jpeg" if self.data[:3] == b"\xff\xd8\xff" else "png"
        self.format = format or "png"

    def _metadata(self):
        md = {}
        if self.width:
            md["width"] = self.width
        if self.height:
            md["height"] = self.height
        return md

    def _repr_html_(self):
        if self.embed:
            return None
        import html

        size = "".join(f' {k}="{v}"' for k, v in self._metadata().items())
        return f'<img src="{html.escape(self.url)}"{size} alt="{html.escape(self.alt or "")}">'

    def _repr_png_(self):
        if self.embed and self.format == "png":
            return self.data, self._metadata()
        return None

    def _repr_jpeg_(self):
        if self.embed and self.format == "jpeg":
            return self.data, self._metadata()
        return None

    def _repr_mimebundle_(self, include=None, exclude=None):
        if self.embed and self.format == "gif":
            return {"image/gif": base64.b64encode(self.data).decode("ascii")}, {"image/gif": self._metadata()}
        return {}


class IFrame:
    def __init__(self, src, width, height, extras=None, **kwargs):
        from urllib.parse import urlencode

        self.src = src + (("?" + urlencode(kwargs)) if kwargs else "")
        self.width, self.height = width, height
        self.extras = " ".join(extras or [])

    def _repr_html_(self):
        return f'<iframe width="{self.width}" height="{self.height}" src="{self.src}" frameborder="0" {self.extras}></iframe>'


class FileLink:
    def __init__(self, path, url_prefix="", result_html_prefix="", result_html_suffix=""):
        self.path = path

    def __repr__(self):
        return os.path.abspath(self.path)


# -- get_ipython() ---------------------------------------------------------------------


class _Events:
    """IPython's shell events; "post_execute" callbacks run after each cell (matplotlib registers one)."""

    def __init__(self):
        self.callbacks = {}

    def register(self, event, function):
        self.callbacks.setdefault(event, []).append(function)

    def unregister(self, event, function):
        try:
            self.callbacks.get(event, []).remove(function)
        except ValueError:
            pass

    def trigger(self, event, *args):
        for function in list(self.callbacks.get(event, [])):
            try:
                function(*args)
            except Exception as e:
                print(f"Error in a {event} callback: {e!r}", file=sys.stderr)


class TerrariumShell:
    """What get_ipython() returns: enough for code that runs magics or looks for a shell."""

    config = {}
    kernel = None

    def __init__(self):
        self.events = _Events()

    def enable_gui(self, gui=None):
        pass  # figures are drawn inline

    @property
    def user_ns(self):
        import __main__

        return __main__.__dict__

    def run_line_magic(self, name, line, _stack_depth=1):
        return line_magic(name, line)

    def run_cell_magic(self, name, line, cell):
        raise UsageError(f"Cell magic `%%{name}` is not supported here.")

    def system(self, cmd):
        return shell(cmd)

    def __repr__(self):
        return "<terrarium notebook shell>"


_shell = TerrariumShell()


def get_ipython():
    return _shell


# -- the IPython module (a shim; the real one does not run here) -------------------

_DISPLAY_NAMES = [
    "display", "update_display", "clear_output", "publish_display_data", "DisplayHandle", "DisplayObject",
    "TextDisplayObject", "HTML", "Markdown", "SVG", "Latex", "Math", "Pretty", "Code", "Javascript", "JSON",
    "Image", "IFrame", "FileLink",
]


class _IPythonShim(importlib.abc.MetaPathFinder, importlib.abc.Loader):
    MODULES = {
        "IPython": True,
        "IPython.display": False,
        "IPython.core": True,
        "IPython.core.display": False,
        "IPython.core.display_functions": False,
        "IPython.core.getipython": False,
        "IPython.core.error": False,
    }

    def find_spec(self, name, path, target=None):
        if name not in self.MODULES:
            return None
        return importlib.util.spec_from_loader(name, self, is_package=self.MODULES[name])

    def create_module(self, spec):
        return None

    def exec_module(self, module):
        g = globals()
        module.__dict__["get_ipython"] = get_ipython
        if module.__name__ in ("IPython", "IPython.display", "IPython.core.display", "IPython.core.display_functions"):
            for name in _DISPLAY_NAMES:
                module.__dict__[name] = g[name]
        if module.__name__ == "IPython":
            module.__dict__["__version__"] = "9.0.0"
            module.__dict__["version_info"] = (9, 0, 0)
        if module.__name__ == "IPython.core.error":
            module.__dict__["UsageError"] = UsageError


sys.meta_path.insert(0, _IPythonShim())


# -- magics ---------------------------------------------------------------------------

_index_url = None
_MAGIC = re.compile(r"^(\s*)(%{1}(?!%)|!)(.*)$")
_HELP = re.compile(r"^(\s*)(?:(\?\??)([A-Za-z_][\w.]*)|([A-Za-z_][\w.]*)(\?\??))\s*$")
_NB = '__import__("_terrarium_notebook")'


def _continued(lines):
    """Which lines continue a logical line: inside a triple-quoted string or
    brackets, or after a backslash (a rough scan; magics only start lines)."""
    out = []
    quote = None
    depth = 0
    backslash = False
    for line in lines:
        out.append(quote is not None or depth > 0 or backslash)
        backslash = False
        i = 0
        while i < len(line):
            if quote:
                if line.startswith(quote, i):
                    quote = None
                    i += 3
                    continue
                i += 2 if line[i] == "\\" else 1
                continue
            c = line[i]
            if c == "#":
                break
            if line.startswith('"""', i) or line.startswith("'''", i):
                quote = line[i:i + 3]
                i += 3
                continue
            if c in "\"'":
                j = i + 1
                while j < len(line) and line[j] != c:
                    j += 2 if line[j] == "\\" else 1
                i = j + 1
                continue
            if c in "([{":
                depth += 1
            elif c in ")]}":
                depth = max(0, depth - 1)
            elif c == "\\" and i == len(line) - 1:
                backslash = True
            i += 1
    return out


def transform_cell(source):
    """Python for a cell: magics become calls, one line each (line numbers stay)."""
    lines = source.split("\n")
    first = next((i for i, line in enumerate(lines) if line.strip()), None)
    if first is not None and lines[first].lstrip().startswith("%%"):
        name = lines[first].strip()[2:].split(" ", 1)[0]
        if name in ("time", "timeit", "capture"):
            lines[first] = ""
        else:
            return ""  # html, markdown, writefile, ...: no Python in it
    continued = _continued(lines)
    out = []
    for i, line in enumerate(lines):
        if continued[i]:
            out.append(line)
            continue
        m = _HELP.match(line)
        if m:
            indent = m.group(1)
            name = m.group(3) or m.group(4)
            marks = m.group(2) or m.group(5)
            out.append(f"{indent}{_NB}.help_magic({name!r}, {len(marks)}, globals())")
            continue
        m = _MAGIC.match(line)
        if not m:
            out.append(line)
            continue
        indent, kind, rest = m.groups()
        if kind == "%":
            name, _, args = rest.partition(" ")
            if name == "pip" and not indent:
                out.append(f"await {_NB}.pip({args!r})")
            else:
                out.append(f"{indent}{_NB}.line_magic({name!r}, {args!r})")
        else:
            words = rest.split()
            if words[:1] in (["pip"], ["pip3"]) and not indent:
                out.append(f"await {_NB}.pip({' '.join(words[1:])!r})")
            else:
                out.append(f"{indent}{_NB}.shell({rest!r})")
    return "\n".join(out)


def _main_ns():
    import __main__

    return __main__.__dict__


def help_magic(name, level, namespace):
    try:
        obj = eval(name, namespace)
    except Exception:
        print(f"Object `{name}` not found.")
        return None
    if level == 2:
        try:
            print(inspect.getsource(obj))
            return None
        except (TypeError, OSError):
            pass
    sig = ""
    try:
        sig = str(inspect.signature(obj))
    except (TypeError, ValueError):
        pass
    print(f"Type:      {type(obj).__name__}")
    if sig:
        print(f"Signature: {name}{sig}")
    doc = inspect.getdoc(obj)
    if doc:
        print(f"Docstring:\n{doc}")
    return None


def _format_time(seconds):
    if seconds >= 1:
        return f"{seconds:.3g} s"
    for unit, scale in (("ms", 1e3), ("µs", 1e6), ("ns", 1e9)):
        if seconds * scale >= 1:
            return f"{seconds * scale:.3g} {unit}"
    return f"{seconds * 1e9:.3g} ns"


def _time(code, namespace):
    t0 = time.perf_counter()
    try:
        value = eval(compile(code, "<magic>", "eval"), namespace)
    except SyntaxError:
        exec(compile(code, "<magic>", "exec"), namespace)
        value = None
    print(f"Wall time: {_format_time(time.perf_counter() - t0)}")
    return value


def _timeit(code, namespace):
    import statistics
    import timeit

    timer = timeit.Timer(code, globals=namespace)
    number, _ = timer.autorange()
    runs = [t / number for t in timer.repeat(repeat=7, number=number)]
    mean, std = statistics.mean(runs), statistics.pstdev(runs)
    loops = "loop" if number == 1 else "loops"
    print(f"{_format_time(mean)} ± {_format_time(std)} per loop (mean ± std. dev. of 7 runs, {number:,} {loops} each)")


def line_magic(name, args):
    ns = _main_ns()
    args = args.strip()
    if name in ("matplotlib", "config", "load_ext", "reload_ext", "autoreload", "aimport", "precision", "xmode"):
        return None  # figures always show inline; the rest has no meaning here
    if name == "time":
        return _time(args, ns)
    if name == "timeit":
        return _timeit(args, ns)
    if name == "pwd":
        return os.getcwd()
    if name == "cd":
        os.chdir(os.path.expanduser(args or "~"))
        print(os.getcwd())
        return None
    if name == "ls":
        for entry in sorted(os.listdir(args or ".")):
            print(entry + ("/" if os.path.isdir(os.path.join(args or ".", entry)) else ""))
        return None
    if name in ("who", "whos"):
        names = sorted(k for k, v in ns.items() if not k.startswith("_") and not inspect.ismodule(v) and k not in ("In", "Out", "exit", "quit", "get_ipython"))
        if name == "who":
            print("\t".join(names) if names else "Interactive namespace is empty.")
        else:
            for k in names:
                print(f"{k:<16}{type(ns[k]).__name__:<12}{_plain(ns[k])[:60]}")
        return None
    if name == "reset":
        keep = {"__name__", "__builtins__", "__doc__", "__loader__", "__spec__", "__package__", "__file__"}
        for k in list(ns):
            if k not in keep:
                del ns[k]
        return None
    if name == "env":
        if not args:
            return dict(os.environ)
        if "=" in args or " " in args:
            key, _, value = args.replace("=", " ", 1).partition(" ")
            os.environ[key.strip()] = value.strip()
            print(f"env: {key.strip()}={value.strip()}")
            return None
        return os.environ.get(args)
    if name == "run":
        import runpy
        import shlex

        parts = shlex.split(args)
        if not parts:
            raise UsageError("%run needs a file name.")
        argv, sys.argv = sys.argv, parts
        try:
            ns.update(runpy.run_path(parts[0], run_name="__main__"))
        finally:
            sys.argv = argv
        return None
    if name == "pip":
        raise UsageError("%pip only works at the top level of a cell.")
    raise UsageError(f"Line magic function `%{name}` not found (not available in Terrarium).")


def shell(command):
    raise UsageError(f"Shell commands are not available on iOS (there is no shell): !{command}")


async def pip(args):
    import shlex

    import pyodide_js

    words = shlex.split(args)
    if not words:
        raise UsageError("Usage: %pip install <packages>")
    command, rest = words[0], [w for w in words[1:] if not w.startswith("-")]
    await pyodide_js.loadPackage("micropip")
    import micropip

    if command == "install":
        if not rest:
            raise UsageError("Usage: %pip install <packages>")
        import _terrarium

        _terrarium._allow_app_scheme()
        kwargs = {"keep_going": True}
        if _index_url:
            kwargs["index_urls"] = [_index_url]
        await micropip.install(rest, **kwargs)
        print("Installed " + ", ".join(rest))
        return None
    if command == "list":
        for name, pkg in sorted(micropip.list().items()):
            print(f"{name:<30}{pkg.version}")
        return None
    if command == "uninstall":
        micropip.uninstall(rest)
        return None
    raise UsageError(f"%pip {command} is not supported (install, list, uninstall are).")


# -- cell magics -------------------------------------------------------------------------


def _cell_magic(name, args, body, ns):
    """Run a cell that starts with %%name; returns the Python to run next, or None."""
    if name in ("html", "HTML"):
        display(HTML(body))
    elif name in ("markdown", "md"):
        display(Markdown(body))
    elif name == "svg":
        display(SVG(body))
    elif name == "latex":
        display(Latex(body))
    elif name == "writefile":
        import shlex

        parts = shlex.split(args)
        append = "-a" in parts or "--append" in parts
        files = [p for p in parts if not p.startswith("-")]
        if not files:
            raise UsageError("%%writefile needs a file name.")
        exists = os.path.exists(files[0])
        with open(files[0], "a" if append else "w") as f:
            f.write(body if body.endswith("\n") else body + "\n")
        print(f"{'Appending to' if append else 'Overwriting' if exists else 'Writing'} {files[0]}")
    elif name in ("bash", "sh", "script", "system", "!"):
        raise UsageError("Shell commands are not available on iOS (there is no shell).")
    elif name in ("javascript", "js"):
        raise UsageError("JavaScript cells are not supported in Terrarium.")
    else:
        raise UsageError(f"Cell magic `%%{name}` not found (not available in Terrarium).")
    return None


# -- running cells ----------------------------------------------------------------------

_installed = False


def _install():
    global _installed
    if _installed:
        return
    _installed = True
    builtins.display = display  # as in Jupyter, without an import
    ns = _main_ns()
    ns.setdefault("get_ipython", get_ipython)


def _show_figures():
    if "matplotlib.pyplot" not in sys.modules:
        return
    try:
        import _terrarium

        if sys.modules["matplotlib.pyplot"].get_fignums():
            _terrarium._show()
    except Exception as e:
        print(f"Could not show the figure: {e}", file=sys.stderr)


def _error(e):
    if isinstance(e, UsageError):
        lines = [f"UsageError: {e}"]
    else:
        import _terrarium_traceback

        # Our own frames (and Pyodide's) go; the cell's stay. As data too (D45).
        trace = _terrarium_traceback.describe(e)
        return {
            "type": "error", "ename": type(e).__name__, "evalue": trace["exceptions"][-1]["message"],
            "traceback": trace["text"].split("\n"), "trace": trace,
        }
    return {"type": "error", "ename": type(e).__name__, "evalue": str(e), "traceback": lines}


def _ends_quietly(code, node):
    """A final expression followed by ';' shows nothing (as in Jupyter)."""
    lines = code.split("\n")
    end = node.end_lineno - 1
    rest = lines[end][node.end_col_offset:] if end < len(lines) else ""
    rest = rest.split("#", 1)[0].strip()
    if rest.startswith(";"):
        return True
    return False


async def run_cell(source, count, index_url=None):
    """Run a cell in __main__; outputs and errors go to the page, nothing is raised."""
    global _index_url
    if index_url:
        _index_url = index_url
    _install()
    ns = _main_ns()
    filename = f"<cell {count}>"
    try:
        timed = False
        code = source
        lines = source.split("\n")
        first = next((i for i, line in enumerate(lines) if line.strip()), None)
        if first is not None and lines[first].lstrip().startswith("%%"):
            name, _, args = lines[first].strip()[2:].partition(" ")
            if name == "time":
                timed = True
            elif name == "timeit":
                body = "\n".join(lines[first + 1:])
                _timeit(body, ns)
                return
            elif name == "capture":
                pass
            else:
                _cell_magic(name, args.strip(), "\n".join(lines[first + 1:]), ns)
                return
        code = transform_cell(code)
        linecache.cache[filename] = (len(source), None, source.splitlines(True), filename)
        tree = ast.parse(code, filename, "exec")
        last = None
        if tree.body and isinstance(tree.body[-1], ast.Expr) and not _ends_quietly(code, tree.body[-1]):
            last = ast.Expression(tree.body.pop().value)
        flags = ast.PyCF_ALLOW_TOP_LEVEL_AWAIT
        t0 = time.perf_counter()
        if tree.body:
            compiled = compile(tree, filename, "exec", flags=flags)
            result = eval(compiled, ns)
            if compiled.co_flags & inspect.CO_COROUTINE:
                await result
        value = None
        if last is not None:
            compiled = compile(last, filename, "eval", flags=flags)
            value = eval(compiled, ns)
            if compiled.co_flags & inspect.CO_COROUTINE:
                value = await value
        if value is not None and value is not _shell:
            ns["_"] = value
            data, md = format_display_data(value)
            _send({"type": "execute_result", "data": data, "metadata": md})
        _shell.events.trigger("post_execute")
        _show_figures()
        if timed:
            print(f"Wall time: {_format_time(time.perf_counter() - t0)}")
    except BaseException as e:  # KeyboardInterrupt and SystemExit too: the kernel lives on
        _show_figures()
        _send(_error(e))
    finally:
        _flush_streams()
