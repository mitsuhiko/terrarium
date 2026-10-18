// The agent's documentation tools (D37): the Python docs the app bundles, as
// Markdown chunks in an FTS5 index the host searches (DocsIndex.swift). The
// version defaults to the one the project runs on; ide_show_docs (ide.ts)
// opens a result for the user.
import { Type } from "@earendil-works/pi-ai";
import { defineExtension, defineTool } from "@earendil-works/pi-durable";
import { call } from "../host";
import { chooseFor, RUNTIMES } from "../runtimes";
import type { ProjectEnv } from "./env";

export interface DocsHit {
  ref: string; // "library/json.html#json.loads"
  link: string; // "docs:3.14/library/json.html#json.loads"
  title: string;
  kind: string;
  breadcrumb: string;
  snippet: string;
}

export interface DocsPage {
  ref: string;
  title: string;
  markdown: string;
}

const MAX_READ = 16_000;
const text = (t: string) => [{ type: "text" as const, text: t }];
const versions = RUNTIMES.map((r) => r.python);

/** The project's Python, or the one asked for. */
export async function docsVersion(api: { env: unknown }, version?: string): Promise<string> {
  if (version) {
    const wanted = version.trim().replace(/^python\s*/i, "");
    const match = versions.find((v) => wanted === v || wanted.startsWith(`${v}.`));
    if (!match) throw new Error(`No docs for Python ${version}; the app has ${versions.join(" and ")}.`);
    return match;
  }
  const env = api.env as ProjectEnv | undefined;
  const choice = await chooseFor(env ? env.appPath("/") : "");
  return choice.ok ? choice.python : versions[0];
}

const versionParam = Type.Optional(Type.String({ description: `Python version of the docs: ${versions.join(" or ")} (default: the project's)` }));

const searchTool = defineTool({
  name: "docs_search",
  description:
    "Search the documentation of the Python the project runs on: the official Python docs (standard library, language reference, tutorial, HOWTOs, glossary, What's New) " +
    "and the app's own modules (ui, turtle in the app, clipboard, console, dialogs, haptics, keychain, location, motion, notification, photos, sound, speech, contacts, reminders; under terrarium/). " +
    "Finds API entries by name (json.loads, ui.Button, photos.pick_image, sound.Player.play) and sections by words. " +
    "Use it before relying on details you are unsure about, and for anything new in recent Python versions. Read a result with docs_read.",
  parameters: Type.Object({
    query: Type.String({ description: "A name like json.loads, or words" }),
    version: versionParam,
    limit: Type.Optional(Type.Number({ description: "Results to return (default 8, at most 25)" })),
  }),
  async execute(args, api) {
    const version = await docsVersion(api, args.version);
    const hits = await call<DocsHit[]>("docs.search", { query: args.query, version, limit: Math.max(1, Math.min(args.limit ?? 8, 25)) });
    if (!hits.length) return { output: text(`No results for "${args.query}" in the Python ${version} docs.`) };
    const lines = hits.map((h, i) => {
      const where = h.breadcrumb ? ` (${h.breadcrumb})` : "";
      const snippet = h.snippet ? `\n   ${h.snippet.replace(/\s+/g, " ").trim()}` : "";
      return `${i + 1}. [${h.kind}] ${h.title}${where}\n   ref: ${h.ref}${snippet}`;
    });
    return {
      output: text(`Python ${version} docs, ${hits.length} result${hits.length === 1 ? "" : "s"} for "${args.query}":\n\n${lines.join("\n")}`),
      details: { version, hits: hits.map((h) => ({ ref: h.ref, title: h.title })) },
    };
  },
});

const readTool = defineTool({
  name: "docs_read",
  description:
    "Read part of the Python documentation as Markdown: a ref from docs_search (a section with its subsections, or one API entry), or a page path like library/json.html. " +
    "Long sections come in parts: pass offset to continue. To link it in your answer, use a Markdown link to docs:<version>/<ref>, " +
    "e.g. [json.loads](docs:3.14/library/json.html#json.loads); the user can tap it to open the docs.",
  parameters: Type.Object({
    ref: Type.String({ description: "A ref from docs_search, e.g. library/json.html#json.loads" }),
    version: versionParam,
    offset: Type.Optional(Type.Number({ description: "Character offset to continue from" })),
  }),
  async execute(args, api) {
    const version = await docsVersion(api, args.version);
    const ref = args.ref.replace(/^docs:[\d.]+\//, "").replace(/^\/+/, "");
    const page = await call<DocsPage | null>("docs.read", { ref, version });
    if (!page) return { output: text(`No such docs section: ${ref} (Python ${version}). Use docs_search to find refs.`), isError: true };
    const offset = Math.max(0, Math.floor(args.offset ?? 0));
    const part = page.markdown.slice(offset, offset + MAX_READ);
    const end = offset + part.length;
    const more = end < page.markdown.length ? `\n\n[… ${page.markdown.length - end} more characters: docs_read with offset ${end}]` : "";
    return {
      output: text(`Python ${version} docs: ${page.title} (docs:${version}/${page.ref})\n\n${part}${more}`),
      details: { version, ref: page.ref },
    };
  },
});

export const DocsTools = defineExtension({
  name: "terrarium-docs",
  tools: [searchTool, readTool],
});
