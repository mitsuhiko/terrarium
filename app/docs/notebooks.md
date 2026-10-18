# Notebooks

A notebook mixes notes and code in **cells**. You run cells one at a time
and see each cell's output right below it: values, printed text, plots,
tables. Everything a cell defines stays around for the cells after it,
because they all run in one Python, the notebook's *kernel*.

Terrarium opens Jupyter notebooks (`.ipynb` files, as Jupyter, JupyterLab,
Google Colab and VS Code write them) and Python files with cells.

## Two kinds of notebooks

**Jupyter notebooks** (`.ipynb`) show as cells with a ▶ button each, a
toolbar (Run All, Restart, Clear) and the outputs saved in the file. A
Markdown cell shows formatted; tap it to edit it. The cell you are in has
buttons to make it a code or Markdown cell, move it, add a cell below it and
delete it. "Show JSON Source" in the ⋯ menu shows the file as it is, and
"Show as Notebook" goes back. New File → Notebook makes one.

**Python files with cells** use the percent format that VS Code, Spyder and
jupytext read: a line `# %%` starts a code cell, `# %% [markdown]` a
Markdown cell (written as comments). Each `# %%` line gets a ▶ button and
the cell's output shows below it. The file stays a normal script: Run (▶
in the bar) runs all of it in a fresh interpreter, as always. The outputs
are not saved in the file.

```python
# %%
import random
rolls = [random.randint(1, 6) for _ in range(1000)]

# %% [markdown]
# ## How often did each face come up?

# %%
from collections import Counter
Counter(rolls)
```

## Running cells

- **▶** on a cell, or **Shift-Return** with a keyboard: run the cell and go
  to the next one (in a `.ipynb`, the last cell gets a new one after it).
  **⌘-Return** runs the cell and stays.
- **Run All** (the toolbar, ▶ in the bar, ⌘R) runs every cell from the top.
  An error stops it there.
- The ⋯ menu also has Run Cells Above and Run Cell and Below.
- **Stop** (⌘. or the cell's ■) raises `KeyboardInterrupt` in the cell. If
  the cell doesn't stop within a second and a half, the kernel is ended.
- **Restart** ends the kernel: its variables and imports are gone, and the
  next cell starts a new one.

The number next to a cell, like `[3]`, counts the cells run in this kernel;
`[*]` means it is running.

One program runs at a time: running a script ends a notebook's kernel, and
running a cell ends a program that was running. The console's `>>>` runs in
the notebook's kernel while it lives.

## Output

- The value of a cell's last line shows below it. End the line with `;` to
  hide it.
- `print()` and errors show below the cell. `input()` asks with a dialog.
- Figures show at the end of the cell, without `plt.show()`.
- Objects show their richest form: pandas tables, Markdown, HTML, images
  (anything with `_repr_html_`, `_repr_png_`, `_repr_markdown_`,
  `_repr_svg_` or `_repr_mimebundle_`, as in Jupyter).
- `display()` shows more than one thing from a cell; it is there without an
  import, as in Jupyter.

HTML with scripts (Plotly, Bokeh and other interactive charts) runs in a
sealed frame: it can't reach the app or your files. Interactive widgets
(ipywidgets) are not supported yet, and turtle graphics draw in the
console.

## Magics

Notebooks often use IPython's `%` commands. These work:

- `%pip install <packages>` (also `!pip install`): install from PyPI; `%pip list`, `%pip uninstall`.
- `%time <statement>` and `%%time` (the first line of a cell): how long it took.
- `%timeit <statement>` and `%%timeit`: run it many times and report the average.
- `%run file.py`: run a script; what it defines lands in the notebook.
- `%cd`, `%pwd`, `%ls`, `%env`, `%who`, `%whos`, `%reset -f`.
- `%%html`, `%%markdown`, `%%svg`, `%%latex`: the cell's text as that.
- `%%writefile <name>` (with `-a` to append): the cell's text into a file.
- `name?` shows help for a name, `name??` its source.
- `%matplotlib inline`, `%load_ext`, `%config` and `%autoreload` are accepted and do nothing.

There is no shell on iOS: `!ls` and `%%bash` explain that instead of running.

## Files and packages

A notebook's folder is its working directory, as for scripts: `open()` reads
the files next to it and it can import the modules in its folder. Packages
come in with `%pip install` or a `# /// script` block in a cell (read when
the kernel starts); numpy, pandas and matplotlib import directly. The
Python version follows the folder (`.python-version`) or Settings.

## The IPython module

`from IPython.display import ...` works: the app has its own small `IPython`
module with what notebooks use for output. It is not IPython itself.

### IPython.display.display(*objs, include=None, exclude=None, metadata=None, display_id=None, raw=False, clear=False)

Show each object below the cell with its richest representation. With
`display_id=True` it returns a `DisplayHandle` whose `update(obj)` replaces
what was shown, wherever it is. In a script, `display()` prints the text
form (images go to the console).

### IPython.display.clear_output(wait=False)

Clear the cell's output; with `wait=True` only when the next output comes,
which avoids flicker in loops that redraw.

### IPython.display.update_display(obj, display_id)

Replace what `display(..., display_id=...)` showed.

### class IPython.display.HTML(data=None, url=None, filename=None)

HTML to show: a string, a file or a URL.

### class IPython.display.Markdown(data=None, url=None, filename=None)

Markdown to show formatted.

### class IPython.display.Image(data=None, url=None, filename=None, format=None, embed=None, width=None, height=None)

A PNG, JPEG or GIF: bytes, a file or a URL. `width` and `height` are in
points.

### class IPython.display.SVG(data=None, url=None, filename=None)

An SVG drawing.

### class IPython.display.JSON(data=None, url=None, filename=None)

Data shown as formatted JSON.

### class IPython.display.Latex(data=None, url=None, filename=None)

LaTeX; shown as its source, as there is no math renderer yet.

### class IPython.display.IFrame(src, width, height)

A web page in a frame.

### IPython.get_ipython()

The notebook's shell object. It runs magics with
`get_ipython().run_line_magic(name, line)`; code that looks for IPython
finds it.
