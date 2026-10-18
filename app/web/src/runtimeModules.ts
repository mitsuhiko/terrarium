// The Python modules the runtime adds (web/public/runtime/python/): written
// into every interpreter at boot, and shown to ty so imports of them are
// checked and completed.

/** iOS device access (D40): Pythonista's module names, implemented on the native host. */
export const DEVICE_MODULES = [
  "clipboard", "console", "contacts", "dialogs", "haptics", "keychain", "location", "motion", "notification",
  "photos", "reminders", "sound", "speech",
];

/** Modules programs import. */
export const PUBLIC_MODULES = ["ui", "turtle", ...DEVICE_MODULES];

/** Every file in /lib/terrarium. */
export const RUNTIME_FILES = [
  "_terrarium.py", "_terrarium_debug.py", "_terrarium_notebook.py", "_terrarium_turtle.py", "_terrarium_traceback.py", "_terrarium_procs.py", "_terrarium_warmup.py", "_device.py",
  ...PUBLIC_MODULES.map((m) => `${m}.py`),
];
