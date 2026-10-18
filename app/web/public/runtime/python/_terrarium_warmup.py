"""Warms up a fresh interpreter before it runs a program (D49).

A worker's native stack is small (512 KB), and recursion through C code
(lru_cache, map, __repr__, json, ...) runs out of it long before CPython's own
check, which only measures the linear (Emscripten) stack. Then Pyodide dies
with "Maximum call stack size exceeded".

JSC first runs wasm code with its baseline compiler, whose native frames are
much bigger than those of its optimizing compiler. Running the usual paths
through C code a few hundred times here gets CPython's hot functions
optimized while the worker waits as a spare, which makes the recursion a
program can do before the crash 1.5 to 6 times deeper (spikes/native-stack).
"""

import dataclasses
import functools
import json


def run(rounds=300):
    class A:
        def __init__(self, child):
            self.child = child

        def __repr__(self):
            return "A(%r)" % (self.child,)

        def __str__(self):
            return f"<{self.child}>"

        def __getattr__(self, name):
            return 0

        @property
        def prop(self):
            return 1

    @functools.lru_cache(None)
    def cached(n):
        return 0 if n == 0 else cached(n - 1) + 1

    def mapped(n):
        return 0 if n == 0 else list(map(mapped, [n - 1]))[0] + 1

    def keyed(n):
        return 0 if n == 0 else sorted([n], key=lambda v: keyed(v - 1))[0]

    def delegated(n):
        if n:
            yield from delegated(n - 1)
        else:
            yield 1

    @dataclasses.dataclass
    class D:
        child: object

    for _ in range(rounds):
        x = None
        for _ in range(20):
            x = A(x)
        repr(x)
        str(x)
        x.missing
        x.prop
        cached.cache_clear()
        cached(20)
        mapped(20)
        keyed(20)
        next(delegated(20))
        y = []
        for _ in range(20):
            y = [y]
        repr(y)
        json.loads(json.dumps(y))
        y == [y]
        t = ()
        for _ in range(20):
            t = (t,)
        hash(t)
        a = b = None
        for _ in range(10):
            a = D(a)
            b = D(b)
        a == b
    cached.cache_clear()
