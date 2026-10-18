# Debug Me: this program has a bug. Find it with the debugger!
#
# 1. Run it. One of the checks at the bottom fails with an AssertionError.
#    Tap Inspect (the ladybug) under the traceback: the console shows the
#    variables at the moment it failed.
#
# 2. Long-press the line number of the `while` line in find() and set a
#    breakpoint, then run again. The program stops there, before the line
#    runs. Step Over (the first arrow above the console, or F6) and watch
#    low, middle and high in the console. Tap a name in the editor to see
#    its value, or type an expression after >>>, like items[middle].
#
# 3. Found it? Fix it, run again, and all the checks pass. (The answer is
#    at the very bottom of the file.)


def find(items, target):
    """Where target is in the sorted list items, or -1 if it isn't there.

    Binary search: look at the middle of the part that is left, and throw
    away the half that can't have the target in it.
    """
    low, high = 0, len(items) - 1
    while low < high:
        middle = (low + high) // 2
        if items[middle] == target:
            return middle
        if items[middle] < target:
            low = middle + 1
        else:
            high = middle - 1
    return -1


primes = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29]

checks = [  # (what to look for, where it should be found)
    (13, 5),
    (7, 3),
    (29, 9),
    (4, -1),
    (2, 0),
]

for target, expected in checks:
    found = find(primes, target)
    print(f"find({target}) = {found}", "✓" if found == expected else f"✗ (should be {expected})")
    assert found == expected, f"find({target}) gave {found}, not {expected}"

print("All checks pass. Well done!")
































# The answer: when low == high, one item is still left to look at, but
# `while low < high` stops before looking at it. It should be
# `while low <= high`.
