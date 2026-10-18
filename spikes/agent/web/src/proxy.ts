// Provider HTTP goes through the host's /__http proxy (D25): no CORS, and
// streaming. Headers fetch refuses to send (User-Agent, which pi-ai sets on
// every request, e.g. `claude-cli/…` for Anthropic subscriptions) are read
// from the call before WebKit sees them and travel in X-Terrarium-Headers.
// Requests carry the launch token, for the spike's host-side key injection
// (D32; the mock steps use it).
const PROXY = new URL("/__http", location.href).href;

/** Headers fetch may not set; the proxy sets them from X-Terrarium-Headers. */
const FORBIDDEN = new Set(["user-agent", "cookie", "referer", "origin"]);
/** Headers that describe our hop, never forwarded. */
const HOP = new Set(["host", "connection", "accept-encoding", "content-length"]);

/** fetch before the patch (the credential check uses it to call the proxy without the token). */
export const rawFetch = globalThis.fetch.bind(globalThis);

function entries(headers: HeadersInit | undefined): [string, string][] {
  if (!headers) return [];
  if (headers instanceof Headers) return [...headers.entries()];
  if (Array.isArray(headers)) return headers.map(([k, v]) => [k, v]);
  return Object.entries(headers).filter(([, v]) => v !== undefined && v !== null) as [string, string][];
}

export function installProxyFetch(token: string) {
  const original = rawFetch;
  globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const raw = entries(init?.headers ?? (input instanceof Request ? input.headers : undefined));
    const request = new Request(input, init);
    const url = new URL(request.url);
    if (!(url.protocol === "http:" || url.protocol === "https:")) return original(request);
    const headers = new Headers();
    request.headers.forEach((value, name) => {
      if (!FORBIDDEN.has(name) && !HOP.has(name)) headers.set(name, value);
    });
    const hidden: Record<string, string> = {};
    for (const [name, value] of raw) if (FORBIDDEN.has(name.toLowerCase())) hidden[name.toLowerCase()] = String(value);
    if (Object.keys(hidden).length) headers.set("X-Terrarium-Headers", JSON.stringify(hidden));
    headers.set("X-Terrarium-Token", token);
    const body = request.method === "GET" || request.method === "HEAD" ? undefined : await request.arrayBuffer();
    return original(`${PROXY}?url=${encodeURIComponent(url.href)}`, { method: request.method, headers, body, signal: request.signal });
  };
}
