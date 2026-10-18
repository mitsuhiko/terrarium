"""The browser backend for turtle graphics (D29).

``turtle.py`` is CPython's module with its Tkinter interface replaced by this
file (``app/scripts/make-turtle.py`` does the splice). Everything above that
interface, i.e. the whole public API, is the standard library's.

The canvas keeps its items here, like Tk's canvas does: lines, polygons,
images and text with coordinates and options. Every change becomes an op;
``update()`` sends them to the page, which draws them on a <canvas> inline in
the console. Taps and keys come back through a blocking call that is made
while the program updates the screen (at most every 30 ms) and while it waits
in ``mainloop()``/``done()``, which is where Tk handles events too.
"""

import base64
import heapq
import itertools
import json
import math
import os
import re
import sys
import time
import traceback
import types

try:
    import _terrariumhost
except ImportError:  # outside the app, e.g. tests on the host
    _terrariumhost = None

__all__ = ["TK", "Canvas", "ScrolledCanvas", "_Root", "TurtleScreenBase"]

# What setup()'s fractions refer to: the default window (50% x 75%) is 600 x 600.
SCREEN_WIDTH, SCREEN_HEIGHT = 1200, 800
POLL_INTERVAL = 0.03  # seconds between event checks while the program draws
TOUCH_SLOP = 10  # canvas units around a turtle that still count as a tap on it

_HERE = os.path.dirname(os.path.abspath(__file__)) + os.sep
_scene_ids = itertools.count(1)
_image_ids = itertools.count(1)
_canvases = []  # open canvases, flushed when the program ends
_events_ok = True  # False when blocking calls are unavailable (no cross-origin isolation)


class TclError(Exception):
    """Raised for bad canvas arguments (turtle.py catches Tk's TclError)."""


class PhotoImage:
    """An image for shapes and bgpic(): a data URL plus its size."""

    def __init__(self, file=None, *, width=1, height=1, master=None, data=None, url=None):
        self.id = next(_image_ids)
        self.url = url
        self._width, self._height = width, height
        if file is not None:
            with open(file, "rb") as f:
                data = f.read()
        if data is not None:
            self.url = f"data:{_mime(data, file)};base64,{base64.b64encode(data).decode('ascii')}"
            self._width, self._height = _image_size(data) or (width, height)

    def width(self):
        return self._width

    def height(self):
        return self._height

    def blank(self):
        self.url = None


# turtle.py refers to TK.TclError and TK.PhotoImage.
TK = types.SimpleNamespace(TclError=TclError, PhotoImage=PhotoImage, ROUND="round")


def _mime(data, name):
    if data[:4] == b"GIF8":
        return "image/gif"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    ext = os.path.splitext(str(name or ""))[1].lower()
    return {".svg": "image/svg+xml", ".bmp": "image/bmp"}.get(ext, "application/octet-stream")


def _image_size(data):
    if data[:4] == b"GIF8" and len(data) >= 10:
        return int.from_bytes(data[6:8], "little"), int.from_bytes(data[8:10], "little")
    if data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24:
        return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
    return None


# -- host calls -------------------------------------------------------------------------

def _send(message):
    if _terrariumhost is not None:
        _terrariumhost.turtle(json.dumps(message, separators=(",", ":")))


def _host_call(request):
    """A blocking round trip to the page (events, dialogs); None if impossible."""
    global _events_ok
    if _terrariumhost is None or not _events_ok:
        return None
    try:
        reply = _terrariumhost.turtle_call(json.dumps(request, separators=(",", ":")))
    except (KeyboardInterrupt, SystemExit):
        raise
    except Exception:
        _events_ok = False
        return None
    return None if reply is None else json.loads(reply)


_color_cache = {}

# Tk color names that CSS does not have (CSS has most of X11's).
_TK_COLORS = {
    "navyblue": "#000080", "lightgoldenrod": "#eedd82", "violetred": "#d02090",
    "lightslateblue": "#8470ff", "mediumforestgreen": "#6b8e23", "verydarkgray": "#202020",
}


def _resolve_color(color):
    """A Tk color as CSS ("#rrggbb" or "rgba(...)"), or None if it is no color."""
    if color in _color_cache:
        return _color_cache[color]
    name = color.strip()
    css = None
    if name.startswith("#"):
        digits = name[1:]
        if re.fullmatch(r"[0-9a-fA-F]+", digits) and len(digits) in (3, 6, 9, 12):
            n = len(digits) // 3  # 1-4 hex digits per channel; keep the top two
            parts = [digits[i * n:(i + 1) * n] for i in range(3)]
            css = "#" + "".join((p * 2 if n == 1 else p[:2]) for p in parts).lower()
    else:
        key = name.replace(" ", "").lower()
        gray = re.fullmatch(r"gr[ae]y(\d{1,3})", key)
        variant = re.fullmatch(r"([a-z]+?)([1-4])", key)
        if gray and int(gray[1]) <= 100:
            v = round(int(gray[1]) * 2.55)
            css = f"#{v:02x}{v:02x}{v:02x}"
        elif key in _TK_COLORS:
            css = _TK_COLORS[key]
        else:
            css = _browser_color(key)
            if css is None and variant:
                # X11's numbered shades: 1 is the color, 2-4 get darker.
                base = _TK_COLORS.get(variant[1]) or _browser_color(variant[1])
                if base and base.startswith("#"):
                    f = (1.0, 0.932, 0.804, 0.545)[int(variant[2]) - 1]
                    r, g, b = (int(base[i:i + 2], 16) for i in (1, 3, 5))
                    css = "#%02x%02x%02x" % (round(r * f), round(g * f), round(b * f))
    _color_cache[color] = css
    return css


def _browser_color(name):
    if _terrariumhost is None:
        return name if re.fullmatch(r"[a-z]+", name) else None
    try:
        return _terrariumhost.css_color(name)
    except AttributeError:
        return name


def _css(color):
    if not color:
        return ""
    return _resolve_color(color) or color


def _font_css(font):
    """A Tk font tuple ("Arial", 12, "bold") as a CSS font."""
    font = font.split() if isinstance(font, str) else list(font or ())
    family = str(font[0]) if font else "Arial"
    size = font[1] if len(font) > 1 else 8
    styles = font[2:]
    try:
        size = int(size)
    except (TypeError, ValueError):
        size = 8
    unit = "px" if size < 0 else "pt"  # Tk: negative sizes are pixels
    words = " ".join(str(s) for s in styles).lower().split()
    style = "italic " if "italic" in words else ""
    weight = "bold " if "bold" in words else ""
    return f'{style}{weight}{abs(size) or 8}{unit} "{family}", sans-serif'


def _measure(font_css, text):
    if _terrariumhost is not None:
        try:
            width = _terrariumhost.measure_text(font_css, text)
            if width is not None:
                return float(width)
        except AttributeError:
            pass
    m = re.search(r"(\d+)(pt|px)", font_css)
    px = int(m[1]) * (4 / 3 if m[2] == "pt" else 1) if m else 11
    return 0.6 * px * len(text)


def _report(exc):
    """Show a traceback without our frames (a failing event handler), as data (D45)."""
    try:
        import _terrarium_traceback
    except ImportError:  # outside the app
        te = traceback.TracebackException.from_exception(exc)
        te.stack = traceback.StackSummary.from_list([f for f in te.stack if not f.filename.startswith(_HERE)])
        sys.stderr.write("".join(te.format()))
    else:
        _terrarium_traceback.report(exc)


# -- the canvas ---------------------------------------------------------------------------

class Canvas:
    """Tk-style canvas items, drawn by the page inline in the console.

    Coordinates are Tk's: x to the right, y down, (0, 0) in the middle of the
    scroll region. The window (``width`` x ``height``) shows the middle of it.
    """

    def __init__(self, master=None, width=600, height=600, canvwidth=None, canvheight=None, bg="white", **_):
        self.id = next(_scene_ids)
        self.master = master
        self.width, self.height = self._size(width, SCREEN_WIDTH), self._size(height, SCREEN_HEIGHT)
        self.canvwidth = int(canvwidth or self.width)
        self.canvheight = int(canvheight or self.height)
        self.bg = bg
        self.title = getattr(master, "_title", None) or "Python Turtle Graphics"
        self.region = self._centered()
        self.items = {}  # id -> [type, coords, options]; dict order is the stacking order
        self._next_item = itertools.count(1)
        self._ops = []
        self._images_sent = set()
        self._screen_binds = {}  # button -> [fun(x, y)]
        self._item_binds = {}  # (item, "press"|"release"|"drag", button) -> [fun(x, y)]
        self._keys = {}  # ("press"|"release", keysym or None) -> fun()
        self._timers = []  # heap of (due, seq, fun)
        self._timer_seq = itertools.count()
        self._grab = None  # the item a press went to: it gets the drag and the release
        self._listening = (False, False)
        self._dispatching = False
        self._last_poll = 0.0
        self.closed = False
        self._op("open", self._info())
        _canvases.append(self)

    @staticmethod
    def _size(value, screen):
        if isinstance(value, float) and 0 <= value <= 1:
            value = screen * value
        return max(1, int(value))

    def _centered(self):
        return (-self.canvwidth / 2, -self.canvheight / 2, self.canvwidth / 2, self.canvheight / 2)

    def _info(self):
        return {"title": self.title, "w": self.width, "h": self.height,
                "region": [round(v, 2) for v in self.region], "bg": _css(self.bg) or "white"}

    def _screen_changed(self):
        self._op("screen", self._info())

    # ops ------------------------------------------------------------------------------

    def _op(self, *op):
        if not self.closed:
            self._ops.append(op)

    def flush(self):
        if self._ops:
            ops, self._ops = self._ops, []
            _send({"id": self.id, "ops": ops})

    # items (the subset of Tk's canvas API turtle uses) ------------------------------------

    def create(self, type_, coords, **options):
        item = next(self._next_item)
        options = self._options(options)
        self.items[item] = [type_, list(coords), options]
        self._op("new", item, type_, _rounded(coords), self._wire(options))
        return item

    def coords(self, item, *coords):
        entry = self.items.get(item)
        if entry is None:
            return []
        if not coords:
            return list(entry[1])
        if len(coords) == 1 and isinstance(coords[0], (list, tuple)):
            coords = coords[0]
        coords = list(coords)
        if coords != entry[1]:
            entry[1] = coords
            if self._ops and self._ops[-1][0] == "xy" and self._ops[-1][1] == item:
                self._ops.pop()
            self._op("xy", item, _rounded(coords))
        return None

    def itemconfigure(self, item, **options):
        entry = self.items.get(item)
        if entry is None:
            return
        changed = {k: v for k, v in self._options(options).items() if entry[2].get(k) != v}
        if changed:
            entry[2].update(changed)
            self._op("set", item, self._wire(changed))

    itemconfig = itemconfigure

    def _options(self, options):
        out = {}
        for key, value in options.items():
            if key in ("fill", "outline"):
                value = _css(value)
            elif key == "image":
                if not isinstance(value, PhotoImage):
                    value = None  # "": no picture (bgpic "nopic")
                elif value.id not in self._images_sent:
                    self._images_sent.add(value.id)
                    self._op("img", value.id, value.url, value.width(), value.height())
            out[key] = value
        return out

    @staticmethod
    def _wire(options):
        return {k: (v.id if isinstance(v, PhotoImage) else v) for k, v in options.items()}

    def tag_raise(self, item):
        if item in self.items and next(reversed(self.items)) != item:
            self.items[item] = self.items.pop(item)
            self._op("top", item)

    def tag_lower(self, item):
        if item in self.items and next(iter(self.items)) != item:
            entry = self.items.pop(item)
            self.items = {item: entry, **self.items}
            self._op("bottom", item)

    def delete(self, item):
        if item == "all":
            self.items.clear()
            self._grab = None
            self._item_binds.clear()
            self._op("del", "all")
            self._listen_changed()
        elif self.items.pop(item, None) is not None:
            if self._grab == item:
                self._grab = None
            if any(key[0] == item for key in self._item_binds):
                self._item_binds = {k: v for k, v in self._item_binds.items() if k[0] != item}
                self._listen_changed()
            self._op("del", item)

    def type(self, item):
        entry = self.items.get(item)
        return entry[0] if entry else None

    def find_all(self):
        return list(self.items)

    def bbox(self, item):
        entry = self.items.get(item)
        if not entry or not entry[1]:
            return None
        xs, ys = entry[1][0::2], entry[1][1::2]
        return min(xs), min(ys), max(xs), max(ys)

    # screen --------------------------------------------------------------------------

    def config(self, bg=None, **_):
        if bg is not None:
            self.bg = bg
            self._screen_changed()

    configure = config

    def cget(self, option):
        return {"bg": self.bg, "width": self.width, "height": self.height}.get(option)

    def reset(self, canvwidth=None, canvheight=None, bg=None):
        """ScrolledCanvas.reset: a new scroll region, centered."""
        if canvwidth:
            self.canvwidth = int(canvwidth)
        if canvheight:
            self.canvheight = int(canvheight)
        if bg:
            self.bg = bg
        self.region = self._centered()
        self._screen_changed()

    def set_window(self, width, height):
        self.width, self.height = max(1, int(width)), max(1, int(height))
        self._screen_changed()

    def set_region(self, x1, y1, x2, y2):
        self.region = (x1, y1, x2, y2)
        self._screen_changed()

    def set_title(self, title):
        self.title = str(title)
        self._screen_changed()

    def winfo_width(self):
        return self.width

    def winfo_height(self):
        return self.height

    def focus_force(self):
        self._op("focus")

    def winfo_toplevel(self):
        return self

    def call(self, *args):
        """Tcl commands (turtle.py raises the window on macOS): nothing to do."""

    def wm_attributes(self, *args, **kwargs):
        pass

    def close(self):
        """bye(): the drawing stays in the console, but takes no more events."""
        if self.closed:
            return
        self._op("close")
        self.flush()
        self.closed = True
        self._timers.clear()
        if self in _canvases:
            _canvases.remove(self)

    def postscript(self):
        return _postscript(self)

    # events ----------------------------------------------------------------------------

    def bind_screen(self, button, fun, add=None):
        self._bind(self._screen_binds, button, fun, add)

    def bind_item(self, item, kind, button, fun, add=None):
        self._bind(self._item_binds, (item, kind, button), fun, add)

    def bind_key(self, kind, key, fun):
        if key is not None:
            key = _keysym(key)
        if fun is None:
            self._keys.pop((kind, key), None)
        else:
            self._keys[(kind, key)] = fun
        self._listen_changed()

    def _bind(self, table, key, fun, add):
        if fun is None:
            table.pop(key, None)
        elif add:
            table.setdefault(key, []).append(fun)
        else:
            table[key] = [fun]
        self._listen_changed()

    def _listen_changed(self):
        listening = (bool(self._screen_binds or self._item_binds), bool(self._keys))
        if listening != self._listening:
            self._listening = listening
            self._op("listen", {"pointer": listening[0], "keys": listening[1]})

    def _has_handlers(self):
        """Something that events or timers can still trigger (exitonclick's
        handler alone does not count: done() returns, the drawing stays)."""
        if self._timers or self._keys or self._item_binds:
            return True
        return any(not getattr(f, "_exit", False) for funs in self._screen_binds.values() for f in funs)

    def after(self, ms, fun):
        heapq.heappush(self._timers, (time.monotonic() + max(0, ms) / 1000, next(self._timer_seq), fun))

    def update(self):
        """Send what changed; handle waiting events and due timers now and then."""
        self.flush()
        if self._dispatching or self.closed:
            return
        now = time.monotonic()
        if now - self._last_poll >= POLL_INTERVAL:
            self._last_poll = now
            self.process()

    def process(self, wait=0.0):
        """Handle events (waiting up to ``wait`` seconds for one) and timers."""
        if self._dispatching or self.closed:
            return
        self.flush()
        if any(self._listening) and _events_ok:
            reply = _host_call({"id": self.id, "wait": round(wait * 1000)})
            if reply is None and wait > 0 and not _events_ok:
                time.sleep(wait)
            elif reply:
                self._dispatch(reply)
        elif wait > 0:
            time.sleep(wait)
        self._run_timers()
        self.flush()

    def mainloop(self):
        """Handle events and timers until bye() or Stop. Returns right away
        when nothing could happen any more (no handlers, no timers)."""
        self.flush()
        while not self.closed and self._has_handlers():
            wait = 0.1  # short waits keep Pause and breakpoint updates responsive
            if self._timers:
                wait = min(wait, max(0.0, self._timers[0][0] - time.monotonic()))
            self.process(wait)
        self.flush()

    def ask(self, title, prompt, default=None):
        self.flush()
        reply = _host_call({"id": self.id, "prompt": {"title": str(title or ""), "text": str(prompt or ""),
                                                     "default": "" if default is None else str(default)}})
        return reply if isinstance(reply, str) else None

    def _run_timers(self):
        now = time.monotonic()
        due = []
        while self._timers and self._timers[0][0] <= now:
            due.append(heapq.heappop(self._timers)[2])
        if due:
            self._run(lambda: [self._call(fun) for fun in due])

    def _dispatch(self, events):
        self._run(lambda: [self._event(e) for e in events])

    def _run(self, fn):
        self._dispatching = True
        try:
            fn()
        finally:
            self._dispatching = False

    def _event(self, e):
        if self.closed:
            return
        kind = e.get("t")
        if kind in ("key", "keyup"):
            which = "press" if kind == "key" else "release"
            fun = self._keys.get((which, e.get("k")))
            if fun is None and which == "press":
                fun = self._keys.get(("press", None))  # onkeypress(fun) without a key
            if fun is not None:
                self._call(fun)
            return
        x, y, button = e.get("x", 0), e.get("y", 0), e.get("b", 1)
        if kind == "down":
            self._grab = self._hit(x, y)
            if self._grab is not None:
                for fun in list(self._item_binds.get((self._grab, "press", button), ())):
                    self._call(fun, x, y)
            for fun in list(self._screen_binds.get(button, ())):
                self._call(fun, x, y)
        elif kind == "move" and self._grab is not None:
            for fun in list(self._item_binds.get((self._grab, "drag", button), ())):
                self._call(fun, x, y)
        elif kind == "up":
            grab, self._grab = self._grab, None
            if grab is not None:
                for fun in list(self._item_binds.get((grab, "release", button), ())):
                    self._call(fun, x, y)

    def _call(self, fun, *args):
        try:
            fun(*args)
        except (KeyboardInterrupt, SystemExit):
            raise
        except Exception as e:
            if type(e).__name__ == "Terminator":  # bye() in a handler
                return
            _report(e)

    def _hit(self, x, y):
        """The topmost item with a binding at (x, y), with some room for fingers."""
        bound = {key[0] for key in self._item_binds}
        for item in reversed(list(self.items)):
            if item in bound and _contains(self.items[item], x, y):
                return item
        return None


ScrolledCanvas = Canvas


# Keys as the page reports them (Tk keysyms); onkey(f, "+") and onkey(f, "up") work too.
_KEYSYMS = {
    " ": "space", "+": "plus", "-": "minus", "=": "equal", ",": "comma", ".": "period", "/": "slash",
    ";": "semicolon", ":": "colon", "'": "apostrophe", '"': "quotedbl", "[": "bracketleft",
    "]": "bracketright", "{": "braceleft", "}": "braceright", "\\": "backslash", "|": "bar", "`": "grave",
    "~": "asciitilde", "*": "asterisk", "!": "exclam", "?": "question", "#": "numbersign", "$": "dollar",
    "%": "percent", "&": "ampersand", "(": "parenleft", ")": "parenright", "_": "underscore", "<": "less",
    ">": "greater", "@": "at", "^": "asciicircum",
    "up": "Up", "down": "Down", "left": "Left", "right": "Right", "return": "Return", "enter": "Return",
    "escape": "Escape", "esc": "Escape", "backspace": "BackSpace", "tab": "Tab", "delete": "Delete",
}


def _keysym(key):
    key = str(key)
    if len(key) > 2 and key.startswith("<") and key.endswith(">"):
        key = key[1:-1]
    if len(key) == 1 and key.isalnum():
        return key
    return _KEYSYMS.get(key) or _KEYSYMS.get(key.lower()) or key


def _rounded(coords):
    return [round(v, 2) for v in coords]


def _contains(entry, x, y):
    type_, coords, options = entry
    points = list(zip(coords[0::2], coords[1::2]))
    if not points:
        return False
    if type_ == "image":
        image = options.get("image")
        w, h = (image.width(), image.height()) if image is not None else (20, 20)
        cx, cy = points[0]
        return abs(x - cx) <= w / 2 + TOUCH_SLOP and abs(y - cy) <= h / 2 + TOUCH_SLOP
    if type_ == "polygon" and _inside(points, x, y):
        return True
    reach = TOUCH_SLOP + (options.get("width") or 1) / 2
    segments = zip(points, points[1:] + (points[:1] if type_ == "polygon" else []))
    return any(_distance(x, y, a, b) <= reach for a, b in segments) or len(points) == 1 and math.dist((x, y), points[0]) <= reach


def _inside(points, x, y):
    inside = False
    for (x1, y1), (x2, y2) in zip(points, points[1:] + points[:1]):
        if (y1 > y) != (y2 > y) and x < x1 + (y - y1) * (x2 - x1) / (y2 - y1):
            inside = not inside
    return inside


def _distance(px, py, a, b):
    (ax, ay), (bx, by) = a, b
    dx, dy = bx - ax, by - ay
    length = dx * dx + dy * dy
    t = 0.0 if length == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def _postscript(cv):
    """The drawing as Encapsulated PostScript (Screen.save)."""
    x0 = (cv.region[0] + cv.region[2]) / 2 - cv.width / 2
    y1 = (cv.region[1] + cv.region[3]) / 2 + cv.height / 2

    def rgb(css):
        m = re.fullmatch(r"#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})", css or "")
        return " ".join(f"{int(c, 16) / 255:.3f}" for c in m.groups()) + " setrgbcolor" if m else "0 setgray"

    def path(coords, close):
        pts = [f"{x - x0:.2f} {y1 - y:.2f}" for x, y in zip(coords[0::2], coords[1::2])]
        return f"newpath {pts[0]} moveto " + " ".join(p + " lineto" for p in pts[1:]) + (" closepath" if close else "")

    out = ["%!PS-Adobe-3.0 EPSF-3.0", f"%%BoundingBox: 0 0 {cv.width} {cv.height}", "1 setlinecap 1 setlinejoin",
           f"{rgb(_css(cv.bg))} 0 0 {cv.width} {cv.height} rectfill"]
    for type_, coords, o in cv.items.values():
        if len(coords) < 2:
            continue
        if type_ == "line" and o.get("fill"):
            out.append(f"{rgb(o['fill'])} {o.get('width') or 1} setlinewidth {path(coords, False)} stroke")
        elif type_ == "polygon":
            if o.get("fill"):
                out.append(f"{rgb(o['fill'])} {path(coords, True)} eofill")
            if o.get("outline"):
                out.append(f"{rgb(o['outline'])} {o.get('width') or 1} setlinewidth {path(coords, True)} stroke")
        elif type_ == "text" and o.get("text"):
            text = str(o["text"]).replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
            out.append(f"{rgb(o.get('fill'))} /Helvetica findfont 12 scalefont setfont "
                       f"{coords[0] - x0:.2f} {y1 - coords[1]:.2f} moveto ({text}) show")
    out.append("showpage")
    return "\n".join(out) + "\n"


# -- turtle.py's Tk interface -------------------------------------------------------------

class _Root:
    """The window: here the place in the console where the canvas is shown."""

    def __init__(self):
        self._title = "Python Turtle Graphics"
        self._canvas = None

    def setupcanvas(self, width, height, cwidth, cheight):
        self._canvas = Canvas(self, width, height, cwidth, cheight)

    def _getcanvas(self):
        return self._canvas

    def set_geometry(self, width, height, startx, starty):
        self._canvas.set_window(width, height)

    def ondestroy(self, destroy):
        pass

    def win_width(self):
        return SCREEN_WIDTH

    def win_height(self):
        return SCREEN_HEIGHT

    def title(self, title):
        self._title = str(title)
        if self._canvas is not None:
            self._canvas.set_title(title)

    def destroy(self):
        if self._canvas is not None:
            self._canvas.close()


class TurtleScreenBase:
    """The graphics primitives turtle.py builds on (Tkinter in CPython)."""

    def _blankimage(self):
        image = PhotoImage(width=1, height=1)
        image.blank()
        return image

    def _image(self, filename):
        return PhotoImage(file=filename)

    def __init__(self, cv):
        self.cv = cv
        self.canvwidth = cv.canvwidth
        self.canvheight = cv.canvheight
        self.xscale = self.yscale = 1.0

    def _flat(self, coordlist):
        out = []
        for x, y in coordlist:
            out.append(x * self.xscale)
            out.append(-y * self.yscale)
        return out

    def _createpoly(self):
        return self.cv.create("polygon", (0, 0, 0, 0, 0, 0), fill="", outline="")

    def _drawpoly(self, polyitem, coordlist, fill=None, outline=None, width=None, top=False):
        self.cv.coords(polyitem, self._flat(coordlist))
        options = {k: v for k, v in (("fill", fill), ("outline", outline), ("width", width)) if v is not None}
        if options:
            self.cv.itemconfigure(polyitem, **options)
        if top:
            self.cv.tag_raise(polyitem)

    def _createline(self):
        return self.cv.create("line", (0, 0, 0, 0), fill="", width=2)

    def _drawline(self, lineitem, coordlist=None, fill=None, width=None, top=False):
        if coordlist is not None:
            self.cv.coords(lineitem, self._flat(coordlist))
        options = {k: v for k, v in (("fill", fill), ("width", width)) if v is not None}
        if options:
            self.cv.itemconfigure(lineitem, **options)
        if top:
            self.cv.tag_raise(lineitem)

    def _delete(self, item):
        self.cv.delete(item)

    def _update(self):
        self.cv.update()

    def _delay(self, delay):
        self.cv.flush()
        if delay and delay > 0:
            time.sleep(delay / 1000)

    def _iscolorstring(self, color):
        return isinstance(color, str) and _resolve_color(color) is not None

    def _bgcolor(self, color=None):
        if color is not None:
            self.cv.config(bg=color)
            self._update()
        else:
            return self.cv.bg

    def _write(self, pos, txt, align, font, pencolor):
        x, y = pos
        x, y = x * self.xscale, y * self.yscale
        anchor = {"left": "sw", "center": "s", "right": "se"}[align]
        css = _font_css(font)
        item = self.cv.create("text", (x - 1, -y), text=str(txt), anchor=anchor, fill=pencolor, font=css,
                              underline="underline" in str(font).lower())
        width = max((_measure(css, line) for line in str(txt).split("\n")), default=0)
        left = {"sw": x - 1, "s": x - 1 - width / 2, "se": x - 1 - width}[anchor]
        return item, left + width - 1

    def _onclick(self, item, fun, num=1, add=None):
        self.cv.bind_item(item, "press", num, self._handler(fun), add)

    def _onrelease(self, item, fun, num=1, add=None):
        self.cv.bind_item(item, "release", num, self._handler(fun), add)

    def _ondrag(self, item, fun, num=1, add=None):
        self.cv.bind_item(item, "drag", num, self._handler(fun), add)

    def _onscreenclick(self, fun, num=1, add=None):
        self.cv.bind_screen(num, self._handler(fun), add)

    def _handler(self, fun):
        if fun is None:
            return None

        def eventfun(x, y):
            fun(x / self.xscale, -y / self.yscale)

        eventfun._exit = getattr(fun, "__name__", "") == "exitGracefully"  # exitonclick()
        return eventfun

    def _onkeyrelease(self, fun, key):
        self.cv.bind_key("release", key, fun)

    def _onkeypress(self, fun, key=None):
        self.cv.bind_key("press", key, fun)

    def _listen(self):
        self.cv.focus_force()

    def _ontimer(self, fun, t):
        self.cv.after(t, fun)

    def _createimage(self, image):
        return self.cv.create("image", (0, 0), image=image)

    def _drawimage(self, item, pos, image):
        x, y = pos
        self.cv.coords(item, (x * self.xscale, -y * self.yscale))
        self.cv.itemconfig(item, image=image)

    def _setbgpic(self, item, image):
        self.cv.itemconfig(item, image=image)
        self.cv.tag_lower(item)

    def _type(self, item):
        return self.cv.type(item)

    def _pointlist(self, item):
        cl = self.cv.coords(item)
        return [(cl[i], -cl[i + 1]) for i in range(0, len(cl) - 1, 2)]

    def _setscrollregion(self, srx1, sry1, srx2, sry2):
        self.cv.set_region(srx1, sry1, srx2, sry2)

    def _rescale(self, xscalefactor, yscalefactor):
        for item in self.cv.find_all():
            coords = self.cv.coords(item)
            self.cv.coords(item, [v * (xscalefactor if i % 2 == 0 else yscalefactor) for i, v in enumerate(coords)])

    def _resize(self, canvwidth=None, canvheight=None, bg=None):
        if canvwidth is canvheight is bg is None:
            return self.cv.canvwidth, self.cv.canvheight
        if canvwidth is not None:
            self.canvwidth = canvwidth
        if canvheight is not None:
            self.canvheight = canvheight
        self.cv.reset(canvwidth, canvheight, bg)

    def _window_size(self):
        return self.cv.width, self.cv.height

    def mainloop(self):
        """Handle taps, keys and timers until bye() (or Stop).

        Unlike Tk's, it returns right away when there is nothing to wait for
        (no handlers, no timers): the drawing stays in the console either way.
        """
        self.cv.mainloop()

    def textinput(self, title, prompt):
        """Ask for a string in a dialog. Returns None if it was cancelled."""
        return self.cv.ask(title, prompt)

    def numinput(self, title, prompt, default=None, minval=None, maxval=None):
        """Ask for a number in a dialog, within minval..maxval if given.
        Returns None if it was cancelled."""
        hint = ""
        while True:
            answer = self.cv.ask(title, prompt + hint, default)
            if answer is None:
                return None
            try:
                value = float(answer)
            except ValueError:
                hint = "\n\nThat is not a number."
                continue
            if minval is not None and value < minval:
                hint = f"\n\nThe allowed minimum value is {minval}."
            elif maxval is not None and value > maxval:
                hint = f"\n\nThe allowed maximum value is {maxval}."
            else:
                return value
            default = answer


# -- program lifecycle (called by the worker) ------------------------------------------------

def flush_all():
    for cv in list(_canvases):
        cv.flush()


def finish():
    """The script returned. Like IDLE, keep a turtle program with handlers or
    timers running (as if it called done()), so it still reacts to taps."""
    for cv in list(_canvases):
        if not cv.closed and cv._has_handlers():
            cv.mainloop()
    flush_all()
