import { timingSafeEqual } from "node:crypto";
import { constants } from "node:fs";
import { createServer } from "node:http";
import { access, mkdir } from "node:fs/promises";
import { dirname } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { Readable } from "node:stream";
import { createSemanticEngine } from "../src/semantic.js";

import { applyMigrations, authConfig, createAuth } from "../src/auth.js";

const config = authConfig(process.env);
const host = process.env.HOST || "127.0.0.1";
const authToken = (process.env.PREVIEW_AUTH_TOKEN || "").trim();
if (!config && host !== "127.0.0.1" && host !== "::1" && host !== "localhost" && !authToken) {
  console.error("Refusing to bind non-loopback host without PREVIEW_AUTH_TOKEN");
  process.exit(1);
}

const dbPath = process.env.SQLITE_PATH || ":memory:";
if (!dbPath.startsWith("file:") && dbPath !== ":memory:") await mkdir(dirname(dbPath), { recursive: true });
const database = new DatabaseSync(dbPath);
database.exec("PRAGMA busy_timeout = 5000;");
const mainFile = database.prepare("PRAGMA database_list").all().find(row => row.name === "main")?.file;
if (config && !mainFile) throw new Error("OAuth requires a persistent SQLite database");
if (mainFile) database.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;");
if (process.env.SKIP_BUILD !== "1") {
  const canBuild = await access(new URL("../", import.meta.url), constants.W_OK)
    .then(() => access(new URL("../dist/", import.meta.url), constants.W_OK))
    .then(() => true, error => {
      if (error.code === "ENOENT") return true;
      if (["EACCES", "EPERM", "EROFS"].includes(error.code)) return false;
      throw error;
    });
  if (canBuild) await import("./build.mjs");
}
const { default: worker } = await import("../dist/server/index.js");
const auth = config && createAuth(database, config);
await applyMigrations(database);

const SEMANTIC = createSemanticEngine({
  database,
  env: { ...process.env, EMBEDDING_CACHE_DIR: process.env.EMBEDDING_CACHE_DIR || dirname(dbPath) + "/models" },
});

const DB = {
  prepare(sql) {
    return {
      bind(...values) {
        const statement = database.prepare(sql);
        const allRows = () => ({ results: statement.all(...values), success: true });
        return {
          allRows,
          async first() { return statement.get(...values) ?? null; },
          async all() { return allRows(); },
          async run() { return { success: true, meta: { changes: statement.run(...values).changes } }; },
        };
      },
    };
  },
  async batch(statements) {
    database.exec("BEGIN");
    try {
      const results = statements.map(statement => statement.allRows());
      database.exec("COMMIT");
      return results;
    } catch (error) {
      database.exec("ROLLBACK");
      throw error;
    }
  },
};

const env = { ...process.env, DB, SEMANTIC };
const server = createServer(async (incoming, outgoing) => {
  try {
    const headers = new Headers(incoming.headers);
    for (const key of [...headers.keys()]) {
      if (key.startsWith("oai-authenticated-")) headers.delete(key);
    }
    if (!auth && incoming.method === "GET" && incoming.url === "/api/auth/providers") {
      outgoing.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" })
        .end(JSON.stringify({ authMode: "legacy", inviteRequired: false, publicOrigin: "", providers: [] }));
      return;
    }
    if (!auth && authToken) {
      const authorization = incoming.headers.authorization || "";
      let token = "";
      if (/^Bearer /i.test(authorization)) token = authorization.slice(7);
      else if (/^Basic /i.test(authorization)) {
        const credentials = Buffer.from(authorization.slice(6), "base64").toString("utf8");
        const separator = credentials.indexOf(":");
        if (separator >= 0) token = credentials.slice(separator + 1);
      } else {
        const cookie = (incoming.headers.cookie || "").split(";")
          .map(value => value.trim()).find(value => value.startsWith("weiji_auth="));
        if (cookie) {
          try { token = decodeURIComponent(cookie.slice("weiji_auth=".length)); } catch {}
        }
      }
      const supplied = Buffer.from(token);
      const expected = Buffer.from(authToken);
      if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) {
        outgoing.writeHead(401, {
          "WWW-Authenticate": 'Basic realm="Weiji"',
          "Cache-Control": "no-store",
        }).end("Unauthorized");
        return;
      }
    }
    if (!auth) {
      headers.set("oai-authenticated-user-id", "local-preview");
      headers.set("oai-authenticated-user-email", "preview@example.invalid");
      headers.set("oai-authenticated-user-full-name", encodeURIComponent("预览账户"));
      headers.set("oai-authenticated-user-full-name-encoding", "percent-encoded-utf-8");
    }
    const origin = config?.origin || `http://${incoming.headers.host}`;
    // Use the HTTP request target as a path, not as a URL with its own origin.
    if (!incoming.url.startsWith("/")) {
      outgoing.writeHead(400).end("Invalid request target");
      return;
    }
    const url = new URL(origin + incoming.url);
    const hasBody = incoming.method !== "GET" && incoming.method !== "HEAD";
    const controller = new AbortController();
    outgoing.once("close", () => { if (!outgoing.writableFinished) controller.abort(); });
    const request = new Request(url, {
      method: incoming.method, headers, signal: controller.signal,
      ...(hasBody ? { body: Readable.toWeb(incoming), duplex: "half" } : {}),
    });
    const response = await auth?.handle(request, url, incoming.socket.remoteAddress) ?? await worker.fetch(request, env);
    if (controller.signal.aborted) return;
    const responseHeaders = Object.fromEntries(response.headers);
    const cookies = response.headers.getSetCookie();
    if (cookies.length) responseHeaders["set-cookie"] = cookies;
    outgoing.writeHead(response.status, responseHeaders);
    if (incoming.method === "HEAD") {
      await response.body?.cancel();
      outgoing.end();
    } else if (response.body) Readable.fromWeb(response.body).on("error", () => outgoing.destroy()).pipe(outgoing);
    else outgoing.end();
  } catch {
    if (outgoing.headersSent) outgoing.destroy();
    else if (auth) outgoing.writeHead(500, { "Content-Type": "application/json", "Cache-Control": "no-store" }).end(JSON.stringify({ error: "暂时无法完成操作，请稍后重试。" }));
    else outgoing.writeHead(500).end("Local preview error");
  }
});

const portIndex = process.argv.indexOf("--port");
const port = Number(process.env.PORT || (portIndex >= 0 && process.argv[portIndex + 1]) || 5173);
server.listen(port, host, () => {
  console.log(`Local preview ready on port ${server.address().port}`);
  const accounts = database.prepare("SELECT DISTINCT account FROM journal_notes").all();
  for (const { account } of accounts) setImmediate(() => SEMANTIC.syncAccount(account));
});
