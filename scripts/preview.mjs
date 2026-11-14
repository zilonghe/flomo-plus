import { createServer } from "node:http";
import { readdir, readFile } from "node:fs/promises";
import { DatabaseSync } from "node:sqlite";
import { Readable } from "node:stream";

await import("./build.mjs");
const { default: worker } = await import("../dist/server/index.js");
const database = new DatabaseSync(":memory:");
const migrations = new URL("../drizzle/", import.meta.url);
for (const file of (await readdir(migrations)).filter(file => file.endsWith(".sql")).sort()) {
  database.exec(await readFile(new URL(file, migrations), "utf8"));
}

const DB = {
  prepare(sql) {
    return {
      bind(...values) {
        const statement = database.prepare(sql);
        return {
          async first() { return statement.get(...values) ?? null; },
          async all() { return { results: statement.all(...values), success: true }; },
          async run() { return { success: true, meta: { changes: statement.run(...values).changes } }; },
        };
      },
    };
  },
};

const server = createServer(async (incoming, outgoing) => {
  try {
    const headers = new Headers(incoming.headers);
    headers.set("oai-authenticated-user-id", "local-preview");
    headers.set("oai-authenticated-user-email", "preview@example.invalid");
    headers.set("oai-authenticated-user-full-name", encodeURIComponent("预览账户"));
    headers.set("oai-authenticated-user-full-name-encoding", "percent-encoded-utf-8");
    const url = new URL(incoming.url, `http://${incoming.headers.host}`);
    const hasBody = incoming.method !== "GET" && incoming.method !== "HEAD";
    const request = new Request(url, {
      method: incoming.method, headers,
      ...(hasBody ? { body: Readable.toWeb(incoming), duplex: "half" } : {}),
    });
    const response = await worker.fetch(request, { DB });
    outgoing.writeHead(response.status, Object.fromEntries(response.headers));
    if (response.body) Readable.fromWeb(response.body).pipe(outgoing);
    else outgoing.end();
  } catch {
    outgoing.writeHead(500).end("Local preview error");
  }
});

const portIndex = process.argv.indexOf("--port");
const port = Number(process.env.PORT || (portIndex >= 0 && process.argv[portIndex + 1]) || 5173);
server.listen(port, "0.0.0.0", () => console.log(`Local preview ready on port ${port}`));
