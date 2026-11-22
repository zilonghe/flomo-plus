import { timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";
import { mkdir, readdir, readFile } from "node:fs/promises";
import { dirname } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { Readable } from "node:stream";
import { createSemanticEngine } from "../src/semantic.js";

const host = process.env.HOST || "127.0.0.1";
const authToken = (process.env.PREVIEW_AUTH_TOKEN || "").trim();
if (host !== "127.0.0.1" && host !== "::1" && host !== "localhost" && !authToken) {
  console.error("Refusing to bind non-loopback host without PREVIEW_AUTH_TOKEN");
  process.exit(1);
}

await import("./build.mjs");
const { default: worker } = await import("../dist/server/index.js");
const dbPath = process.env.SQLITE_PATH || ":memory:";
if (dbPath !== ":memory:") await mkdir(dirname(dbPath), { recursive: true });
const database = new DatabaseSync(dbPath);
if (dbPath !== ":memory:") database.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;");
database.exec("CREATE TABLE IF NOT EXISTS _migrations (name TEXT PRIMARY KEY)");
const appliedMigration = database.prepare("SELECT name FROM _migrations WHERE name = ?");
const recordMigration = database.prepare("INSERT OR IGNORE INTO _migrations (name) VALUES (?)");
// Adopt the legacy table without marking future migrations as applied.
if (database.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='journal_notes'").get()) {
  recordMigration.run("0000_journal_notes.sql");
}
const migrations = new URL("../drizzle/", import.meta.url);
for (const file of (await readdir(migrations)).filter(file => file.endsWith(".sql")).sort()) {
  if (appliedMigration.get(file)) continue;
  const sql = await readFile(new URL(file, migrations), "utf8");
  database.exec("BEGIN");
  try {
    database.exec(sql);
    recordMigration.run(file);
    database.exec("COMMIT");
  } catch (error) {
    database.exec("ROLLBACK");
    throw error;
  }
}

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
    if (authToken) {
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
    const headers = new Headers(incoming.headers);
    headers.set("oai-authenticated-user-id", "local-preview");
    headers.set("oai-authenticated-user-email", "preview@example.invalid");
    headers.set("oai-authenticated-user-full-name", encodeURIComponent("预览账户"));
    headers.set("oai-authenticated-user-full-name-encoding", "percent-encoded-utf-8");
    const url = new URL(incoming.url, `http://${incoming.headers.host}`);
    const hasBody = incoming.method !== "GET" && incoming.method !== "HEAD";
    const controller = new AbortController();
    outgoing.once("close", () => { if (!outgoing.writableFinished) controller.abort(); });
    const request = new Request(url, {
      method: incoming.method, headers, signal: controller.signal,
      ...(hasBody ? { body: Readable.toWeb(incoming), duplex: "half" } : {}),
    });
    const response = await worker.fetch(request, env);
    if (controller.signal.aborted) return;
    outgoing.writeHead(response.status, Object.fromEntries(response.headers));
    if (response.body) Readable.fromWeb(response.body).pipe(outgoing);
    else outgoing.end();
  } catch {
    outgoing.writeHead(500).end("Local preview error");
  }
});

const portIndex = process.argv.indexOf("--port");
const port = Number(process.env.PORT || (portIndex >= 0 && process.argv[portIndex + 1]) || 5173);
server.listen(port, host, () => {
  console.log(`Local preview ready on port ${port}`);
  const accounts = database.prepare("SELECT DISTINCT account FROM journal_notes").all();
  for (const { account } of accounts) setImmediate(() => SEMANTIC.syncAccount(account));
});
