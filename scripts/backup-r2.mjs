import { randomUUID } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { pipeline } from "node:stream/promises";
import { createGzip, createGunzip } from "node:zlib";

import { createS3Client, parseForcePathStyle } from "../src/s3.js";

function required(env, name) {
  const value = env[name]?.trim();
  if (!value) throw new Error(`Set ${name}`);
  return value;
}

function storage(env) {
  return createS3Client({
    endpoint: required(env, "BACKUP_S3_ENDPOINT"),
    bucket: required(env, "BACKUP_S3_BUCKET"),
    region: required(env, "BACKUP_S3_REGION"),
    accessKeyId: required(env, "BACKUP_S3_ACCESS_KEY_ID"),
    secretAccessKey: required(env, "BACKUP_S3_SECRET_ACCESS_KEY"),
    forcePathStyle: parseForcePathStyle(env.BACKUP_S3_FORCE_PATH_STYLE),
  });
}

async function prune(s3, prefix, days) {
  if (!days) return 0;
  const cutoff = Date.now() - days * 86_400_000;
  // Read and validate every page before the first delete.
  const expired = new Set((await s3.listObjects(prefix))
    .filter(({ key, lastModified }) => key.startsWith(prefix) && key.endsWith(".db.gz") && Date.parse(lastModified) < cutoff)
    .map(({ key }) => key));
  for (const key of expired) await s3.deleteObject(key);
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

async function verifyRemote(s3, key, dir) {
  const file = join(dir, "remote.db.gz");
  const database = join(dir, "remote.db");
  await s3.getObjectToFile(key, file);
  await pipeline(createReadStream(file), createGunzip(), createWriteStream(database));
  return verify(database);
}

const temp = await mkdtemp(join(tmpdir(), "weiji-backup-"));
try {
  const snapshot = join(temp, "snapshot.db");
  const args = process.argv.slice(2);
  if (args[0] === "--verify" && args.length === 2) {
    await pipeline(createReadStream(args[1]), createGunzip(), createWriteStream(snapshot));
    console.log(`BACKUP_VERIFY_OK journal_notes=${verify(snapshot)}`);
  } else if (args[0] === "--verify-remote" && args.length === 2) {
    const notes = await verifyRemote(storage(process.env), args[1], temp);
    console.log(`BACKUP_VERIFY_REMOTE_OK key=${args[1]} journal_notes=${notes}`);
  } else {
    const verifyUploaded = (args[0] === "--verify-uploaded" && args.length === 1) ||
      (!args.length && process.env.BACKUP_VERIFY_UPLOADED === "1");
    if (args.length && !verifyUploaded) {
      throw new Error("Usage: backup-r2.mjs [--verify file.db.gz | --verify-remote key | --verify-uploaded]");
    }
    const s3 = storage(process.env);
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
    const key = `${prefix}notes-${time}-${randomUUID()}.db.gz`;
    await s3.putObjectFile(key, file);
    if (verifyUploaded && await verifyRemote(s3, key, temp) !== notes) throw new Error("Remote backup note count mismatch");
    const pruned = await prune(s3, prefix, retention);
    console.log(`BACKUP_OK key=${key} journal_notes=${notes} pruned=${pruned}`);
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  await rm(temp, { recursive: true, force: true });
}
