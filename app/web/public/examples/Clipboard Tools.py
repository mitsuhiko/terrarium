# Clipboard Tools: copy some text in any app, run this, pick a tool, and
# paste the result back.
#
# Tip: this is a good one for the Home Screen. In the ⋯ menu, "Add to Home
# Screen…" shows how to start it with one tap.
#
# Every tool is a plain function from text to text: add your own to TOOLS.
import base64
import json
import re
import unicodedata
import urllib.parse

import clipboard
import console
import dialogs


def stats(text):
    words = len(text.split())
    lines = text.count("\n") + 1 if text else 0
    minutes = max(1, round(words / 230))
    console.alert("Text statistics",
                  f"{len(text):,} characters\n{words:,} words\n{lines:,} lines\nAbout {minutes} min to read",
                  "OK", hide_cancel_button=True)
    # No return: None means there is nothing to copy.


def slug(text):
    ascii_text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", ascii_text.lower()).strip("-")


def unique_lines(text):
    return "\n".join(dict.fromkeys(text.splitlines()))  # dicts keep the first of each, in order


def find_all(pattern):
    return lambda text: "\n".join(dict.fromkeys(re.findall(pattern, text))) or None


TOOLS = {
    "Count words": stats,
    "UPPERCASE": str.upper,
    "lowercase": str.lower,
    "Title Case": str.title,
    "Sort lines": lambda text: "\n".join(sorted(text.splitlines(), key=str.casefold)),
    "Remove duplicate lines": unique_lines,
    "Reverse lines": lambda text: "\n".join(reversed(text.splitlines())),
    "Trim spaces": lambda text: "\n".join(" ".join(line.split()) for line in text.splitlines()),
    "Pretty JSON": lambda text: json.dumps(json.loads(text), indent=2, ensure_ascii=False),
    "Compact JSON": lambda text: json.dumps(json.loads(text), separators=(",", ":"), ensure_ascii=False),
    "Bulleted list": lambda text: "\n".join(f"- {line.strip()}" for line in text.splitlines() if line.strip()),
    "Find links": find_all(r"https?://[^\s<>\"')\]]+"),
    "Find email addresses": find_all(r"[\w.+-]+@[\w-]+\.[\w.-]+"),
    "URL-encode": urllib.parse.quote,
    "URL-decode": urllib.parse.unquote,
    "Base64-encode": lambda text: base64.b64encode(text.encode()).decode(),
    "Base64-decode": lambda text: base64.b64decode(text.strip()).decode(),
    "Slug (for URLs)": slug,
    "ROT13": lambda text: text.translate(str.maketrans(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
        "NOPQRSTUVWXYZABCDEFGHIJKLMnopqrstuvwxyzabcdefghijklm")),
}


def short(text, limit=60):
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


text = clipboard.get() or ""
if not text:
    console.alert("The clipboard is empty", "Copy some text first, then run this again.", "OK",
                  hide_cancel_button=True)
else:
    print(f"Clipboard: {short(text)}\n")
    name = dialogs.list_dialog(f"“{short(text, 40)}”", list(TOOLS))
    if name:
        try:
            result = TOOLS[name](text)
        except (ValueError, UnicodeDecodeError) as e:  # bad JSON or Base64, for example
            console.alert(name, f"That didn't work: {e}", "OK", hide_cancel_button=True)
        else:
            if result is None and name != "Count words":
                console.hud_alert("Nothing found", "error")
            elif result is not None:
                clipboard.set(result)
                print(f"{name}:\n{result}")
                console.hud_alert("Copied")
