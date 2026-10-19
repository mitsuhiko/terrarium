# Notes for App Review (draft)

Paste into App Store Connect → the version → App Review Information → Notes.
Sign-in is not required (see the end).

---

Terrarium is a Python IDE: the user writes Python and runs it on the device. It is meant for learning and writing programs (guideline 2.5.2's exception for apps that teach, develop or let users test code).

How code runs:
- Python is CPython compiled to WebAssembly (Pyodide). It runs inside WKWebView and is executed only by WebKit's JavaScript engine. The app has no interpreter of its own and loads no native code.
- The only code that runs is code the user writes or opens: their own files, and the examples that come with the app. Downloaded code does not change the app's features or functionality.
- A program can install Python packages from the Python Package Index (pypi.org) or Pyodide's package index. This happens only when the user's program asks for them (an import or a dependency list), and they run in WebKit like the user's code.
- Programs that use the ui module draw native views. Those views only show what the program describes, inside the app.

Things to try (no account needed):
1. Files → Examples → Plot.py → Run (▶). The plot appears in the console. The first time, numpy and matplotlib download.
2. Examples → Todo App.py → Run: an app written in Python with native views. Tap × to end it.
3. Examples → Countdown.py: long-press line number 5 to set a breakpoint, then Run. Step with the buttons in the console's header.
4. Examples → Notebook.ipynb → Run All.
5. ⋯ → Python Docs: the bundled documentation.

Coding agent (optional): ✨ in the editor's title bar. It needs a model provider account of the user's own. Users sign in with a provider (OAuth in a web sheet) or paste an API key. Before the first message goes to a provider, the app asks for permission (guideline 5.1.2(i)). The app sells nothing: there are no in-app purchases, and accounts are the providers'. No demo account is provided: the agent works with the user's own provider account or API key, and everything else in the app works without it. With a key of your own: ✨ → ⋯ → Accounts → API Keys → <provider> → Add Key, then ask "Write a program that prints the first 10 primes and run it."

Device modules (camera, photos, location, motion, microphone, speech, contacts, reminders, notifications) are used only when a program the user writes or runs calls them. Examples → Device Tour.py shows them. Each asks for permission on first use.

The app collects no data and has no accounts of its own.

---

Sign-in information: not required. The agent needs the user's own model
provider account, so there is no test key (2026-10-19).
