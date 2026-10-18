// The agent's ExecutionEnv: the project folder through the native bridge.
// The agent sees the project as "/"; paths that leave it are refused. There is
// no shell (D7): `exec` fails with shell_unavailable. pi-durable's read, write
// and edit only need absolutePath, exists, fileInfo, openBinaryReader,
// readTextFile and writeFile; the rest is here for completeness or answers
// not_supported.
import type { Context } from "@earendil-works/chord";
import {
  type BinaryReader,
  type DirReader,
  err,
  ExecutionError,
  type ExecutionEnv,
  FileError,
  type FileErrorCode,
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
import { base64ToBytes, bytesToBase64, call } from "./bridge";

const CODES = new Set<FileErrorCode>(["aborted", "not_found", "permission_denied", "not_directory", "is_directory", "invalid", "not_supported", "unknown"]);
const encoder = new TextEncoder();

function fileError(error: unknown, path: string): FileError {
  const message = error instanceof Error ? error.message : String(error);
  const code = message.split(":")[0] as FileErrorCode;
  return new FileError(CODES.has(code) ? code : "unknown", message, path);
}

const unsupported = <T>(what: string, path?: string): Result<T, FileError> =>
  err(new FileError("not_supported", `${what} is not supported in the project environment`, path));

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

export class ProjectEnv implements ExecutionEnv {
  readonly id = "terrarium-project";
  cwd = "/";

  private async native<T>(op: string, path: string, args: Record<string, unknown> = {}): Promise<Result<T, FileError>> {
    try {
      return ok(await call<T>(op, { path: path.replace(/^\/+/, ""), ...args }));
    } catch (e) {
      return err(fileError(e, path));
    }
  }

  private resolve(path: string): Result<string, FileError> {
    const resolved = normalize(path.startsWith("/") ? path : `${this.cwd}/${path}`);
    return resolved === undefined ? err(new FileError("permission_denied", `Outside the project: ${path}`, path)) : ok(resolved);
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

  async readBinaryFile(path: string, _context: Context): Promise<Result<Uint8Array, FileError>> {
    const p = this.resolve(path);
    if (!p.ok) return p;
    const r = await this.native<string>("fs.read", p.value);
    return r.ok ? ok(base64ToBytes(r.value)) : r;
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
      scanLines: async (options: { startLine: number; endLine?: number }) => {
        try {
          const scanner = new LineScanner(options.startLine, options.endLine);
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
    const bytes = typeof content === "string" ? encoder.encode(content) : content;
    const r = await this.native<null>("fs.write", p.value, { data: bytesToBase64(bytes) });
    return r.ok ? ok(undefined) : r;
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
    return ok(undefined); // writes are atomic and synchronous natively
  }

  async renameFile(source: string, destination: string, _context: Context): Promise<Result<void, FileError>> {
    const from = this.resolve(source);
    if (!from.ok) return from;
    const to = this.resolve(destination);
    if (!to.ok) return to;
    const r = await this.native<null>("fs.rename", from.value, { to: to.value.replace(/^\/+/, "") });
    return r.ok ? ok(undefined) : r;
  }

  async fileInfo(path: string, _context: Context): Promise<Result<FileInfo, FileError>> {
    const p = this.resolve(path);
    if (!p.ok) return p;
    return this.native<FileInfo>("fs.stat", p.value);
  }

  async exists(path: string, context: Context): Promise<Result<boolean, FileError>> {
    const r = await this.fileInfo(path, context);
    if (r.ok) return ok(true);
    return r.error.code === "not_found" ? ok(false) : r;
  }

  async listDir(path: string, _context: Context): Promise<Result<FileInfo[], FileError>> {
    const p = this.resolve(path);
    if (!p.ok) return p;
    return this.native<FileInfo[]>("fs.list", p.value);
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

  async createDir(path: string, options: { recursive?: boolean } | undefined, _context: Context): Promise<Result<void, FileError>> {
    const p = this.resolve(path);
    if (!p.ok) return p;
    const r = await this.native<null>("fs.mkdir", p.value, { recursive: options?.recursive ?? false });
    return r.ok ? ok(undefined) : r;
  }

  async remove(path: string, options: { recursive?: boolean; force?: boolean } | undefined, _context: Context): Promise<Result<void, FileError>> {
    const p = this.resolve(path);
    if (!p.ok) return p;
    if (p.value === "/") return err(new FileError("permission_denied", "Cannot remove the project", path));
    const r = await this.native<null>("fs.remove", p.value, { force: options?.force ?? false });
    return r.ok ? ok(undefined) : r;
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
