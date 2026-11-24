import { createCipheriv, createDecipheriv, createHash, createHmac, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { isIP } from "node:net";

const minute = 60_000;
const day = 1440 * minute;
const iosCallback = "weiji://auth/callback";
const pkceString = /^[A-Za-z0-9_-]{43,128}$/;
const randomToken = () => randomBytes(32).toString("base64url");
const stamp = (offset = 0) => new Date(Date.now() + offset).toISOString();
export const digest = value => createHash("sha256").update(value).digest("hex");
const challenge = value => createHash("sha256").update(value).digest("base64url");
const equal = (a, b) => Buffer.byteLength(a) === Buffer.byteLength(b) && timingSafeEqual(Buffer.from(a), Buffer.from(b));

class AuthError extends Error {
  constructor(status, message, headers) {
    super(message);
    this.status = status;
    this.headers = headers;
  }
}
const reject = (status, message, headers) => { throw new AuthError(status, message, headers); };

export function immediate(db, action) {
  db.exec("BEGIN IMMEDIATE");
  try {
    const result = action();
    db.exec("COMMIT");
    return result;
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

export async function applyMigrations(db) {
  const directory = new URL("../drizzle/", import.meta.url);
  const names = (await readdir(directory)).filter(name => name.endsWith(".sql")).sort();
  const files = await Promise.all(names.map(async name => [name, await readFile(new URL(name, directory), "utf8")]));
  immediate(db, () => {
    db.exec("CREATE TABLE IF NOT EXISTS _migrations (name TEXT PRIMARY KEY)");
    const applied = db.prepare("SELECT name FROM _migrations WHERE name = ?");
    const record = db.prepare("INSERT OR IGNORE INTO _migrations (name) VALUES (?)");
    // Adopt existing legacy notes while still applying every later migration.
    if (db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'journal_notes'").get()) {
      record.run("0000_journal_notes.sql");
    }
    for (const [name, sql] of files) {
      if (applied.get(name)) continue;
      db.exec(sql);
      record.run(name);
    }
  });
}

export function createInvite(db, { maxUses = 1, days = null, note = null, createdBy = null } = {}) {
  if (!Number.isSafeInteger(maxUses) || maxUses < 1 || maxUses > 1_000_000 ||
      (days !== null && (!Number.isSafeInteger(days) || days < 1 || days > 36_500)) ||
      (note !== null && (typeof note !== "string" || note.length > 500))) {
    reject(400, "邀请码参数无效。");
  }
  const bytes = randomBytes(12);
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const chars = Array.from(bytes, byte => alphabet[byte & 31]).join("");
  const code = "WJ-" + chars.match(/.{4}/g).join("-");
  const codeHash = digest(code);
  const expiresAt = days === null ? null : stamp(days * day);
  db.prepare(`INSERT INTO auth_invites (code_hash, code_hint, note, max_uses, created_by, expires_at, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)`).run(codeHash, code.slice(-4), note, maxUses, createdBy, expiresAt, stamp());
  return { code, codeHash, expiresAt };
}

export function listInvites(db) {
  return db.prepare(`SELECT code_hash AS codeHash, code_hint AS codeHint, note, max_uses AS maxUses,
    used_count AS usedCount, expires_at AS expiresAt, revoked_at AS revokedAt, created_at AS createdAt
    FROM auth_invites ORDER BY created_at DESC`).all();
}

export function revokeInvite(db, codeHash) {
  return db.prepare("UPDATE auth_invites SET revoked_at = ? WHERE code_hash = ? AND revoked_at IS NULL")
    .run(stamp(), codeHash).changes > 0;
}

export function authConfig(env) {
  const definitions = {
    github: {
      name: "GitHub", scope: "read:user",
      authorize: new URL("/login/oauth/authorize", env.OAUTH_GITHUB_ORIGIN || "https://github.com"),
      token: new URL("/login/oauth/access_token", env.OAUTH_GITHUB_ORIGIN || "https://github.com"),
      profile: new URL("/user", env.OAUTH_GITHUB_API_ORIGIN || "https://api.github.com"),
    },
    google: {
      name: "Google", scope: "openid profile email",
      authorize: new URL("/o/oauth2/v2/auth", env.OAUTH_GOOGLE_AUTH_ORIGIN || "https://accounts.google.com"),
      token: new URL("/token", env.OAUTH_GOOGLE_TOKEN_ORIGIN || "https://oauth2.googleapis.com"),
      profile: new URL("/oauth2/v3/userinfo", env.OAUTH_GOOGLE_USERINFO_ORIGIN || "https://www.googleapis.com"),
    },
  };
  const providers = new Map();
  for (const [id, definition] of Object.entries(definitions)) {
    const clientID = env[id.toUpperCase() + "_CLIENT_ID"]?.trim();
    const secret = env[id.toUpperCase() + "_CLIENT_SECRET"]?.trim();
    if (clientID && secret) providers.set(id, { ...definition, id, clientID, secret });
  }
  if (env.AUTH_MODE && !["legacy", "oauth"].includes(env.AUTH_MODE)) throw new Error("Invalid AUTH_MODE");
  if (env.AUTH_MODE !== "oauth" && providers.size === 0) return null;
  if (!providers.size) throw new Error("AUTH_MODE=oauth requires complete provider credentials");
  const origin = env.PUBLIC_ORIGIN;
  let parsed;
  try { parsed = new URL(origin); } catch {}
  if (!parsed || parsed.origin !== origin ||
      !(parsed.protocol === "https:" || (parsed.protocol === "http:" && env.ALLOW_INSECURE_PUBLIC_ORIGIN === "1"))) {
    throw new Error("OAuth requires a valid HTTPS PUBLIC_ORIGIN without a trailing slash");
  }
  if (!env.SQLITE_PATH?.trim() || env.SQLITE_PATH === ":memory:") {
    throw new Error("OAuth requires a persistent SQLITE_PATH");
  }
  return { origin, providers, trustProxy: env.TRUST_PROXY === "1" };
}

const privateHeaders = {
  "Cache-Control": "no-store",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
};
function json(data, status = 200, headers) {
  const result = new Headers(headers);
  for (const [key, value] of Object.entries(privateHeaders)) result.set(key, value);
  return Response.json(data, { status, headers: result });
}
function page(title, content, status = 200) {
  return new Response(`<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title} · 微记</title><link rel="stylesheet" href="/styles.css">
<main class="auth-page"><h1>${title}</h1>${content}</main></html>`, {
    status,
    headers: {
      ...privateHeaders,
      "Referrer-Policy": "same-origin",
      "Content-Type": "text/html; charset=utf-8",
      "Content-Security-Policy": "default-src 'none'; style-src 'self'; form-action 'self' weiji:; base-uri 'none'; frame-ancestors 'none'",
    },
  });
}
function redirect(location, cookies = [], status = 302) {
  const headers = new Headers({ ...privateHeaders, Location: location });
  for (const cookie of cookies) headers.append("Set-Cookie", cookie);
  return new Response(null, { status, headers });
}
function cookieValue(request, name) {
  const item = request.headers.get("Cookie")?.split(";").find(part => part.trimStart().startsWith(name + "="));
  return item?.trim().slice(name.length + 1) || "";
}

async function fields(request, allowForm = false) {
  const type = request.headers.get("Content-Type")?.split(";")[0].trim().toLowerCase();
  if (type !== "application/json" && !(allowForm && type === "application/x-www-form-urlencoded")) reject(415, "请求格式不支持。");
  if (Number(request.headers.get("Content-Length")) > 8192) reject(413, "请求过长。");
  if (!request.body) reject(400, "请求缺少内容。");
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 8192) {
        void reader.cancel().catch(() => {});
        reject(413, "请求过长。");
      }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const text = Buffer.concat(chunks).toString("utf8");
  if (type !== "application/json") return Object.fromEntries(new URLSearchParams(text));
  let data;
  try { data = JSON.parse(text); } catch {}
  if (!data || typeof data !== "object" || Array.isArray(data)) reject(400, "请求内容无效。");
  return data;
}

// iOS needs the original client state on the final redirect; keep it sealed in SQLite.
function clientStateKey(provider) {
  return createHmac("sha256", provider.secret).update("weiji-ios-client-state:" + provider.id).digest();
}
function sealClientState(provider, state) {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", clientStateKey(provider), iv);
  const encrypted = Buffer.concat([cipher.update(state, "utf8"), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), encrypted]).toString("base64url");
}
function openClientState(provider, sealed) {
  try {
    const data = Buffer.from(sealed, "base64url");
    const decipher = createDecipheriv("aes-256-gcm", clientStateKey(provider), data.subarray(0, 12));
    decipher.setAuthTag(data.subarray(12, 28));
    return Buffer.concat([decipher.update(data.subarray(28)), decipher.final()]).toString("utf8");
  } catch {
    reject(400, "登录链接已失效，请重新登录。");
  }
}

export function createAuth(db, { origin, providers, trustProxy }) {
  const cookie = (name, value, path, ttl) =>
    `${name}=${value}; Path=${path}; HttpOnly; SameSite=Lax; Max-Age=${ttl / 1000}${origin.startsWith("https:") ? "; Secure" : ""}`;
  const inviteCookie = (value, ttl) => cookie("weiji_invite_ticket", value, "/auth", ttl);
  const nonceCookie = (value, ttl) => cookie("weiji_oauth_nonce", value, "/auth", ttl);
  const sessionCookie = (value, ttl) => cookie("weiji_session", value, "/", ttl);
  const webTTL = 30 * day;
  const windows = new Map();
  let sweepAt = 0;
  function rateLimit(request, route, socketIP) {
    const proxyIP = request.headers.get("X-Real-IP") || "";
    const loopback = ["127.0.0.1", "::1", "::ffff:127.0.0.1"].includes(socketIP);
    const ip = trustProxy && loopback && isIP(proxyIP) ? proxyIP : socketIP;
    const key = route + ":" + ip;
    const now = Date.now();
    if (now >= sweepAt) {
      for (const [oldKey, hits] of windows) if (hits.at(-1) <= now - minute) windows.delete(oldKey);
      db.prepare("DELETE FROM auth_oauth_states WHERE expires_at <= ?").run(stamp());
      sweepAt = now + minute;
    }
    const hits = (windows.get(key) || []).filter(time => time > now - minute);
    if (hits.length >= 12 || (!windows.has(key) && windows.size >= 20_000)) {
      reject(429, "操作太频繁，请稍后再试。", { "Retry-After": String(Math.ceil(((hits[0] ?? now) + minute - now) / 1000)) });
    }
    hits.push(now);
    windows.set(key, hits);
  }

  function checkOrigin(request) {
    if (request.headers.get("Origin") !== origin || request.headers.get("Sec-Fetch-Site") === "cross-site") {
      reject(403, "请在微记页面内提交此操作。");
    }
  }
  function saveState(purpose, payload, ttl, raw = randomToken()) {
    db.prepare("INSERT INTO auth_oauth_states (id, purpose, payload_json, expires_at) VALUES (?, ?, ?, ?)")
      .run(digest(raw), purpose, JSON.stringify(payload), stamp(ttl));
    return raw;
  }
  function readState(purpose, raw) {
    const id = digest(raw);
    const row = db.prepare(`SELECT payload_json FROM auth_oauth_states
      WHERE id = ? AND purpose = ? AND consumed_at IS NULL AND expires_at > ?`).get(id, purpose, stamp());
    return row ? { id, ...JSON.parse(row.payload_json) } : null;
  }
  function consumeState({ id }) {
    db.prepare("UPDATE auth_oauth_states SET consumed_at = ? WHERE id = ?").run(stamp(), id);
  }
  function userByID(id) {
    return db.prepare("SELECT id, role, name, email, status FROM auth_users WHERE id = ?").get(id);
  }
  function identity(provider, subject) {
    return db.prepare(`SELECT u.id, u.role, u.name, u.email, u.status FROM auth_identities i
      JOIN auth_users u ON u.id = i.user_id WHERE i.provider = ? AND i.subject = ?`).get(provider, subject);
  }
  function issueSession(userID, kind, label) {
    const sessionId = randomUUID();
    const token = randomToken();
    const expiresAt = stamp(kind === "ios" ? 90 * day : webTTL);
    const now = stamp();
    db.prepare(`INSERT INTO auth_sessions (id, user_id, token_hash, kind, label, created_at, last_used_at, expires_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)`).run(sessionId, userID, digest(token), kind, label, now, now, expiresAt);
    return { sessionId, token, expiresAt };
  }
  function appRedirect(params) {
    return iosCallback + "?" + new URLSearchParams(params);
  }
  function complete(user, flow, cookies = []) {
    const clientState = flow.client === "ios" ? openClientState(providers.get(flow.provider), flow.sealedClientState) : null;
    if (user.status !== "active") {
      if (clientState !== null) return redirect(appRedirect({ error: "account_disabled", state: clientState }), cookies);
      reject(403, "该账号已停用。");
    }
    if (flow.client === "ios") {
      const code = saveState("app_code", { userID: user.id, codeChallenge: flow.codeChallenge }, 2 * minute);
      return redirect(appRedirect({ code, state: clientState }), cookies);
    }
    const session = issueSession(user.id, "web", "浏览器");
    return redirect(origin + "/", [...cookies, sessionCookie(session.token, webTTL)]);
  }

  // Derive the upstream verifier from the transient state so neither needs to be stored in plaintext.
  const verifierFor = (provider, state) => createHmac("sha256", provider.secret).update("weiji-oauth:" + state).digest("base64url");
  const callbackFor = provider => `${origin}/auth/${provider.id}/callback`;
  function start(provider, query) {
    const client = query.get("client") ?? "web";
    const flow = { provider: provider.id, client };
    if (client === "ios") {
      flow.codeChallenge = query.get("code_challenge");
      const clientState = query.get("state");
      if (query.get("redirect_uri") !== iosCallback || !pkceString.test(flow.codeChallenge || "") ||
          !clientState || clientState.length > 256) reject(400, "iOS 登录参数无效。");
      flow.sealedClientState = sealClientState(provider, clientState);
    } else if (client !== "web") reject(400, "不支持的登录客户端。");
    const nonce = client === "web" ? randomToken() : null;
    if (nonce) flow.nonceHash = digest(nonce);
    const state = saveState("oauth_state", flow, 10 * minute);
    const target = new URL(provider.authorize);
    target.search = new URLSearchParams({
      client_id: provider.clientID, redirect_uri: callbackFor(provider), scope: provider.scope,
      response_type: "code", state, code_challenge: challenge(verifierFor(provider, state)), code_challenge_method: "S256",
    });
    return redirect(target.href, nonce ? [nonceCookie(nonce, 10 * minute)] : []);
  }

  async function providerJSON(url, options) {
    try {
      const response = await fetch(url, { ...options, redirect: "error", signal: AbortSignal.timeout(10_000) });
      if (response.ok) return await response.json();
    } catch {}
    reject(502, "登录服务暂不可用，请重试。");
  }
  async function callback(request, provider, query) {
    const state = query.get("state") || "";
    const code = query.get("code") || "";
    if (!state || !code) reject(400, "登录已取消或链接无效。");
    const flow = immediate(db, () => {
      const stored = readState("oauth_state", state);
      if (!stored || stored.provider !== provider.id) reject(400, "登录链接已失效。");
      if (stored.client === "web" && !equal(digest(cookieValue(request, "weiji_oauth_nonce")), stored.nonceHash)) {
        reject(403, "请在开始登录的浏览器中继续。");
      }
      consumeState(stored);
      return stored;
    });
    const token = await providerJSON(provider.token, {
      method: "POST",
      headers: { Accept: "application/json" },
      body: new URLSearchParams({
        client_id: provider.clientID, client_secret: provider.secret, code, redirect_uri: callbackFor(provider),
        grant_type: "authorization_code", code_verifier: verifierFor(provider, state),
      }),
    });
    if (typeof token?.access_token !== "string" || !token.access_token) reject(502, "登录服务未返回访问令牌。");
    const profile = await providerJSON(provider.profile, {
      headers: { Accept: "application/json", Authorization: `Bearer ${token.access_token}`, "User-Agent": "Weiji" },
    });
    const subject = provider.id === "github" && Number.isSafeInteger(profile?.id) && profile.id > 0
      ? String(profile.id) : provider.id === "google" ? profile?.sub : null;
    if (typeof subject !== "string" || !subject) reject(502, "登录服务未返回账号标识。");
    const cookies = flow.client === "web" ? [nonceCookie("", 0)] : [];
    return immediate(db, () => {
      const existing = identity(provider.id, subject);
      if (existing) return complete(existing, flow, cookies);
      const text = key => typeof profile[key] === "string" ? profile[key].slice(0, 2048) : null;
      const ticket = saveState("invite_ticket", {
        provider: provider.id, subject, client: flow.client, sealedClientState: flow.sealedClientState,
        codeChallenge: flow.codeChallenge, name: text("name"), email: text("email"),
        login: text("login"), avatar: text(provider.id === "github" ? "avatar_url" : "picture"),
      }, 15 * minute);
      return redirect(origin + "/auth/invite", [...cookies, inviteCookie(ticket, 15 * minute)]);
    });
  }

  function invitePage(message = "", status = 200) {
    return page("输入邀请码", `${message ? "<p role=alert>" + message + "</p>" : ""}
<form method="POST" action="/auth/invite/redeem"><label>邀请码 <input name="code" required maxlength="64" autocomplete="off" autocapitalize="characters"></label>
<button type="submit">继续</button></form>`, status);
  }
  async function redeem(request) {
    checkOrigin(request);
    const { code } = await fields(request, true);
    const rawTicket = cookieValue(request, "weiji_invite_ticket");
    return immediate(db, () => {
      const ticket = readState("invite_ticket", rawTicket);
      if (!ticket) reject(400, "登录链接已失效，请重新登录。");
      if (identity(ticket.provider, ticket.subject)) reject(409, "该账号已激活，请重新登录。");
      const now = stamp();
      const updated = typeof code === "string" && db.prepare(`UPDATE auth_invites SET used_count = used_count + 1
        WHERE code_hash = ? AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > ?) AND used_count < max_uses`)
        .run(digest(code.trim().toUpperCase()), now).changes;
      if (!updated) {
        const message = "邀请码无效、已用尽或已过期。";
        if (request.headers.get("Content-Type")?.startsWith("application/x-www-form-urlencoded")) return invitePage(message, 400);
        reject(400, message);
      }
      const id = randomUUID();
      db.prepare(`INSERT INTO auth_users (id, name, email, avatar_url, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)`)
        .run(id, ticket.name || ticket.login, ticket.email, ticket.avatar, now, now);
      db.prepare(`INSERT INTO auth_identities (provider, subject, user_id, email, login, created_at) VALUES (?, ?, ?, ?, ?, ?)`)
        .run(ticket.provider, ticket.subject, id, ticket.email, ticket.login, now);
      consumeState(ticket);
      return complete(userByID(id), ticket, [inviteCookie("", 0)]);
    });
  }
  async function exchange(request) {
    checkOrigin(request);
    const { code, codeVerifier, deviceLabel } = await fields(request);
    return immediate(db, () => {
      const state = typeof code === "string" && readState("app_code", code);
      if (!state || typeof codeVerifier !== "string" || !pkceString.test(codeVerifier) ||
          !equal(challenge(codeVerifier), state.codeChallenge)) reject(401, "登录凭证无效或已过期。");
      const user = userByID(state.userID);
      if (user?.status !== "active") reject(403, "该账号已停用。");
      consumeState(state);
      return json({ ...issueSession(user.id, "ios", typeof deviceLabel === "string" ? deviceLabel.slice(0, 120) : "iOS"),
        user: { id: user.id, name: user.name || user.email || "我的笔记", email: user.email || "", role: user.role } });
    });
  }

  function session(request) {
    const authorization = request.headers.get("Authorization");
    const token = authorization === null ? cookieValue(request, "weiji_session") : authorization.match(/^Bearer ([A-Za-z0-9_-]+)$/i)?.[1];
    if (!token) return null;
    const now = stamp();
    const row = db.prepare(`SELECT s.id AS sessionId, u.id, u.name, u.email, u.role, s.last_used_at
      FROM auth_sessions s JOIN auth_users u ON u.id = s.user_id
      WHERE s.token_hash = ? AND s.kind = ? AND s.revoked_at IS NULL AND s.expires_at > ? AND u.status = 'active'`)
      .get(digest(token), authorization === null ? "web" : "ios", now);
    if (row && row.last_used_at <= stamp(-minute)) {
      db.prepare("UPDATE auth_sessions SET last_used_at = ? WHERE id = ?").run(now, row.sessionId);
    }
    return row;
  }

  async function handle(request, url, socketIP) {
    const { pathname: path, searchParams: query } = url;
    const method = request.method;
    try {
      if (method === "GET" && path === "/api/auth/providers") {
        return json({ authMode: "oauth", inviteRequired: true, publicOrigin: origin,
          providers: Array.from(providers.values(), ({ id, name }) => ({ id, name })) });
      }
      const oauthRoute = path.match(/^\/auth\/([^/]+)\/(start|callback)$/);
      if (method === "GET" && oauthRoute) {
        const [, id, action] = oauthRoute;
        if (action === "start") rateLimit(request, "start", socketIP);
        const provider = providers.get(id);
        if (!provider) reject(404, "该登录方式未启用。");
        return action === "start" ? start(provider, query) : await callback(request, provider, query);
      }
      if (method === "GET" && path === "/auth/invite") {
        if (!readState("invite_ticket", cookieValue(request, "weiji_invite_ticket"))) reject(400, "登录链接已失效，请重新登录。");
        return invitePage();
      }
      if (method === "POST" && path === "/auth/invite/redeem") {
        rateLimit(request, "redeem", socketIP);
        return await redeem(request);
      }
      if (method === "POST" && path === "/api/auth/exchange") {
        rateLimit(request, "exchange", socketIP);
        return await exchange(request);
      }
      const current = session(request);
      if (!current && path.startsWith("/api/")) reject(401, "请先登录。");
      if (!current && path === "/connect" && (method === "GET" || method === "HEAD")) return redirect(`${origin}/`);
      if (!current && (path === "/" || path === "/login")) {
        return page("登录微记", '<nav>' + Array.from(providers.values(), ({ id, name }) =>
          `<a href="/auth/${id}/start">用 ${name} 登录</a>`).join("") + "</nav>");
      }
      if (path.startsWith("/api/auth/") || path.startsWith("/api/admin/")) {
        const expected = request.headers.get("X-Journal-Account");
        if (expected !== null && expected !== current.id) reject(403, "登录账号已变化，请重新登录。");
        if (method !== "GET") checkOrigin(request);
        if (path.startsWith("/api/admin/") && current.role !== "admin") reject(403, "仅管理员可以操作。");
        if (path === "/api/auth/sessions" && method === "GET") {
          const sessions = db.prepare(`SELECT id, kind, label, created_at AS createdAt, last_used_at AS lastUsedAt, expires_at AS expiresAt
            FROM auth_sessions WHERE user_id = ? AND revoked_at IS NULL AND expires_at > ? ORDER BY last_used_at DESC`).all(current.id, stamp());
          return json({ sessions: sessions.map(row => ({ ...row, current: row.id === current.sessionId })) });
        }
        const sessionID = path.match(/^\/api\/auth\/sessions\/([^/]+)$/)?.[1];
        const logout = path === "/api/auth/logout" && method === "POST";
        if ((sessionID && method === "DELETE") || logout) {
          const id = sessionID || current.sessionId;
          if (!db.prepare(`UPDATE auth_sessions SET revoked_at = ? WHERE id = ? AND user_id = ?
            AND revoked_at IS NULL AND expires_at > ?`).run(stamp(), id, current.id, stamp()).changes) reject(404, "找不到该会话。");
          const cookie = id === current.sessionId ? sessionCookie("", 0) : null;
          if (logout && request.headers.get("Accept")?.toLowerCase().includes("text/html")) {
            return redirect(`${origin}/`, [cookie], 303);
          }
          return json({ ok: true }, 200, cookie ? { "Set-Cookie": cookie } : undefined);
        }
        if (path === "/api/admin/invites" && method === "GET") return json({ invites: listInvites(db) });
        if (path === "/api/admin/invites" && method === "POST") {
          const { maxUses, days, note } = await fields(request);
          return json(createInvite(db, { maxUses, days, note, createdBy: current.id }), 201);
        }
        const codeHash = path.match(/^\/api\/admin\/invites\/([a-f0-9]{64})$/)?.[1];
        if (codeHash && method === "DELETE") {
          if (!revokeInvite(db, codeHash)) reject(404, "找不到有效邀请码。");
          return json({ ok: true });
        }
        reject(404, "这个操作不可用。");
      }
      if (current) {
        request.headers.set("oai-authenticated-user-id", current.id);
        request.headers.set("oai-authenticated-user-email", current.email || "");
        request.headers.set("oai-authenticated-user-full-name", encodeURIComponent(current.name || ""));
        request.headers.set("oai-authenticated-user-full-name-encoding", "percent-encoded-utf-8");
        request.headers.set("oai-authenticated-user-role", current.role);
        request.headers.set("oai-authenticated-auth-mode", "oauth");
      }
      return null;
    } catch (error) {
      if (!(error instanceof AuthError)) throw error;
      if (path.startsWith("/auth/") && !error.headers) {
        return page("无法继续登录", `<p>${error.message}</p><a href="/">返回登录</a>`, error.status);
      }
      return json({ error: error.message }, error.status, error.headers);
    }
  }

  return { handle };
}
