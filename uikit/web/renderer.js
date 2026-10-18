// Page side of ui.py: applies the op stream that Python sends and reports
// events back. Python owns the element tree; this file only keeps a map from
// element id to DOM node and knows how to build and update each element type.
//
//   const r = new UIRenderer(rootElement, (id, argsJson) => worker.send(id, argsJson));
//   worker.onUIRender = (json) => r.render(json);
//
// Messages: {seq, ops: [...]}. Ops:
//   ["mount", parentId, beforeId|null, {i, t, p, c}]   build a subtree, insert it
//   ["move", parentId, id, beforeId|null]                reorder
//   ["unmount", id]                                      remove (and forget the subtree)
//   ["set", id, {prop: value}]                           update props
//   ["call", id, method, args]                           focus(), blur(), ...
//   ["config", {theme, tint, title, close_button}]  ["dialog", n, spec]
//   ["toast", text, seconds]  ["frame", canvasId]  ["reset"]
//   ["close"]                                            ui.close(): the app ends
// close_button is for the app's native renderer (a page has nothing to close);
// here "close" calls onClose, which clears the view unless the page replaces it.
// Events go back as sendEvent("<id>:<event>", JSON args). A new renderer asks
// for a full snapshot ("0:resync"), so it can attach to a running app.
//
// This renderer is what published web apps use; inside the Terrarium app the
// same op stream drives native SwiftUI views (app/ios/Sources/UIRenderer).
// Modifiers arrive as plain values (points, color names) and become CSS here.

const SVG_NS = "http://www.w3.org/2000/svg";

export class UIRenderer {
  constructor(root, sendEvent, { resync = true } = {}) {
    this.root = root;
    this.sendEvent = sendEvent;
    this.onRendered = () => {};
    this.onClose = () => this.clear();
    root.classList.add("ui-root");
    this.content = h("div", "ui-content");
    this.layer = h("div", "ui-layer");
    root.replaceChildren(this.content, this.layer);
    this.reset();
    if (resync) sendEvent("0:resync", "[]");
  }

  reset() {
    for (const el of this.nodes?.values() ?? []) BUILDERS[el.__t]?.unmount?.(el, this);
    Object.assign(this.content, { __uid: 0, __t: "#root", __p: {} });
    this.content.replaceChildren();
    this.layer.querySelectorAll(".ui-sheet-backdrop").forEach((n) => n.remove());
    this.nodes = new Map([[0, this.content]]);
  }

  /** Apply one message from Python (a JSON string or an object). */
  render(message) {
    const t0 = performance.now();
    const msg = typeof message === "string" ? JSON.parse(message) : message;
    for (const op of msg.ops ?? []) {
      try {
        this.apply(op);
      } catch (e) {
        console.error("ui: op failed", op, e);
      }
    }
    this.onRendered(msg.seq, { domMs: performance.now() - t0, ops: msg.ops?.length ?? 0, bytes: message.length ?? 0 });
  }

  clear() {
    this.reset();
    this.layer.replaceChildren();
  }

  /** Send an event for element el (ignored once el is gone). */
  emit(el, event, ...args) {
    if (el.__uid === undefined || this.nodes.get(el.__uid) !== el) return;
    this.sendEvent(`${el.__uid}:${event}`, JSON.stringify(args));
  }

  apply(op) {
    switch (op[0]) {
      case "mount": {
        const parent = this.nodes.get(op[1]);
        if (!parent) return;
        this.insert(parent, this.build(op[3]), op[2] == null ? null : this.nodes.get(op[2]) ?? null, false);
        break;
      }
      case "move": {
        const parent = this.nodes.get(op[1]);
        const el = this.nodes.get(op[2]);
        if (parent && el) this.insert(parent, el, op[3] == null ? null : this.nodes.get(op[3]) ?? null, false, true);
        break;
      }
      case "unmount": {
        const el = this.nodes.get(op[1]);
        if (!el) return;
        const parent = el.__parent;
        this.forget(el);
        const b = BUILDERS[parent?.__t];
        if (b?.remove) b.remove(parent, el, this);
        else el.remove();
        b?.changed?.(parent, this);
        break;
      }
      case "set": {
        const el = this.nodes.get(op[1]);
        if (!el) return;
        for (const k in op[2]) this.setProp(el, k, op[2][k]);
        BUILDERS[el.__t]?.updated?.(el, this);
        break;
      }
      case "call": {
        const el = this.nodes.get(op[1]);
        if (!el) return;
        const b = BUILDERS[el.__t];
        if (b?.call) b.call(el, op[2], op[3], this);
        else {
          const target = el.__input ?? el;
          target[op[2]]?.(...(op[3] ?? []));
        }
        break;
      }
      case "config":
        this.configure(op[1] ?? {});
        break;
      case "dialog":
        showDialog(this, op[1], op[2]);
        break;
      case "toast":
        showToast(this, op[1], op[2]);
        break;
      case "frame":
        this.nodes.get(op[1])?.__frameAck?.();
        break;
      case "reset":
        this.reset();
        break;
      case "close":
        this.onClose();
        break;
    }
  }

  configure({ theme, tint, title }) {
    if (theme === "light" || theme === "dark") this.root.dataset.theme = theme;
    else delete this.root.dataset.theme;
    if (tint) this.root.style.setProperty("--tint", cssColor(tint));
    else this.root.style.removeProperty("--tint");
    this.title = title ?? null;
  }

  build(tree) {
    const b = BUILDERS[tree.t] ?? UNKNOWN;
    const el = b.create(this, tree);
    el.__uid = tree.i;
    el.__t = tree.t;
    el.__p = {};
    this.nodes.set(tree.i, el);
    const p = tree.p;
    if (p) for (const k in p) this.setProp(el, k, p[k]);
    if (tree.c) for (const c of tree.c) this.insert(el, this.build(c), null, true);
    b.ready?.(el, this);
    return el;
  }

  insert(parent, el, before, initial, moving = false) {
    el.__parent = parent;
    const b = BUILDERS[parent.__t];
    if (b?.insert) b.insert(parent, el, before, this, initial);
    else {
      const host = parent.__host ?? parent;
      host.insertBefore(el, before && before.parentNode === host ? before : null);
    }
    if (!initial && !moving) b?.changed?.(parent, this);
  }

  forget(el) {
    const walk = (n) => {
      if (n.__uid !== undefined && this.nodes.get(n.__uid) === n) {
        this.nodes.delete(n.__uid);
        BUILDERS[n.__t]?.unmount?.(n, this);
      }
      for (const c of n.childNodes) walk(c);
      if (n.__portal) walk(n.__portal);
    };
    walk(el);
  }

  setProp(el, k, v) {
    const old = el.__p[k];
    el.__p[k] = v;
    if (k in MODIFIERS) {
      MODIFIERS[k]((el.__style ?? el), v, el);
      return;
    }
    const b = BUILDERS[el.__t];
    if (k.startsWith("on_")) {
      // Events a builder doesn't emit itself become plain DOM listeners, so
      // on_click works on a Card, an Image or a stack.
      const event = k.slice(3);
      if (v && !b?.emits?.includes(event) && el.addEventListener) listen(el, event, this);
      b?.set?.(el, k, v, old, this);
      return;
    }
    if (k === "disabled" && !b?.handlesDisabled) {
      const target = el.__input ?? el;
      if ("disabled" in target) target.disabled = !!v;
      (el.__style ?? el).classList?.toggle("ui-disabled", !!v);
      return;
    }
    b?.set?.(el, k, v, old, this);
  }
}

// -- modifiers ----------------------------------------------------------------------

// iOS system colors (light mode values; the semantic ones follow the theme).
const SYSTEM_COLORS = {
  red: "var(--red)", green: "var(--green)", orange: "#ff9500", yellow: "#ffcc00", mint: "#00c7be", teal: "#30b0c7",
  cyan: "#32ade6", blue: "#007aff", indigo: "#5856d6", purple: "#af52de", pink: "#ff2d55", brown: "#a2845e", gray: "#8e8e93",
  primary: "var(--label)", label: "var(--label)", secondary: "var(--secondary)", tertiary: "var(--tertiary)",
  tint: "var(--tint)", accent: "var(--tint)", background: "var(--bg)", secondary_background: "var(--cell)",
  separator: "var(--separator)", fill: "var(--fill)", clear: "transparent",
};

export function cssColor(v) {
  if (v == null || v === "") return "";
  return SYSTEM_COLORS[v] ?? v;
}

const edges = (v) => (v == null ? "" : Array.isArray(v) ? v.map((x) => `${x}px`).join(" ") : `${v}px`);
const size = (v) => (v == null ? "" : v === "fill" ? "100%" : `${v}px`);
const style = (prop, fn) => (target, v) => target.style?.setProperty(prop, fn(v));

const MODIFIERS = {
  padding: style("padding", edges),
  margin: style("margin", edges),
  width: style("width", size),
  height: style("height", size),
  min_width: style("min-width", size),
  max_width: style("max-width", size),
  min_height: style("min-height", size),
  max_height: style("max-height", size),
  flex: style("flex", (v) => (v == null ? "" : `${v} 1 0%`)),
  background: style("background", cssColor),
  color: style("color", cssColor),
  tint: style("--tint", cssColor),
  font_size: style("font-size", (v) => (v == null ? "" : `${v}px`)),
  font_weight: style("font-weight", (v) => (v == null ? "" : String(v))),
  text_align: style("text-align", (v) => ({ leading: "start", trailing: "end" })[v] ?? v ?? ""),
  corner_radius: style("border-radius", (v) => (v == null ? "" : `${v}px`)),
  border: style("border", (v) => (v ? `${v[0]}px solid ${cssColor(v[1])}` : "")),
  opacity: style("opacity", (v) => (v == null ? "" : String(v))),
  shadow: style("box-shadow", (v) => (v ? `0 2px ${v}px rgba(0,0,0,0.12)` : "")),
  a11y: (target, v) => (v == null ? target.removeAttribute?.("aria-label") : target.setAttribute?.("aria-label", v)),
  hidden: (target, v) => (target.hidden = !!v),
};

// -- helpers ------------------------------------------------------------------------

function h(tag, cls, text) {
  const el = document.createElement(tag);
  if (cls) el.className = cls;
  if (text !== undefined) el.textContent = text;
  return el;
}

function setText(el, text) {
  const s = text == null ? "" : String(text);
  if (el.textContent !== s) el.textContent = s;
}

function swapClass(el, prefix, old, next) {
  if (old) el.classList.remove(`${prefix}${old}`);
  if (next) el.classList.add(`${prefix}${next}`);
}

const ALIGN_V = { leading: "flex-start", start: "flex-start", center: "center", trailing: "flex-end", end: "flex-end", stretch: "stretch" };
const ALIGN_H = { top: "flex-start", start: "flex-start", center: "center", bottom: "flex-end", end: "flex-end", baseline: "baseline", stretch: "stretch" };
const JUSTIFY = {
  start: "flex-start", leading: "flex-start", top: "flex-start", center: "center", end: "flex-end", trailing: "flex-end",
  bottom: "flex-end", between: "space-between", around: "space-around", evenly: "space-evenly",
};
const px = (v) => (v == null ? "" : typeof v === "number" ? `${v}px` : v);

function stackBuilder(cls, alignMap) {
  return {
    create: () => h("div", cls),
    set(el, k, v) {
      if (k === "spacing") el.style.gap = px(v);
      else if (k === "align") el.style.alignItems = alignMap[v] ?? v ?? "";
      else if (k === "justify") el.style.justifyContent = JUSTIFY[v] ?? v ?? "";
      else if (k === "wrap") el.style.flexWrap = v ? "wrap" : "";
    },
  };
}

function capture(el, pointerId) {
  try {
    el.setPointerCapture?.(pointerId);
  } catch {
    // synthetic or already released pointer
  }
}

// Pointer drag helper: calls move(dx, dy, e) and end(dx, dy, velocityX) once
// the gesture is recognised as horizontal.
function horizontalDrag(el, { start, move, end, edge }) {
  let s = null;
  el.addEventListener("pointerdown", (e) => {
    if (e.button !== 0) return;
    if (edge != null && e.clientX - el.getBoundingClientRect().left > edge) return;
    if (start && !start(e)) return;
    s = { x: e.clientX, y: e.clientY, t: e.timeStamp, id: e.pointerId, active: false, lastX: e.clientX, lastT: e.timeStamp, v: 0 };
  });
  el.addEventListener("pointermove", (e) => {
    if (!s || e.pointerId !== s.id) return;
    const dx = e.clientX - s.x;
    const dy = e.clientY - s.y;
    if (!s.active) {
      if (Math.abs(dy) > 10 && Math.abs(dy) > Math.abs(dx)) {
        s = null;
        return;
      }
      if (Math.abs(dx) < 8) return;
      s.active = true;
      capture(el, e.pointerId);
    }
    const dt = e.timeStamp - s.lastT;
    if (dt > 0) s.v = (e.clientX - s.lastX) / dt;
    s.lastX = e.clientX;
    s.lastT = e.timeStamp;
    move(dx, dy, e);
    e.preventDefault();
  });
  const finish = (e) => {
    if (!s || e.pointerId !== s.id) return;
    const was = s;
    s = null;
    if (was.active) {
      end(e.clientX - was.x, e.clientY - was.y, was.v);
      el.__dragged = true;
      setTimeout(() => (el.__dragged = false), 0);
    }
  };
  el.addEventListener("pointerup", finish);
  el.addEventListener("pointercancel", finish);
}

// -- icons (24x24, stroked; ".fill" variants are filled) ----------------------------

const ICONS = {
  plus: "M12 5v14M5 12h14",
  minus: "M5 12h14",
  xmark: "M6 6l12 12M18 6 6 18",
  checkmark: "M5 12.5l4.5 4.5L19 7",
  "chevron.right": "M9 5l7 7-7 7",
  "chevron.left": "M15 5l-7 7 7 7",
  "chevron.down": "M5 9l7 7 7-7",
  "chevron.up": "M5 15l7-7 7 7",
  trash: "M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3",
  pencil: "M4 20h4L19 9l-4-4L4 16v4zM14 6l4 4",
  star: "M12 3l2.9 5.9 6.5.9-4.7 4.6 1.1 6.5L12 17.8l-5.8 3.1 1.1-6.5-4.7-4.6 6.5-.9z",
  heart: "M12 20s-7-4.4-9.2-8.6C1.3 8.2 3.2 4.5 6.8 4.5c2.1 0 3.4 1.2 5.2 3.1 1.8-1.9 3.1-3.1 5.2-3.1 3.6 0 5.5 3.7 4 6.9C19 15.6 12 20 12 20z",
  house: "M3 11l9-7 9 7M5 10v10h5v-6h4v6h5V10",
  gear: "M12 15a3 3 0 100-6 3 3 0 000 6zM12 2v3M12 19v3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M2 12h3M19 12h3M4.9 19.1 7 17M17 7l2.1-2.1",
  person: "M12 12a4 4 0 100-8 4 4 0 000 8zM4 21c0-4 3.6-7 8-7s8 3 8 7",
  magnifyingglass: "M11 18a7 7 0 100-14 7 7 0 000 14zM16 16l5 5",
  info: "M12 22a10 10 0 100-20 10 10 0 000 20zM12 11v6M12 7.5v.5",
  bell: "M6 16v-5a6 6 0 1112 0v5l2 2H4l2-2zM10 21h4",
  calendar: "M4 6h16v15H4zM4 10h16M8 3v4M16 3v4",
  folder: "M3 6h6l2 2h10v11H3z",
  doc: "M6 3h8l4 4v14H6zM14 3v4h4",
  photo: "M3 5h18v14H3zM3 16l5-5 4 4 3-3 6 6M15.5 9.5h.01",
  play: "M7 4l13 8-13 8z",
  pause: "M8 5v14M16 5v14",
  stop: "M6 6h12v12H6z",
  "arrow.clockwise": "M20 12a8 8 0 11-2.3-5.7M20 4v5h-5",
  share: "M12 3v12M8 7l4-4 4 4M5 11v9h14v-9",
  ellipsis: "M7 12a1.6 1.6 0 1 1-3.2 0 1.6 1.6 0 0 1 3.2 0zM13.6 12a1.6 1.6 0 1 1-3.2 0 1.6 1.6 0 0 1 3.2 0zM20.2 12a1.6 1.6 0 1 1-3.2 0 1.6 1.6 0 0 1 3.2 0z",
  list: "M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01",
  circle: "M12 21a9 9 0 100-18 9 9 0 000 18z",
  "checkmark.circle": "M12 21a9 9 0 100-18 9 9 0 000 18zM8 12.5l3 3 5-6",
  cart: "M3 4h2l2.5 11h11L21 7H6.5M9 20h.01M18 20h.01",
  clock: "M12 21a9 9 0 100-18 9 9 0 000 18zM12 7v5l3 2",
  location: "M12 21s-6-5.5-6-11a6 6 0 1112 0c0 5.5-6 11-6 11zM12 12a2 2 0 100-4 2 2 0 000 4z",
  sun: "M12 16a4 4 0 100-8 4 4 0 000 8zM12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4",
  moon: "M20 14.5A8 8 0 019.5 4a8 8 0 1010.5 10.5z",
  bolt: "M13 2 4 14h7l-1 8 9-12h-7z",
  envelope: "M3 5h18v14H3zM3 6l9 7 9-7",
  "music.note": "M9 18V5l11-2v13M9 18a3 3 0 11-6 0 3 3 0 016 0zM20 16a3 3 0 11-6 0 3 3 0 016 0z",
  camera: "M4 7h4l2-3h4l2 3h4v13H4zM12 17a4 4 0 100-8 4 4 0 000 8z",
  lock: "M6 11h12v10H6zM8 11V7a4 4 0 118 0v4",
  globe: "M12 21a9 9 0 100-18 9 9 0 000 18zM3 12h18M12 3c3 3.5 3 14.5 0 18M12 3c-3 3.5-3 14.5 0 18",
  flag: "M5 21V4M5 4h12l-2 4 2 4H5",
  bookmark: "M6 3h12v18l-6-4-6 4z",
};
const ALWAYS_FILLED = new Set(["ellipsis"]);
const ICON_ALIASES = { gearshape: "gear", "square.and.arrow.up": "share", search: "magnifyingglass", "info.circle": "info", x: "xmark", check: "checkmark" };

function icon(name, size) {
  let fill = false;
  let key = name ?? "";
  if (key.endsWith(".fill")) {
    fill = true;
    key = key.slice(0, -5);
  }
  key = ICON_ALIASES[key] ?? key;
  const span = h("span", "ui-icon");
  if (size) span.style.setProperty("--icon-size", px(size));
  const d = ICONS[key];
  if (!d) {
    span.textContent = name ?? ""; // emoji or text
    span.classList.add("ui-icon-text");
    return span;
  }
  const svg = document.createElementNS(SVG_NS, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS(SVG_NS, "path");
  path.setAttribute("d", d);
  if (fill || ALWAYS_FILLED.has(key)) path.setAttribute("fill", "currentColor");
  svg.append(path);
  span.append(svg);
  return span;
}

function setIcon(el, slot, name, size) {
  const next = name ? icon(name, size) : null;
  if (el[slot]) el[slot].replaceWith(next ?? document.createComment("icon"));
  el[slot] = next ?? null;
  return next;
}

// -- builders -----------------------------------------------------------------------

const UNKNOWN = {
  create: (r, tree) => h("div", "ui-unknown", `unknown element ${tree.t}`),
};

function eventPayload(e) {
  const t = e.currentTarget;
  const out = { type: e.type };
  if (t && "value" in t) out.value = t.value;
  if (t && t.type === "checkbox") out.checked = t.checked;
  if (e.key !== undefined) Object.assign(out, { key: e.key, code: e.code, shift: e.shiftKey, ctrl: e.ctrlKey, alt: e.altKey, meta: e.metaKey });
  if (e.clientX !== undefined && t?.getBoundingClientRect) {
    const rect = t.getBoundingClientRect();
    Object.assign(out, { x: e.clientX - rect.left, y: e.clientY - rect.top, width: rect.width, height: rect.height });
  }
  return out;
}

function listen(el, event, r) {
  el.__events ??= new Set();
  if (el.__events.has(event)) return;
  el.__events.add(event);
  if (event === "click") (el.__style ?? el).classList.add("ui-tappable");
  el.addEventListener(event, (e) => {
    if (event === "submit") e.preventDefault();
    r.emit(el, event, eventPayload(e));
  });
}

function fieldRow(cls, input) {
  const el = h("label", `ui-field ${cls}`);
  el.__label = h("span", "ui-field-label");
  el.__label.hidden = true;
  el.__input = input;
  el.append(el.__label, input);
  return el;
}

function setLabel(el, v) {
  setText(el.__label, v);
  el.__label.hidden = v == null || v === "";
  el.classList.toggle("ui-field-labelled", !el.__label.hidden);
}

const INPUT_KIND = {
  text: ["text", "text"], password: ["password", "text"], email: ["email", "email"], number: ["text", "numeric"],
  decimal: ["text", "decimal"], search: ["search", "search"], url: ["url", "url"], tel: ["tel", "tel"],
};

function textInput(r, el, input, submit) {
  input.addEventListener("input", (e) => {
    if (e.isComposing) return;
    r.emit(el, "change", input.value);
  });
  input.addEventListener("compositionend", () => r.emit(el, "change", input.value));
  if (submit) {
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.isComposing) {
        e.preventDefault();
        r.emit(el, "submit", input.value);
      }
    });
  }
}

const BUILDERS = {
  "#text": {
    emits: ["click"],
    create: () => document.createTextNode(""),
    set(el, k, v) {
      if (k === "text" && el.data !== v) el.data = v ?? "";
    },
  },

  Text: {
    create: () => h("span", "ui-text ui-text-body"),
    set(el, k, v, old) {
      if (k === "text") setText(el, v);
      else if (k === "font") swapClass(el, "ui-text-", old ?? "body", v ?? "body");
      else if (k === "bold" || k === "italic" || k === "mono" || k === "selectable") el.classList.toggle(`ui-text-${k}`, !!v);
      else if (k === "lines") {
        el.classList.toggle("ui-text-clamp", !!v);
        el.style.webkitLineClamp = v ? String(v) : "";
      }
    },
  },

  VStack: stackBuilder("ui-vstack", ALIGN_V),
  HStack: stackBuilder("ui-hstack", ALIGN_H),
  ZStack: {
    create: () => h("div", "ui-zstack"),
    set(el, k, v) {
      if (k === "align") el.style.placeItems = { center: "center", top: "start center", bottom: "end center", leading: "center start", trailing: "center end", fill: "stretch" }[v] ?? v ?? "";
    },
  },
  Grid: {
    create: () => h("div", "ui-grid"),
    set(el, k, v) {
      if (k === "spacing") el.style.gap = px(v);
      const p = el.__p;
      if (k === "columns" || k === "min") {
        el.style.gridTemplateColumns = p.min != null ? `repeat(auto-fill, minmax(min(${px(p.min)}, 100%), 1fr))` : `repeat(${p.columns ?? 2}, minmax(0, 1fr))`;
      }
    },
  },
  ScrollView: {
    create: () => h("div", "ui-scroll ui-scroll-vertical"),
    set(el, k, v, old) {
      if (k === "axis") swapClass(el, "ui-scroll-", old ?? "vertical", v ?? "vertical");
      else if (k === "spacing") el.style.gap = px(v);
    },
  },
  Spacer: {
    create: () => h("div", "ui-spacer"),
    set(el, k, v) {
      if (k === "size") {
        el.style.flex = v == null ? "" : `0 0 ${px(v)}`;
        el.style.minWidth = el.style.minHeight = v == null ? "" : px(v);
      }
    },
  },
  Divider: { create: () => h("div", "ui-divider") },
  Card: {
    create: () => h("div", "ui-card"),
    set(el, k, v) {
      if (k === "spacing") el.style.gap = px(v);
    },
  },

  // -- navigation --

  Screen: {
    emits: ["back"],
    create(r) {
      const el = h("div", "ui-screen");
      el.__bar = h("div", "ui-navbar");
      el.__leading = h("div", "ui-navbar-leading");
      el.__titleSmall = h("div", "ui-navbar-title");
      el.__trailing = h("div", "ui-navbar-trailing");
      el.__back = h("button", "ui-navbar-back");
      el.__back.append(icon("chevron.left"), h("span"));
      el.__back.hidden = true;
      el.__back.addEventListener("click", () => r.emit(el, "back"));
      el.__leading.append(el.__back);
      el.__bar.append(el.__leading, el.__titleSmall, el.__trailing);
      el.__title = h("h1", "ui-screen-title");
      el.__host = h("div", "ui-screen-content");
      el.append(el.__bar, el.__title, el.__host);
      // The small title appears once the large one has scrolled away.
      el.addEventListener("scroll", () => {
        const scrolled = el.scrollTop > el.__title.offsetTop + el.__title.offsetHeight - el.__bar.offsetHeight;
        el.classList.toggle("ui-screen-scrolled", scrolled);
      }, { passive: true });
      return el;
    },
    set(el, k, v) {
      if (k === "title") {
        setText(el.__title, v);
        setText(el.__titleSmall, v);
      } else if (k === "large") el.classList.toggle("ui-screen-inline", !v);
      else if (k === "back") {
        el.__back.hidden = v == null;
        setText(el.__back.lastChild, v === true ? "Back" : v);
      }
      BUILDERS.Screen.updated(el);
    },
    updated(el) {
      const p = el.__p;
      el.__title.hidden = !p.title || p.large === false;
      const hasBar = !!p.title || p.back != null || el.__leading.childElementCount > 1 || el.__trailing.childElementCount > 0;
      el.classList.toggle("ui-screen-barless", !hasBar);
    },
    insert(el, child, before) {
      if (child.__t === "Toolbar") {
        (child.__p.placement === "leading" ? el.__leading : el.__trailing).append(child);
        BUILDERS.Screen.updated(el);
        return;
      }
      el.__host.insertBefore(child, before && before.parentNode === el.__host ? before : null);
    },
  },
  Toolbar: { create: () => h("div", "ui-toolbar") },

  NavigationStack: {
    emits: [],
    create(r) {
      const el = h("div", "ui-nav");
      // Swipe from the left edge to go back.
      horizontalDrag(el, {
        edge: 24,
        start: () => el.childElementCount > 1,
        move(dx) {
          const top = el.lastElementChild;
          top.style.transition = "none";
          top.style.transform = `translateX(${Math.max(0, dx)}px)`;
        },
        end(dx, dy, v) {
          const top = el.lastElementChild;
          top.style.transition = "";
          if (dx > el.clientWidth * 0.35 || v > 0.5) {
            top.style.transform = "translateX(100%)";
            top.__swiped = true;
            r.emit(top, "back");
          } else {
            top.style.transform = "";
          }
        },
      });
      return el;
    },
    ready(el) {
      el.__ready = true;
      BUILDERS.NavigationStack.changed(el);
    },
    insert(el, child, before, r, initial) {
      el.append(child);
      if (!initial && el.__ready) {
        child.classList.add("ui-push-in");
        child.previousElementSibling?.classList.add("ui-push-under");
        child.addEventListener("animationend", () => {
          child.classList.remove("ui-push-in");
          child.previousElementSibling?.classList.remove("ui-push-under");
        }, { once: true });
      }
    },
    remove(el, child) {
      const prev = child.previousElementSibling;
      if (child.__swiped || child !== el.lastElementChild || !el.isConnected) {
        if (child.__swiped) setTimeout(() => child.remove(), 260);
        else child.remove();
        return;
      }
      child.classList.add("ui-pop-out");
      prev?.classList.add("ui-pop-under");
      child.inert = true;
      child.addEventListener("animationend", () => {
        child.remove();
        prev?.classList.remove("ui-pop-under");
      }, { once: true });
    },
    changed(el) {
      const screens = [...el.children].filter((c) => !c.classList.contains("ui-pop-out") && !c.__swiped);
      screens.forEach((s, i) => (s.inert = i !== screens.length - 1));
    },
  },

  TabView: {
    emits: ["change"],
    create(r) {
      const el = h("div", "ui-tabview");
      el.__host = h("div", "ui-tabs-content");
      el.__bar = h("nav", "ui-tabbar");
      el.append(el.__host, el.__bar);
      el.__refresh = () => BUILDERS.TabView.refresh(el, r);
      return el;
    },
    ready(el, r) {
      BUILDERS.TabView.refresh(el, r);
    },
    set(el, k, v, old, r) {
      if (k === "selected") BUILDERS.TabView.refresh(el, r);
    },
    changed(el, r) {
      BUILDERS.TabView.refresh(el, r);
    },
    refresh(el, r) {
      const tabs = [...el.__host.children].filter((c) => c.__t === "Tab");
      const selected = Math.min(el.__p.selected ?? 0, Math.max(0, tabs.length - 1));
      el.__bar.replaceChildren(
        ...tabs.map((tab, i) => {
          const b = h("button", "ui-tabbar-item");
          if (i === selected) b.classList.add("selected");
          if (tab.__p.icon) b.append(icon(tab.__p.icon));
          b.append(h("span", "ui-tabbar-title", tab.__p.title ?? ""));
          if (tab.__p.badge != null && tab.__p.badge !== "") b.append(h("span", "ui-tabbar-badge", String(tab.__p.badge)));
          b.addEventListener("click", () => {
            el.__p.selected = i;
            BUILDERS.TabView.refresh(el, r);
            r.emit(el, "change", i);
          });
          return b;
        }),
      );
      tabs.forEach((tab, i) => (tab.hidden = i !== selected));
    },
  },
  Tab: {
    create: () => h("div", "ui-tab"),
    set(el) {
      el.parentNode?.parentNode?.__refresh?.();
    },
  },

  Sheet: {
    emits: ["dismiss"],
    create(r) {
      const el = h("div", "ui-sheet-anchor");
      el.hidden = true;
      const backdrop = h("div", "ui-sheet-backdrop");
      const sheet = h("div", "ui-sheet");
      const grab = h("div", "ui-sheet-grabber");
      const header = h("div", "ui-sheet-header");
      el.__sheetTitle = h("div", "ui-sheet-title");
      const done = h("button", "ui-sheet-done", "Done");
      header.append(h("span"), el.__sheetTitle, done);
      el.__header = header;
      el.__host = h("div", "ui-sheet-body");
      sheet.append(grab, header, el.__host);
      backdrop.append(sheet);
      el.__portal = backdrop;
      el.__sheet = sheet;
      const dismiss = () => {
        BUILDERS.Sheet.show(el, r, false);
        r.emit(el, "dismiss");
      };
      done.addEventListener("click", dismiss);
      backdrop.addEventListener("click", (e) => e.target === backdrop && dismiss());
      // Drag down on the grabber or header to dismiss.
      let start = null;
      const down = (e) => (start = { y: e.clientY, id: e.pointerId });
      const move = (e) => {
        if (!start || e.pointerId !== start.id) return;
        const dy = Math.max(0, e.clientY - start.y);
        sheet.style.transition = "none";
        sheet.style.transform = `translateY(${dy}px)`;
      };
      const up = (e) => {
        if (!start) return;
        const dy = e.clientY - start.y;
        start = null;
        sheet.style.transition = "";
        sheet.style.transform = "";
        if (dy > 120) dismiss();
      };
      for (const t of [grab, header]) {
        t.addEventListener("pointerdown", (e) => {
          down(e);
          capture(t, e.pointerId);
        });
        t.addEventListener("pointermove", move);
        t.addEventListener("pointerup", up);
        t.addEventListener("pointercancel", up);
      }
      return el;
    },
    set(el, k, v, old, r) {
      if (k === "open") BUILDERS.Sheet.show(el, r, !!v);
      else if (k === "title") {
        setText(el.__sheetTitle, v);
        el.__header.classList.toggle("ui-sheet-header-titled", !!v);
      } else if (k === "size") el.__sheet.classList.toggle("ui-sheet-medium", v === "medium");
    },
    show(el, r, open) {
      const backdrop = el.__portal;
      if (open === el.__open) return;
      el.__open = open;
      clearTimeout(el.__closeTimer);
      if (open) {
        backdrop.classList.remove("ui-closing");
        r.layer.append(backdrop);
      } else if (backdrop.isConnected) {
        backdrop.classList.add("ui-closing");
        el.__closeTimer = setTimeout(() => backdrop.remove(), 280);
      }
    },
    unmount(el) {
      clearTimeout(el.__closeTimer);
      el.__portal.remove();
    },
  },

  // -- lists --

  Section: {
    create() {
      const el = h("section", "ui-section");
      el.__header = h("div", "ui-section-header");
      el.__host = h("div", "ui-section-body");
      el.__footer = h("div", "ui-section-footer");
      el.__header.hidden = el.__footer.hidden = true;
      el.append(el.__header, el.__host, el.__footer);
      return el;
    },
    set(el, k, v) {
      if (k === "header" || k === "footer") {
        const part = k === "header" ? el.__header : el.__footer;
        setText(part, v);
        part.hidden = v == null || v === "";
      }
    },
  },

  Row: {
    emits: ["click", "check", "delete"],
    create(r) {
      const el = h("div", "ui-row");
      const inner = (el.__inner = h("div", "ui-row-inner"));
      el.__check = h("span", "ui-row-check");
      el.__check.hidden = true;
      el.__iconSlot = document.createComment("icon");
      el.__text = h("div", "ui-row-text");
      el.__title = h("div", "ui-row-title");
      el.__subtitle = h("div", "ui-row-subtitle");
      el.__subtitle.hidden = true;
      el.__text.append(el.__title, el.__subtitle);
      el.__host = h("div", "ui-row-content");
      el.__detail = h("div", "ui-row-detail");
      el.__detail.hidden = true;
      el.__accessory = document.createComment("accessory");
      inner.append(el.__check, el.__iconSlot, el.__text, el.__host, el.__detail, el.__accessory);
      el.__delete = h("button", "ui-row-delete", "Delete");
      el.__delete.hidden = true;
      el.append(el.__delete, inner);
      el.__delete.addEventListener("click", () => {
        BUILDERS.Row.reveal(el, false);
        r.emit(el, "delete");
      });
      inner.addEventListener("click", (e) => {
        if (inner.__dragged) return;
        if (el.__revealed) {
          BUILDERS.Row.reveal(el, false);
          return;
        }
        if (e.target === el.__check && el.__p.on_check) r.emit(el, "check");
        else if (el.__p.on_click) r.emit(el, "click");
      });
      horizontalDrag(inner, {
        start: () => !!el.__p.on_delete,
        move(dx) {
          inner.style.transition = "none";
          const base = el.__revealed ? -88 : 0;
          inner.style.transform = `translateX(${Math.min(0, Math.max(-el.clientWidth, base + dx))}px)`;
        },
        end(dx, dy, v) {
          inner.style.transition = "";
          const base = el.__revealed ? -88 : 0;
          if (base + dx < -el.clientWidth * 0.6) {
            BUILDERS.Row.reveal(el, false);
            r.emit(el, "delete");
          } else BUILDERS.Row.reveal(el, base + dx < -44 || v < -0.4);
        },
      });
      return el;
    },
    reveal(el, open) {
      el.__revealed = open;
      el.__inner.style.transform = open ? "translateX(-88px)" : "";
    },
    set(el, k, v, old) {
      switch (k) {
        case "title":
          setText(el.__title, v);
          el.__text.hidden = (v == null || v === "") && !el.__p.subtitle;
          break;
        case "subtitle":
          setText(el.__subtitle, v);
          el.__subtitle.hidden = v == null || v === "";
          break;
        case "detail":
          setText(el.__detail, v);
          el.__detail.hidden = v == null || v === "";
          break;
        case "icon": {
          const next = v ? icon(v) : document.createComment("icon");
          if (v) next.classList.add("ui-row-icon");
          el.__iconSlot.replaceWith(next);
          el.__iconSlot = next;
          break;
        }
        case "accessory": {
          const next = v ? icon({ chevron: "chevron.right", check: "checkmark", info: "info" }[v] ?? v) : document.createComment("accessory");
          if (v) next.classList.add("ui-row-accessory", `ui-row-accessory-${v}`);
          el.__accessory.replaceWith(next);
          el.__accessory = next;
          break;
        }
        case "checked":
          el.__check.hidden = v == null;
          el.__check.classList.toggle("checked", !!v);
          el.classList.toggle("ui-row-done", !!v);
          break;
        case "on_click":
          el.classList.toggle("ui-row-tappable", !!v);
          break;
        case "on_check":
          el.__check.classList.toggle("ui-row-check-tappable", !!v);
          break;
        case "on_delete":
          el.__delete.hidden = !v;
          break;
      }
    },
  },

  // -- content --

  Label: {
    create() {
      const el = h("span", "ui-label");
      el.__iconEl = null;
      el.__textEl = h("span");
      el.append(el.__textEl);
      return el;
    },
    set(el, k, v) {
      if (k === "text") setText(el.__textEl, v);
      else if (k === "icon") {
        el.__iconEl?.remove();
        el.__iconEl = v ? icon(v) : null;
        if (el.__iconEl) el.prepend(el.__iconEl);
      }
    },
  },
  Icon: {
    create: () => h("span", "ui-icon-wrap"),
    set(el, k, v) {
      if (k === "name" || k === "size") el.replaceChildren(icon(el.__p.name, el.__p.size));
    },
  },
  Image: {
    create: () => h("img", "ui-image"),
    set(el, k, v) {
      if (k === "src") {
        if (el.getAttribute("src") !== v) el.src = v ?? "";
      } else if (k === "fit") el.style.objectFit = v ?? "";
      else if (k === "alt") el.alt = v ?? "";
    },
  },
  ProgressView: {
    create() {
      const el = h("div", "ui-progress");
      el.__bar = h("div", "ui-progress-track");
      el.__fill = h("div", "ui-progress-fill");
      el.__bar.append(el.__fill);
      el.__spinner = h("div", "ui-spinner");
      el.__labelEl = h("div", "ui-progress-label");
      el.__labelEl.hidden = true;
      el.append(el.__spinner, el.__bar, el.__labelEl);
      el.__bar.hidden = true;
      return el;
    },
    set(el, k, v) {
      if (k === "value") {
        const determinate = v != null;
        el.__bar.hidden = !determinate;
        el.__spinner.hidden = determinate;
        if (determinate) el.__fill.style.width = `${Math.max(0, Math.min(1, v)) * 100}%`;
      } else if (k === "label") {
        setText(el.__labelEl, v);
        el.__labelEl.hidden = !v;
      }
    },
  },
  Link: {
    create() {
      const el = h("a", "ui-link");
      el.target = "_blank";
      el.rel = "noopener";
      return el;
    },
    set(el, k, v) {
      if (k === "text") setText(el, v);
      else if (k === "url") el.href = v ?? "";
    },
  },
  Canvas: {
    emits: ["frame", "pointer_down", "pointer_move", "pointer_up"],
    create(r) {
      const el = h("canvas", "ui-canvas");
      el.__ctx = el.getContext("2d");
      const pointer = (name) => (e) => {
        if (!el.__p[`on_${name}`]) return;
        const rect = el.getBoundingClientRect();
        const x = ((e.clientX - rect.left) * (el.__p.cw ?? rect.width)) / rect.width;
        const y = ((e.clientY - rect.top) * (el.__p.ch ?? rect.height)) / rect.height;
        r.emit(el, name, { x, y, id: e.pointerId, buttons: e.buttons });
        if (name === "pointer_down") capture(el, e.pointerId);
      };
      el.addEventListener("pointerdown", pointer("pointer_down"));
      el.addEventListener("pointermove", pointer("pointer_move"));
      el.addEventListener("pointerup", pointer("pointer_up"));
      return el;
    },
    set(el, k, v, old, r) {
      if (k === "cw" || k === "ch") BUILDERS.Canvas.resize(el);
      else if (k === "cmds") BUILDERS.Canvas.paint(el);
      else if (k === "on_frame") BUILDERS.Canvas.loop(el, r, !!v);
      else if (k.startsWith("on_pointer")) el.style.touchAction = "none";
    },
    resize(el) {
      const w = el.__p.cw ?? 300;
      const hgt = el.__p.ch ?? 300;
      const dpr = window.devicePixelRatio || 1;
      el.width = Math.round(w * dpr);
      el.height = Math.round(hgt * dpr);
      el.style.aspectRatio = `${w} / ${hgt}`;
      el.style.setProperty("--canvas-width", `${w}px`);
      BUILDERS.Canvas.paint(el);
    },
    paint(el) {
      const ctx = el.__ctx;
      const cmds = el.__p.cmds;
      if (!ctx || !cmds) return;
      if (ctx.reset) ctx.reset();
      else el.width = el.width; // eslint-disable-line no-self-assign
      const s = el.width / (el.__p.cw ?? 300);
      ctx.setTransform(s, 0, 0, s, 0, 0);
      for (const [m, ...a] of cmds) {
        try {
          if (m === "=") ctx[a[0]] = a[1];
          else if (m === "$clear") {
            ctx.clearRect(0, 0, el.__p.cw ?? 300, el.__p.ch ?? 300);
            if (a[0]) {
              ctx.save();
              ctx.fillStyle = a[0];
              ctx.fillRect(0, 0, el.__p.cw ?? 300, el.__p.ch ?? 300);
              ctx.restore();
            }
          } else if (m === "$circle") {
            const [x, y, rad, fill, stroke, width] = a;
            ctx.beginPath();
            ctx.arc(x, y, rad, 0, Math.PI * 2);
            if (fill) {
              ctx.fillStyle = fill;
              ctx.fill();
            }
            if (stroke || !fill) {
              if (stroke) ctx.strokeStyle = stroke;
              if (width) ctx.lineWidth = width;
              ctx.stroke();
            }
          } else if (m === "$line") {
            const [x1, y1, x2, y2, color, width] = a;
            ctx.beginPath();
            ctx.moveTo(x1, y1);
            ctx.lineTo(x2, y2);
            if (color) ctx.strokeStyle = color;
            if (width) ctx.lineWidth = width;
            ctx.stroke();
          } else if (m === "$text") {
            const [text, x, y, color, font, align] = a;
            if (color) ctx.fillStyle = color;
            if (font) ctx.font = font;
            if (align) ctx.textAlign = align;
            ctx.fillText(text, x, y);
          } else ctx[m](...a);
        } catch (e) {
          console.warn("ui canvas:", m, e.message);
        }
      }
    },
    loop(el, r, on) {
      el.__frames = on;
      if (!on || el.__looping) return;
      el.__looping = true;
      let waiting = false;
      let last = null;
      let sentAt = 0;
      el.__frameAck = () => (waiting = false);
      const tick = (ts) => {
        if (!el.__frames || el.__stopped) {
          el.__looping = false;
          return;
        }
        // One frame in flight at a time; don't wait forever on a lost ack.
        if (!waiting || ts - sentAt > 1000) {
          const dt = last == null ? 1 / 60 : Math.min(0.1, (ts - last) / 1000);
          last = ts;
          waiting = true;
          sentAt = ts;
          r.emit(el, "frame", dt);
        }
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    },
    unmount(el) {
      el.__stopped = true;
    },
  },

  // -- inputs --

  Button: {
    emits: ["click"],
    create(r) {
      const el = h("button", "ui-button ui-button-filled");
      el.type = "button";
      el.__iconSlot = document.createComment("icon");
      el.__labelEl = h("span", "ui-button-label");
      el.append(el.__iconSlot, el.__labelEl);
      el.addEventListener("click", () => r.emit(el, "click"));
      return el;
    },
    set(el, k, v, old) {
      if (k === "label") {
        setText(el.__labelEl, v);
        el.__labelEl.hidden = v == null || v === "";
      } else if (k === "kind") swapClass(el, "ui-button-", old ?? "filled", v ?? "filled");
      else if (k === "size") swapClass(el, "ui-button-", old, v);
      else if (k === "icon") {
        const next = v ? icon(v) : document.createComment("icon");
        el.__iconSlot.replaceWith(next);
        el.__iconSlot = next;
      }
    },
  },

  TextField: {
    emits: ["change", "submit"],
    create(r) {
      const input = h("input", "ui-input");
      const el = fieldRow("ui-textfield", input);
      textInput(r, el, input, true);
      return el;
    },
    set(el, k, v) {
      const input = el.__input;
      if (k === "value") {
        if (input.value !== (v ?? "")) input.value = v ?? "";
      } else if (k === "placeholder") input.placeholder = v ?? "";
      else if (k === "label") setLabel(el, v);
      else if (k === "kind") {
        const [type, mode] = INPUT_KIND[v] ?? ["text", "text"];
        input.type = type;
        input.inputMode = mode;
        input.autocapitalize = type === "text" && mode === "text" ? "sentences" : "off";
        input.enterKeyHint = type === "search" ? "search" : "done";
      } else if (k === "autofocus" && v) setTimeout(() => input.focus(), 50);
    },
  },
  TextArea: {
    emits: ["change"],
    create(r) {
      const input = h("textarea", "ui-input ui-textarea-input");
      const el = h("div", "ui-textarea");
      el.__input = input;
      el.append(input);
      textInput(r, el, input, false);
      return el;
    },
    set(el, k, v) {
      const input = el.__input;
      if (k === "value") {
        if (input.value !== (v ?? "")) input.value = v ?? "";
      } else if (k === "placeholder") input.placeholder = v ?? "";
      else if (k === "rows") input.rows = v ?? 4;
    },
  },
  Toggle: {
    emits: ["change"],
    create(r) {
      const el = h("label", "ui-toggle");
      el.__labelEl = h("span", "ui-toggle-label");
      el.__input = h("input", "ui-switch");
      el.__input.type = "checkbox";
      el.__input.setAttribute("role", "switch");
      el.__input.addEventListener("change", () => r.emit(el, "change", el.__input.checked));
      el.append(el.__labelEl, el.__input);
      return el;
    },
    set(el, k, v) {
      if (k === "label") setText(el.__labelEl, v);
      else if (k === "value") el.__input.checked = !!v;
    },
  },
  Slider: {
    emits: ["change"],
    create(r) {
      const input = h("input", "ui-slider");
      input.type = "range";
      input.step = "any";
      const el = fieldRow("ui-slider-row", input);
      input.addEventListener("input", () => {
        BUILDERS.Slider.fill(el);
        r.emit(el, "change", Number(input.value));
      });
      return el;
    },
    set(el, k, v) {
      const input = el.__input;
      if (k === "min") input.min = v ?? 0;
      else if (k === "max") input.max = v ?? 1;
      else if (k === "step") input.step = v ?? "any";
      else if (k === "value") {
        if (Number(input.value) !== v) input.value = v ?? 0;
      } else if (k === "label") setLabel(el, v);
      BUILDERS.Slider.fill(el);
    },
    fill(el) {
      const i = el.__input;
      const span = Number(i.max) - Number(i.min) || 1;
      el.style.setProperty("--fill", `${((Number(i.value) - Number(i.min)) / span) * 100}%`);
    },
  },
  Stepper: {
    emits: ["change"],
    create(r) {
      const el = h("div", "ui-stepper");
      el.__labelEl = h("span", "ui-stepper-label");
      el.__valueEl = h("span", "ui-stepper-value");
      const buttons = h("div", "ui-stepper-buttons");
      el.__minus = h("button", "ui-stepper-button");
      el.__plus = h("button", "ui-stepper-button");
      el.__minus.append(icon("minus"));
      el.__plus.append(icon("plus"));
      el.__minus.setAttribute("aria-label", "Decrement");
      el.__plus.setAttribute("aria-label", "Increment");
      el.__minus.addEventListener("click", () => r.emit(el, "change", -1));
      el.__plus.addEventListener("click", () => r.emit(el, "change", 1));
      buttons.append(el.__minus, h("span", "ui-stepper-sep"), el.__plus);
      el.append(el.__labelEl, el.__valueEl, buttons);
      return el;
    },
    handlesDisabled: true,
    set(el, k, v) {
      if (k === "label") setText(el.__labelEl, v);
      else if (k === "value") setText(el.__valueEl, typeof v === "number" ? +v.toFixed(6) : v);
      const p = el.__p;
      el.__minus.disabled = !!p.disabled || (p.min != null && p.value <= p.min);
      el.__plus.disabled = !!p.disabled || (p.max != null && p.value >= p.max);
    },
  },
  Picker: {
    emits: ["change"],
    create(r) {
      const el = h("div", "ui-picker ui-picker-segmented");
      el.__labelEl = h("span", "ui-field-label");
      el.__labelEl.hidden = true;
      el.__segments = h("div", "ui-segmented");
      el.__select = h("select", "ui-select");
      el.__select.addEventListener("change", () => {
        el.__p.value = Number(el.__select.value);
        BUILDERS.Picker.refresh(el, r);
        r.emit(el, "change", el.__p.value);
      });
      el.__menu = h("label", "ui-picker-select");
      el.__menuValue = h("span", "ui-picker-value");
      el.__menu.append(el.__menuValue, icon("chevron.down"), el.__select);
      el.append(el.__labelEl, el.__segments, el.__menu);
      el.__r = r;
      return el;
    },
    handlesDisabled: true,
    set(el, k, v, old, r) {
      if (k === "kind") swapClass(el, "ui-picker-", old ?? "segmented", v ?? "segmented");
      else if (k === "label") {
        setText(el.__labelEl, v);
        el.__labelEl.hidden = !v;
      }
      BUILDERS.Picker.refresh(el, r);
    },
    refresh(el, r) {
      const options = el.__p.options ?? [];
      const selected = el.__p.value ?? -1;
      const disabled = !!el.__p.disabled;
      if (el.__builtFor !== options) {
        el.__builtFor = options;
        el.__segments.replaceChildren(
          ...options.map((label, i) => {
            const b = h("button", "ui-segment", label);
            b.type = "button";
            b.addEventListener("click", () => {
              el.__p.value = i;
              BUILDERS.Picker.refresh(el, r);
              r.emit(el, "change", i);
            });
            return b;
          }),
        );
        el.__select.replaceChildren(...options.map((label, i) => Object.assign(h("option", "", label), { value: String(i) })));
      }
      [...el.__segments.children].forEach((b, i) => {
        b.classList.toggle("selected", i === selected);
        b.disabled = disabled;
      });
      el.__select.value = String(selected);
      el.__select.disabled = disabled;
      setText(el.__menuValue, options[selected] ?? "");
      el.__segments.style.setProperty("--count", options.length || 1);
      el.__segments.style.setProperty("--index", Math.max(0, selected));
      el.__segments.classList.toggle("has-selection", selected >= 0);
    },
  },
  DatePicker: {
    emits: ["change"],
    create(r) {
      const input = h("input", "ui-date");
      input.type = "date";
      const el = fieldRow("ui-datepicker", input);
      input.addEventListener("change", () => r.emit(el, "change", input.value));
      return el;
    },
    set(el, k, v) {
      if (k === "kind") el.__input.type = { date: "date", time: "time", datetime: "datetime-local" }[v] ?? "date";
      else if (k === "value") {
        if (el.__input.value !== (v ?? "")) el.__input.value = v ?? "";
      } else if (k === "label") setLabel(el, v);
    },
  },
  ColorPicker: {
    emits: ["change"],
    create(r) {
      const input = h("input", "ui-color");
      input.type = "color";
      const el = fieldRow("ui-colorpicker", input);
      input.addEventListener("input", () => r.emit(el, "change", input.value));
      return el;
    },
    set(el, k, v) {
      if (k === "value") {
        if (el.__input.value !== (v ?? "")) el.__input.value = v ?? "#000000";
      } else if (k === "label") setLabel(el, v);
    },
  },
};

// -- dialogs and toasts -------------------------------------------------------------------

function showDialog(r, id, spec) {
  const reply = (value) => {
    backdrop.classList.add("ui-closing");
    setTimeout(() => backdrop.remove(), 200);
    r.sendEvent("0:dialog", JSON.stringify([id, value]));
  };
  const backdrop = h("div", "ui-dialog-backdrop");
  if (spec.kind === "choose") {
    backdrop.classList.add("ui-actionsheet-backdrop");
    const sheet = h("div", "ui-actionsheet");
    const group = h("div", "ui-actionsheet-group");
    if (spec.title || spec.message) {
      const head = h("div", "ui-actionsheet-head");
      if (spec.title) head.append(h("div", "ui-actionsheet-title", spec.title));
      if (spec.message) head.append(h("div", "ui-actionsheet-message", spec.message));
      group.append(head);
    }
    spec.options.forEach((label, i) => {
      const b = h("button", "ui-actionsheet-button", label);
      b.addEventListener("click", () => reply(i));
      group.append(b);
    });
    const cancel = h("button", "ui-actionsheet-button ui-actionsheet-cancel", spec.cancel ?? "Cancel");
    cancel.addEventListener("click", () => reply(null));
    backdrop.addEventListener("click", (e) => e.target === backdrop && reply(null));
    sheet.append(group, cancel);
    backdrop.append(sheet);
    r.layer.append(backdrop);
    return;
  }
  const box = h("div", "ui-alert");
  const body = h("div", "ui-alert-body");
  body.append(h("div", "ui-alert-title", spec.title ?? ""));
  if (spec.message) body.append(h("div", "ui-alert-message", spec.message));
  let input = null;
  if (spec.kind === "prompt") {
    input = h("input", "ui-alert-input");
    input.value = spec.value ?? "";
    input.placeholder = spec.placeholder ?? "";
    input.addEventListener("keydown", (e) => e.key === "Enter" && reply(input.value));
    body.append(input);
  }
  const buttons = h("div", "ui-alert-buttons");
  if (spec.kind !== "alert") {
    const cancel = h("button", "ui-alert-button", spec.cancel ?? "Cancel");
    cancel.addEventListener("click", () => reply(spec.kind === "confirm" ? false : null));
    buttons.append(cancel);
  }
  const ok = h("button", "ui-alert-button ui-alert-default", spec.ok ?? "OK");
  if (spec.destructive) ok.classList.add("ui-alert-destructive");
  ok.addEventListener("click", () => reply(spec.kind === "confirm" ? true : spec.kind === "prompt" ? input.value : null));
  buttons.append(ok);
  box.append(body, buttons);
  backdrop.append(box);
  r.layer.append(backdrop);
  if (input) setTimeout(() => input.focus(), 50);
}

function showToast(r, text, seconds) {
  const toast = h("div", "ui-toast", text);
  r.layer.append(toast);
  setTimeout(() => {
    toast.classList.add("ui-closing");
    setTimeout(() => toast.remove(), 250);
  }, (seconds ?? 2) * 1000);
}
