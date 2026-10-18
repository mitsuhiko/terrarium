#!/usr/bin/env node
// UI test driver for the web app in headless Chrome (port 9333).
//
//   node uishot.mjs [--device iphone|iphone-se|ipad|ipad-landscape] [--dark] [--js '<code>'] [--type '<text>'] [--wait ms] <name>
//
// --type sends real key events (CDP Input) to the focused element after --js;
// "\n" presses Enter.
//
// Applies device metrics, touch and color scheme in the same CDP session as the
// evaluation and the screenshot, so the overrides hold. Prints the PNG path.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
// cdp.js reads the port at import time, so set it before importing (never
// touch the shared browser on 9222).
process.env.BROWSER_DEBUG_PORT = "9333";
const { connect } = await import("/Users/mitsuhiko/Development/agent-stuff/skills/web-browser/scripts/cdp.js");

const DEVICES = {
  iphone: { width: 390, height: 844, deviceScaleFactor: 2, mobile: true },
  "iphone-se": { width: 375, height: 667, deviceScaleFactor: 2, mobile: true },
  "iphone-max": { width: 440, height: 956, deviceScaleFactor: 2, mobile: true },
  ipad: { width: 820, height: 1180, deviceScaleFactor: 1.5, mobile: true },
  "ipad-landscape": { width: 1180, height: 820, deviceScaleFactor: 1.5, mobile: true },
};

const args = process.argv.slice(2);
let device = "iphone";
let dark = false;
let js = null;
let wait = 600;
let name = "shot";
let type = null;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--device") device = args[++i];
  else if (args[i] === "--dark") dark = true;
  else if (args[i] === "--js") js = args[++i];
  else if (args[i] === "--wait") wait = Number(args[++i]);
  else if (args[i] === "--type") type = args[++i];
  else name = args[i];
}

const cdp = await connect(5000);
const page = (await cdp.getPages()).at(-1);
const session = await cdp.attachToPage(page.targetId);
const metrics = DEVICES[device];
await cdp.send("Emulation.setDeviceMetricsOverride", metrics, session);
await cdp.send("Emulation.setTouchEmulationEnabled", { enabled: true, maxTouchPoints: 5 }, session);
await cdp.send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: dark ? "dark" : "light" }] }, session);
await new Promise((r) => setTimeout(r, 150));
if (js) {
  const result = await cdp.evaluate(session, `(async () => { for (let i = 0; i < 150 && !window.__app; i++) await new Promise((r) => setTimeout(r, 100)); ${js} })()`);
  if (result !== undefined && result !== null) console.error(String(result));
}
if (type !== null) {
  for (const ch of type.replace(/\\n/g, "\n")) {
    if (ch === "\n") {
      for (const t of ["rawKeyDown", "char", "keyUp"]) {
        await cdp.send("Input.dispatchKeyEvent", { type: t, key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, text: t === "char" ? "\r" : undefined }, session);
      }
    } else {
      await cdp.send("Input.dispatchKeyEvent", { type: "keyDown", text: ch, key: ch, unmodifiedText: ch }, session);
      await cdp.send("Input.dispatchKeyEvent", { type: "keyUp", key: ch }, session);
    }
    await new Promise((r) => setTimeout(r, 40));
  }
}
await new Promise((r) => setTimeout(r, wait));
const data = await cdp.screenshot(session);
const dir = fileURLToPath(new URL("../build/ui", import.meta.url));
mkdirSync(dir, { recursive: true });
const out = join(dir, `${name}-${device}${dark ? "-dark" : ""}-${Date.now()}.png`);
writeFileSync(out, data);
console.log(out);
cdp.close();
