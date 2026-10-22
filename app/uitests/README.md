# UI stress runs

XCUITest runs that drive the installed app (`../run.sh` installs it) with
real touches and check that it keeps working (D60). They attach by bundle ID;
the app's project has no test target.

```
./run.sh monkey [SEED] [STEPS]   # random taps, seeded; FAST=1 taps during animations, ROTATE=1 rotates (iPad)
./run.sh scenarios [TIMES]       # the wide layout's transitions, repeated (ONLY=split,move,...)
./run.sh dump                    # the hierarchy as XCTest sees it
SIM=<udid> ./run.sh ...          # default: the booted simulator
```

Checks after every step: the app answers a hierarchy snapshot within 4 s,
and editor tabs on screen come with an editor (its web view). Every 15
steps the monkey goes through ⋯ → Settings… → Done to see that taps land.
The app's own checks (Diagnostics: main-thread hangs over 250 ms, a web
view not in its place on screen) are collected from its log. Output is in
`build/out-<run>/`: `log.txt` (every action, timestamped), `anomalies.txt`,
`app.log` and screenshots (both screens on an iPhone Duo; XCUIScreen's are
black there, so `run.sh` takes them with `simctl`).

Notes:
- An iPhone Duo simulator boots closed and nothing headless opens it, and
  XCUIDevice's rotations don't turn its inner screen: run the wide layout on
  an open Duo (DeviceHub) or an iPad, the narrow one on a closed Duo.
- Don't share a simulator with another run: the taps mix.
- A monkey step can leave an example edited (a tap on the key bar);
  `../run.sh --reset` wipes Documents.
