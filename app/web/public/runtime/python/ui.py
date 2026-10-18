"""Build apps with fine-grained reactive UI, in the style of SolidJS.

Components are plain functions that run **once** and return elements. State
lives in signals; any callable you pass as a prop or child (a ``lambda`` or a
signal itself) becomes a live binding that updates just that spot when the
signals it reads change. Nothing is re-rendered or diffed.

    import ui

    def Counter():
        count = ui.signal(0)
        return ui.Screen(
            "Counter",
            ui.Text(lambda: f"{count()} taps", font="largeTitle"),
            ui.Button("Tap me", on_click=lambda: count.update(lambda n: n + 1)),
        )

    ui.run(Counter)

Reactivity: signal, computed, effect, batch, untrack, on_cleanup, on_mount,
store, bind, resource, interval, timeout.
Control flow: Show, For.
Elements: layout (VStack, HStack, ZStack, Grid, ScrollView, Spacer, Divider,
Card), navigation (NavigationStack, Screen, TabView, Tab, Sheet), lists
(Section, Row), content (Text, Label, Icon, Image, ProgressView, Link, Canvas)
and inputs (Button, TextField, TextArea, Toggle, Slider, Stepper, Picker,
DatePicker, ColorPicker). Inside the Terrarium app they are native SwiftUI
views; in a published web app the same tree is drawn with HTML.
Dialogs: alert, confirm, prompt, choose, toast (async, use ``await``).
"""

from __future__ import annotations

import asyncio
import base64
import datetime as _dt
import inspect
import io
import json
import mimetypes
import os
import sys
import traceback
from collections.abc import Callable, Iterable, Iterator, MutableMapping, MutableSequence
from typing import Any, Generic, TypeIs, TypeVar, Union, overload

__all__ = [
    # reactivity
    "Signal", "Computed", "signal", "computed", "effect", "batch", "untrack",
    "on_cleanup", "on_mount", "store", "unwrap", "bind", "resource", "Resource",
    "interval", "timeout",
    # control flow
    "Show", "For",
    # app
    "run", "close", "navigation", "alert", "confirm", "prompt", "choose", "toast",
    "Element", "Event",
    # layout
    "VStack", "HStack", "ZStack", "Grid", "ScrollView", "Spacer", "Divider", "Card",
    # navigation
    "NavigationStack", "Screen", "TabView", "Tab", "Sheet",
    # lists
    "Section", "Row",
    # content
    "Text", "Label", "Icon", "Image", "ProgressView", "Link", "Canvas",
    # inputs
    "Button", "TextField", "TextArea", "Toggle", "Slider", "Stepper", "Picker",
    "DatePicker", "ColorPicker",
]

T = TypeVar("T")
#: A value, or a function/signal returning the value (which makes it live).
Reactive = Union[T, Callable[[], T]]
Handler = Callable[..., Any]
Child = Any


# =============================================================================
# Reactive core
#
# Signals are sources, computations (computed values and effects) observe them.
# Setting a signal marks direct observers DIRTY and everything downstream
# CHECK; effects are queued and then pulled: a CHECK node first brings its
# computed sources up to date and only re-runs if one of them actually changed
# (no glitches, no wasted runs). Computations are also owners: anything created
# while one runs (bindings, nested effects, cleanups) is disposed before it
# runs again or when its owner goes away.
# =============================================================================

_CLEAN, _CHECK, _DIRTY, _DISPOSED = 0, 1, 2, 3
_UNSET: Any = object()


class _Runtime:
    __slots__ = ("listener", "owner", "batch", "queue", "running", "building", "quiet")

    def __init__(self):
        self.listener: Computation | None = None  # tracks reads
        self.owner: Owner | None = None  # adopts new computations and cleanups
        self.batch = 0
        self.queue: list[Computation] = []
        self.running = False
        self.building = 0  # > 0 while component code runs (for the untracked-read hint)
        self.quiet = 0  # > 0 inside untrack()


_rt = _Runtime()


def _same(a, b) -> bool:
    """Whether setting b over a is a no-op. Only immutable values compare equal:
    mutable objects always notify, so ``items.set(items())`` after an in-place
    change still updates the UI."""
    if a is b:
        return type(a) in _IMMUTABLE or a is None
    if type(a) is type(b) and type(a) in _IMMUTABLE:
        try:
            return bool(a == b)
        except Exception:
            return False
    return False


_IMMUTABLE = {int, float, str, bool, bytes, complex, tuple, frozenset, type(None),
              _dt.date, _dt.datetime, _dt.time}


class Owner:
    """Owns computations and cleanup callbacks and disposes them together."""

    __slots__ = ("parent", "owned", "cleanups", "context", "state")

    def __init__(self, parent: Owner | None = _UNSET):
        self.parent = _rt.owner if parent is _UNSET else parent
        self.owned: dict[Owner, None] | None = None
        self.cleanups: list[Callable[[], Any]] | None = None
        self.context: dict | None = None
        self.state = _CLEAN
        if self.parent is not None:
            if self.parent.owned is None:
                self.parent.owned = {}
            self.parent.owned[self] = None

    def _clean(self):
        owned, self.owned = self.owned, None
        if owned:
            for child in reversed(list(owned)):
                child.dispose()
        cleanups, self.cleanups = self.cleanups, None
        if cleanups:
            for fn in reversed(cleanups):
                try:
                    _untracked(fn)
                except Exception as e:
                    _report(e)

    def dispose(self):
        if self.state == _DISPOSED:
            return
        self._clean()
        self.state = _DISPOSED
        if self.parent is not None and self.parent.owned:
            self.parent.owned.pop(self, None)

    def lookup(self, key):
        o = self
        while o is not None:
            if o.context and key in o.context:
                return o.context[key]
            o = o.parent
        return None


class _Dep:
    """A bare dependency: something computations can subscribe to."""

    __slots__ = ("observers",)

    def __init__(self):
        self.observers: dict[Computation, None] | None = None


def _track(src):
    listener = _rt.listener
    if listener is not None and listener.state != _DISPOSED and src not in listener.sources:
        listener.sources[src] = None
        if src.observers is None:
            src.observers = {}
        src.observers[listener] = None


def _notify(src):
    if not src.observers:
        return
    for o in list(src.observers):
        o._mark(_DIRTY)
    if _rt.batch == 0:
        _run_effects()


def _run_effects():
    if _rt.running:
        return
    _rt.running = True
    try:
        rounds = 0
        while _rt.queue:
            queue, _rt.queue = _rt.queue, []
            for c in queue:
                if c.state != _DISPOSED:
                    c._update()
            rounds += 1
            if rounds > 10_000:
                _rt.queue = []
                raise RuntimeError("ui: effects keep triggering each other (an effect sets a signal it reads?)")
    finally:
        _rt.running = False


_warned: set = set()


def _hint_untracked_read():
    """A signal was read while components were being built, outside any binding.
    That spot will never update, which is almost always a mistake."""
    f = sys._getframe(1)
    while f is not None and f.f_code.co_filename == __file__:
        f = f.f_back
    where = (f.f_code.co_filename, f.f_lineno) if f is not None else None
    if where in _warned:
        return
    _warned.add(where)
    loc = f"{os.path.basename(where[0])}, line {where[1]}" if where else "your code"
    sys.stderr.write(
        f"ui hint ({loc}): a signal was read while the UI was being built, so this spot "
        "will not update when it changes. Wrap the expression in a lambda to make it "
        "live (ui.Text(lambda: f\"{count()}\")), or use .peek() to read it once on purpose.\n"
    )


class Signal(Generic[T]):
    """A value that updates everything that reads it when it changes.

    Read with ``count()`` (or ``count.value``), write with ``count.set(5)``,
    ``count.value = 5`` or ``count.update(lambda n: n + 1)``.
    """

    __slots__ = ("_value", "observers")

    def __init__(self, value: T):
        self._value = value
        self.observers: dict[Computation, None] | None = None

    def __call__(self) -> T:
        if _rt.listener is not None:
            _track(self)
        elif _rt.building and not _rt.quiet:
            _hint_untracked_read()
        return self._value

    def peek(self) -> T:
        """Read without subscribing to changes."""
        return self._value

    def set(self, value: T) -> None:
        if _same(self._value, value):
            return
        self._value = value
        _notify(self)

    def update(self, fn: Callable[[T], T]) -> None:
        """Set the value to ``fn(current_value)``."""
        self.set(fn(self._value))

    @property
    def value(self) -> T:
        return self()

    @value.setter
    def value(self, value: T) -> None:
        self.set(value)

    def __str__(self):
        return str(self())

    def __format__(self, spec):
        return format(self(), spec)

    def __bool__(self):
        raise TypeError("a signal is always truthy; call it to get its value: if flag(): ...")

    def __repr__(self):
        return f"Signal({self._value!r})"


class Computation(Owner):
    """An effect or a computed value. Re-runs when the signals it read change."""

    __slots__ = ("fn", "sources", "observers", "_value", "is_effect")

    def __init__(self, fn: Callable[[], Any], is_effect: bool):
        super().__init__()
        self.fn = fn
        self.sources: dict = {}
        self.observers: dict[Computation, None] | None = None
        self._value: Any = None
        self.is_effect = is_effect
        self.state = _DIRTY

    def _mark(self, state):
        if self.state < state:
            if self.state == _CLEAN and self.is_effect:
                _rt.queue.append(self)
            self.state = state
            if self.observers:
                for o in list(self.observers):
                    o._mark(_CHECK)

    def _update(self):
        if self.state == _CHECK:
            for src in list(self.sources):
                if isinstance(src, Computation):
                    src._update()
                    if self.state == _DIRTY:
                        break
        if self.state == _DIRTY:
            self._run()
        if self.state != _DISPOSED:
            self.state = _CLEAN

    def _run(self):
        self._clean()
        for src in self.sources:
            if src.observers:
                src.observers.pop(self, None)
        self.sources = {}
        prev_listener, prev_owner = _rt.listener, _rt.owner
        _rt.listener = _rt.owner = self
        try:
            new = self.fn()
        except Exception as e:
            _report(e)
            return
        finally:
            _rt.listener, _rt.owner = prev_listener, prev_owner
        if not self.is_effect and not _same(self._value, new):
            self._value = new
            if self.observers:
                for o in list(self.observers):
                    o._mark(_DIRTY)

    def dispose(self):
        if self.state == _DISPOSED:
            return
        for src in self.sources:
            if src.observers:
                src.observers.pop(self, None)
        self.sources = {}
        super().dispose()


class Computed(Computation, Generic[T]):
    """A derived value, recomputed lazily when its inputs change. Read with ``c()``."""

    __slots__ = ()

    def __init__(self, fn: Callable[[], T]):
        super().__init__(fn, False)

    def __call__(self) -> T:
        if _rt.listener is not None:
            _track(self)
        elif _rt.building and not _rt.quiet:
            _hint_untracked_read()
        if self.state != _CLEAN and self.state != _DISPOSED:
            self._update()
        return self._value

    def peek(self) -> T:
        return untrack(self)

    @property
    def value(self) -> T:
        return self()

    def __str__(self):
        return str(self())

    def __format__(self, spec):
        return format(self(), spec)

    def __bool__(self):
        raise TypeError("a computed value is always truthy; call it to get its value: if done(): ...")

    def __repr__(self):
        return f"Computed({self._value!r})"


@overload
def signal() -> Signal[Any]: ...
@overload
def signal(value: T) -> Signal[T]: ...
def signal(value=None):
    """Create a signal holding ``value``: ``count = ui.signal(0)``."""
    return Signal(value)


def computed(fn: Callable[[], T]) -> Computed[T]:
    """A value derived from signals: ``total = ui.computed(lambda: a() + b())``.
    Also works as a decorator."""
    return Computed(fn)


def effect(fn: Callable[[], Any]) -> Computation:
    """Run ``fn`` now and again whenever a signal it read changes. Also works as
    a decorator. Inside a component it stops when the component goes away;
    ``.dispose()`` stops it early."""
    c = Computation(fn, True)
    with _Batch():  # writes made by fn are applied after it ran
        c._update()
    return c


class _Batch:
    def __enter__(self):
        _rt.batch += 1

    def __exit__(self, *exc):
        _rt.batch -= 1
        if _rt.batch == 0:
            _run_effects()


def batch(fn: Callable[[], T] | None = None):
    """Apply several changes, then update once. Use as ``with ui.batch(): ...``
    or ``ui.batch(fn)``. Event handlers are batched automatically."""
    if fn is None:
        return _Batch()
    with _Batch():
        return fn()


def untrack(fn: Callable[[], T]) -> T:
    """Call ``fn`` without subscribing to the signals it reads."""
    prev = _rt.listener
    _rt.listener = None
    _rt.quiet += 1
    try:
        return fn()
    finally:
        _rt.listener = prev
        _rt.quiet -= 1


def _untracked(fn, *args):
    prev = _rt.listener
    _rt.listener = None
    try:
        return fn(*args)
    finally:
        _rt.listener = prev


def on_cleanup(fn: Callable[[], Any]) -> Callable[[], Any]:
    """Run ``fn`` when the current component (or effect run) goes away."""
    owner = _rt.owner
    if owner is not None:
        if owner.cleanups is None:
            owner.cleanups = []
        owner.cleanups.append(fn)
    return fn


def on_mount(fn: Callable[[], Any]) -> Callable[[], Any]:
    """Run ``fn`` once the current component is on screen."""
    _app.mount_callbacks.append((fn, _rt.owner))
    _app.schedule()
    return fn


def _build(fn, args=(), owner: Owner | None = None):
    """Run component code: untracked, under ``owner``, with the read hint on."""
    prev = (_rt.listener, _rt.owner)
    _rt.listener = None
    _rt.building += 1
    if owner is not None:
        _rt.owner = owner
    try:
        return fn(*args)
    finally:
        _rt.listener, _rt.owner = prev
        _rt.building -= 1


# -- stores --------------------------------------------------------------------

def _wrap(value):
    if type(value) is dict:
        return ReactiveDict(value)
    if type(value) is list:
        return ReactiveList(value)
    return value


def unwrap(value):
    """Turn store data back into plain dicts and lists (e.g. for json.dumps).
    Inside an effect it reads everything, so the effect re-runs on any change:
    ``ui.effect(lambda: save(ui.unwrap(data)))``."""
    if isinstance(value, ReactiveDict):
        return {k: unwrap(value[k]) for k in value}
    if isinstance(value, ReactiveList):
        return [unwrap(v) for v in value]
    if isinstance(value, dict):
        return {k: unwrap(v) for k, v in value.items()}
    if isinstance(value, list):
        return [unwrap(v) for v in value]
    return value


class ReactiveDict(MutableMapping):
    """A dict whose keys are individually reactive. Keys also work as
    attributes (``todo.done``) when they don't clash with dict methods."""

    __slots__ = ("_data", "_deps", "_keys")

    def __init__(self, data=(), **kwargs):
        object.__setattr__(self, "_data", {k: _wrap(v) for k, v in dict(data, **kwargs).items()})
        object.__setattr__(self, "_deps", {})
        object.__setattr__(self, "_keys", _Dep())

    def _dep(self, key):
        dep = self._deps.get(key)
        if dep is None:
            dep = self._deps[key] = _Dep()
        return dep

    def __getitem__(self, key):
        if _rt.listener is not None:
            _track(self._dep(key))
        return self._data[key]

    def __setitem__(self, key, value):
        value = _wrap(value)
        old = self._data.get(key, _UNSET)
        self._data[key] = value
        with _Batch():
            if old is _UNSET:
                _notify(self._keys)
            if not _same(old, value):
                dep = self._deps.get(key)
                if dep is not None:
                    _notify(dep)

    def __delitem__(self, key):
        del self._data[key]
        with _Batch():
            _notify(self._keys)
            dep = self._deps.get(key)
            if dep is not None:
                _notify(dep)

    def __iter__(self):
        if _rt.listener is not None:
            _track(self._keys)
        return iter(list(self._data))

    def __len__(self):
        if _rt.listener is not None:
            _track(self._keys)
        return len(self._data)

    def __contains__(self, key):
        if _rt.listener is not None:
            _track(self._dep(key))
        return key in self._data

    def update(self, other=(), /, **kwargs):
        with _Batch():
            for k, v in dict(other, **kwargs).items():
                self[k] = v

    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)
        try:
            return self[name]
        except KeyError:
            raise AttributeError(f"store has no key {name!r}") from None

    def __setattr__(self, name, value):
        if name.startswith("_"):
            object.__setattr__(self, name, value)
        else:
            self[name] = value

    def __delattr__(self, name):
        try:
            del self[name]
        except KeyError:
            raise AttributeError(name) from None

    def __eq__(self, other):
        return unwrap(self) == unwrap(other)

    __hash__ = None  # type: ignore[assignment]

    def __repr__(self):
        return f"store({unwrap(self)!r})"


class ReactiveList(MutableSequence):
    """A list that updates readers when items are added, removed or moved.
    Items that are dicts or lists become stores themselves."""

    __slots__ = ("_items", "_dep")

    def __init__(self, items: Iterable = ()):
        self._items = [_wrap(v) for v in items]
        self._dep = _Dep()

    def _read(self):
        if _rt.listener is not None:
            _track(self._dep)
        return self._items

    def _changed(self):
        _notify(self._dep)

    def __getitem__(self, index):
        return self._read()[index]

    def __setitem__(self, index, value):
        if isinstance(index, slice):
            self._items[index] = [_wrap(v) for v in value]
        else:
            self._items[index] = _wrap(value)
        self._changed()

    def __delitem__(self, index):
        del self._items[index]
        self._changed()

    def __len__(self):
        return len(self._read())

    def __iter__(self) -> Iterator:
        return iter(list(self._read()))

    def __contains__(self, value):
        return value in self._read()

    def __reversed__(self):
        return iter(list(reversed(self._read())))

    def insert(self, index, value):
        self._items.insert(index, _wrap(value))
        self._changed()

    def append(self, value):
        self._items.append(_wrap(value))
        self._changed()

    def extend(self, values):
        self._items.extend(_wrap(v) for v in values)
        self._changed()

    def __iadd__(self, values):
        self.extend(values)
        return self

    def clear(self):
        self._items.clear()
        self._changed()

    def pop(self, index=-1):
        value = self._items.pop(index)
        self._changed()
        return value

    def _find(self, value):
        for i, x in enumerate(self._items):
            if x is value:
                return i
        return self._items.index(value)

    def index(self, value, start=0, stop=None):
        items = self._read()
        for i, x in enumerate(items[start:stop], start):
            if x is value:
                return i
        return items.index(value, start, len(items) if stop is None else stop)

    def remove(self, value):
        """Remove ``value`` (the same object if present, else an equal one)."""
        del self._items[self._find(value)]
        self._changed()

    def sort(self, *, key=None, reverse=False):
        self._items.sort(key=key, reverse=reverse)
        self._changed()

    def reverse(self):
        self._items.reverse()
        self._changed()

    def set(self, values: Iterable):
        """Replace all items at once."""
        self._items = [_wrap(v) for v in values]
        self._changed()

    def __eq__(self, other):
        return unwrap(self) == unwrap(other)

    __hash__ = None  # type: ignore[assignment]

    def __repr__(self):
        return f"store({unwrap(self)!r})"


def store(value: dict | list | None = None, /, **kwargs) -> Any:
    """Reactive data: ``ui.store([...])`` gives a reactive list, ``ui.store({...})``
    or ``ui.store(name="x")`` a reactive dict. Nested dicts and lists become
    reactive too, so ``todos[0].done = True`` updates only what shows it."""
    if value is None:
        return ReactiveDict(kwargs)
    if isinstance(value, (list, tuple)):
        return ReactiveList(value)
    return ReactiveDict(value, **kwargs)


class _Binding:
    """A two-way binding to one key of a store (see ``bind``)."""

    __slots__ = ("obj", "key")

    def __init__(self, obj, key):
        self.obj = obj
        self.key = key

    def __call__(self):
        return self.obj[self.key]

    def peek(self):
        return untrack(self)

    def set(self, value):
        self.obj[self.key] = value

    def update(self, fn):
        self.set(fn(self.peek()))

    def __repr__(self):
        return f"bind({self.obj!r}, {self.key!r})"


def bind(obj, key) -> Any:
    """A signal-like view of ``obj[key]`` for two-way inputs:
    ``ui.Toggle("Done", value=ui.bind(todo, "done"))``."""
    return _Binding(obj, key)


def _writable(value) -> TypeIs[Signal | _Binding]:
    return isinstance(value, (Signal, _Binding))


# -- resources and timers -----------------------------------------------------------

class Resource(Generic[T]):
    """Async data. ``r()`` is the latest result (or None), ``r.loading()`` and
    ``r.error()`` are signals too. Call ``r.refetch()`` to load again."""

    def __init__(self, fetcher, source=None):
        self.data: Signal[T | None] = Signal(None)
        self.loading: Signal[bool] = Signal(False)
        self.error: Signal[BaseException | None] = Signal(None)
        self._fetcher = fetcher
        self._source = source
        self._gen = 0
        self._task = None
        on_cleanup(self._cancel)
        if source is None:
            self.refetch()
        else:
            effect(lambda: self._start(source() if callable(source) else source))

    def __call__(self) -> T | None:
        return self.data()

    def _cancel(self):
        self._gen += 1
        if self._task is not None and not self._task.done():
            self._task.cancel()

    def refetch(self):
        self._start(untrack(self._source) if callable(self._source) else self._source)

    def _start(self, arg):
        self._cancel()
        gen = self._gen
        if self._source is not None and (arg is None or arg is False):
            return
        args = () if self._source is None else (arg,)

        async def load():
            try:
                result = self._fetcher(*args)
                if inspect.isawaitable(result):
                    result = await result
            except asyncio.CancelledError:
                raise
            except Exception as e:
                if gen == self._gen:
                    with _Batch():
                        self.error.set(e)
                        self.loading.set(False)
                    _app.flush_soon()
                return
            if gen == self._gen:
                with _Batch():
                    self.data.set(result)
                    self.error.set(None)
                    self.loading.set(False)
                _app.flush_soon()

        self.loading.set(True)
        self._task = asyncio.ensure_future(load())


def resource(fetcher: Callable[..., Any], source: Reactive[Any] = None) -> Resource:
    """Load data asynchronously. ``fetcher`` may be async. With ``source``
    (a signal or lambda), it is called with the source's value and runs again
    whenever that changes (skipped while it is None or False)."""
    return Resource(fetcher, source)


class _Timer:
    def __init__(self, seconds, fn, repeat):
        self.seconds = seconds
        self.fn = fn
        self.repeat = repeat
        self.owner = _rt.owner
        self.handle = None
        on_cleanup(self.cancel)
        self._arm()

    def _arm(self):
        self.handle = asyncio.get_event_loop().call_later(self.seconds, self._fire)

    def _fire(self):
        if self.repeat:
            self._arm()
        else:
            self.handle = None
        _app.invoke(self.fn, [], self.owner)

    def cancel(self):
        if self.handle is not None:
            self.handle.cancel()
            self.handle = None


def interval(seconds: float, fn: Callable[[], Any]) -> _Timer:
    """Call ``fn`` every ``seconds``. Stops with the component, or ``.cancel()``."""
    return _Timer(seconds, fn, True)


def timeout(seconds: float, fn: Callable[[], Any]) -> _Timer:
    """Call ``fn`` once after ``seconds``. ``.cancel()`` stops it."""
    return _Timer(seconds, fn, False)


# =============================================================================
# Element tree
#
# Python keeps the tree; the renderer keeps one view per element id. Elements
# are created detached; once their parent is on screen, changes become ops:
#   ["mount", parent, before, tree]  ["move", parent, id, before]
#   ["unmount", id]  ["set", id, {prop: value}]  ["call", id, method, args]
# plus app-level ops (config, dialog, toast, frame). Children are "parts":
# elements or regions (Show, For, live callables) that own a run of siblings.
# =============================================================================

class Event(dict):
    """Event details, e.g. canvas pointer events: ``e.x``, ``e.y``..."""

    def __getattr__(self, name):
        try:
            return self[name]
        except KeyError:
            raise AttributeError(name) from None


def _json(value):
    if value is None or isinstance(value, (bool, int, str)):
        return value
    if isinstance(value, float):
        return value if value == value and value not in (float("inf"), float("-inf")) else None
    if isinstance(value, (ReactiveDict, ReactiveList)):
        return _json(unwrap(value))
    if isinstance(value, dict):
        return {str(k): _json(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json(v) for v in value]
    if isinstance(value, (_dt.date, _dt.time)):
        return value.isoformat()
    return str(value)


def _is_live(value) -> bool:
    return callable(value) and not isinstance(value, (type, Element, _Region))


class Element:
    """Something on screen. Created by component functions like ``ui.Text``."""

    __slots__ = ("id", "type", "props", "handlers", "parts", "container", "mounted")

    def __init__(self, type: str, children: Iterable[Child] = (), **props):
        self.id = _app.new_id()
        self.type = type
        self.props: dict[str, Any] = {}
        self.handlers: dict[str, tuple[Callable, Owner | None]] = {}
        self.parts: list[Element | _Region] = []
        self.container: Element | _Region | None = None
        self.mounted = False
        for name, value in props.items():
            self.bind(name, value)
        for child in _flatten(children):
            part = _to_part(child)
            if part is not None:
                _adopt(self, part)
                self.parts.append(part)

    def __repr__(self):
        return f"<ui.{self.type} #{self.id}>"

    # -- props and events --

    def bind(self, name: str, value: Any, convert: Callable[[Any], Any] | None = None) -> Element:
        """Set a prop. Functions and signals stay live; ``on_*`` names are events."""
        if value is None:
            return self
        if name.startswith("on_") and name != "on_":
            return self.on(name[3:], value)
        mod = _MODIFIERS.get(name)
        if mod is not None:
            name, convert = mod
        conv = convert or _json
        if _is_live(value):
            effect(lambda: self._set(name, conv(value())))
        else:
            self.props[name] = conv(value)
        return self

    def on(self, event: str, handler: Handler) -> Element:
        """Call ``handler`` when ``event`` happens (``click``, ``change``, ...)."""
        self.handlers[event] = (handler, _rt.owner)
        self._set(f"on_{event}", True)
        return self

    def _set(self, name, value):
        props = self.props
        if name in props and props[name] == value and type(props[name]) is type(value):
            return
        props[name] = value
        if self.mounted:
            _app.queue_set(self.id, name, value)

    def call(self, method: str, *args) -> None:
        """Call a method on the element in the renderer (``focus``, ``blur``...)."""
        if self.mounted:
            _app.queue_call(["call", self.id, method, [_json(a) for a in args]])

    def focus(self):
        self.call("focus")

    def blur(self):
        self.call("blur")

    def scroll_into_view(self):
        self.call("scrollIntoView")

    # -- tree --

    def _dom_children(self) -> list[Element]:
        out = []
        for part in self.parts:
            if isinstance(part, Element):
                out.append(part)
            else:
                part._collect(out)
        return out

    def _serialize(self) -> dict:
        self.mounted = True
        _app.nodes[self.id] = self
        out: dict[str, Any] = {"i": self.id, "t": self.type}
        if self.props:
            out["p"] = dict(self.props)
        kids = self._dom_children()
        if kids:
            out["c"] = [k._serialize() for k in kids]
        return out

    def _unmark(self):
        self.mounted = False
        _app.nodes.pop(self.id, None)
        for k in self._dom_children():
            k._unmark()

    def _insert(self, part, before_part=None):
        """Add a child part (before ``before_part`` or at the end)."""
        _adopt(self, part)
        if before_part is None:
            self.parts.append(part)
            anchor = _next_dom(part)
        else:
            self.parts.insert(_index(self.parts, before_part), part)
            anchor = _first_dom(before_part) or _next_dom(before_part)
        _mount_part(part, anchor)

    def _remove(self, part):
        _unmount_part(part)
        del self.parts[_index(self.parts, part)]
        _release(part)


class _Region:
    """A run of sibling parts that changes over time."""

    __slots__ = ("items", "container")

    def __init__(self):
        self.items: list[Element | _Region] = []
        self.container: Element | _Region | None = None

    def _collect(self, out):
        for it in self.items:
            if isinstance(it, Element):
                out.append(it)
            else:
                it._collect(out)

    def _set_items(self, parts):
        """Replace the items, unmounting the old and mounting the new."""
        for p in self.items:
            _unmount_part(p)
            _release(p)
        anchor = _next_dom(self)
        self.items = []
        for p in parts:
            _adopt(self, p)
            self.items.append(p)
        for p in parts:
            _mount_part(p, anchor)


class _Group(_Region):
    __slots__ = ()


def _flatten(items, out=None):
    if out is None:
        out = []
    for item in items:
        if item is None or item is True or item is False:
            continue
        if isinstance(item, (list, tuple)) or inspect.isgenerator(item):
            _flatten(item, out)
        else:
            out.append(item)
    return out


def _to_part(child):
    if isinstance(child, (Element, _Region)):
        return child
    if isinstance(child, (str, int, float)):
        return Element("#text", text=str(child))
    if _is_live(child):
        return _Dynamic(child)
    if _looks_like_image(child):
        return Image(child)
    if isinstance(child, (ReactiveList, ReactiveDict)):
        return Element("#text", text=repr(child))
    return Element("#text", text=str(child))


def _part_of(result):
    """Normalize what a render function returned into one part (or None)."""
    items = [p for p in (_to_part(c) for c in _flatten([result])) if p is not None]
    if not items:
        return None
    if len(items) == 1:
        return items[0]
    group = _Group()
    for p in items:
        _adopt(group, p)
        group.items.append(p)
    return group


def _release(part):
    """Detach ``part`` from its container (groups are throwaway wrappers, so
    their items are released too and can be shown again elsewhere)."""
    part.container = None
    if isinstance(part, _Group):
        for it in part.items:
            _release(it)
        part.items = []


def _adopt(container, part):
    if part.container is not None:
        raise ValueError(f"{part!r} is already on screen somewhere else; create a new one instead")
    part.container = container


def _index(items, part):
    for i, it in enumerate(items):
        if it is part:
            return i
    raise ValueError("part not found")


def _parent_el(part) -> Element | None:
    c = part.container
    while isinstance(c, _Region):
        c = c.container
    return c


def _first_dom(part) -> Element | None:
    if part is None:
        return None
    if isinstance(part, Element):
        return part
    for it in part.items:
        n = _first_dom(it)
        if n is not None:
            return n
    return None


def _dom_list(part) -> list[Element]:
    if isinstance(part, Element):
        return [part]
    out: list[Element] = []
    part._collect(out)
    return out


def _next_dom(part) -> Element | None:
    """The first element on screen after ``part`` within its parent element."""
    c = part.container
    while c is not None:
        items = c.parts if isinstance(c, Element) else c.items
        for it in items[_index(items, part) + 1:]:
            n = _first_dom(it)
            if n is not None:
                return n
        if isinstance(c, Element):
            return None
        part, c = c, c.container
    return None


def _mount_part(part, before: Element | None):
    parent = _parent_el(part)
    if parent is None or not parent.mounted:
        return
    for node in _dom_list(part):
        _app.queue(["mount", parent.id, before.id if before is not None else None, node._serialize()])


def _unmount_part(part):
    for node in _dom_list(part):
        if node.mounted:
            node._unmark()
            _app.queue(["unmount", node.id])


def _move_part(part, before: Element | None):
    parent = _parent_el(part)
    if parent is None or not parent.mounted:
        return
    for node in _dom_list(part):
        _app.queue(["move", parent.id, node.id, before.id if before is not None else None])


# -- live regions and control flow ---------------------------------------------------

class _Dynamic(_Region):
    """A child that is a function: re-runs it when what it read changes."""

    __slots__ = ("fn", "comp")

    def __init__(self, fn):
        super().__init__()
        self.fn = fn
        self.comp = effect(self._run)

    def _run(self):
        result = self.fn()
        if isinstance(result, (str, int, float)) and not isinstance(result, bool):
            items = self.items
            if len(items) == 1 and isinstance(items[0], Element) and items[0].type == "#text":
                items[0]._set("text", str(result))
                return
        part = _part_of(result)
        self._set_items([part] if part is not None else [])


def _arity(fn) -> int:
    try:
        params = inspect.signature(fn).parameters.values()
    except (TypeError, ValueError):
        return 1
    n = 0
    for p in params:
        if p.kind == p.VAR_POSITIONAL:
            return 99
        if p.kind in (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD):
            n += 1
    return n


def _call(fn, args):
    """Call ``fn`` with as many of ``args`` as it accepts."""
    return fn(*args[: _arity(fn)])


def Show(when: Reactive[Any], *children: Child, fallback: Child = None) -> _Region:
    """Show ``children`` while ``when`` is truthy, else ``fallback``.

    A single function child is called (with the value of ``when`` if it takes
    an argument) each time the condition becomes true, so it is built lazily.
    """
    if not _is_live(when):
        value = when
        when = lambda: value  # noqa: E731
    truthy = Computed(lambda: bool(when()))

    def branch(chosen):
        if len(chosen) == 1 and _is_live(chosen[0]) and not _writable(chosen[0]):
            fn = chosen[0]
            return _build(lambda: _call(fn, [untrack(when)]))
        return list(chosen)

    then_parts = list(children)
    else_parts = [fallback] if fallback is not None else []
    return _Dynamic(lambda: branch(then_parts if truthy() else else_parts))


class _Entry:
    __slots__ = ("key", "item", "owner", "part", "index", "new")

    def __init__(self, key, item):
        self.key = key
        self.item = item
        self.owner: Owner | None = None
        self.part = None
        self.index: Signal[int] | None = None
        self.new = True


def _identity_key(item):
    if item is None or isinstance(item, (str, int, float, bool, bytes, tuple, frozenset)):
        try:
            hash(item)
            return ("v", type(item), item)
        except TypeError:
            pass
    return ("o", id(item))


def _lis(seq):
    """Indices of a longest increasing subsequence of seq (ignoring -1)."""
    tails: list[int] = []
    prev = [-1] * len(seq)
    for i, v in enumerate(seq):
        if v < 0:
            continue
        lo, hi = 0, len(tails)
        while lo < hi:
            mid = (lo + hi) // 2
            if seq[tails[mid]] < v:
                lo = mid + 1
            else:
                hi = mid
        if lo > 0:
            prev[i] = tails[lo - 1]
        if lo == len(tails):
            tails.append(i)
        else:
            tails[lo] = i
    out = set()
    i = tails[-1] if tails else -1
    while i >= 0:
        out.add(i)
        i = prev[i]
    return out


class For(_Region):
    """Render ``render(item)`` (or ``render(item, index)``) for each item of
    ``each`` (a store list, a signal, or a lambda returning a list).

    Rows are keyed by item identity (or by ``key(item)``): when the list
    changes, existing rows are kept and moved, only new items are rendered.
    ``index`` is a signal. ``fallback`` is shown while the list is empty.
    """

    __slots__ = ("each", "render", "key", "fallback", "entries", "owner", "fb", "arity", "comp")

    def __init__(self, each: Any, render: Callable[..., Child], *, key: Callable[[Any], Any] | None = None,
                 fallback: Child = None):
        super().__init__()
        self.each = each
        self.render = render
        self.key = key
        self.fallback = fallback
        self.entries: list[_Entry] = []
        self.owner = Owner()
        self.fb: tuple[Owner, Any] | None = None
        self.arity = _arity(render)
        prev = _rt.owner
        _rt.owner = self.owner
        try:
            self.comp = effect(self._update)
        finally:
            _rt.owner = prev

    def _update(self):
        each = self.each
        items = each() if _is_live(each) else each
        items = list(items) if items is not None else []
        prev = _rt.listener
        _rt.listener = None
        try:
            self._reconcile(items)
        finally:
            _rt.listener = prev

    def _reconcile(self, items):
        keyfn = self.key
        counts: dict = {}
        old = {e.key: e for e in self.entries}
        old_pos = {id(e): i for i, e in enumerate(self.entries)}
        removed: list[_Entry] = []
        entries: list[_Entry] = []
        for item in items:
            base = keyfn(item) if keyfn is not None else _identity_key(item)
            n = counts.get(base, 0)
            counts[base] = n + 1
            k = (base, n)
            e = old.pop(k, None)
            if e is not None and e.item is not item and keyfn is not None:
                # Same key, new data: render it again.
                removed.append(e)
                e = None
            if e is None:
                e = _Entry(k, item)
            else:
                e.new = False
            entries.append(e)
        removed.extend(old.values())
        for e in removed:
            if e.part is not None:
                _unmount_part(e.part)
                _release(e.part)
            if e.owner is not None:
                e.owner.dispose()

        if entries and self.fb is not None:
            owner, part = self.fb
            if part is not None:
                _unmount_part(part)
                _release(part)
            owner.dispose()
            self.fb = None

        # Render new rows first, in order (render functions may have side effects).
        for i, e in enumerate(entries):
            if e.new:
                e.owner = Owner(self.owner)
                args = [e.item]
                if self.arity >= 2:
                    e.index = Signal(i)
                    args.append(e.index)
                e.part = _part_of(_build(self.render, args[: max(self.arity, 1)], e.owner))
                if e.part is not None:
                    _adopt(self, e.part)

        # Then place them from the end, each before the next one: rows on the
        # longest increasing run of old positions stay where they are.
        keep = _lis([-1 if e.new else old_pos[id(e)] for e in entries])
        anchor = _next_dom(self)
        self.entries = entries
        for i in range(len(entries) - 1, -1, -1):
            e = entries[i]
            if e.new:
                if e.part is not None:
                    _mount_part(e.part, anchor)
            else:
                if i not in keep and e.part is not None:
                    _move_part(e.part, anchor)
                if e.index is not None:
                    e.index.set(i)
            first = _first_dom(e.part)
            if first is not None:
                anchor = first
        self.items = [e.part for e in entries if e.part is not None]

        if not entries and self.fallback is not None:
            if self.fb is None:
                owner = Owner(self.owner)
                fb = self.fallback
                part = _part_of(_build(fb if _is_live(fb) else (lambda: fb), (), owner))
                self.fb = (owner, part)
                if part is not None:
                    _adopt(self, part)
                    _mount_part(part, _next_dom(self))
            if self.fb[1] is not None:
                self.items = [self.fb[1]]


# =============================================================================
# The app: ops queue, flushing, event dispatch
# =============================================================================

class _App:
    def __init__(self):
        self.next_id = 1
        self.host = None
        self.nodes: dict[int, Element] = {}
        self.ops: list = []
        self.sets: dict[int, dict] = {}
        self.calls: list = []
        self.seq = 0
        self.scheduled = False
        self.dispatching = 0
        self.mount_callbacks: list = []
        self.owner: Owner | None = None
        self.root: Element | None = None
        self.dialogs: dict[int, asyncio.Future] = {}
        self.next_dialog = 1
        self.schedule_fn: Callable[[Callable[[], None]], None] | None = None
        self.config: dict = {}

    def new_id(self) -> int:
        i = self.next_id
        self.next_id += 1
        return i

    def queue(self, op):
        self.ops.append(op)
        self.schedule()

    def queue_set(self, node_id, name, value):
        props = self.sets.get(node_id)
        if props is None:
            props = self.sets[node_id] = {}
        props[name] = value
        self.schedule()

    def queue_call(self, op):
        self.calls.append(op)
        self.schedule()

    def schedule(self):
        if self.dispatching or self.scheduled or self.root is None:
            return
        self.scheduled = True
        if self.schedule_fn is not None:
            self.schedule_fn(self.flush)
            return
        try:
            asyncio.get_event_loop().call_soon(self.flush)
        except RuntimeError:
            self.scheduled = False

    def flush_soon(self):
        if self.ops or self.sets or self.calls:
            self.schedule()

    def flush(self):
        """Send everything queued to the renderer as one message."""
        self.scheduled = False
        ops = self.ops
        if self.sets:
            ops.extend(["set", i, p] for i, p in self.sets.items() if i in self.nodes)
            self.sets = {}
        if self.calls:
            ops.extend(self.calls)
            self.calls = []
        self.ops = []
        if ops and self.host is not None:
            self.seq += 1
            self.host.render(json.dumps({"seq": self.seq, "ops": ops}, separators=(",", ":")))
        callbacks, self.mount_callbacks = self.mount_callbacks, []
        for fn, owner in callbacks:
            if owner is None or owner.state != _DISPOSED:
                self.invoke(fn, [], owner)

    def invoke(self, fn, args, owner):
        """Run a callback like an event handler: batched, then flushed."""
        prev_owner, prev_listener = _rt.owner, _rt.listener
        _rt.owner, _rt.listener = owner, None
        self.dispatching += 1
        try:
            with _Batch():
                result = _call(fn, args)
            if inspect.isawaitable(result):
                asyncio.ensure_future(_guard(result))
        except Exception as e:
            _report(e)
        finally:
            _rt.owner, _rt.listener = prev_owner, prev_listener
            self.dispatching -= 1
        if not self.dispatching:
            self.flush()

    def dispatch(self, cb_id, args_json=None):
        """Called by the renderer: ``cb_id`` is "<element id>:<event>"."""
        node_id, _, event = str(cb_id).partition(":")
        try:
            el = self.nodes.get(int(node_id))
        except ValueError:
            return
        if el is None:
            return
        handler = el.handlers.get(event)
        if handler is None:
            return
        args = json.loads(args_json) if args_json else []
        args = [Event(a) if isinstance(a, dict) else a for a in args]
        self.invoke(handler[0], args, handler[1])

    # -- lifecycle --

    def connect(self):
        if self.host is not None:
            return
        try:
            import _uihost  # ty: ignore[unresolved-import]  # provided by the worker
        except ImportError:
            raise RuntimeError("ui apps need the Terrarium app or a published page to show up") from None
        from pyodide.ffi import create_proxy  # ty: ignore[unresolved-import]

        self.host = _uihost
        _uihost.set_dispatcher(create_proxy(self.dispatch))

    def start(self, app, config):
        self.connect()
        self.stop()
        root = Element("#root")
        root.id = 0
        root.mounted = True
        self.root = root
        self.nodes = {0: root}
        root.handlers["dialog"] = (self._dialog_result, None)
        root.handlers["resync"] = (self.resync, None)
        self.owner = Owner(None)
        self.config = config
        self.ops.append(["config", config])
        if _is_live(app) and not isinstance(app, (Signal, Computed)):
            result = _build(app, (), self.owner)
        else:
            result = app
        part = _part_of(result)
        if part is not None:
            root._insert(part)
        self.flush()

    def resync(self):
        """A new renderer attached (or one lost messages): send everything."""
        if self.root is None:
            return
        self.sets = {}
        self.ops = [["reset"], ["config", self.config]]
        self.ops.extend(["mount", 0, None, el._serialize()] for el in self.root._dom_children())

    def stop(self):
        if self.owner is not None:
            self.owner.dispose()
            self.owner = None
        if self.root is not None:
            for part in list(self.root.parts):
                self.root._remove(part)
        for fut in self.dialogs.values():
            if not fut.done():
                fut.cancel()
        self.dialogs = {}

    # -- dialogs --

    def dialog(self, spec) -> asyncio.Future:
        fut = asyncio.get_event_loop().create_future()
        i = self.next_dialog
        self.next_dialog += 1
        self.dialogs[i] = fut
        self.queue_call(["dialog", i, spec])
        return fut

    def _dialog_result(self, i, value=None):
        fut = self.dialogs.pop(i, None)
        if fut is not None and not fut.done():
            fut.set_result(value)


_app = _App()


async def _guard(awaitable):
    try:
        await awaitable
    except asyncio.CancelledError:
        pass
    except Exception as e:
        _report(e)
    _app.flush_soon()


def _report(exc: BaseException):
    """Print a traceback without this module's frames (in the app: as data, D45)."""
    try:
        import _terrarium_traceback  # type: ignore[import-not-found]
    except ImportError:  # a published web app, the tests
        te = traceback.TracebackException.from_exception(exc)
        frames = [f for f in te.stack if f.filename != __file__]
        te.stack = traceback.StackSummary.from_list(frames)
        sys.stderr.write("".join(te.format()))
    else:
        _terrarium_traceback.report(exc)


def run(app: Callable[[], Child] | Child, *, title: str | None = None, theme: str = "auto",
        tint: str | None = None, close_button: bool = True) -> None:
    """Show ``app`` (a component function or an element) full screen.

    ``theme`` is "auto", "light" or "dark"; ``tint`` is the accent color.
    In Terrarium the app's first screen has a close button that ends the
    program (touch and hold it to restart). ``close_button=False`` leaves it
    out: the app ends itself with ``ui.close()``, and a two-finger swipe
    down still closes it. Running again replaces the previous app.
    """
    _app.start(app, {"title": title, "theme": theme, "tint": tint, "close_button": bool(close_button)})


def close() -> None:
    """End the app, like its close button. In Terrarium the program stops;
    on a web page the app's view is cleared."""
    if _app.root is None:
        return
    _app.queue_call(["close"])
    if not _app.dispatching:
        _app.flush()


def navigation() -> NavigationStack:
    """The NavigationStack around the current component or event handler."""
    owner = _rt.owner
    nav = owner.lookup(NavigationStack) if owner is not None else None
    if nav is None:
        raise RuntimeError("ui.navigation() needs to be called inside a ui.NavigationStack")
    return nav


def alert(title: str, message: str | None = None, *, button: str = "OK") -> asyncio.Future:
    """Show an alert. ``await ui.alert("Saved")``."""
    return _app.dialog({"kind": "alert", "title": title, "message": message, "ok": button})


def confirm(title: str, message: str | None = None, *, ok: str = "OK", cancel: str = "Cancel",
            destructive: bool = False) -> asyncio.Future:
    """Ask yes or no. ``if await ui.confirm("Delete?"): ...``"""
    return _app.dialog({"kind": "confirm", "title": title, "message": message, "ok": ok,
                        "cancel": cancel, "destructive": destructive})


def prompt(title: str, message: str | None = None, *, value: str = "", placeholder: str = "",
           ok: str = "OK", cancel: str = "Cancel") -> asyncio.Future:
    """Ask for text. Resolves to the text, or None when cancelled."""
    return _app.dialog({"kind": "prompt", "title": title, "message": message, "value": value,
                        "placeholder": placeholder, "ok": ok, "cancel": cancel})


def choose(title: str | None, options: list[str], *, message: str | None = None,
           cancel: str = "Cancel") -> asyncio.Future:
    """An action sheet. Resolves to the chosen option, or None."""

    async def pick():
        i = await _app.dialog({"kind": "choose", "title": title, "message": message,
                               "options": [str(o) for o in options], "cancel": cancel})
        return options[i] if isinstance(i, int) and 0 <= i < len(options) else None

    return asyncio.ensure_future(pick())


def toast(text: str, *, seconds: float = 2.0) -> None:
    """Show a short message that goes away by itself."""
    _app.queue_call(["toast", str(text), seconds])


# =============================================================================
# Components
# =============================================================================

# Modifiers are sent as plain values (points, colors, names); each renderer
# turns them into its own terms (SwiftUI modifiers in the app, CSS on the web).

def _num(v):
    if v is None or isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return v
    raise TypeError(f"expected a number, got {v!r}")


def _edges(v):
    """padding/margin: a number, (vertical, horizontal) or (top, right, bottom, left)."""
    if v is None or v is False:
        return None
    if isinstance(v, (list, tuple)):
        if len(v) not in (2, 4):
            raise ValueError("padding takes one number, (vertical, horizontal) or (top, right, bottom, left)")
        return [_num(x) or 0 for x in v]
    return _num(v)


def _size(v):
    """width/height: points, or "fill" for all the room there is."""
    if v is None or v is False:
        return None
    if v in ("fill", "100%"):
        return "fill"
    return _num(v)


def _flex(v):
    if v is None or v is False:
        return None
    if v is True:
        return 1
    return _num(v)


def _color(v):
    """A color: "#rrggbb", "#rrggbbaa", "rgb(...)", a CSS color name, a system
    color (red, orange, ..., gray) or a semantic one (primary, secondary,
    tertiary, tint, background, separator)."""
    if v is None or v is False or v == "":
        return None
    return str(v)


_WEIGHTS = {"ultralight": 100, "thin": 200, "light": 300, "regular": 400, "normal": 400, "medium": 500,
            "semibold": 600, "bold": 700, "heavy": 800, "black": 900}


def _weight(v):
    if v is None or v is False:
        return None
    if isinstance(v, str):
        if v.isdigit():
            return int(v)
        if v.lower() not in _WEIGHTS:
            raise ValueError(f"unknown font weight {v!r}")
        return _WEIGHTS[v.lower()]
    return _num(v)


def _align(v):
    if v is None:
        return None
    return {"left": "leading", "start": "leading", "right": "trailing", "end": "trailing"}.get(v, v)


def _border(v):
    """A color (1 point wide) or (width, color)."""
    if v is None or v is False or v == "":
        return None
    if isinstance(v, (list, tuple)):
        width, color = v
        return [_num(width), _color(color)]
    return [1, _color(v)]


def _shadow(v):
    if v is None or v is False:
        return None
    if v is True:
        return 12
    return _num(v)


def _str(v):
    return "" if v is None else str(v)


# Keyword arguments every element accepts.
_MODIFIERS: dict[str, tuple[str, Callable[[Any], Any]]] = {
    "padding": ("padding", _edges),
    "margin": ("margin", _edges),
    "width": ("width", _size),
    "height": ("height", _size),
    "min_width": ("min_width", _size),
    "max_width": ("max_width", _size),
    "min_height": ("min_height", _size),
    "max_height": ("max_height", _size),
    "flex": ("flex", _flex),
    "background": ("background", _color),
    "color": ("color", _color),
    "tint": ("tint", _color),
    "font_size": ("font_size", _num),
    "font_weight": ("font_weight", _weight),
    "text_align": ("text_align", _align),
    "corner_radius": ("corner_radius", _num),
    "border": ("border", _border),
    "opacity": ("opacity", _num),
    "shadow": ("shadow", _shadow),
    "accessibility_label": ("a11y", lambda v: None if v is None else str(v)),
    "aria_label": ("a11y", lambda v: None if v is None else str(v)),
    "hidden": ("hidden", bool),
    "disabled": ("disabled", bool),
}


def _el(type: str, children=(), **props) -> Element:
    return Element(type, children, **props)


def _bind_value(el: Element, value, on_change, decode=None, encode=None, prop="value"):
    """Bind an input's value: live from a signal, written back to it on change
    (unless ``on_change`` is given, which then decides)."""
    el.bind(prop, value, encode)
    writable = _writable(value)

    def changed(v):
        if decode is not None:
            v = decode(v)
        # The renderer already shows v; remember that so echoing it back is a no-op.
        el.props[prop] = (encode or _json)(v)
        if on_change is not None:
            return _call(on_change, [v])
        if writable:
            value.set(v)
        return None

    el.on("change", changed)


# -- layout ------------------------------------------------------------------------

def VStack(*children: Child, spacing: Reactive[float] = 8, align: Reactive[str] = "stretch",
           justify: Reactive[str] | None = None, **mods) -> Element:
    """Children top to bottom. align: stretch, leading, center, trailing."""
    return _el("VStack", children, spacing=spacing, align=align, justify=justify, **mods)


def HStack(*children: Child, spacing: Reactive[float] = 8, align: Reactive[str] = "center",
           justify: Reactive[str] | None = None, wrap: Reactive[bool] = False, **mods) -> Element:
    """Children left to right. align: top, center, bottom, baseline, stretch."""
    return _el("HStack", children, spacing=spacing, align=align, justify=justify, wrap=wrap or None, **mods)


def ZStack(*children: Child, align: Reactive[str] = "center", **mods) -> Element:
    """Children on top of each other (the last one in front)."""
    return _el("ZStack", children, align=align, **mods)


def Grid(*children: Child, columns: Reactive[int] | None = 2, min_width: Reactive[float] | None = None,
         spacing: Reactive[float] = 8, **mods) -> Element:
    """A grid with a fixed number of ``columns``, or as many as fit ``min_width``."""
    return _el("Grid", children, columns=None if min_width is not None else columns,
               min=min_width, spacing=spacing, **mods)


def ScrollView(*children: Child, axis: str = "vertical", spacing: Reactive[float] = 8, **mods) -> Element:
    """A scrolling area (vertical or horizontal)."""
    return _el("ScrollView", children, axis=axis, spacing=spacing, **mods)


def Spacer(size: Reactive[float] | None = None, **mods) -> Element:
    """Flexible empty space in a stack (or a fixed ``size``)."""
    return _el("Spacer", (), size=size, **mods)


def Divider(**mods) -> Element:
    """A thin line."""
    return _el("Divider", (), **mods)


def Card(*children: Child, spacing: Reactive[float] = 8, **mods) -> Element:
    """A rounded box on the background, like a list section without rows."""
    return _el("Card", children, spacing=spacing, **mods)


# -- navigation --------------------------------------------------------------------

def _toolbar(placement, items):
    if items is None:
        return None
    return _el("Toolbar", [items], placement=placement)


def Screen(title: Reactive[str] | None = None, *children: Child, leading: Child = None,
           trailing: Child = None, large_title: bool = True, **mods) -> Element:
    """A full screen with a navigation bar and scrolling content. ``leading``
    and ``trailing`` go into the bar (usually buttons)."""
    if isinstance(title, (Element, _Region)):
        children = (title, *children)
        title = None
    parts = [_toolbar("leading", leading), _toolbar("trailing", trailing), *children]
    return _el("Screen", parts, title=title, large=large_title, **mods)


class NavigationStack(Element):
    """Screens that slide in from the right with a back button.

    ``nav.push(DetailScreen, item)`` calls ``DetailScreen(item)`` and shows it;
    ``nav.pop()`` goes back. Inside the stack, ``ui.navigation()`` returns it.
    """

    __slots__ = ("stack", "owner")

    def __init__(self, root: Callable[[], Child] | Element, **mods):
        super().__init__("NavigationStack", (), **mods)
        self.owner = Owner()
        self.owner.context = {NavigationStack: self}
        self.stack: list[tuple[Owner, Element]] = []
        self._push(root, (), {}, animated=False)

    @property
    def depth(self) -> int:
        return len(self.stack)

    def _push(self, screen, args, kwargs, animated=True):
        owner = Owner(self.owner)
        if _is_live(screen):
            result = _build(lambda: screen(*args, **kwargs), (), owner)
        else:
            result = screen
        if not (isinstance(result, Element) and result.type == "Screen"):
            result = Screen(None, result)
        if self.stack:
            prev = self.stack[-1][1]
            result._set("back", prev.props.get("title") or "Back")
            prev_owner = _rt.owner
            _rt.owner = owner
            try:
                result.on("back", lambda: self.pop())
            finally:
                _rt.owner = prev_owner
        self.stack.append((owner, result))
        self._insert(result)
        return result

    def push(self, screen: Callable[..., Child] | Element, *args, **kwargs) -> Element:
        """Show a new screen: a component function (called with ``args``) or an element."""
        return self._push(screen, args, kwargs)

    def pop(self, count: int = 1) -> None:
        """Go back ``count`` screens (never past the first)."""
        for _ in range(min(count, len(self.stack) - 1)):
            owner, el = self.stack.pop()
            self._remove(el)
            owner.dispose()

    def pop_to_root(self) -> None:
        self.pop(len(self.stack) - 1)


def TabView(*tabs: Element, selected: Reactive[int] | None = None, on_change: Handler | None = None,
            **mods) -> Element:
    """Tabs with a tab bar at the bottom. ``selected`` is the tab index; pass a
    signal to keep it in sync."""
    el = _el("TabView", tabs, **mods)
    if selected is None:
        selected = Signal(0)
    _bind_value(el, selected, on_change, decode=int, prop="selected")
    return el


def Tab(title: Reactive[str], *children: Child, icon: Reactive[str] | None = None,
        badge: Reactive[Any] = None, **mods) -> Element:
    """One tab of a TabView."""
    return _el("Tab", children, title=title, icon=icon, badge=badge, **mods)


def Sheet(*children: Child, open: Reactive[bool] = False, title: Reactive[str] | None = None,
          on_dismiss: Handler | None = None, size: str = "large", **mods) -> Element:
    """A card that slides up over the app while ``open`` is true. Pass a
    signal: swiping down or tapping Done sets it to False. size: large, medium."""
    el = _el("Sheet", children, title=title, size=size, **mods)
    el.bind("open", open, bool)

    def dismissed():
        el.props["open"] = False
        if _writable(open):
            open.set(False)
        if on_dismiss is not None:
            return _call(on_dismiss, [])
        return None

    el.on("dismiss", dismissed)
    return el


# -- lists -------------------------------------------------------------------------

def Section(*children: Child, header: Reactive[str] | None = None, footer: Reactive[str] | None = None,
            **mods) -> Element:
    """A rounded group of rows (iOS Settings style)."""
    return _el("Section", children, header=header, footer=footer, **mods)


def Row(title: Reactive[str] | None = None, *children: Child, subtitle: Reactive[str] | None = None,
        detail: Reactive[Any] = None, icon: Reactive[str] | None = None,
        accessory: Reactive[str] | None = None, checked: Reactive[bool] | None = None,
        on_click: Handler | None = None, on_check: Handler | None = None,
        on_delete: Handler | None = None, **mods) -> Element:
    """A list row for use in a Section. ``accessory``: chevron, check, info.
    ``checked`` shows a round check box; tapping it calls ``on_check`` (or
    ``on_click``). ``on_delete`` enables swipe to delete."""
    if isinstance(title, (Element, _Region)):
        children = (title, *children)
        title = None
    return _el("Row", children, title=title, subtitle=subtitle, detail=detail, icon=icon,
               accessory=accessory, checked=checked, on_click=on_click, on_check=on_check,
               on_delete=on_delete, **mods)


# -- content -----------------------------------------------------------------------

def Text(text: Reactive[Any] = "", *, font: Reactive[str] = "body", bold: Reactive[bool] = False,
         italic: Reactive[bool] = False, mono: Reactive[bool] = False, lines: Reactive[int] | None = None,
         selectable: bool = False, **mods) -> Element:
    """Text. font: largeTitle, title, title2, title3, headline, body, callout,
    subheadline, footnote, caption. ``lines`` cuts it off after that many lines."""
    return _el("Text", (), text=_live_str(text), font=font, bold=bold or None, italic=italic or None,
               mono=mono or None, lines=lines, selectable=selectable or None, **mods)


def _live_str(v):
    if _is_live(v):
        return lambda: _str(v())
    return _str(v)


def Label(text: Reactive[str], icon: Reactive[str] | None = None, **mods) -> Element:
    """An icon followed by text."""
    return _el("Label", (), text=_live_str(text), icon=icon, **mods)


def Icon(name: Reactive[str], *, size: Reactive[float] | None = None, **mods) -> Element:
    """A built-in icon by name (plus, trash, star, heart, gear, ...) or an emoji."""
    return _el("Icon", (), name=name, size=size, **mods)


def _looks_like_image(obj) -> bool:
    return (hasattr(obj, "savefig") or (hasattr(obj, "save") and hasattr(obj, "mode"))
            or isinstance(obj, (bytes, bytearray)))


def _sniff(data: bytes) -> str:
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:4] == b"GIF8":
        return "image/gif"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    if data.lstrip()[:1] == b"<":
        return "image/svg+xml"
    return "application/octet-stream"


def _image_src(src) -> str:
    """URLs pass through; files, bytes, PIL images and matplotlib figures
    become data URLs."""
    if src is None:
        return ""
    if isinstance(src, os.PathLike):
        src = os.fspath(src)
    if isinstance(src, str):
        if src.startswith(("http:", "https:", "data:", "blob:", "app:", "/")) and not os.path.isfile(src):
            return src
        if os.path.isfile(src):
            with open(src, "rb") as f:
                data = f.read()
            mime = mimetypes.guess_type(src)[0] or _sniff(data)
            return f"data:{mime};base64,{base64.b64encode(data).decode('ascii')}"
        return src
    if isinstance(src, (bytes, bytearray)):
        data = bytes(src)
    elif hasattr(src, "savefig"):  # matplotlib figure or pyplot
        buf = io.BytesIO()
        src.savefig(buf, format="png", dpi=144, bbox_inches="tight")
        data = buf.getvalue()
    elif hasattr(src, "save"):  # PIL image
        buf = io.BytesIO()
        src.save(buf, format="PNG")
        data = buf.getvalue()
    else:
        return str(src)
    return f"data:{_sniff(data)};base64,{base64.b64encode(data).decode('ascii')}"


def Image(src: Reactive[Any], *, fit: Reactive[str] = "contain", alt: str = "", **mods) -> Element:
    """An image from a URL, a project file, bytes, a PIL image or a matplotlib
    figure. fit: contain, cover, fill."""
    el = _el("Image", (), fit=fit, alt=alt, **mods)
    el.bind("src", src, _image_src)
    return el


def ProgressView(value: Reactive[float] | None = None, *, label: Reactive[str] | None = None,
                 **mods) -> Element:
    """A progress bar for ``value`` between 0 and 1, or a spinner without one."""
    return _el("ProgressView", (), value=value, label=label, **mods)


def Link(text: Reactive[str], url: Reactive[str], **mods) -> Element:
    """A link that opens ``url``."""
    return _el("Link", (), text=_live_str(text), url=url, **mods)


class _Painter:
    """Records canvas drawing calls. Method and attribute names are those of the
    browser's CanvasRenderingContext2D in snake_case (``fill_rect``,
    ``fill_style``, ...), plus a few shortcuts (``clear``, ``circle``,
    ``line``, ``text``). The app draws them natively; it knows paths
    (``begin_path``, ``move_to``, ``line_to``, ``arc``, ``arc_to``, ``ellipse``,
    ``rect``, ``round_rect``, ``quadratic_curve_to``, ``bezier_curve_to``,
    ``close_path``, ``fill``, ``stroke``, ``clip``), rectangles, text,
    ``save``/``restore``, transforms and the usual style attributes."""

    def __init__(self, width, height):
        object.__setattr__(self, "_cmds", [])
        object.__setattr__(self, "width", width)
        object.__setattr__(self, "height", height)

    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)
        method = _camel(name)
        cmds = self._cmds

        def record(*args):
            cmds.append([method, *[_json(a) for a in args]])

        return record

    def __setattr__(self, name, value):
        self._cmds.append(["=", _camel(name), _json(value)])

    def clear(self, color: str | None = None):
        """Erase everything (and fill with ``color``)."""
        self._cmds.append(["$clear", color])

    def circle(self, x, y, r, fill: str | None = None, stroke: str | None = None, width: float | None = None):
        self._cmds.append(["$circle", x, y, r, fill, stroke, width])

    def line(self, x1, y1, x2, y2, color: str | None = None, width: float | None = None):
        self._cmds.append(["$line", x1, y1, x2, y2, color, width])

    def text(self, s, x, y, color: str | None = None, font: str | None = None, align: str | None = None):
        self._cmds.append(["$text", str(s), x, y, color, font, align])


def _camel(name: str) -> str:
    head, *rest = name.split("_")
    return head + "".join(p[:1].upper() + p[1:] for p in rest)


def Canvas(draw: Callable[[_Painter], Any] | None = None, *, width: float = 300, height: float = 300,
           on_frame: Handler | None = None, **mods) -> Element:
    """A drawing surface of ``width`` x ``height`` units, scaled to fit.

    ``draw(p)`` paints with the browser's canvas API in snake_case
    (``p.fill_style = "red"; p.fill_rect(0, 0, 10, 10)``) and runs again when
    signals it reads change. ``on_frame(dt)`` is called every animation frame;
    ``on_pointer_down/move/up(e)`` get ``e.x`` and ``e.y`` in canvas units.
    """
    el = _el("Canvas", (), cw=width, ch=height, **mods)
    if draw is not None:
        def paint():
            p = _Painter(width, height)
            draw(p)
            return p._cmds

        effect(lambda: el._set("cmds", paint()))
    if on_frame is not None:
        def frame(dt):
            try:
                return _call(on_frame, [dt])
            finally:
                _app.queue_call(["frame", el.id])

        el.on("frame", frame)
    return el


# -- inputs ------------------------------------------------------------------------

def Button(label: Reactive[str] | Element | None = None, on_click: Handler | None = None, *,
           kind: Reactive[str] = "filled", icon: Reactive[str] | None = None,
           size: Reactive[str] | None = None, disabled: Reactive[bool] = False, **mods) -> Element:
    """A button. kind: filled, tinted, gray, plain, destructive.
    size: small, large. ``on_click`` may be async."""
    children = ()
    if isinstance(label, (Element, _Region)):
        children, label = (label,), None
    return _el("Button", children, label=_live_str(label) if label is not None else None, kind=kind,
               icon=icon, size=size, disabled=disabled, on_click=on_click, **mods)


def TextField(value: Reactive[str] = "", *, placeholder: Reactive[str] = "", label: Reactive[str] | None = None,
              kind: str = "text", on_change: Handler | None = None, on_submit: Handler | None = None,
              autofocus: bool = False, disabled: Reactive[bool] = False, **mods) -> Element:
    """A one-line text input. Pass a signal as ``value`` to keep it in sync.
    kind: text, password, email, number, decimal, search, url, tel."""
    el = _el("TextField", (), placeholder=placeholder, label=label, kind=kind,
             autofocus=autofocus or None, disabled=disabled, on_submit=on_submit, **mods)
    _bind_value(el, value, on_change, encode=_str)
    return el


def TextArea(value: Reactive[str] = "", *, placeholder: Reactive[str] = "", rows: int = 4,
             on_change: Handler | None = None, disabled: Reactive[bool] = False, **mods) -> Element:
    """A multi-line text input."""
    el = _el("TextArea", (), placeholder=placeholder, rows=rows, disabled=disabled, **mods)
    _bind_value(el, value, on_change, encode=_str)
    return el


def Toggle(label: Reactive[str], value: Reactive[bool] = False, *, on_change: Handler | None = None,
           disabled: Reactive[bool] = False, **mods) -> Element:
    """An on/off switch with a label."""
    el = _el("Toggle", (), label=_live_str(label), disabled=disabled, **mods)
    _bind_value(el, value, on_change, decode=bool, encode=bool)
    return el


def Slider(value: Reactive[float] = 0.0, *, min: float = 0.0, max: float = 1.0, step: float | None = None,
           label: Reactive[str] | None = None, on_change: Handler | None = None,
           disabled: Reactive[bool] = False, **mods) -> Element:
    """A slider from ``min`` to ``max``."""
    el = _el("Slider", (), min=min, max=max, step=step, label=label, disabled=disabled, **mods)
    as_int = all(isinstance(x, int) for x in (min, max, step if step is not None else 1)) and step is not None
    _bind_value(el, value, on_change, decode=(lambda v: int(round(v))) if as_int else float)
    return el


def Stepper(label: Reactive[str], value: Reactive[float] = 0, *, min: float | None = None,
            max: float | None = None, step: float = 1, on_change: Handler | None = None,
            **mods) -> Element:
    """A label with − and + buttons."""
    el = _el("Stepper", (), label=_live_str(label), min=min, max=max, **mods)
    el.bind("value", value)

    def stepped(direction):
        current = value.peek() if _writable(value) else el.props.get("value", 0)
        new = (current or 0) + step * (1 if direction > 0 else -1)
        if min is not None:
            new = builtins_max(min, new)
        if max is not None:
            new = builtins_min(max, new)
        if on_change is not None:
            return _call(on_change, [new])
        if _writable(value):
            value.set(new)
        else:
            el._set("value", new)
        return None

    el.on("change", stepped)
    return el


builtins_min, builtins_max = min, max


def _options(options):
    if isinstance(options, dict):
        return list(options.keys()), [str(v) for v in options.values()]
    values, labels = [], []
    for o in options:
        if isinstance(o, tuple) and len(o) == 2:
            values.append(o[0])
            labels.append(str(o[1]))
        else:
            values.append(o)
            labels.append(str(o))
    return values, labels


def Picker(options: Reactive[Any], value: Reactive[Any] = None, *, kind: str = "segmented",
           label: Reactive[str] | None = None, on_change: Handler | None = None,
           disabled: Reactive[bool] = False, **mods) -> Element:
    """Pick one of ``options`` (a list, a list of (value, label) pairs, or a
    dict of value: label). kind: segmented, menu."""
    el = _el("Picker", (), kind=kind, label=label, disabled=disabled, **mods)
    live_options = _is_live(options)

    def opts():
        return _options(options() if live_options else options)

    def index(v, values):
        for i, x in enumerate(values):
            if x is v or x == v:
                return i
        return -1

    el.bind("options", (lambda: opts()[1]) if live_options else opts()[1])
    if live_options or _is_live(value):
        el.bind("value", lambda: index(value() if _is_live(value) else value, opts()[0]))
    else:
        el.props["value"] = index(value, opts()[0])

    def changed(i):
        values = untrack(opts)[0]
        i = int(i)
        if not 0 <= i < len(values):
            return None
        el.props["value"] = i
        if on_change is not None:
            return _call(on_change, [values[i]])
        if _writable(value):
            value.set(values[i])
        return None

    el.on("change", changed)
    return el


def _date_decode(kind):
    def decode(s):
        if not s:
            return None
        if kind == "time":
            return _dt.time.fromisoformat(s)
        if kind == "datetime":
            return _dt.datetime.fromisoformat(s)
        return _dt.date.fromisoformat(s)

    return decode


def _date_encode(kind):
    def encode(v):
        if v is None or v == "":
            return ""
        if isinstance(v, str):
            return v
        if kind == "datetime" and isinstance(v, _dt.datetime):
            return v.replace(second=0, microsecond=0, tzinfo=None).isoformat(timespec="minutes")
        if kind == "time" and isinstance(v, _dt.time):
            return v.isoformat(timespec="minutes")
        return v.isoformat()

    return encode


def DatePicker(value: Reactive[Any] = None, *, kind: str = "date", label: Reactive[str] | None = None,
               on_change: Handler | None = None, disabled: Reactive[bool] = False, **mods) -> Element:
    """Pick a date (``datetime.date``), time or datetime. kind: date, time, datetime."""
    el = _el("DatePicker", (), kind=kind, label=label, disabled=disabled, **mods)
    _bind_value(el, value, on_change, decode=_date_decode(kind), encode=_date_encode(kind))
    return el


def ColorPicker(value: Reactive[str] = "#007aff", *, label: Reactive[str] | None = None,
                on_change: Handler | None = None, **mods) -> Element:
    """Pick a color (a "#rrggbb" string)."""
    el = _el("ColorPicker", (), label=label, **mods)
    _bind_value(el, value, on_change, encode=_str)
    return el
