// The agent's ExecutionEnv (D32): one project folder through the host's file
// bridge (FileStore: Documents and linked folders). The agent sees the
// project as "/"; paths that leave it are refused. There is no shell: `exec`
// answers shell_unavailable (run_python is the way to run code).
//
// pi-durable's read, write and edit use absolutePath, exists, fileInfo,
// openBinaryReader, readTextFile and writeFile; our own tools add listDir and
// the project tree. Every write is reported (onWrite) so the editors and the
// file browser pick it up, and the first read of each call saves what the
// editors have not saved yet.
import type { Context } from "@earendil-works/chord";
import {
  type BinaryReader,
  type DirReader,
  err,
  ExecutionError,
  type ExecutionEnv,
  FileError,
  type FileInfo,
  type FileWatcher,
  LineScanner,
  type LineScan,
  ok,
  type Result,
  type ShellExecResult,
  type TextLine,
  type TextLineReader,
} from "@earendil-works/pi-durable/env";
import { base64ToBytes, bytesToBase64, call, fs, join } from "../host";

const encoder = new TextEncoder();

/** "/a/./b/../c" -> "/a/c"; undefined when it leaves the root. */
export function normalize(path: string): string | undefined {
  const out: string[] = [];
  for (const part of path.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") {
      if (!out.length) return undefined;
      out.pop();
    } else out.push(part);
  }
  return "/" + out.join("/");
}

type Stat = { name: string; path: string; dir: boolean; size: number; mtime: number };

const unsupported = <T>(what: string, path?: string): Result<T, FileError> =>
  err(new FileError("not_supported", `${what} is not supported in the project`, path));

export interface ProjectEnvOptions {
  /** The project folder as the app addresses it ("" for Documents, "@iCloud/x" for a linked folder). */
  project: string;
  /** A file was written or deleted (app paths). */
  onWrite?: (paths: string[]) => void;
}

export class ProjectEnv implements ExecutionEnv {
  readonly id: string;
  cwd = "/";
  private flushed: Promise<unknown> | null = null;

  constructor(private options: ProjectEnvOptions) {
    this.id = `terrarium:${options.project}`;
  }

  get project() {
    return this.options.project;
  }

  /** Report files changed outside writeFile (run_python's write-back). */
  notifyWrites(appPaths: string[]) {
    this.options.onWrite?.(appPaths);
  }

  /** The app path of a project path ("/a/b.py" -> "<project>/a/b.py"). */
  appPath(path: string): string {
    return join(this.options.project, path.replace(/^\/+/, ""));
  }

  resolve(path: string): Result<string, FileError> {
    const resolved = normalize(path.startsWith("/") ? path : `${this.cwd}/${path}`);
    return resolved === undefined ? err(new FileError("permission_denied", `Outside the project: ${path}`, path)) : ok(resolved);
  }

  /** Unsaved editor text reaches the disk before the agent reads (once per call). */
  private flush() {
    this.flushed ??= call("agent.flushEditors").catch(() => {});
    return this.flushed;
  }

  private async stat(path: string): Promise<Result<Stat | null, FileError>> {
    try {
      return ok(await call<Stat | null>("fs.stat", { path: this.appPath(path) }));
    } catch (e) {
      return err(new FileError("unknown", String((e as Error).message ?? e), path));
    }
  }

  private info(path: string, s: Stat): FileInfo {
    return { name: path === "/" ? "/" : s.name, path, kind: s.dir ? "directory" : "file", size: s.size, mtimeMs: s.mtime };
  }

  async absolutePath(path: string, _context: Context) {
    return this.resolve(path);
  }
  async canonicalPath(path: string, _context: Context) {
    return this.resolve(path);
  }
  async joinPath(parts: string[], _context: Context) {
    return ok<string, FileError>(parts.join("/").replace(/\/+/g, "/"));
  }

  async fileInfo(path: string, _context: Context): Promise<Result<FileInfo, FileError>> {
    const p = this.resolve(path);
    if (!p.ok) return p;
    await this.flush();
    const s = await this.stat(p.value);
    if (!s.ok) return s;
    if (!s.value) return err(new FileError("not_found", `No such file: ${path}`, path));
    return ok(this.info(p.value, s.value));
  }

  async exists(path: string, context: Context): Promise<Result<boolean, FileError>> {
    const r = await this.fileInfo(path, context);
    if (r.ok) return ok(true);
    return r.error.code === "not_found" ? ok(false) : r;
  }

  async readBinaryFile(path: string, context: Context): Promise<Result<Uint8Array, FileError>> {
    const info = await this.fileInfo(path, context);
    if (!info.ok) return info;
    if (info.value.kind === "directory") return err(new FileError("is_directory", `Is a directory: ${path}`, path));
    try {
      return ok(base64ToBytes(await fs.readBase64(this.appPath(info.value.path))));
    } catch (e) {
      return err(new FileError("unknown", String((e as Error).message ?? e), path));
    }
  }

  async readTextFile(path: string, context: Context): Promise<Result<string, FileError>> {
    const r = await this.readBinaryFile(path, context);
    // Keep a BOM: edit strips and restores it itself.
    return r.ok ? ok(new TextDecoder("utf-8", { ignoreBOM: true }).decode(r.value)) : r;
  }

  async readTextLines(path: string, options: { maxLines?: number } | undefined, context: Context): Promise<Result<string[], FileError>> {
    const r = await this.readTextFile(path, context);
    if (!r.ok) return r;
    const lines = r.value.split("\n");
    if (lines.at(-1) === "") lines.pop();
    return ok(options?.maxLines === undefined ? lines : lines.slice(0, options.maxLines));
  }

  async openTextLineReader(path: string, context: Context): Promise<Result<TextLineReader, FileError>> {
    const r = await this.readTextFile(path, context);
    if (!r.ok) return r;
    const text = r.value;
    let position = 0;
    return ok({
      readLine: async () => {
        if (position >= text.length) return ok<TextLine | undefined, FileError>(undefined);
        const end = text.indexOf("\n", position);
        const line = end < 0 ? { text: text.slice(position), terminated: false } : { text: text.slice(position, end), terminated: true };
        position = end < 0 ? text.length : end + 1;
        return ok<TextLine | undefined, FileError>(line);
      },
      close: async () => {},
    });
  }

  /** Projects are small: the whole file is read once and sliced in memory. */
  async openBinaryReader(path: string, _options: { noFollow?: boolean } | undefined, context: Context): Promise<Result<BinaryReader, FileError>> {
    const info = await this.fileInfo(path, context);
    if (!info.ok) return info;
    if (info.value.kind === "directory") return err(new FileError("is_directory", `Is a directory: ${path}`, path));
    const data = await this.readBinaryFile(path, context);
    if (!data.ok) return data;
    const bytes = data.value;
    const fileInfo = { ...info.value, size: bytes.length };
    return ok({
      info: async () => ok<FileInfo, FileError>(fileInfo),
      read: async (offset: number, length: number) => ok<Uint8Array, FileError>(bytes.slice(offset, offset + length)),
      scanLines: async (o: { startLine: number; endLine?: number }) => {
        try {
          const scanner = new LineScanner(o.startLine, o.endLine);
          scanner.push(bytes);
          return ok<LineScan, FileError>(scanner.finish());
        } catch {
          return err<LineScan, FileError>(new FileError("invalid", "Invalid line range", path));
        }
      },
      close: async () => {},
    });
  }

  async writeFile(path: string, content: string | Uint8Array, _context: Context): Promise<Result<void, FileError>> {
    const p = this.resolve(path);
    if (!p.ok) return p;
    if (p.value === "/") return err(new FileError("is_directory", "The project is a directory", path));
    const bytes = typeof content === "string" ? encoder.encode(content) : content;
    try {
      await fs.writeBase64(this.appPath(p.value), bytesToBase64(bytes));
    } catch (e) {
      return err(new FileError("unknown", String((e as Error).message ?? e), path));
    }
    this.options.onWrite?.([this.appPath(p.value)]);
    return ok(undefined);
  }

  async appendFile(path: string, content: string | Uint8Array, context: Context): Promise<Result<void, FileError>> {
    const old = await this.readBinaryFile(path, context);
    if (!old.ok && old.error.code !== "not_found") return old;
    const add = typeof content === "string" ? encoder.encode(content) : content;
    const prev = old.ok ? old.value : new Uint8Array();
    const next = new Uint8Array(prev.length + add.length);
    next.set(prev);
    next.set(add, prev.length);
    return this.writeFile(path, next, context);
  }

  async truncateFile(path: string, size: number, context: Context): Promise<Result<void, FileError>> {
    const old = await this.readBinaryFile(path, context);
    if (!old.ok) return old;
    const next = new Uint8Array(size);
    next.set(old.value.subarray(0, size));
    return this.writeFile(path, next, context);
  }

  async flushFile(_path: string, _context: Context): Promise<Result<void, FileError>> {
    return ok(undefined); // the host writes atomically
  }

  async renameFile(source: string, destination: string, _context: Context): Promise<Result<void, FileError>> {
    const from = this.resolve(source);
    if (!from.ok) return from;
    const to = this.resolve(destination);
    if (!to.ok) return to;
    try {
      await fs.rename(this.appPath(from.value), this.appPath(to.value));
    } catch (e) {
      return err(new FileError("unknown", String((e as Error).message ?? e), source));
    }
    this.options.onWrite?.([this.appPath(from.value), this.appPath(to.value)]);
    return ok(undefined);
  }

  async listDir(path: string, _context: Context): Promise<Result<FileInfo[], FileError>> {
    const p = this.resolve(path);
    if (!p.ok) return p;
    const s = await this.stat(p.value);
    if (!s.ok) return s;
    if (!s.value) return err(new FileError("not_found", `No such directory: ${path}`, path));
    if (!s.value.dir) return err(new FileError("not_directory", `Not a directory: ${path}`, path));
    const entries = await fs.list(this.appPath(p.value));
    return ok(entries.map((e) => this.info(join(p.value, e.name).replace(/^\/?/, "/"), { ...e, name: e.name })));
  }

  async openDirReader(path: string, context: Context): Promise<Result<DirReader, FileError>> {
    const r = await this.listDir(path, context);
    if (!r.ok) return r;
    let rest = r.value;
    return ok({
      next: async (maxEntries: number) => {
        const entries = rest.slice(0, maxEntries);
        rest = rest.slice(maxEntries);
        return ok<{ entries: FileInfo[]; done: boolean }, FileError>({ entries, done: rest.length === 0 });
      },
      close: async () => {},
    });
  }

  async createDir(path: string, _options: { recursive?: boolean } | undefined, _context: Context): Promise<Result<void, FileError>> {
    const p = this.resolve(path);
    if (!p.ok) return p;
    await fs.mkdir(this.appPath(p.value));
    this.options.onWrite?.([]);
    return ok(undefined);
  }

  async remove(path: string, options: { recursive?: boolean; force?: boolean } | undefined, context: Context): Promise<Result<void, FileError>> {
    const p = this.resolve(path);
    if (!p.ok) return p;
    if (p.value === "/") return err(new FileError("permission_denied", "Cannot remove the project", path));
    const exists = await this.exists(p.value, context);
    if (!exists.ok) return exists;
    if (!exists.value) return options?.force ? ok(undefined) : err(new FileError("not_found", `No such file: ${path}`, path));
    await fs.remove(this.appPath(p.value));
    this.options.onWrite?.([this.appPath(p.value)]);
    return ok(undefined);
  }

  /** Every file below a project directory: project paths and contents (base64). */
  async tree(path = "/"): Promise<{ path: string; data: string }[]> {
    const p = this.resolve(path);
    if (!p.ok) throw p.error;
    await this.flush();
    const files = await fs.tree(this.appPath(p.value));
    return files.map((f) => ({ path: join(p.value, f.path).replace(/^\/?/, "/"), data: f.data }));
  }

  async watch(): Promise<Result<FileWatcher, FileError>> {
    return unsupported("watch");
  }
  async createTempDir(): Promise<Result<string, FileError>> {
    return unsupported("createTempDir");
  }
  async createTempFile(): Promise<Result<string, FileError>> {
    return unsupported("createTempFile");
  }

  async exec(): Promise<Result<ShellExecResult, ExecutionError>> {
    return err(new ExecutionError("shell_unavailable", "There is no shell on iOS; use run_python"));
  }

  async cleanup() {}
}
