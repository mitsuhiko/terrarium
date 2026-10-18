// The coding agent in the engine page (D34): a pi-durable Harness on native
// SQLite (D32), conversations per project folder (D36, conversations.ts),
// models from pi-ai with credentials in the Keychain (D33). The host drives it
// through the engine's `agent` command and gets a compact transcript
// (`agent.state`) of the conversation on screen to draw natively. Other
// conversations keep running in the background. Everything is committed
// before it is shown, so a crash or a reload of the engine page resumes the
// turn where it was.
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { AttachedReplicatedState } from "@earendil-works/chord";
import type { AuthType, Model, MutableModels } from "@earendil-works/pi-ai";
import { createModels } from "@earendil-works/pi-ai/models";
import { anthropicProvider } from "@earendil-works/pi-ai/providers/anthropic";
import { deepseekProvider } from "@earendil-works/pi-ai/providers/deepseek";
import { fauxProvider, type FauxProviderHandle } from "@earendil-works/pi-ai/providers/faux";
import { githubCopilotProvider } from "@earendil-works/pi-ai/providers/github-copilot";
import { googleProvider } from "@earendil-works/pi-ai/providers/google";
import { groqProvider } from "@earendil-works/pi-ai/providers/groq";
import { kimiCodingProvider } from "@earendil-works/pi-ai/providers/kimi-coding";
import { metaProvider } from "@earendil-works/pi-ai/providers/meta";
import { mistralProvider } from "@earendil-works/pi-ai/providers/mistral";
import { openaiProvider } from "@earendil-works/pi-ai/providers/openai";
import { openaiCodexProvider } from "@earendil-works/pi-ai/providers/openai-codex";
import { openrouterProvider } from "@earendil-works/pi-ai/providers/openrouter";
import { radiusProvider } from "@earendil-works/pi-ai/providers/radius";
import { xaiProvider } from "@earendil-works/pi-ai/providers/xai";
import {
  type Conversation,
  type ConversationId,
  type ConversationView,
  createRegistry,
  Harness,
  type Submission,
} from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { call } from "../host";
import { ConversationIndex } from "./conversations";
import { KeychainCredentialStore } from "./credentials";
import { ProjectEnv } from "./env";
import { contextBlock, contextKey, IDE_TOOLS, ideHooks, IDETools, type IDEState, projectPath } from "./ide";
import { cancelLogin, login } from "./login";
import { Prompt } from "./prompt";
import { installProxyFetch } from "./proxy";
import { BridgeSqlite } from "./sqlite";
import { DocsTools } from "./docs";
import { ProjectTools } from "./tools";

const ctx = BACKGROUND_CONTEXT;
type ModelRef = { provider: string; modelId: string };

/** Our user entries: the model sees the message with the IDE context, the app shows the text and the file. */
const USER_ENTRY = "terrarium.user";
/** The IDE context, placed mid-turn when the user moved to another file (D36). */
const IDE_ENTRY = "terrarium.ide";

/** Radius (pi's gateway) comes first: in the account list and as the default model. */
const FEATURED_PROVIDER = "radius";
/** Defaults within a provider; the user picks in the app. */
const PREFERRED = [/sonnet/, /haiku/, /gpt-5[.\d]*-codex/, /gpt-5/, /gemini-[\d.]+-pro/, /flash/];
/** Providers whose model list comes from the server (refreshed at start and after sign-in). */
const DYNAMIC_CATALOGS = ["radius", "github-copilot", "openrouter"];

// -- the transcript the app draws ---------------------------------------------------

export interface Item {
  id: string;
  /** "context": the IDE context the model got mid-turn. */
  kind: "user" | "assistant" | "tool" | "error" | "note" | "context";
  text: string;
  /** An IDE tool (ide.ts): one compact line in the transcript. */
  ide?: boolean;
  thinking?: string;
  streaming?: boolean;
  tool?: string;
  summary?: string;
  status?: "pending" | "running" | "done" | "error";
  output?: string;
  diff?: string;
  path?: string;
  line?: number;
  images?: number;
}

const contentText = (content: unknown): string =>
  typeof content === "string"
    ? content
    : Array.isArray(content)
      ? content.map((c: any) => (c.type === "text" ? c.text : "")).join("")
      : "";

function summarize(name: string, args: any): { summary: string; path?: string } {
  const path = typeof args?.path === "string" ? args.path.replace(/^\/+/, "") : undefined;
  switch (name) {
    case "read":
    case "write":
    case "edit":
    case "ls":
      return { summary: path ?? "/", path: name === "ls" ? undefined : path };
    case "find":
      return { summary: args?.pattern ?? "all files" };
    case "grep":
      return { summary: `${args?.pattern ?? ""}${args?.glob ? `  in ${args.glob}` : ""}` };
    case "run_python": {
      if (path) return { summary: path, path };
      const first = String(args?.code ?? "").split("\n").find((l: string) => l.trim() && !l.trim().startsWith("#")) ?? "";
      return { summary: first.trim().slice(0, 80) };
    }
    case "check":
    case "format":
      return { summary: Array.isArray(args?.paths) && args.paths.length ? args.paths.join(", ") : "all Python files" };
    case "ide_state":
      return { summary: "" };
    case "ide_open":
    case "ide_close":
    case "ide_lint":
    case "ide_format":
      return { summary: path ?? "the active file", path };
    default:
      return { summary: JSON.stringify(args ?? {}).slice(0, 80) };
  }
}

function buildItems(view: ConversationView): { items: Item[]; busy: boolean; status: string | null } {
  const items: Item[] = [];
  const tools = new Map<string, Item>();
  const addAssistant = (id: string, message: any, streaming: boolean) => {
    const content = Array.isArray(message?.content) ? message.content : [];
    const text = content.filter((c: any) => c.type === "text").map((c: any) => c.text).join("");
    const thinking = content.filter((c: any) => c.type === "thinking").map((c: any) => c.thinking).join("");
    if (text || thinking || streaming) items.push({ id, kind: "assistant", text, thinking: thinking || undefined, streaming: streaming || undefined });
    for (const c of content) {
      if (c.type !== "toolCall") continue;
      const { summary, path } = summarize(c.name, c.arguments);
      const item: Item = { id: c.id, kind: "tool", text: "", tool: c.name, summary, path, status: "pending", ide: IDE_TOOLS.has(c.name) || undefined };
      if (c.name === "ide_open" && typeof c.arguments?.line === "number") item.line = c.arguments.line;
      tools.set(c.id, item);
      items.push(item);
    }
    if ((message?.stopReason === "error" || message?.stopReason === "aborted") && !streaming) {
      items.push({ id: `${id}:error`, kind: "error", text: message.stopReason === "aborted" ? "Stopped." : (message.errorMessage ?? "The model failed.") });
    }
  };
  for (const entry of view.entries) {
    const m: any = entry.model?.[0];
    switch (entry.kind) {
      case "pi.user":
        items.push({ id: String(entry.id), kind: "user", text: contentText(m?.content) });
        break;
      case USER_ENTRY: {
        const data: any = entry.data ?? {};
        items.push({ id: String(entry.id), kind: "user", text: String(data.text ?? ""), path: data.file ?? undefined, line: data.line ?? undefined });
        break;
      }
      case IDE_ENTRY: {
        const data: any = entry.data ?? {};
        items.push({ id: String(entry.id), kind: "context", text: data.file ? "" : "No file open", path: data.file ?? undefined, line: data.line ?? undefined });
        break;
      }
      case "pi.assistant":
        addAssistant(String(entry.id), m, false);
        break;
      case "pi.tool-result": {
        const item = m && tools.get(m.toolCallId);
        if (!item) break;
        item.status = m.isError ? "error" : "done";
        const out = contentText(m.content);
        item.output = out.length > 6000 ? `${out.slice(0, 6000)}\n…` : out;
        // IDE tools show their message as one line: without the harness's wrapper around errors.
        if (item.ide) item.text = out.replace(/^<\/?harness>$/gm, "").replace(/^\[(error|warning)\] /gm, "").trim();
        item.images = (m.content ?? []).filter((c: any) => c.type === "image").length || undefined;
        const details = m.details ?? {};
        if (typeof details.diff === "string") item.diff = details.diff;
        else if (typeof details.patch === "string" && details.patch) item.diff = details.patch;
        if (typeof details.firstChangedLine === "number") item.line = details.firstChangedLine;
        break;
      }
      case "pi.compaction":
        items.push({ id: String(entry.id), kind: "note", text: "Earlier messages were summarized to save space." });
        break;
      case "pi.reset":
        items.push({ id: String(entry.id), kind: "note", text: "New context." });
        break;
    }
  }
  const live: any = view.docs["pi.live"] ?? {};
  if (live.generation?.message) addAssistant("live", live.generation.message, true);
  for (const slot of live.tools ?? []) {
    const item = tools.get(slot.callId);
    if (!item || item.status === "done" || item.status === "error") continue;
    item.status = slot.status === "pending" ? "pending" : "running";
    if (slot.output) item.output = slot.output.length > 6000 ? `…${slot.output.slice(-6000)}` : slot.output;
  }
  const busy = !!live.run;
  let status: string | null = null;
  if (live.generation?.retry) status = `Retrying: ${String(live.generation.retry.error).slice(0, 200)}`;
  else if (live.compactions?.length) status = "Summarizing earlier messages…";
  else if (busy && !live.generation?.message && !(live.tools ?? []).some((t: any) => t.status === "running")) status = "Thinking…";
  return { items, busy, status };
}

/** The first line of the first message, for the conversation list. */
function titleFromText(text: string): string {
  const line = text.trim().split("\n")[0].trim();
  return line.length > 60 ? `${line.slice(0, 59).trimEnd()}…` : line;
}

function titleOf(view: ConversationView): string | null {
  for (const entry of view.entries) {
    if (entry.kind === USER_ENTRY) return titleFromText(String((entry.data as any)?.text ?? ""));
    if (entry.kind === "pi.user") return titleFromText(contentText((entry.model?.[0] as any)?.content));
  }
  return null;
}

// -- the service ----------------------------------------------------------------------

export class AgentService {
  readonly store = new KeychainCredentialStore();
  readonly models: MutableModels;
  private starting: Promise<Harness> | null = null;
  private indexing: Promise<ConversationIndex> | null = null;
  /** The conversation on screen; `project` is its folder, `root` the project the host asked for. */
  private current: { project: string; root: string; conversation: Conversation; view: AttachedReplicatedState<ConversationView> } | null = null;
  private error: string | null = null;
  private stateTimer: ReturnType<typeof setTimeout> | null = null;
  /** Whether the agent sheet is on screen (unread marks). */
  private visible = false;
  /** Conversations with live work, from the task graph. */
  private running = new Set<number>();
  /** A mid-turn IDE context entry not placed yet, per conversation, and the key the model had before it. */
  private pendingIDE = new Map<number, { submission: Submission; previous: string | null }>();
  private ideTimer: ReturnType<typeof setTimeout> | null = null;
  /** Scripted model for the self-test. */
  faux: FauxProviderHandle | null = null;

  constructor() {
    installProxyFetch();
    // No ambient credentials on iOS: no environment variables or files.
    this.models = createModels({ credentials: this.store, authContext: { env: async () => undefined, fileExists: async () => false } });
    for (const provider of [
      radiusProvider(),
      anthropicProvider(),
      openaiProvider(),
      openaiCodexProvider(),
      githubCopilotProvider(),
      googleProvider(),
      openrouterProvider(),
      xaiProvider(),
      mistralProvider(),
      groqProvider(),
      deepseekProvider(),
      kimiCodingProvider(),
      metaProvider(),
    ]) {
      this.models.setProvider(provider);
    }
  }

  start(): Promise<Harness> {
    this.starting ??= (async () => {
      const storage = await SqliteStorage.open(await BridgeSqlite.open("agent"));
      const registry = createRegistry();
      registry.install(Prompt);
      registry.install(ProjectTools);
      registry.install(IDETools);
      registry.install(DocsTools);
      const harness = await Harness.open(
        storage,
        {
          models: this.models,
          registry,
          env: (target) => (target.cwd === undefined ? undefined : this.env(target.cwd)),
          settings: {
            // A browser WebSocket cannot carry auth headers (OpenAI Codex prefers one).
            stream: { transport: "sse" },
            retry: { maxRetries: 4 },
            progress: { partialIntervalMs: 150, outputIntervalMs: 250 },
          },
          onReport: (report: unknown) => void call("log", `[agent] ${JSON.stringify(report).slice(0, 2000)}`).catch(() => {}),
        },
        ctx,
      );
      harness.resume(); // finish what the last page left running
      void this.refreshCatalogs();
      await this.followTasks(harness);
      ideHooks.seen = async (id, state) => void (await (await this.index()).setIDE(id, contextKey(state)));
      return harness;
    })();
    return this.starting;
  }

  private index(): Promise<ConversationIndex> {
    this.indexing ??= ConversationIndex.open();
    return this.indexing;
  }

  /** Which conversations are working; a run that ends counts as activity (and is unread when not on screen). */
  private async followTasks(harness: Harness) {
    const graph = await harness.taskGraph(ctx);
    const update = () => {
      const now = new Set<number>();
      for (const task of Object.values(graph.value?.tasks ?? {})) if (!task.background) now.add(Number(task.conversationId));
      const ended = [...this.running].filter((id) => !now.has(id));
      const changed = ended.length || [...now].some((id) => !this.running.has(id));
      this.running = now;
      if (ended.length) {
        void (async () => {
          const index = await this.index();
          for (const id of ended) {
            await index.touch(id);
            if (this.visible && this.currentId === id) await index.markSeen(id);
          }
          this.scheduleState();
        })();
      }
      if (changed) this.scheduleState();
    };
    graph.subscribe(update);
    update();
  }

  private get currentId(): number | null {
    return this.current ? Number(this.current.conversation.id) : null;
  }

  /** Fetch the model lists of signed-in providers whose catalogs live on their servers. */
  private async refreshCatalogs() {
    const signedIn = new Set((await this.store.list()).map((c) => c.providerId));
    const providers = DYNAMIC_CATALOGS.filter((id) => signedIn.has(id));
    if (!providers.length) return;
    await this.models.refresh({ providers, allowNetwork: true }).catch(() => {});
    this.scheduleState();
  }

  private env(project: string) {
    return new ProjectEnv({
      project,
      onWrite: (paths) => void call("files.changed", { paths }).catch(() => {}),
    });
  }

  // -- models and accounts ---------------------------------------------------------------

  /** Providers and how one signs in to them. */
  async accounts() {
    const stored = new Map((await this.store.list()).map((c) => [c.providerId, c.type]));
    return this.models
      .getProviders()
      .filter((p) => p.id !== "faux" && p.id !== "selftest")
      .map((p) => ({
        id: p.id,
        name: p.name,
        featured: p.id === FEATURED_PROVIDER,
        oauth: p.auth.oauth ? { name: p.auth.oauth.name, label: p.auth.oauth.loginLabel ?? null, subscription: !!p.auth.oauth.isSubscription } : null,
        apiKey: p.auth.apiKey?.login ? { name: p.auth.apiKey.name } : null,
        signedIn: stored.get(p.id) ?? null,
      }));
  }

  /** Chat models of the providers that have credentials. */
  async availableModels() {
    const out: { provider: string; providerName: string; id: string; name: string; reasoning: boolean }[] = [];
    for (const p of this.models.getProviders()) {
      if (!(await this.store.read(p.id)) && p.id !== "selftest") continue;
      for (const m of await this.models.getAvailable(p.id)) {
        out.push({ provider: p.id, providerName: p.name, id: m.id, name: m.name ?? m.id, reasoning: !!m.reasoning });
      }
    }
    return out;
  }

  private async defaultModel(preferred?: ModelRef | null): Promise<ModelRef | null> {
    const available = await this.availableModels();
    if (preferred && available.some((m) => m.provider === preferred.provider && m.id === preferred.modelId)) return preferred;
    // The featured provider's models first, then everyone else's.
    const featured = available.filter((m) => m.provider === FEATURED_PROVIDER);
    for (const pool of [featured, available]) {
      for (const re of PREFERRED) {
        const m = pool.find((x) => re.test(x.id));
        if (m) return { provider: m.provider, modelId: m.id };
      }
      if (pool[0]) return { provider: pool[0].provider, modelId: pool[0].id };
    }
    return null;
  }

  async login(providerId: string, type: AuthType) {
    this.error = null;
    await login(this.models, providerId, type);
    if (DYNAMIC_CATALOGS.includes(providerId)) await this.models.refresh({ providers: [providerId], allowNetwork: true, force: true }).catch(() => {});
    this.scheduleState();
    return true;
  }

  cancelLogin() {
    cancelLogin();
  }

  async logout(providerId: string) {
    await this.models.logout(providerId);
    this.scheduleState();
  }

  // -- conversations -----------------------------------------------------------------------

  /**
   * Show a conversation of the project: the one on screen when it belongs there, else the most
   * recent one, else a new one. Returns its ID.
   */
  async open(project: string, preferred?: ModelRef | null): Promise<number> {
    const harness = await this.start();
    const index = await this.index();
    const c = this.current;
    if (c && c.root === project) return Number(c.conversation.id);
    if (c && (await index.get(Number(c.conversation.id)))?.project === project) {
      c.root = project;
      this.scheduleState();
      return Number(c.conversation.id);
    }
    const row = await index.latest(project);
    const conversation = row && (await harness.conversation(row.id as unknown as ConversationId, ctx));
    if (!row || !conversation) return this.newConversation(project, preferred);
    await this.attach(row.project, project, conversation);
    return row.id;
  }

  /** A new conversation in the project (the one on screen when it has no messages yet). */
  async newConversation(project: string, preferred?: ModelRef | null): Promise<number> {
    const index = await this.index();
    const c = this.current;
    if (c && c.project === project && !(await index.get(Number(c.conversation.id)))?.title && !c.view.value?.entries.length) {
      c.root = project;
      this.scheduleState();
      return Number(c.conversation.id);
    }
    const model = (await this.currentModel()) ?? (await this.defaultModel(preferred));
    const harness = await this.start();
    const conversation = await harness.createConversation(
      { ownership: { kind: "ownerless" }, agent: { cwd: project, ...(model ? { model } : {}) } },
      ctx,
    );
    await index.add(Number(conversation.id), project);
    await this.attach(project, project, conversation);
    return Number(conversation.id);
  }

  /** Show another conversation of the list. */
  async switchTo(id: number) {
    const harness = await this.start();
    const row = await (await this.index()).get(id);
    const conversation = row && (await harness.conversation(id as unknown as ConversationId, ctx));
    if (!row || !conversation) return false;
    await this.attach(row.project, this.current?.root ?? row.project, conversation);
    return true;
  }

  async rename(id: number, title: string) {
    await (await this.index()).setTitle(id, title.trim().slice(0, 120) || null);
    this.scheduleState();
  }

  /** Archived conversations stay (D36): hidden from the start, listed apart, and they can come back. */
  async archive(id: number, archived: boolean) {
    const index = await this.index();
    await index.setArchived(id, archived);
    const c = this.current;
    if (archived && c && Number(c.conversation.id) === id) {
      const next = await index.latest(c.root);
      if (next) await this.switchTo(next.id);
      else await this.newConversation(c.root);
    }
    this.scheduleState();
  }

  /** Conversations the app knew before the index (project -> ID, D34) join it once. */
  async importConversations(map: Record<string, number>) {
    const harness = await this.start();
    const index = await this.index();
    let at = Date.now() - Object.keys(map).length * 1000;
    for (const [project, id] of Object.entries(map)) {
      at += 1000;
      if (await index.get(id)) continue;
      const conversation = await harness.conversation(id as unknown as ConversationId, ctx);
      if (!conversation) continue;
      const view = await conversation.viewState(ctx);
      const title = view.value ? titleOf(view.value) : null;
      view.dispose();
      await index.add(id, project, title, at);
    }
    this.scheduleState();
  }

  /** A folder was renamed or moved in the app: its conversations work there now. */
  async renamed(from: string, to: string) {
    const harness = await this.start();
    const rows = await (await this.index()).move(from, to);
    for (const row of rows) {
      const conversation = await harness.conversation(row.id as unknown as ConversationId, ctx);
      await conversation?.configure({ cwd: row.project }, ctx);
      const c = this.current;
      if (c && Number(c.conversation.id) === row.id) c.project = row.project;
    }
    const c = this.current;
    if (c && (c.root === from || c.root.startsWith(from + "/"))) c.root = to + c.root.slice(from.length);
    this.scheduleState();
  }

  /** The agent sheet appeared or went away. */
  async setVisible(visible: boolean) {
    this.visible = visible;
    const id = this.currentId;
    if (visible && id !== null) await (await this.index()).markSeen(id);
    this.scheduleState();
  }

  private async attach(project: string, root: string, conversation: Conversation) {
    if (this.current?.conversation.id === conversation.id) {
      this.current.root = root;
      return;
    }
    this.current?.view.dispose();
    const view = await conversation.viewState(ctx);
    this.current = { project, root, conversation, view };
    ideHooks.active = Number(conversation.id);
    this.error = null;
    view.subscribe(() => this.scheduleState());
    if (this.visible) await (await this.index()).markSeen(Number(conversation.id));
    this.scheduleState();
  }

  private async currentModel(): Promise<ModelRef | null> {
    const agent: any = this.current?.view.value?.docs["pi.agent"];
    const m = agent?.model;
    return m?.provider && m?.modelId ? { provider: m.provider, modelId: m.modelId } : null;
  }

  async setModel(provider: string, modelId: string) {
    if (!this.current) return;
    await this.current.conversation.configure({ model: { provider, modelId } }, ctx);
    this.scheduleState();
  }

  /** The IDE context the model has, after withdrawing a mid-turn entry that is still queued. */
  private async seenKey(id: number): Promise<string | null> {
    const index = await this.index();
    const pending = this.pendingIDE.get(id);
    this.pendingIDE.delete(id);
    if (pending && (await pending.submission.abort(ctx)) === "aborted") {
      await index.setIDE(id, pending.previous);
      return pending.previous;
    }
    return (await index.get(id))?.ide ?? null;
  }

  async submit(text: string, ide?: IDEState | null) {
    const c = this.current;
    if (!c || !text.trim()) return;
    this.error = null;
    let model = await this.currentModel();
    if (!model) {
      model = await this.defaultModel();
      if (!model) {
        this.error = "Sign in to a model provider first (Accounts).";
        return this.scheduleState();
      }
      await c.conversation.configure({ model }, ctx);
    }
    const id = Number(c.conversation.id);
    const index = await this.index();
    // The model reads the IDE context before the message when it changed; the transcript keeps them apart.
    const key = contextKey(ide);
    const changed = !!ide && key !== (await this.seenKey(id));
    const block = changed ? `${contextBlock(c.project, ide!)}\n\n` : "";
    const file = changed && ide!.file ? (projectPath(c.project, ide!.file) ?? ide!.file) : null;
    if (changed) await index.setIDE(id, key);
    const row = await index.get(id);
    if (!row) await index.add(id, c.project);
    if (!row?.title) await index.setTitle(id, titleFromText(text));
    await index.touch(id);
    await index.markSeen(id);
    const submission: Submission = await c.conversation.submit(
      {
        type: "input",
        content: block + text,
        entry: { kind: USER_ENTRY, data: { text, file, line: file ? (ide!.line ?? null) : null, selection: changed && !!ide!.selection?.text, error: changed && !!ide!.error } },
        requestId: crypto.randomUUID(),
      },
      ctx,
    );
    void submission.wait(ctx).then((settled) => {
      if (settled.status === "unanswered" && settled.reason !== "aborted") {
        const detail = settled.detail === undefined ? "" : `: ${typeof settled.detail === "string" ? settled.detail : JSON.stringify(settled.detail)}`;
        this.error = `${settled.reason.replace(/_/g, " ")}${detail}`.slice(0, 600);
        this.scheduleState();
      }
    });
  }

  /**
   * The user moved in the IDE (another file, tabs) while the conversation on screen works: the
   * model hears about it at the next boundary, unless it already knows (D36).
   */
  ideChanged(_state?: IDEState) {
    if (this.ideTimer) clearTimeout(this.ideTimer);
    this.ideTimer = setTimeout(() => {
      this.ideTimer = null;
      // What an IDE tool changed is in its result; look again after it.
      if (ideHooks.inFlight) return this.ideChanged();
      void this.injectIDE().catch((e) => call("log", `[agent] ide context: ${e}`).catch(() => {}));
    }, 400);
  }

  private async injectIDE() {
    const c = this.current;
    const live: any = c?.view.value?.docs["pi.live"];
    if (!c || !live?.run) return; // idle: the next message carries it
    const state = await call<IDEState>("ide", { method: "state" }); // settled since the host noticed
    const id = Number(c.conversation.id);
    const key = contextKey(state);
    const previous = await this.seenKey(id);
    if (key === previous) return;
    await (await this.index()).setIDE(id, key);
    const file = state.file ? (projectPath(c.project, state.file) ?? state.file) : null;
    const submission = await c.conversation.submit(
      {
        type: "write",
        entry: {
          kind: IDE_ENTRY,
          data: { file, line: state.line ?? null },
          model: [{ role: "user", content: contextBlock(c.project, state), timestamp: Date.now() }],
        },
      },
      ctx,
    );
    this.pendingIDE.set(id, { submission, previous });
    void submission.wait(ctx).then(() => {
      if (this.pendingIDE.get(id)?.submission === submission) this.pendingIDE.delete(id);
    });
  }

  async abort() {
    await this.current?.conversation.abort(ctx);
  }

  // -- state for the host ---------------------------------------------------------------

  private scheduleState() {
    if (this.stateTimer) return;
    this.stateTimer = setTimeout(() => {
      this.stateTimer = null;
      void this.sendState();
    }, 60);
  }

  async state() {
    const c = this.current;
    const value = c?.view.value;
    const built = value ? buildItems(value) : { items: [], busy: false, status: null };
    const ref = await this.currentModel();
    const model: Model<any> | undefined = ref ? this.models.getModel(ref.provider, ref.modelId) : undefined;
    const rows = c ? await (await this.index()).list(c.root) : [];
    const currentId = this.currentId;
    const conversations = rows
      .filter((r) => r.title || r.id === currentId)
      .map((r) => ({
        id: r.id,
        title: r.title,
        project: r.project,
        updated: r.updated,
        archived: r.archived,
        running: this.running.has(r.id),
        unread: r.id !== currentId && r.updated > r.seen,
      }));
    return {
      project: c?.project ?? null,
      root: c?.root ?? null,
      conversationId: currentId,
      conversations,
      items: built.items,
      busy: built.busy,
      status: built.status,
      error: this.error,
      model: ref ? { provider: ref.provider, id: ref.modelId, name: model?.name ?? ref.modelId } : null,
      signedIn: (await this.store.list()).length > 0 || !!this.faux,
    };
  }

  private async sendState() {
    try {
      await call("agent.state", { json: JSON.stringify(await this.state()) });
    } catch {
      // the host is not listening yet
    }
  }

  // -- self-test ------------------------------------------------------------------------------

  /** A scripted model (pi-ai's faux provider, as "selftest") for the self-test. */
  useFaux(): FauxProviderHandle {
    if (!this.faux) {
      this.faux = fauxProvider({ provider: "selftest" });
      this.models.setProvider(this.faux.provider);
    }
    return this.faux;
  }
}

export const agent = new AgentService();
