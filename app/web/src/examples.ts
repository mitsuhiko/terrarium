import { fs, join } from "./host";

const EXAMPLES_DIR = "Examples";
const SEEDED_KEY = "terrarium.examples"; // name -> sha256 of the version we wrote

// Earlier bundled versions (sha256). A copy matching one of them was never
// edited, so it may be replaced, e.g. the D14 ui examples after P1.
const PREVIOUS: Record<string, string[]> = {
  "Plot.py": ["e988e219dfe3aec1227905a4940b29e83818b8a6c871c40900bb98ebd985d345"], // before the wider figure
  "Counter App.py": ["31315c9546a3972c997cfe2a6e69cb1ff78a916fab5f040582c451f58ca1192f"],
  "Todo App.py": [
    "8d60cead56a4abf497c78ff36302fbd7c57bee1bbb456843ef896c35e7e6397e",
    "e6e142c03f5bd0ce78fb2a1c3dbe53530be422c17e37a870e735e3caa9936e83", // saved to todos.json
  ],
};

async function sha256(text: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Make the folders above an example in a subfolder ("Adventure/world.py"). */
async function makeParents(path: string) {
  const parts = path.split("/").slice(0, -1);
  for (let i = 1; i <= parts.length; i++) {
    const dir = parts.slice(0, i).join("/");
    if (!(await fs.exists(dir))) await fs.mkdir(dir);
  }
}

/** Copy the bundled examples into Documents/Examples. New examples are added
 * and untouched ones updated; edited or deleted examples are left alone.
 * Names may have folders: "Adventure/Adventure.py". */
export async function seedExamples() {
  const fresh = !(await fs.exists(EXAMPLES_DIR));
  if (fresh) await fs.mkdir(EXAMPLES_DIR);
  let seeded: Record<string, string> = {};
  try {
    // Without the folder (first launch, or Documents was wiped) nothing we
    // remember having written is there any more.
    seeded = fresh ? {} : JSON.parse(localStorage.getItem(SEEDED_KEY) ?? "{}");
  } catch {
    // start over
  }
  const names: string[] = await (await fetch("/examples/index.json")).json();
  for (const name of names) {
    const text = await (await fetch(`/examples/${name.split("/").map(encodeURIComponent).join("/")}`)).text();
    const hash = await sha256(text);
    if (seeded[name] === hash) continue;
    const path = join(EXAMPLES_DIR, name);
    if (await fs.exists(path)) {
      const current = await sha256(await fs.readText(path));
      const untouched = current === hash || current === seeded[name] || PREVIOUS[name]?.includes(current);
      if (!untouched) continue;
      if (current !== hash) await fs.writeText(path, text);
    } else if (!fresh && name in seeded) {
      continue; // the user deleted it
    } else {
      await makeParents(path);
      await fs.writeText(path, text);
    }
    seeded[name] = hash;
  }
  localStorage.setItem(SEEDED_KEY, JSON.stringify(seeded));
}
