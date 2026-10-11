// ChatGPT (Codex) credentials for libfx agents. The engine sends Codex requests
// without credentials; this module adds them at the fetch edge, from the host's
// `credentials` callback, refreshing near expiry and once after a rejection.
// Credentials never enter the engine or a session's saved records.

export const chatgptIssuer = "https://auth.openai.com";
export const chatgptClientId = "app_EMoamEEZ73f0CkXaXp7hrann";

const codexOrigin = "https://chatgpt.com";
const codexPaths = new Set(["/backend-api/codex/responses", "/backend-api/codex/models"]);
const authClaim = "https://api.openai.com/auth";
const refreshSkewMs = 5 * 60 * 1000;
const maxRememberedCredentials = 256;
const maxTokenBytes = 64 * 1024;
const encoder = new TextEncoder();

/** True only for the exact Codex endpoints the engine calls. */
export function isCodexRequest(url) {
  let parsed;
  try { parsed = new URL(String(url)); } catch { return false; }
  return parsed.origin === codexOrigin && codexPaths.has(parsed.pathname);
}

function tokenString(value, name, required) {
  if (value === undefined && !required) return undefined;
  if (typeof value !== "string" || value.length === 0) {
    throw new TypeError(`ChatGPT credentials ${name} must be a non-empty string`);
  }
  if (encoder.encode(value).length > maxTokenBytes) {
    throw new RangeError(`ChatGPT credentials ${name} exceeds ${maxTokenBytes} bytes`);
  }
  return value;
}

/** The claims of a JWT, or null when it is not one. Does not verify it. */
export function jwtClaims(token) {
  const part = typeof token === "string" ? token.split(".")[1] : undefined;
  if (!part) return null;
  try {
    const base64 = part.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(part.length / 4) * 4, "=");
    const binary = atob(base64);
    const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
    const claims = JSON.parse(new TextDecoder().decode(bytes));
    return claims && typeof claims === "object" ? claims : null;
  } catch {
    return null;
  }
}

/**
 * Validates credentials from the host. The account id and expiry default to
 * the access token's own claims. Returns a new object.
 */
export function normalizeChatgptCredentials(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("credentials() must return { accessToken, refreshToken?, accountId?, expiresAt? }");
  }
  const accessToken = tokenString(value.accessToken, "accessToken", true);
  const refreshToken = tokenString(value.refreshToken, "refreshToken", false);
  const claims = jwtClaims(accessToken);
  const accountId = value.accountId === undefined
    ? claims?.[authClaim]?.chatgpt_account_id
    : tokenString(value.accountId, "accountId", true);
  if (typeof accountId !== "string" || accountId.length === 0) {
    throw new TypeError("ChatGPT credentials need an accountId; it was not in the access token");
  }
  let expiresAt = value.expiresAt;
  if (expiresAt === undefined && Number.isFinite(claims?.exp)) expiresAt = claims.exp * 1000;
  if (expiresAt !== undefined && !Number.isFinite(expiresAt)) {
    throw new TypeError("ChatGPT credentials expiresAt must be milliseconds since the epoch");
  }
  return { accessToken, ...(refreshToken === undefined ? {} : { refreshToken }), accountId, ...(expiresAt === undefined ? {} : { expiresAt }) };
}

/** True when the credentials can and should be refreshed before use. */
export function needsRefresh(credentials, nowMs) {
  return credentials.refreshToken !== undefined &&
    credentials.expiresAt !== undefined &&
    credentials.expiresAt - refreshSkewMs <= nowMs;
}

/**
 * Exchanges a refresh token at OpenAI. Keeps the old refresh token when the
 * response does not rotate it.
 */
export async function refreshChatgptCredentials(credentials, { fetch, signal } = {}) {
  if (credentials.refreshToken === undefined) throw new TypeError("ChatGPT credentials have no refreshToken");
  const doFetch = fetch ?? globalThis.fetch?.bind(globalThis);
  const response = await doFetch(`${chatgptIssuer}/oauth/token`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ client_id: chatgptClientId, grant_type: "refresh_token", refresh_token: credentials.refreshToken }),
    signal,
  });
  if (!response.ok) {
    await response.body?.cancel().catch(() => {});
    const error = new Error(`ChatGPT token refresh failed with HTTP ${response.status}`);
    error.code = "LIBFX_CHATGPT_REFRESH_FAILED";
    error.status = response.status;
    throw error;
  }
  const tokens = await response.json();
  const next = normalizeChatgptCredentials({
    accessToken: tokens.access_token,
    refreshToken: tokens.refresh_token ?? credentials.refreshToken,
    ...(Number.isFinite(tokens.expires_in) ? { expiresAt: Date.now() + tokens.expires_in * 1000 } : {}),
  });
  return next.accountId === credentials.accountId ? next : { ...next, accountId: credentials.accountId };
}

/**
 * The fetch edge for Codex requests. `credentials({ provider, sessionId })`
 * supplies credentials; `onCredentials(next, { provider, sessionId })` receives
 * refreshed ones, with the session whose request needed them, so the host can
 * save them.
 */
export function createChatgptAuthorizer({ credentials, onCredentials, fetch, now = Date.now }) {
  if (typeof credentials !== "function") throw new TypeError("provider \"codex\" needs a credentials() function");
  if (onCredentials !== undefined && typeof onCredentials !== "function") {
    throw new TypeError("onCredentials must be a function");
  }
  // Each access token the host supplied maps to the newest credentials refreshed
  // from it, so sessions on one account share a refresh and a host that has not
  // saved a rotation yet never spends the old refresh token twice.
  const descendants = new Map();
  const refreshing = new Map();

  const remember = (supplied, credentials) => {
    descendants.delete(supplied.accessToken);
    descendants.set(supplied.accessToken, credentials);
    if (descendants.size > maxRememberedCredentials) descendants.delete(descendants.keys().next().value);
  };

  const refresh = (supplied, credentials, sessionId, signal) => {
    const pending = refreshing.get(credentials.refreshToken);
    if (pending) return pending;
    const task = (async () => {
      const next = await refreshChatgptCredentials(credentials, { fetch, signal });
      remember(supplied, next);
      await onCredentials?.(next, { provider: "codex", sessionId });
      return next;
    })().finally(() => refreshing.delete(credentials.refreshToken));
    refreshing.set(credentials.refreshToken, task);
    return task;
  };

  const current = async (sessionId, signal) => {
    const supplied = normalizeChatgptCredentials(await credentials({ provider: "codex", sessionId }));
    const best = descendants.get(supplied.accessToken) ?? supplied;
    const used = needsRefresh(best, now()) ? await refresh(supplied, best, sessionId, signal) : best;
    return { supplied, used };
  };

  const withCredentials = (init, credentials) => {
    const headers = new Headers(init.headers);
    headers.set("authorization", `Bearer ${credentials.accessToken}`);
    headers.set("chatgpt-account-id", credentials.accountId);
    return { ...init, headers };
  };

  return {
    /** Sends one Codex request with credentials, refreshing once after a 401. */
    async fetch(hostFetch, input, init = {}) {
      const sessionId = new Headers(init.headers).get("session-id") || undefined;
      const { supplied, used } = await current(sessionId, init.signal);
      const response = await hostFetch(input, withCredentials(init, used));
      if (response.status !== 401 || used.refreshToken === undefined) return response;
      await response.body?.cancel().catch(() => {});
      const next = await refresh(supplied, used, sessionId, init.signal);
      return hostFetch(input, withCredentials(init, next));
    },
  };
}
