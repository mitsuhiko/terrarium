// Turtle graphics on the page (D29). A TurtleScene mirrors the items of one
// turtle screen (lines, polygons, images, text: Tk's canvas model, kept in
// _terrarium_turtle.py) from the ops the program sends, queues taps and keys for
// it. The native console draws the scene (D31): the engine forwards the ops and
// state changes to the host through `turtleSync`.

export interface TurtleInfo {
  title: string;
  w: number; // the window, in canvas units
  h: number;
  region: [number, number, number, number]; // scroll region; the window shows its middle
  bg: string;
}

type ItemType = "line" | "polygon" | "image" | "text";

interface Item {
  type: ItemType;
  xy: number[];
  o: Record<string, any>;
}

export type TurtleEvent =
  | { t: "down" | "move" | "up"; x: number; y: number; b: number }
  | { t: "key" | "keyup"; k: string };

type Change = "info" | "draw" | "focus";

const MAX_EVENTS = 200;

/** Hooks the engine sets to mirror scenes in the host. */
export const turtleSync = {
  ops: (_scene: TurtleScene, _ops: any[]) => {},
  state: (_scene: TurtleScene) => {},
};

export class TurtleScene {
  info: TurtleInfo = { title: "Python Turtle Graphics", w: 600, h: 600, region: [-200, -150, 200, 150], bg: "#ffffff" };
  items = new Map<number, Item>(); // in stacking order
  listening = { pointer: false, keys: false };
  /** The program can still take events (false after bye() or when it ended). */
  live = true;
  /** The program (or console input) is running: only then does anyone read events. */
  active = true;
  /** Bumped when info or listening changes (the view re-renders). */
  version = 0;
  private events: TurtleEvent[] = [];
  private waiter: { wake: () => void; cancel: () => void } | null = null;
  private listeners = new Set<(change: Change) => void>();

  constructor(readonly key: string) {}

  subscribe = (fn: (change: Change) => void) => {
    this.listeners.add(fn);
    return () => void this.listeners.delete(fn);
  };

  private emit(change: Change) {
    if (change === "info") turtleSync.state(this);
    for (const fn of this.listeners) fn(change);
  }

  apply(ops: any[]) {
    turtleSync.ops(this, ops);
    let info = false;
    let focus = false;
    for (const op of ops) {
      const item = typeof op[1] === "number" ? this.items.get(op[1]) : undefined;
      switch (op[0]) {
        case "open":
        case "screen":
          this.info = { ...this.info, ...op[1] };
          info = true;
          break;
        case "new":
          this.items.set(op[1], { type: op[2], xy: op[3], o: op[4] });
          break;
        case "xy":
          if (item) item.xy = op[2];
          break;
        case "set":
          if (item) Object.assign(item.o, op[2]);
          break;
        case "top":
          if (item) {
            this.items.delete(op[1]);
            this.items.set(op[1], item);
          }
          break;
        case "bottom":
          if (item) this.items = new Map([[op[1] as number, item], ...[...this.items].filter(([id]) => id !== op[1])]);
          break;
        case "del":
          if (op[1] === "all") this.items.clear();
          else this.items.delete(op[1]);
          break;
        case "listen":
          this.listening = op[1];
          this.events = this.events.filter((e) => (e.t === "key" || e.t === "keyup" ? this.listening.keys : this.listening.pointer));
          info = true;
          break;
        case "focus":
          focus = true;
          break;
        case "close":
          this.end();
          info = true;
          break;
      }
    }
    if (info) this.version++;
    this.emit(info ? "info" : "draw");
    if (focus) this.emit("focus");
  }

  /** A tap or key from the view; kept until the program asks for events. */
  push(e: TurtleEvent) {
    if (!this.live || !this.active) return;
    const key = e.t === "key" || e.t === "keyup";
    if (key ? !this.listening.keys : !this.listening.pointer) return;
    const last = this.events.at(-1);
    if (e.t === "move" && last?.t === "move") this.events[this.events.length - 1] = e;
    else this.events.push(e);
    if (this.events.length > MAX_EVENTS) this.events.splice(0, this.events.length - MAX_EVENTS);
    this.waiter?.wake();
  }

  /** The program asks for events, waiting up to waitMs for the first. */
  take(waitMs: number): Promise<TurtleEvent[]> {
    this.waiter?.cancel(); // an earlier call that was interrupted: its answer is dropped
    if (this.events.length || waitMs <= 0 || !this.live) return Promise.resolve(this.drain());
    return new Promise((resolve) => {
      const finish = (events: TurtleEvent[]) => {
        clearTimeout(timer);
        this.waiter = null;
        resolve(events);
      };
      const timer = setTimeout(() => finish(this.drain()), waitMs);
      this.waiter = { wake: () => finish(this.drain()), cancel: () => finish([]) };
    });
  }

  private drain() {
    const events = this.events;
    this.events = [];
    return events;
  }

  /** Whether code runs in the program's interpreter (the session tells us). */
  setActive(active: boolean) {
    if (active === this.active) return;
    this.active = active;
    if (!active) this.events = [];
    this.version++;
    this.emit("info");
  }

  /** Whether taps and keys go to the program right now. */
  get accepting() {
    return this.live && this.active;
  }

  /** bye(), or the program ended: the drawing stays, events stop. */
  end() {
    if (!this.live) return;
    this.live = false;
    this.listening = { pointer: false, keys: false };
    this.events = [];
    this.waiter?.wake();
    this.version++;
    this.emit("info");
  }
}

/** Scenes by key (the console line refers to its scene by key). */
export const turtleScenes = new Map<string, TurtleScene>();
