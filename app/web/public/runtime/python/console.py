"""The console and simple system services: alerts, colors, links, Quick Look, "Open in…".

    import console
    console.set_color(0.2, 0.6, 1.0)
    print("blue text")
    console.set_color()
    name = console.input_alert("Your name?")
    console.hud_alert(f"Hi {name}!")

The alerts' Cancel button raises KeyboardInterrupt (which ends the program
unless you catch it); pass hide_cancel_button=True to leave it out.
"""

import base64
import os
import sys

from _device import call, file_ref

__all__ = [
    "clear", "set_color", "set_font", "secure_input", "show_image", "alert", "input_alert", "password_alert",
    "login_alert", "hud_alert", "show_activity", "hide_activity", "write_link", "hide_output", "quicklook",
    "open_in", "set_idle_timer_disabled", "is_in_background",
]


def clear():
    """Clear the console's output."""
    call("console.clear")


def set_color(r=None, g=None, b=None):
    """Color for the text printed after this (components 0.0-1.0); no arguments resets it."""
    if r is None:
        sys.stdout.write("\x1b[0m")
    else:
        g = r if g is None else g
        b = r if b is None else b
        rgb = [max(0, min(255, round(float(c) * 255))) for c in (r, g, b)]
        sys.stdout.write("\x1b[38;2;%d;%d;%dm" % tuple(rgb))
    sys.stdout.flush()


def set_font(name=None, size=None):
    """Accepted for compatibility: the console has one monospaced font. A bold name prints bold."""
    bold = bool(name) and "bold" in str(name).lower()
    sys.stdout.write("\x1b[1m" if bold else "\x1b[22m")
    sys.stdout.flush()


def write_link(title, link_url):
    """Print a tappable link."""
    sys.stdout.write("\x1b]8;;%s\x1b\\%s\x1b]8;;\x1b\\" % (link_url, title))
    sys.stdout.flush()


def show_image(image_path):
    """Show an image file (PNG, JPEG, GIF, ...) in the console."""
    import _terrariumhost

    sys.stdout.flush()
    with open(image_path, "rb") as f:
        _terrariumhost.image(base64.b64encode(f.read()).decode("ascii"))


def _cancelled(value):
    if value is None:
        raise KeyboardInterrupt
    return value


def alert(title, message="", button1=None, button2=None, button3=None, hide_cancel_button=False):
    """An alert with up to three buttons; returns 1, 2 or 3 for the button tapped.

    Without buttons it shows OK (returns 1). Cancel raises KeyboardInterrupt.
    """
    buttons = [str(b) for b in (button1, button2, button3) if b is not None] or ["OK"]
    index = call("alert", title=str(title), message=str(message or ""), buttons=buttons, cancel=not hide_cancel_button)
    return _cancelled(index or None)


def input_alert(title, message="", input="", ok_button_title="OK", hide_cancel_button=False):
    """An alert with a text field; returns the text. Cancel raises KeyboardInterrupt."""
    reply = call("input", title=str(title), message=str(message or ""), fields=[{"text": str(input or "")}],
                 ok=str(ok_button_title or "OK"), cancel=not hide_cancel_button)
    return _cancelled(reply)[0]


def password_alert(title, message="", password="", ok_button_title="OK", hide_cancel_button=False):
    """An alert with a hidden text field; returns the text. Cancel raises KeyboardInterrupt."""
    reply = call("input", title=str(title), message=str(message or ""),
                 fields=[{"text": str(password or ""), "secure": True, "placeholder": "Password"}],
                 ok=str(ok_button_title or "OK"), cancel=not hide_cancel_button)
    return _cancelled(reply)[0]


def login_alert(title, message="", login="", password="", ok_button_title="Log In"):
    """An alert with login and password fields; returns (login, password). Cancel raises KeyboardInterrupt."""
    reply = call("input", title=str(title), message=str(message or ""),
                 fields=[{"text": str(login or ""), "placeholder": "Login"},
                         {"text": str(password or ""), "secure": True, "placeholder": "Password"}],
                 ok=str(ok_button_title or "OK"), cancel=True)
    return tuple(_cancelled(reply))


def secure_input(prompt=""):
    """Ask for text without showing it (e.g. a password)."""
    return password_alert(str(prompt or "Input"))


def hud_alert(message, icon="success", duration=1.8):
    """A brief message with a checkmark ('success') or a cross ('error'); returns after duration seconds."""
    call("hud", message=str(message), icon=str(icon), duration=max(0.25, min(5.0, float(duration))))


def show_activity():
    """Show a spinner (hidden again when the program ends)."""
    call("activity", show=True)


def hide_activity():
    """Hide the spinner."""
    call("activity", show=False)


def hide_output():
    """Make room on screen: the console shrinks to its title."""
    call("console.hide")


def quicklook(file_path):
    """Preview files (images, PDF, text, CSV, Office documents, ...) full screen; returns when closed."""
    paths = [file_path] if isinstance(file_path, (str, os.PathLike)) else list(file_path)
    call("quicklook", files=[file_ref(p) for p in paths])


def open_in(file_path):
    """Show the share sheet ("Open in…", AirDrop, Save to Files) for a file.

    Returns the activity that was chosen, or None.
    """
    return call("share", items=[{"file": file_ref(file_path)}])


def set_idle_timer_disabled(flag):
    """Keep the screen on (True) while the app is open, or let it sleep again (False)."""
    call("idleTimer", disabled=bool(flag))


def is_in_background():
    """Whether the app is in the background."""
    return bool(call("background"))
