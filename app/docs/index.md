# Terrarium Modules

Terrarium runs real Python (CPython, compiled to WebAssembly) on your
iPhone or iPad. Next to the standard library it has modules for building
apps, drawing and using the device. This part of the documentation covers
them, and how programs run in the app.

## Building apps and drawing

- [ui](ui.html): native iOS apps from Python: screens, lists, buttons, text
  fields, navigation, drawing. Components run once; signals update what
  changed.
- [turtle](turtle.html): Python's turtle graphics, drawn in the console.

## Processes

- [Processes](processes.html): `multiprocessing` and `subprocess`: run work
  in several Pythons at once, on several CPU cores.

## Notebooks

- [Notebooks](notebooks.html): Jupyter notebooks (`.ipynb`) and Python
  files with `# %%` cells: run cells one by one, outputs below them,
  magics like `%pip`, and the `IPython.display` module.

## The device

These modules use the names and the API of Pythonista's, so scripts written
for it often run unchanged.

- [clipboard](clipboard.html): copy and paste text and images.
- [console](console.html): alerts, colored output, links, Quick Look,
  "Open in…".
- [dialogs](dialogs.html): ready-made dialogs: lists, forms, text, dates,
  sharing, picking files.
- [haptics](haptics.html): taps and buzzes from the Taptic Engine.
- [keychain](keychain.html): store passwords securely.
- [location](location.html): where the device is, and addresses.
- [motion](motion.html): accelerometer, gyroscope and compass.
- [notification](notification.html): notifications at a time or place.
- [photos](photos.html): the camera and the photo library.
- [sound](sound.html): sound effects, music and recording.
- [speech](speech.html): text to speech and speech recognition.
- [contacts](contacts.html): the address book.
- [reminders](reminders.html): the Reminders app's lists.

Each module asks for permission the first time it needs it. If access is
denied, its functions raise `PermissionError`; you can allow access later
in the Settings app under Terrarium.

## How programs run

**Run** (▶ or ⌘R) runs the file in a fresh interpreter. The program's folder
is its working directory, so `open("data.txt")` reads a file next to it,
and it can import the other modules in that folder. What it writes is on
disk right away.

**Input and output.** `print()` writes to the console; `input()` asks in the
console and waits. Errors show a traceback whose lines open the file at
that line.

**Stop** (⌘.) raises `KeyboardInterrupt` in the program; if it doesn't end
within a second and a half, it is ended. Dialogs a program waits for close.

**Packages.** numpy, pandas, matplotlib, Pillow and many more import
directly (they are downloaded the first time and kept). Other packages come
from PyPI: declare them in a block at the top of the script, as `uv run`
reads it:

```python
# /// script
# dependencies = ["rich"]
# ///
from rich import print
```

**Python versions.** Programs run on Python 3.14 by default. A
`.python-version` file in the folder (or above it) or `requires-python` in
the block above picks another bundled version, like the 3.15 preview. The
⋯ menu shows the version and can pin the folder to one.

**Memory and recursion.** Programs can use about an eighth of the device's
memory together (about 680 MB on an iPhone with 6 GB); past that, Python
raises `MemoryError`, and the console says how much there is. The stack is
smaller than on a computer: plain Python recursion goes 1000 levels deep as
usual (`sys.setrecursionlimit()` raises that), but recursion through code
written in C, like `functools.lru_cache`, `map()`, `__repr__` or `json` of
deeply nested data, can run out after a few hundred levels. Python then
stops with a `RecursionError` that shows where, and the next run starts a
fresh Python. If iOS ever ends Python for using too much memory, the console
keeps what it showed and says so.

**HTTP.** `requests`, `httpx`, `urllib` and `pyodide.http.pyfetch` work for
any site. There are no raw sockets and no threads, but there are
[processes](processes.html).

**Links.** `webbrowser.open(url)` opens web pages in an in-app browser and
other links (like `maps://`) in the app they belong to.

**Help.** `help(json.loads)` in the console opens these docs at that
function, for the standard library and the modules above.

**Notebooks.** A `.ipynb` file, or a `.py` file with `# %%` lines, runs
cell by cell in a kernel that keeps its variables; see
[Notebooks](notebooks.html).

**Markdown.** A `.md` file opens formatted. The pencil button where Run
is edits it, and the eye button shows it formatted again. Its links open other files
in the app (`notes.md#a-heading`, `main.py#L12` for a line), and
`docs:3.14/library/json.html` links open these docs.

**Shortcuts.** A program can get an icon on the Home Screen: "Add to Home
Screen…" in the ⋯ menu shows how, with the "Run Python Program" action in
the Shortcuts app. `terrarium://run?path=Folder/File.py` links run a
program too.
