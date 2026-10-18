"""Calls from the device modules (clipboard, dialogs, photos, ...) into the app (D40).

Each call blocks until the app answers, like ``input()``. Files travel as
references: a path in the program's folder (which the app reads and writes
directly) or, for files elsewhere in the interpreter, their bytes.
"""

import base64
import datetime as _dt
import io
import json
import os
import sys

try:
    import _terrariumhost
except ImportError:  # outside the app (tests, a published web app)
    _terrariumhost = None

PROJECT = "/home/pyodide/project"


class DeviceError(RuntimeError):
    """The app could not do what was asked."""


_ERRORS = {
    "PermissionError": PermissionError,
    "ValueError": ValueError,
    "FileNotFoundError": FileNotFoundError,
    "IOError": OSError,
    "OSError": OSError,
    "NotImplementedError": NotImplementedError,
    "KeyError": KeyError,
}


def _default(value):
    if isinstance(value, (_dt.datetime, _dt.date, _dt.time)):
        return value.isoformat()
    if isinstance(value, bytes):
        return base64.b64encode(value).decode("ascii")
    if isinstance(value, (set, tuple)):
        return list(value)
    raise TypeError(f"{type(value).__name__} can't be sent to the app")


def available():
    return _terrariumhost is not None and hasattr(_terrariumhost, "device")


def call(op, **args):
    """Run ``device.<op>`` in the app and return its (JSON) answer."""
    if not available():
        raise NotImplementedError(f"{op.split('.')[0]} needs the Terrarium app")
    sys.stdout.flush()
    sys.stderr.flush()
    request = json.dumps({"op": f"device.{op}", "value": args}, default=_default)
    try:
        reply = _terrariumhost.device(request)
    except (KeyboardInterrupt, SystemExit):
        raise
    except Exception as e:  # a JsException carrying the app's error
        message = str(e).split("\n")[0]
        for prefix in ("Error: ", "error: "):
            if message.startswith(prefix):
                message = message[len(prefix):]
        kind, sep, rest = message.partition(": ")
        if sep and kind in _ERRORS:
            raise _ERRORS[kind](rest) from None
        raise DeviceError(message) from None
    return None if reply is None else json.loads(reply)


# -- files -------------------------------------------------------------------------


def in_project(path):
    """The path relative to the program's folder, or None if it is elsewhere."""
    full = os.path.abspath(os.fspath(path))
    if full == PROJECT:
        return ""
    if full.startswith(PROJECT + "/"):
        return full[len(PROJECT) + 1:]
    return None


def file_ref(path):
    """How the app finds a file it should read."""
    path = os.fspath(path)
    if not os.path.exists(path):
        raise FileNotFoundError(path)
    rel = in_project(path)
    if rel is not None:
        return {"project": rel}
    with open(path, "rb") as f:
        return {"data": base64.b64encode(f.read()).decode("ascii"), "name": os.path.basename(path)}


def target_ref(path):
    """Where the app should write a file: only in the program's folder."""
    rel = in_project(path)
    if rel is None:
        raise ValueError(f"{path}: the app can only write files in the program's folder")
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    return {"project": rel}


def temp_file(data_b64, name):
    """Bytes from the app as a file in the interpreter's temporary folder."""
    import tempfile

    folder = tempfile.mkdtemp(prefix="terrarium-")
    path = os.path.join(folder, os.path.basename(name) or "file")
    with open(path, "wb") as f:
        f.write(base64.b64decode(data_b64))
    return path


# -- images ------------------------------------------------------------------------


def pil_image(data_b64):
    """A PIL image from base64 image data (Pillow is loaded on demand)."""
    if data_b64 is None:
        return None
    raw = base64.b64decode(data_b64)
    try:
        from PIL import Image
    except ImportError:
        # Pillow loads with the program when it imports photos, clipboard or PIL.
        raise ImportError(
            "images need Pillow: add `import PIL` at the top of the program "
            "(this Python may not have it), or ask for raw data (raw_data=True)"
        ) from None
    img = Image.open(io.BytesIO(raw))
    img.load()
    return img


def image_payload(image, format="png", jpeg_quality=0.9):
    """Image data for the app: a PIL image, bytes, or a path."""
    if isinstance(image, (bytes, bytearray)):
        return base64.b64encode(bytes(image)).decode("ascii")
    if isinstance(image, (str, os.PathLike)):
        with open(image, "rb") as f:
            return base64.b64encode(f.read()).decode("ascii")
    if hasattr(image, "save"):  # PIL
        buf = io.BytesIO()
        if format == "jpeg":
            image.convert("RGB").save(buf, "JPEG", quality=int(max(0.0, min(1.0, jpeg_quality)) * 100))
        else:
            image.save(buf, "PNG")
        return base64.b64encode(buf.getvalue()).decode("ascii")
    raise TypeError(f"expected a PIL image, bytes or a file path, not {type(image).__name__}")


def parse_datetime(value):
    if value is None:
        return None
    return _dt.datetime.fromisoformat(value)
