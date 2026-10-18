// Code editor color themes (D39). Each has a light and a dark variant; the
// page follows the app's appearance (prefers-color-scheme, which the host
// sets from Settings: system, light or dark). The colors become CSS
// variables on :root[data-theme=<id>], used by editor.ts's theme and
// highlight style. The default is drawn from the app icon: Python's blue
// and yellow on the icon's navy.

export interface Palette {
  bg: string;
  fg: string;
  gutter: string; // line numbers
  gutterActive: string; // the cursor's line number
  caret: string;
  activeLine: string;
  selection: string;
  bracket: string; // matching bracket
  keyword: string;
  string: string;
  number: string;
  comment: string;
  def: string; // names being defined (def, class)
  call: string; // called functions and methods
  self: string;
  class: string; // class names in use
  meta: string; // decorators
  keywordBold?: boolean;
  commentItalic?: boolean;
}

export interface Theme {
  id: string;
  name: string;
  light: Palette;
  dark: Palette;
}

export const DEFAULT_THEME = "terrarium";

export const THEMES: Theme[] = [
  {
    id: "terrarium",
    name: "Terrarium",
    light: {
      bg: "#fbfcfe", fg: "#1b2433", gutter: "#a3adbf", gutterActive: "#3776ab", caret: "#3776ab",
      activeLine: "rgba(255, 212, 59, 0.14)", selection: "rgba(55, 118, 171, 0.22)", bracket: "rgba(255, 212, 59, 0.5)",
      keyword: "#1f4f8f", string: "#a35d00", number: "#c2410c", comment: "#7b879b", def: "#3776ab", call: "#2f6690",
      self: "#8a5a00", class: "#1f6fb8", meta: "#b07d00", keywordBold: true, commentItalic: true,
    },
    dark: {
      bg: "#121a2b", fg: "#dfe6f2", gutter: "#4b5878", gutterActive: "#ffd43b", caret: "#ffd43b",
      activeLine: "rgba(63, 120, 196, 0.14)", selection: "rgba(74, 143, 208, 0.38)", bracket: "rgba(255, 212, 59, 0.28)",
      keyword: "#ffd43b", string: "#f2a65a", number: "#ff8f70", comment: "#6c7a96", def: "#6fb3ff", call: "#9cc8f5",
      self: "#ffe36e", class: "#57b9ff", meta: "#ffcf6b", keywordBold: true, commentItalic: true,
    },
  },
  {
    id: "xcode",
    name: "Xcode",
    light: {
      bg: "#ffffff", fg: "#000000", gutter: "rgba(60, 60, 67, 0.3)", gutterActive: "rgba(60, 60, 67, 0.6)", caret: "#007aff",
      activeLine: "rgba(0, 122, 255, 0.045)", selection: "rgba(0, 122, 255, 0.22)", bracket: "rgba(0, 122, 255, 0.16)",
      keyword: "#ad3da4", string: "#c41a16", number: "#1c00cf", comment: "#707f8c", def: "#0f68a0", call: "#326d74",
      self: "#ad3da4", class: "#0b4f79", meta: "#643820", keywordBold: true, commentItalic: true,
    },
    dark: {
      bg: "#1f1f24", fg: "#ffffff", gutter: "rgba(235, 235, 245, 0.3)", gutterActive: "rgba(235, 235, 245, 0.6)", caret: "#0a84ff",
      activeLine: "rgba(255, 255, 255, 0.04)", selection: "rgba(10, 132, 255, 0.35)", bracket: "rgba(10, 132, 255, 0.3)",
      keyword: "#fc5fa3", string: "#fc6a5d", number: "#d0bf69", comment: "#7f8c98", def: "#41a1c0", call: "#67b7a4",
      self: "#fc5fa3", class: "#5dd8ff", meta: "#fd8f3f", keywordBold: true, commentItalic: true,
    },
  },
  {
    id: "github",
    name: "GitHub",
    light: {
      bg: "#ffffff", fg: "#1f2328", gutter: "#8c959f", gutterActive: "#1f2328", caret: "#0969da",
      activeLine: "rgba(234, 238, 242, 0.6)", selection: "rgba(84, 174, 255, 0.3)", bracket: "rgba(74, 194, 107, 0.25)",
      keyword: "#cf222e", string: "#0a3069", number: "#0550ae", comment: "#6e7781", def: "#8250df", call: "#8250df",
      self: "#953800", class: "#953800", meta: "#8250df",
    },
    dark: {
      bg: "#0d1117", fg: "#e6edf3", gutter: "#6e7681", gutterActive: "#e6edf3", caret: "#58a6ff",
      activeLine: "rgba(110, 118, 129, 0.1)", selection: "rgba(56, 139, 253, 0.35)", bracket: "rgba(63, 185, 80, 0.3)",
      keyword: "#ff7b72", string: "#a5d6ff", number: "#79c0ff", comment: "#8b949e", def: "#d2a8ff", call: "#d2a8ff",
      self: "#ffa657", class: "#ffa657", meta: "#d2a8ff",
    },
  },
  {
    id: "solarized",
    name: "Solarized",
    light: {
      bg: "#fdf6e3", fg: "#657b83", gutter: "#93a1a1", gutterActive: "#586e75", caret: "#268bd2",
      activeLine: "#eee8d5", selection: "rgba(147, 161, 161, 0.3)", bracket: "rgba(181, 137, 0, 0.25)",
      keyword: "#859900", string: "#2aa198", number: "#d33682", comment: "#93a1a1", def: "#268bd2", call: "#268bd2",
      self: "#b58900", class: "#cb4b16", meta: "#6c71c4", commentItalic: true,
    },
    dark: {
      bg: "#002b36", fg: "#839496", gutter: "#586e75", gutterActive: "#93a1a1", caret: "#268bd2",
      activeLine: "#073642", selection: "rgba(88, 110, 117, 0.45)", bracket: "rgba(181, 137, 0, 0.3)",
      keyword: "#859900", string: "#2aa198", number: "#d33682", comment: "#586e75", def: "#268bd2", call: "#268bd2",
      self: "#b58900", class: "#cb4b16", meta: "#6c71c4", commentItalic: true,
    },
  },
  {
    id: "one",
    name: "One",
    light: {
      bg: "#fafafa", fg: "#383a42", gutter: "#9d9d9f", gutterActive: "#383a42", caret: "#526fff",
      activeLine: "rgba(56, 58, 66, 0.04)", selection: "rgba(64, 120, 242, 0.18)", bracket: "rgba(64, 120, 242, 0.18)",
      keyword: "#a626a4", string: "#50a14f", number: "#986801", comment: "#a0a1a7", def: "#4078f2", call: "#4078f2",
      self: "#e45649", class: "#c18401", meta: "#0184bc", commentItalic: true,
    },
    dark: {
      bg: "#282c34", fg: "#abb2bf", gutter: "#4b5263", gutterActive: "#abb2bf", caret: "#528bff",
      activeLine: "#2c313c", selection: "#3e4451", bracket: "rgba(97, 175, 239, 0.25)",
      keyword: "#c678dd", string: "#98c379", number: "#d19a66", comment: "#5c6370", def: "#61afef", call: "#61afef",
      self: "#e06c75", class: "#e5c07b", meta: "#56b6c2", commentItalic: true,
    },
  },
];

export const themeFor = (id: string) => THEMES.find((t) => t.id === id) ?? THEMES.find((t) => t.id === DEFAULT_THEME)!;

function variables(p: Palette): string {
  const vars: Record<string, string> = {
    "editor-bg": p.bg, "editor-fg": p.fg, gutter: p.gutter, "gutter-active": p.gutterActive, caret: p.caret,
    "active-line": p.activeLine, selection: p.selection, "bracket-match": p.bracket,
    "syn-keyword": p.keyword, "syn-string": p.string, "syn-number": p.number, "syn-comment": p.comment,
    "syn-def": p.def, "syn-call": p.call, "syn-self": p.self, "syn-class": p.class, "syn-meta": p.meta,
    "syn-keyword-weight": p.keywordBold ? "600" : "normal", "syn-comment-style": p.commentItalic ? "italic" : "normal",
  };
  return Object.entries(vars).map(([k, v]) => `--${k}: ${v};`).join(" ");
}

/** The themes as CSS (installed once by the editor page). */
export function themeCSS(): string {
  return THEMES.map((t) =>
    `:root[data-theme="${t.id}"] { ${variables(t.light)} }\n` +
    `@media (prefers-color-scheme: dark) { :root[data-theme="${t.id}"] { ${variables(t.dark)} } }`,
  ).join("\n");
}

export function installThemes() {
  const style = document.createElement("style");
  style.textContent = themeCSS();
  document.head.append(style);
}
