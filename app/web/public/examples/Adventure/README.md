# The Glasshouse

A small text adventure, and an example of a program in several files.
Run [Adventure.py](Adventure.py) and type `help`.

## How it is built

| File | What it does |
|---|---|
| [Adventure.py](Adventure.py) | Reads what you type, picks the command, prints the answer |
| [world.py](world.py) | The rules: the `Game` class with a method per command |
| [rooms.json](rooms.json) | The map, the items and the puzzles, as data |

`Adventure.py` imports the other module with `from world import Game`:
Python finds `world.py` because it is in the same folder as the program.
`world.py` reads `rooms.json` next to itself, with
[pathlib](docs:3.14/library/pathlib.html).

## Make it yours

Add a room to `rooms.json`, for example a cellar under the shed:

```json
"cellar": {
  "name": "Cellar",
  "description": "Cold and dark. Stairs lead up.",
  "exits": {"up": "shed"},
  "items": []
}
```

and an exit to it in the shed: `"exits": {"west": "garden", "down": "cellar"}`.
Then `go down` (or `d`) works, without any change to the code.

Puzzles are entries in `actions`: using an `item` (in a `room`) can
give a new item (`gives`), turn it into another (`replace`), use it up
(`consume`) or win the game (`win`).

Ideas: a lamp that you need in the cellar, a score for each puzzle, or
saving the game with [json](docs:3.14/library/json.html).
