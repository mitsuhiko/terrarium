"""The visual debugger (D23): bdb on the ``monitoring`` backend, driven by the page.

Every stop blocks in ``_terrariumhost.debug()`` (a synchronous call through the
worker's Atomics channel) until the page sends a command. Commands that only
look at the program (variables, evaluate, scopes) are answered and the next
command is awaited; resume commands (continue, next, stepIn, stepOut) return
to the program. Stop raises KeyboardInterrupt out of the blocking call (D11).

- Breakpoints arrive with the run. While the program runs, the page sends
  SIGUSR2 through the interrupt buffer and we fetch the new list.
- Pause sends SIGUSR1: we stop at the next line of user code.
- ``breakpoint()`` stops here instead of in pdb (``import pdb`` still works).
- ``post_mortem()`` inspects ``sys.last_exc`` after a failed run.

Only files in the project stop; the runtime, the stdlib and installed
packages are skipped, and their frames are hidden from the stack.
"""

import ast
import bdb
import json
import os
import reprlib
import signal
import sys
import traceback
import types

import _terrariumhost

PROJECT = "/home/pyodide/project"
SIGPAUSE = signal.SIGUSR1
SIGBREAKPOINTS = signal.SIGUSR2

_repr = reprlib.Repr()
_repr.maxstring = 160
_repr.maxother = 160
_repr.maxlong = 60
_repr.maxlist = _repr.maxtuple = _repr.maxset = _repr.maxfrozenset = _repr.maxdeque = 12
_repr.maxdict = 8
_repr.maxlevel = 3

MAX_CHILDREN = 300
_NO_CHILDREN = (str, bytes, bytearray, int, float, complex, bool, type(None), range)
_HIDDEN_GLOBALS = (types.ModuleType, types.FunctionType, types.BuiltinFunctionType, type)


def _call_page(message):
    """Blocking round trip to the page; None if the run was interrupted."""
    reply = _terrariumhost.debug(json.dumps(message))
    return None if reply is None else json.loads(reply)


def short_repr(value):
    try:
        if type(value).__repr__ is object.__repr__ and hasattr(value, "__dict__"):
            return _object_repr(value)
        return _repr.repr(value)
    except Exception as e:  # a broken __repr__ must not break the debugger
        return f"<{type(value).__name__}: repr failed: {e}>"


def _object_repr(value):
    """Counter(count=0, history=[]) instead of <__main__.Counter object at 0x…>."""
    fields = [(k, v) for k, v in vars(value).items() if not k.startswith("_")][:6]
    inner = ", ".join(f"{k}={_repr.repr(v)}" for k, v in fields)
    if len(inner) > 120:
        inner = inner[:117] + "…"
    return f"{type(value).__qualname__}({inner})"


def _has_children(value):
    if isinstance(value, _NO_CHILDREN) or isinstance(value, (types.FunctionType, types.BuiltinFunctionType, types.MethodType)):
        return False
    if isinstance(value, (dict, list, tuple, set, frozenset)):
        return len(value) > 0
    if isinstance(value, (types.ModuleType, type)):
        return False
    try:
        return bool(vars(value))
    except TypeError:
        return bool(getattr(type(value), "__slots__", None))


def _children(value):
    if isinstance(value, dict):
        return [(short_repr(k), v) for k, v in list(value.items())[:MAX_CHILDREN]]
    if isinstance(value, (list, tuple)):
        return [(f"[{i}]", v) for i, v in enumerate(value[:MAX_CHILDREN])]
    if isinstance(value, (set, frozenset)):
        items = list(value)[:MAX_CHILDREN]
        try:
            items.sort()
        except TypeError:
            pass
        return [("·", v) for v in items]
    try:
        attrs = vars(value)
    except TypeError:
        attrs = {name: getattr(value, name) for name in getattr(type(value), "__slots__", ()) if hasattr(value, name)}
    return [(k, v) for k, v in attrs.items() if not k.startswith("__")][:MAX_CHILDREN]


class Debugger(bdb.Bdb):
    def __init__(self):
        super().__init__(backend="monitoring")
        self.reason = "step"
        self.pause_requested = False
        self.interacting = False
        self.armed = False
        self.refs = {}
        self.stack = []  # [(frame, lineno)], innermost first, user frames only

    # -- which code is the user's ----------------------------------------------------

    def canonic(self, filename):
        if filename.startswith("<") and filename.endswith(">"):
            return filename
        # The main script runs with a path relative to the project (its cwd may change).
        if not os.path.isabs(filename):
            filename = os.path.join(PROJECT, filename)
        return os.path.normpath(filename)

    def is_user_file(self, filename):
        path = self.canonic(filename)
        return path.startswith(PROJECT + "/") and "/site-packages/" not in path

    def is_user(self, frame):
        return self.is_user_file(frame.f_code.co_filename)

    def stop_here(self, frame):
        return self.is_user(frame) and super().stop_here(frame)

    def trace_dispatch(self, frame, event, arg):
        if self.interacting:  # code evaluated while paused runs untraced
            return None
        return super().trace_dispatch(frame, event, arg)

    def do_clear(self, arg):  # temporary breakpoints are not used
        pass

    # -- arming --------------------------------------------------------------------------

    def set_breakpoints(self, breakpoints):
        """breakpoints: {project-relative path: [line, ...]}"""
        self.clear_all_breaks()
        for rel, lines in breakpoints.items():
            path = os.path.join(PROJECT, rel)
            for line in lines:
                self.set_break(path, line)

    def arm(self, frame=None):
        """Trace in "continue" mode: stop only at breakpoints."""
        if not self.armed:
            self.reset()
            self.botframe = sys._getframe()  # a sentinel; no frame below it is ever "returned to"
            self._set_stopinfo(self.botframe, None, -1)
            self.start_trace()
            self.armed = True
        # Frames that are already running only see line events if they are traced.
        while frame is not None:
            if self.break_anywhere(frame):
                frame.f_trace = self.trace_dispatch
                frame.f_trace_lines = True
            frame = frame.f_back
        self.monitoring_tracer.update_local_events(sys._getframe())
        self.restart_events()

    def stop_trace(self):
        super().stop_trace()
        self.armed = False

    def start_trace(self):
        super().start_trace()
        self.armed = True

    # -- stops ---------------------------------------------------------------------------

    def break_into(self, frame, reason):
        """Stop as soon as user code runs (breakpoint(), Pause)."""
        self.reason = reason
        self.set_trace(frame)

    def user_opcode(self, frame):
        # set_trace() stops at the next instruction, which may be in runtime code
        # (e.g. our time.sleep); then step on to the next line of user code.
        if self.is_user(frame):
            self.interact(frame, self.reason)
        else:
            self.set_step()

    def user_line(self, frame):
        filename = self.canonic(frame.f_code.co_filename)
        reason = "breakpoint" if frame.f_lineno in self.breaks.get(filename, ()) else self.reason
        self.interact(frame, reason)

    def user_call(self, frame, argument_list):
        pass  # stop on the first line instead

    def user_return(self, frame, return_value):
        pass  # stepping past a return stops in the caller

    def _live_stack(self, frame):
        stack = []
        while frame is not None:
            if self.is_user(frame):
                stack.append((frame, frame.f_lineno))
            frame = frame.f_back
        return stack

    def interact(self, frame, reason, stack=None, exception=None, selected=0):
        self.stack = stack if stack is not None else self._live_stack(frame)
        if not self.stack:
            return self.set_continue()
        self.refs = {}
        self.pause_requested = False
        self.reason = "step"
        self.interacting = True
        try:
            message = {
                "event": "stopped",
                "reason": reason,
                "postMortem": stack is not None,
                "exception": exception,
                "frames": [self._describe_frame(f, line) for f, line in self.stack],
                "selected": selected,
                "scopes": self._scopes(selected),
            }
            while True:
                command = _call_page(message)
                if command is None:  # interrupted (Stop raises before we get here)
                    command = {"op": "continue"}
                op = command.get("op")
                if op in ("continue", "next", "stepIn", "stepOut"):
                    if stack is None:  # post-mortem frames have finished; nothing to resume
                        self._resume(op)
                    return
                message = {"event": "result", **self._answer(command)}
        finally:
            self.interacting = False
            self.refs = {}

    def _resume(self, op):
        if not self.stack or self.stack[0][0] is None:
            return
        top = self.stack[0][0]
        if op == "continue":
            self.set_continue()
        elif op == "next":
            self.set_next(top)
        elif op == "stepIn":
            self.set_step()
        elif op == "stepOut":
            self.set_return(top)

    def _answer(self, command):
        op = command.get("op")
        try:
            if op == "scopes":
                return {"scopes": self._scopes(int(command.get("frame", 0)))}
            if op == "variables":
                value = self.refs.get(int(command["ref"]))
                return {"variables": [self._describe(name, v) for name, v in _children(value)]}
            if op == "evaluate":
                return self._evaluate(command["expr"], int(command.get("frame", 0)), command.get("context", "hover"))
            if op == "setBreakpoints":
                self.set_breakpoints(command["breakpoints"])
                return {}
            return {"error": f"unknown command {op!r}"}
        except Exception as e:
            return {"error": f"{type(e).__name__}: {e}"}

    # -- describing the program -----------------------------------------------------------

    def _describe_frame(self, frame, line):
        path = self.canonic(frame.f_code.co_filename)
        return {
            "name": frame.f_code.co_qualname,
            "file": os.path.relpath(path, PROJECT),
            "line": line,
        }

    def _describe(self, name, value):
        ref = 0
        if _has_children(value):
            ref = len(self.refs) + 1
            self.refs[ref] = value
        return {"name": name, "value": short_repr(value), "type": type(value).__name__, "ref": ref}

    def _scopes(self, index):
        if not 0 <= index < len(self.stack):
            return []
        frame = self.stack[index][0]
        local_vars = [
            (k, v) for k, v in frame.f_locals.items()
            if not (k.startswith("__") and k.endswith("__")) and not k.startswith("__terrarium")  # runtime plumbing
        ]
        if frame.f_globals is frame.f_locals or frame.f_code.co_name == "<module>":
            data = [(k, v) for k, v in local_vars if not isinstance(v, _HIDDEN_GLOBALS)]
            return [{"name": "Variables", "variables": [self._describe(k, v) for k, v in data]}]
        globals_ = [
            (k, v) for k, v in frame.f_globals.items()
            if not k.startswith("_") and not isinstance(v, _HIDDEN_GLOBALS)
        ]
        scopes = [{"name": "Locals", "variables": [self._describe(k, v) for k, v in local_vars]}]
        if globals_:
            scopes.append({"name": "Globals", "variables": [self._describe(k, v) for k, v in globals_]})
        return scopes

    def _evaluate(self, expr, index, context):
        frame = self.stack[index][0]
        if context == "repl":
            run_console(expr, frame.f_globals, frame.f_locals)
            return {}
        try:
            value = eval(compile(expr, "<inspect>", "eval"), frame.f_globals, frame.f_locals)
        except Exception as e:
            return {"error": f"{type(e).__name__}: {e}"}
        return {"value": self._describe(expr, value)}


def run_console(source, globals_, locals_):
    """REPL semantics in a paused frame: show the value of a final expression."""
    try:
        tree = ast.parse(source, "<console>", "exec")
        last = None
        if tree.body and isinstance(tree.body[-1], ast.Expr):
            last = ast.Expression(tree.body.pop().value)
        if tree.body:
            exec(compile(tree, "<console>", "exec"), globals_, locals_)
        if last is not None:
            value = eval(compile(last, "<console>", "eval"), globals_, locals_)
            if value is not None:
                print(repr(value))
    except Exception as e:
        # Hide this function's own frame from the traceback.
        tb = e.__traceback__.tb_next if e.__traceback__ else None
        traceback.print_exception(type(e), e, tb, file=sys.stderr)


debugger = Debugger()


def start(breakpoints_json):
    """Called by the worker right before the program runs.

    The breakpoints came with the run; ask again in case they changed while
    the environment was prepared (an update signal handled then is lost).
    """
    breakpoints = json.loads(breakpoints_json or "{}")
    try:
        command = _call_page({"event": "breakpoints"})
        if command and command.get("op") == "setBreakpoints":
            breakpoints = command["breakpoints"]
    except Exception:
        pass  # not cross-origin isolated: no blocking calls, use what we got
    debugger.set_breakpoints(breakpoints)
    if debugger.breaks:
        debugger.arm()


def finished():
    """The main script returned: later code (UI callbacks) only stops at breakpoints."""
    if debugger.armed:
        debugger.set_continue()


def _on_pause(signum, frame):
    debugger.pause_requested = True
    debugger.break_into(frame, "pause")


def _on_breakpoints(signum, frame):
    command = _call_page({"event": "breakpoints"})
    if not command or command.get("op") != "setBreakpoints":
        return
    debugger.set_breakpoints(command["breakpoints"])
    if debugger.breaks:
        debugger.arm(frame)
    else:
        debugger.restart_events()


def _breakpointhook(*args, **kwargs):
    debugger.break_into(sys._getframe(1), "breakpoint()")


def install(host_sleep=None):
    signal.signal(SIGPAUSE, _on_pause)
    signal.signal(SIGBREAKPOINTS, _on_breakpoints)
    sys.breakpointhook = _breakpointhook
    if host_sleep is not None:
        _install_sleep(host_sleep)


def _install_sleep(host_sleep):
    """time.sleep on top of the worker's Atomics wait (D13).

    Any signal written into the interrupt buffer wakes the wait early. Stop
    raises KeyboardInterrupt at the loop's next check; a breakpoint update just
    sleeps on; Pause ends the sleep so the debugger stops right after it.
    """
    import time

    import pyodide.webloop

    def sleep(seconds):
        if seconds < 0:
            raise ValueError("sleep length must be non-negative")
        deadline = time.monotonic() + seconds
        while True:
            # Signal handlers run on this backward jump, before the check.
            if debugger.pause_requested:
                return
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            host_sleep(remaining)

    time.sleep = pyodide.webloop._orig_sleep = sleep


def post_mortem(selected=0):
    """Inspect the frames of the last uncaught exception (the console's "Inspect"),
    at frame ``selected`` (innermost first; a traceback frame's "debug" index, D45)."""
    exc = getattr(sys, "last_exc", None)
    if exc is None:
        return
    stack = [(frame, line) for frame, line in traceback.walk_tb(exc.__traceback__) if debugger.is_user(frame)]
    stack.reverse()
    if not stack:
        _terrariumhost.status("The error did not happen in your code, so there is nothing to inspect.")
        return
    summary = "".join(traceback.format_exception_only(type(exc), exc)).strip()
    selected = selected if 0 <= selected < len(stack) else 0
    debugger.interact(stack[0][0], "exception", stack=stack, exception=summary, selected=selected)
