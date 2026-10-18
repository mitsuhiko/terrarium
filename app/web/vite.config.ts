import { createReadStream, existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { defineConfig, type Plugin } from "vite";

// The bundled Pythons (D37): /pyodide/<python>/ and /docs/<python>/ from vendor/, /pkgs/<python>/ from the CDN.
const RUNTIMES: { python: string; pyodide: string; cdn: string }[] = JSON.parse(
  readFileSync(join(import.meta.dirname, "..", "runtimes.json"), "utf8"),
).runtimes;
const VENDOR = join(import.meta.dirname, "..", "vendor");

const HOP_HEADERS = new Set(["host", "origin", "referer", "connection", "content-length", "accept-encoding", "x-pyslop-headers", "cookie"]);
const DROPPED = new Set(["content-encoding", "content-length", "transfer-encoding", "connection", "keep-alive", "cross-origin-opener-policy", "cross-origin-embedder-policy", "cross-origin-resource-policy"]);

async function proxyHttp(req: import("node:http").IncomingMessage, res: import("node:http").ServerResponse) {
  const target = new URL(req.url!, "http://x").searchParams.get("url");
  if (!target || !/^https?:/.test(target)) {
    res.statusCode = 400;
    return res.end("bad proxy request");
  }
  const headers: Record<string, string> = {};
  for (const [name, value] of Object.entries(req.headers)) {
    if (!HOP_HEADERS.has(name) && !name.startsWith("sec-") && typeof value === "string") headers[name] = value;
  }
  const hidden = req.headers["x-pyslop-headers"];
  if (typeof hidden === "string") for (const [name, value] of Object.entries(JSON.parse(hidden))) headers[name.toLowerCase()] = String(value);
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  try {
    const r = await fetch(target, { method: req.method, headers, body: chunks.length ? Buffer.concat(chunks) : undefined, redirect: "follow" });
    res.statusCode = r.status;
    r.headers.forEach((value, name) => !DROPPED.has(name) && res.setHeader(name, value));
    res.setHeader("X-Pyslop-Final-Url", r.url);
    res.end(Buffer.from(await r.arrayBuffer()));
  } catch (e) {
    const message = String((e as Error).cause ?? e).replace(/\n/g, " ");
    res.statusCode = 502;
    res.setHeader("X-Pyslop-Error", message);
    res.end(message);
  }
}

// Mirrors the iOS host for `npm run dev`: cross-origin isolation headers on
// everything, /pyodide/ and /docs/ from vendor/, /pkgs/ proxied to the CDN.
function hostShim(): Plugin {
  return {
    name: "terrarium-host-shim",
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        res.setHeader("Cross-Origin-Opener-Policy", "same-origin");
        res.setHeader("Cross-Origin-Embedder-Policy", "require-corp");
        res.setHeader("Cross-Origin-Resource-Policy", "same-origin");
        const url = req.url?.split("?")[0] ?? "";
        const local = /^\/(pyodide|docs)\/([\d.]+)\/(.*)$/.exec(url);
        const runtime = local && RUNTIMES.find((r) => r.python === local[2]);
        if (local && runtime) {
          const dir = local[1] === "pyodide" ? join(VENDOR, `pyodide-${runtime.pyodide}`) : join(VENDOR, `docs-${runtime.python}`, "html");
          const file = join(dir, local[3]);
          if (existsSync(file) && statSync(file).isFile()) {
            const type = file.endsWith(".wasm") ? "application/wasm" : file.endsWith("js") ? "text/javascript" : file.endsWith(".html") ? "text/html" : file.endsWith(".css") ? "text/css" : "application/octet-stream";
            res.setHeader("Content-Type", type);
            createReadStream(file).pipe(res);
            return;
          }
        }
        const pkg = /^\/pkgs\/([\d.]+)\/(.+)$/.exec(url);
        const pkgRuntime = pkg && RUNTIMES.find((r) => r.python === pkg[1]);
        if (pkg && pkgRuntime) {
          fetch(pkgRuntime.cdn + pkg[2])
            .then(async (r) => {
              res.statusCode = r.status;
              res.end(Buffer.from(await r.arrayBuffer()));
            })
            .catch((e) => { res.statusCode = 502; res.end(String(e)); });
          return;
        }
        if (url.startsWith("/pypi/simple/")) {
          // Same contract as the iOS host: Simple JSON API with file URLs pointing back here.
          const project = url.slice("/pypi/simple/".length).replace(/\/$/, "");
          fetch(`https://pypi.org/simple/${project}/`, { headers: { Accept: "application/vnd.pypi.simple.v1+json" } })
            .then(async (r) => {
              const body = (await r.text()).replaceAll("https://files.pythonhosted.org/", "/pypi-files/");
              res.statusCode = r.status;
              res.setHeader("Content-Type", "application/vnd.pypi.simple.v1+json");
              res.end(body);
            })
            .catch((e) => { res.statusCode = 502; res.end(String(e)); });
          return;
        }
        if (url === "/__http") {
          // HTTP for Python programs, same contract as the iOS host (D25).
          void proxyHttp(req, res);
          return;
        }
        if (url.startsWith("/pypi-files/")) {
          fetch(`https://files.pythonhosted.org/${url.slice("/pypi-files/".length)}`)
            .then(async (r) => {
              res.statusCode = r.status;
              res.end(Buffer.from(await r.arrayBuffer()));
            })
            .catch((e) => { res.statusCode = 502; res.end(String(e)); });
          return;
        }
        next();
      });
    },
  };
}

// Acknowledgements (Settings → Acknowledgements): licenses.json in dist, the
// npm packages that end up in the bundle (both pages and their workers) with
// their license texts, after what the bundle carries from outside npm
// (licenses-extra.json: Pyodide, CPython, Emscripten).
const bundledPackages = new Map<string, { name: string; version: string; license: string; dir: string; homepage?: string }>();
const packageDirs = new Map<string, string | null>();

function packageOf(file: string): string | null {
  const dir = dirname(file);
  if (packageDirs.has(dir)) return packageDirs.get(dir)!;
  let found: string | null = null;
  const manifest = join(dir, "package.json");
  if (existsSync(manifest)) {
    // Nested package.json files ({"type": "module"}) have no name.
    const pkg = JSON.parse(readFileSync(manifest, "utf8"));
    found = pkg.name && pkg.version ? dir : null;
  }
  if (!found && dirname(dir) !== dir) found = packageOf(dir);
  packageDirs.set(dir, found);
  return found;
}

const MIT = `Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.`;

// Packages without a license file that share another package's (ty is built from ruff's repository).
const LICENSE_FROM: Record<string, string> = { ty_wasm: "@astral-sh/ruff-wasm-web" };

function licenseText(dir: string): string | null {
  const file = readdirSync(dir).find((f) => /^(licen[cs]e|copying)(\.(md|txt|markdown))?$/i.test(f));
  return file ? readFileSync(join(dir, file), "utf8").trim() : null;
}

function licenses(emit: boolean): Plugin {
  return {
    name: "terrarium-licenses",
    apply: "build",
    generateBundle(_, bundle) {
      for (const out of Object.values(bundle)) {
        if (out.type !== "chunk") continue;
        for (const id of Object.keys(out.modules)) {
          const file = id.replace(/^\0/, "").split("?")[0];
          if (!file.startsWith("/") || !existsSync(file)) continue;
          const dir = packageOf(file);
          if (!dir || dir === import.meta.dirname) continue;
          const pkg = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
          const homepage = typeof pkg.repository === "string" ? pkg.repository : (pkg.repository?.url ?? pkg.homepage);
          bundledPackages.set(pkg.name, { name: pkg.name, version: pkg.version, license: pkg.license ?? "see text", dir, homepage });
        }
      }
      if (!emit) return;
      const extra = JSON.parse(readFileSync(join(import.meta.dirname, "licenses-extra.json"), "utf8"));
      const builtIn = extra.map((e: Record<string, string>) => {
        // Pyodide: one entry per bundled core (runtimes.json).
        if (e.name !== "Pyodide") return e;
        return { ...e, version: RUNTIMES.map((r) => r.pyodide).join(", ") };
      });
      const packages = [...bundledPackages.values()]
        .sort((a, b) => a.name.localeCompare(b.name))
        .map((p) => {
          let text = licenseText(p.dir);
          const from = LICENSE_FROM[p.name] && bundledPackages.get(LICENSE_FROM[p.name]);
          if (!text && from) text = licenseText(from.dir);
          if (!text && p.license === "MIT") text = `MIT License\n\n${MIT}`;
          if (!text) this.warn(`no license text for ${p.name}@${p.version} (${p.license})`);
          const url = p.homepage
            ?.replace(/^git\+/, "")
            .replace(/^git:\/\//, "https://")
            .replace(/^(github:)?([\w.-]+\/[\w.-]+)$/, "https://github.com/$2")
            .replace(/\.git$/, "");
          return { name: p.name, version: p.version, license: p.license, url: url?.startsWith("http") ? url : undefined, text: text ?? "" };
        });
      this.emitFile({ type: "asset", fileName: "licenses.json", source: JSON.stringify({ builtIn, packages }) });
    },
  };
}

const PI_AI = join(import.meta.dirname, "node_modules/@earendil-works/pi-ai/dist");

export default defineConfig({
  plugins: [hostShim(), licenses(true)],
  // Worker bundles are built before the pages' bundle is written: their packages are in licenses.json too.
  worker: { plugins: () => [licenses(false)] },
  base: "/",
  resolve: {
    alias: [
      // The agent's sign-in flows (D33): pi-ai loads them through an import()
      // bundlers can't follow, and they are not in its exports; we import
      // them directly and register them like pi-ai's Bun build does.
      { find: /^@oauth\/(.*)$/, replacement: `${PI_AI}/auth/oauth/$1` },
      // Two flows import Node built-ins: the loopback callback server (on the
      // host's listener) and randomBytes.
      { find: "node:http", replacement: join(import.meta.dirname, "src/agent/shims/http.ts") },
      { find: "node:crypto", replacement: join(import.meta.dirname, "src/agent/shims/crypto.ts") },
    ],
  },
  // Two pages, no UI framework (D31): the engine (Python + analysis, no UI)
  // and the editor (one CodeMirror pane). Everything else is native.
  build: {
    outDir: "dist",
    target: "es2023",
    sourcemap: true,
    rollupOptions: { input: { engine: join(import.meta.dirname, "engine.html"), editor: join(import.meta.dirname, "editor.html") } },
  },
});
