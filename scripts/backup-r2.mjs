import { createHash, createHmac, randomUUID } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { mkdtemp, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { pipeline } from "node:stream/promises";
import { createGzip, createGunzip } from "node:zlib";

const sha256 = value => createHash("sha256").update(value).digest("hex");
const hmac = (key, value) => createHmac("sha256", key).update(value).digest();
const encode = value => encodeURIComponent(value).replace(/[!'()*]/g, char => "%" + char.charCodeAt(0).toString(16).toUpperCase());
const compare = (a, b) => a < b ? -1 : a > b ? 1 : 0;

function required(env, name) {
  const value = env[name]?.trim();
  if (!value) throw new Error(`Set ${name}`);
  return value;
}

function storage(env) {
  const endpoint = new URL(required(env, "BACKUP_S3_ENDPOINT"));
  if (!["https:", "http:"].includes(endpoint.protocol) || endpoint.username || endpoint.password || endpoint.search || endpoint.hash) {
    throw new Error("Invalid backup endpoint");
  }
  if (endpoint.protocol === "http:" && !["localhost", "127.0.0.1", "[::1]"].includes(endpoint.hostname)) {
    throw new Error("Backup endpoint requires HTTPS");
  }
  const bucket = required(env, "BACKUP_S3_BUCKET");
  if (!/^[a-z0-9][a-z0-9.-]*[a-z0-9]$/.test(bucket)) throw new Error("Invalid bucket name");
  const region = required(env, "BACKUP_S3_REGION");
  const access = required(env, "BACKUP_S3_ACCESS_KEY_ID");
  const secret = required(env, "BACKUP_S3_SECRET_ACCESS_KEY");
  const base = endpoint.pathname.replace(/\/$/, "").split("/").map(s => encode(decodeURIComponent(s))).join("/") + "/" + encode(bucket);

  return async function request(method, { key, params = {}, file } = {}) {
    const uri = key === undefined ? base : base + "/" + key.split("/").map(encode).join("/");
    const query = Object.entries(params).map(([name, value]) => [encode(name), encode(value)])
      .sort(([a, av], [b, bv]) => compare(a, b) || compare(av, bv)).map(pair => pair.join("=")).join("&");
    const url = new URL(endpoint.origin + uri + (query ? "?" + query : ""));
    if (url.pathname !== uri) throw new Error("Unsafe object key path");
    const hash = createHash("sha256");
    if (file) for await (const chunk of createReadStream(file)) hash.update(chunk);
    const payloadHash = hash.digest("hex");
    const date = new Date().toISOString().replace(/[:-]|\.\d{3}/g, "");
    const short = date.slice(0, 8);
    const headers = { host: url.host, "x-amz-content-sha256": payloadHash, "x-amz-date": date };
    const signed = Object.keys(headers).join(";");
    const canonicalHeaders = Object.entries(headers).map(([name, value]) => `${name}:${value}\n`).join("");
    const canonical = [method, uri, query, canonicalHeaders, signed, payloadHash].join("\n");
    const scope = `${short}/${region}/s3/aws4_request`;
    const signingKey = hmac(hmac(hmac(hmac("AWS4" + secret, short), region), "s3"), "aws4_request");
    const signature = hmac(signingKey, ["AWS4-HMAC-SHA256", date, scope, sha256(canonical)].join("\n")).toString("hex");
    headers.authorization = `AWS4-HMAC-SHA256 Credential=${access}/${scope}, SignedHeaders=${signed}, Signature=${signature}`;
    if (file) headers["content-length"] = String((await stat(file)).size);
    const response = await fetch(url, {
      method, headers, redirect: "error", signal: AbortSignal.timeout(300_000),
      ...(file ? { body: createReadStream(file), duplex: "half" } : {}),
    });
    if (!response.ok) {
      await response.body?.cancel();
      throw new Error(`S3 ${method} failed with HTTP ${response.status}`);
    }
    return response.text();
  };
}

const xmlText = value => value.replace(/&(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);/g, (_, entity) => {
  const plain = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" }[entity];
  return plain ?? String.fromCodePoint(entity[1] === "x" ? parseInt(entity.slice(2), 16) : Number(entity.slice(1)));
});

async function prune(request, prefix, days) {
  if (!days) return 0;
  const cutoff = Date.now() - days * 86_400_000;
  const expired = new Set();
  const seenTokens = new Set();
  const params = { "list-type": "2", prefix, "encoding-type": "url" };
  while (true) {
    const xml = await request("GET", { params });
    if (!/<ListBucketResult(?:\s|>)/.test(xml)) throw new Error("Invalid S3 list response");
    const urlEncoded = /<EncodingType>url<\/EncodingType>/.test(xml);
    for (const [, item] of xml.matchAll(/<Contents>([\s\S]*?)<\/Contents>/g)) {
      const raw = item.match(/<Key>([\s\S]*?)<\/Key>/)?.[1];
      if (raw === undefined) continue;
      let key = xmlText(raw);
      if (urlEncoded) key = decodeURIComponent(key);
      const modified = Date.parse(item.match(/<LastModified>([^<]+)<\/LastModified>/)?.[1]);
      if (key.startsWith(prefix) && key.endsWith(".db.gz") && modified < cutoff) expired.add(key);
    }
    if (/<IsTruncated>false<\/IsTruncated>/.test(xml)) break;
    const token = xml.match(/<NextContinuationToken>([\s\S]+?)<\/NextContinuationToken>/)?.[1];
    if (!/<IsTruncated>true<\/IsTruncated>/.test(xml) || !token || seenTokens.has(token)) throw new Error("Invalid S3 pagination");
    seenTokens.add(token);
    params["continuation-token"] = xmlText(token);
  }
  for (const key of expired) await request("DELETE", { key });
  return expired.size;
}

function verify(path) {
  const db = new DatabaseSync(path, { readOnly: true });
  try {
    const results = db.prepare("PRAGMA integrity_check").all();
    if (results.length !== 1 || results[0].integrity_check !== "ok") throw new Error("SQLite integrity check failed");
    return db.prepare("SELECT COUNT(*) AS n FROM journal_notes").get().n;
  } finally { db.close(); }
}

const temp = await mkdtemp(join(tmpdir(), "weiji-backup-"));
try {
  const snapshot = join(temp, "snapshot.db");
  const args = process.argv.slice(2);
  if (args[0] === "--verify" && args.length === 2) {
    await pipeline(createReadStream(args[1]), createGunzip(), createWriteStream(snapshot));
    console.log(`BACKUP_VERIFY_OK journal_notes=${verify(snapshot)}`);
  } else {
    if (args.length) throw new Error("Usage: backup-r2.mjs [--verify file.db.gz]");
    const request = storage(process.env);
    const prefix = required(process.env, "BACKUP_S3_PREFIX");
    if (!prefix.endsWith("/") || prefix.startsWith("/") || prefix.split("/").some(s => s === "." || s === "..")) {
      throw new Error("BACKUP_S3_PREFIX must identify a nonempty directory ending in /");
    }
    const retention = Number(process.env.BACKUP_RETENTION_DAYS ?? 0);
    if (!Number.isSafeInteger(retention) || retention < 0) throw new Error("Invalid BACKUP_RETENTION_DAYS");
    const db = new DatabaseSync(required(process.env, "SQLITE_PATH"), { readOnly: true });
    try {
      db.exec("PRAGMA busy_timeout = 5000;");
      db.prepare("VACUUM INTO ?").run(snapshot);
    } finally { db.close(); }
    const notes = verify(snapshot);
    const file = snapshot + ".gz";
    await pipeline(createReadStream(snapshot), createGzip(), createWriteStream(file));
    const time = new Date().toISOString().replace(/[-:.]/g, "");
    await request("PUT", { key: `${prefix}notes-${time}-${randomUUID()}.db.gz`, file });
    const pruned = await prune(request, prefix, retention);
    console.log(`BACKUP_OK journal_notes=${notes} pruned=${pruned}`);
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  await rm(temp, { recursive: true, force: true });
}
